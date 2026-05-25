import Foundation

/// Transport-agnostic message bus interface that backs MobileRelayServer.
/// Real WebSocket sessions implement this; tests use an in-memory pair so
/// they can drive the server without touching `NWListener`.
public protocol RelayClientChannel: AnyObject, Sendable {
    var clientId: String { get }
    func deliver(_ frame: Data) async throws
    func disconnect(reason: String) async
}

/// MobileRelayServer — single-authority command router.
///
/// Responsibilities:
///   - Enforce single-authority: only one paired iPhone owns the session.
///   - Verify pairing codes through `MobileRelayPairing`.
///   - Route incoming commands through `RobotSafetyPort`.
///   - Emit telemetry, command responses, watchdog stop events.
///   - Run a heartbeat watchdog: if no heartbeat for `watchdogTimeoutMs`,
///     force a stop and emit `watchdog.stop`.
///
/// All public methods are safe to call from any context; the server runs
/// commands sequentially via a serial actor task so robot safety is
/// preserved even under contention.
public actor MobileRelayServer {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var macName: String
        public var macVersion: String
        public var heartbeatIntervalMs: Int
        public var watchdogTimeoutMs: Int
        public var ackTimeoutMs: Int
        public var pairingGraceMs: Int

        public init(macName: String = ProcessInfo.processInfo.hostName,
                    macVersion: String = "0.1.0",
                    heartbeatIntervalMs: Int = MobileRelayWireProtocol.heartbeatIntervalMs,
                    watchdogTimeoutMs: Int = MobileRelayWireProtocol.watchdogTimeoutMs,
                    ackTimeoutMs: Int = 1500,
                    pairingGraceMs: Int = 1000) {
            self.macName = macName
            self.macVersion = macVersion
            self.heartbeatIntervalMs = heartbeatIntervalMs
            self.watchdogTimeoutMs = watchdogTimeoutMs
            self.ackTimeoutMs = ackTimeoutMs
            self.pairingGraceMs = pairingGraceMs
        }
    }

    // MARK: - Battery gate threshold (V288-4 일관, defense-in-depth)
    //
    // 비유: 자동차 연료 게이지 0 → 시동 거부. iOS preflight 가 1차 방어선이지만
    // stale voltage 또는 spoofed 패킷 경우를 대비해 Mac 측에서 2차 검증한다.
    //
    // 기술: ARM 명령 수신 시 `batteryVoltage` 클로저로 Mac-side 최신 전압을 조회.
    // - voltage < 10.5V (armBatteryThreshold) → commandRejected reason "lowBattery"
    // - voltage == nil (측정 불가) → 보수 정책으로 reject
    // - voltage >= 10.5V → 정상 진행
    public static let armBatteryThreshold: Double = 10.5

    // MARK: - State

    private struct Session {
        let channel: RelayClientChannel
        let sessionId: String
        let deviceName: String
        let connectedAt: Date
        var lastHeartbeatAt: Date
        var activeCommandId: String?
    }

    private let configuration: Configuration
    private let pairing: MobileRelayPairing
    private let port: RobotSafetyPort
    private let clock: () -> Date
    private let harness: (any HarnessFacade)?
    /// Mac-side 최신 배터리 전압을 반환하는 클로저.
    /// nil → 전압 측정 불가 (보수 정책: ARM reject).
    private let batteryVoltage: @Sendable () async -> Double?
    private var session: Session?
    private var watchdogTask: Task<Void, Never>?
    /// **V291-11** — transport disconnect grace period timer.
    /// 1.5s 안에 새 hello 들어오면 cancel. 만료 시 stop + disarm + close.
    private var disconnectGraceTask: Task<Void, Never>?
    private var eventIdCounter: UInt64 = 0
    private var commandIdsSeen: Set<String> = []

    public init(configuration: Configuration = .init(),
                pairing: MobileRelayPairing,
                port: RobotSafetyPort,
                clock: @escaping () -> Date = Date.init,
                harness: (any HarnessFacade)? = nil,
                batteryVoltage: @escaping @Sendable () async -> Double? = { nil }) {
        self.configuration = configuration
        self.pairing = pairing
        self.port = port
        self.clock = clock
        // nil 이면 production 경로 — MobileRelayController 가 LiveHarness.shared 를
        // 명시 주입하므로 실제로 nil 상태로 사용되지 않음. 테스트는 항상 주입.
        self.harness = harness
        self.batteryVoltage = batteryVoltage
    }

    public func currentSessionId() -> String? { session?.sessionId }
    public func hasActiveSession() -> Bool { session != nil }
    /// P1-2 fix (truth-gap report, 2026-05-25): expose the paired iPhone's
    /// device name so the Mac toolbar chip can render `연결됨 — <iPhone>`
    /// while a session is owned. Returns nil when no session is active.
    public func currentDeviceName() -> String? { session?.deviceName }

    // MARK: - Transport callbacks

    /// Called by the transport when a new client opens the WebSocket.
    /// Returns after the welcome / rejection envelope has been delivered.
    public func handleClientConnected(_ channel: RelayClientChannel,
                                      handshake firstFrame: Data) async {
        do {
            let head = try RelayCodec.decoder.decode(RelayEnvelopeHead.self, from: firstFrame)
            guard head.type == InboundCommandType.sessionHello.rawValue else {
                try await sendSessionRejected(channel: channel, id: head.id,
                                              reason: "protocolMismatch",
                                              message: "first frame must be session.hello")
                await channel.disconnect(reason: "missingHello")
                return
            }
            let env = try RelayCodec.decoder.decode(RelayEnvelope<HelloPayload>.self,
                                                    from: firstFrame)
            try await acceptHello(channel: channel, hello: env)
        } catch {
            try? await sendSessionRejected(channel: channel, id: "evt_handshake_error",
                                           reason: "invalidPayload",
                                           message: String(describing: error))
            await channel.disconnect(reason: "invalidHello")
        }
    }

    public func handleClientFrame(_ data: Data, from channel: RelayClientChannel) async {
        guard let head = try? RelayCodec.decoder.decode(RelayEnvelopeHead.self, from: data) else {
            return
        }
        guard let session, session.channel.clientId == channel.clientId else {
            await respondRejected(channel: channel, id: head.id,
                                  reason: "alreadyOwned",
                                  message: "Session is owned by another client.")
            return
        }
        if commandIdsSeen.contains(head.id) {
            // duplicate — silently ignore
            return
        }
        commandIdsSeen.insert(head.id)
        if commandIdsSeen.count > 4096 {
            commandIdsSeen.removeAll(keepingCapacity: true)
        }
        switch head.type {
        case InboundCommandType.pilotHeartbeat.rawValue:
            await handleHeartbeat(data: data)
        case InboundCommandType.pilotArm.rawValue:
            await handleArm(data: data)
        case InboundCommandType.pilotDisarm.rawValue:
            await handleDisarm(data: data)
        case InboundCommandType.pilotEstop.rawValue:
            await handleEstop(data: data)
        case InboundCommandType.pilotMotion.rawValue:
            await handleMotion(data: data)
        case InboundCommandType.pilotWalk.rawValue:
            await handleWalk(data: data)
        case InboundCommandType.pilotStop.rawValue:
            await handleStop(data: data)
        case InboundCommandType.pilotHead.rawValue:
            await handleHead(data: data)
        case InboundCommandType.sessionGoodbye.rawValue:
            await closeSession(reason: "goodbye")
        default:
            await emitTransportWarning(kind: "unknownType",
                                       message: "Unknown message type: \(head.type)")
        }
    }

    /// **V291-11** — Transport disconnect 처리.
    ///
    /// 비유: Wi-Fi 깜빡일 때는 잠시 기다리고, 진짜 끊겼으면 안전 종료. 비행기 자동
    /// 조종 끊김 → 1.5초 대기 후 manual 전환과 동일 원리.
    ///
    /// 정책:
    /// - **active command 진행 중** (walk/motion): 즉시 stop — watchdog 500ms 보다
    ///   빨리 도착할 수 있는 transport 신호이므로 grace 없음.
    /// - **idle/armed**: 1.5초 grace 후 새 hello 오지 않으면 stop + disarm + ARM reset.
    public func handleClientDisconnected(_ channel: RelayClientChannel,
                                         reason: String) async {
        guard let session, session.channel.clientId == channel.clientId else { return }
        let hasActiveCommand = session.activeCommandId != nil

        if hasActiveCommand {
            // active 시 즉시 stop (watchdog 과 동일 정책)
            await performDisconnectStop(channel: channel, reason: reason,
                                        gracePeriodApplied: false)
        } else {
            // idle/armed 시 1.5s grace
            cancelDisconnectGraceTask()
            disconnectGraceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.performDisconnectStop(channel: channel, reason: reason,
                                                 gracePeriodApplied: true)
            }
        }
    }

    /// **V291-11** — disconnect grace timeout 후 실제 stop + disarm.
    /// active command 시 즉시 호출. idle 시 1.5s 후 호출.
    private func performDisconnectStop(channel: RelayClientChannel,
                                       reason: String,
                                       gracePeriodApplied: Bool) async {
        guard let session, session.channel.clientId == channel.clientId else { return }
        let durationSec = Int(clock().timeIntervalSince(session.connectedAt))
        _ = try? await port.sendStop(reason: "transportDisconnect")
        // **V291-11** — ARM 자동 reset. iPhone 재연결 시 mismatch 회피.
        _ = try? await port.disarm(reason: "transportTimeout")
        await emitWatchdogStop(reason: "transportDisconnect", lastHeartbeatAgeMs: nil)
        await emitTelemetry(.mobilePilotDisconnected, level: .info, actor: .system,
                            data: ["reason": AnyCodable(reason),
                                   "sessionDurationSec": AnyCodable(durationSec),
                                   "gracePeriodApplied": AnyCodable(gracePeriodApplied)])
        await closeSession(reason: reason)
    }

    /// **V291-11** — grace timer cancel. 재연결 또는 explicit close 시 호출.
    private func cancelDisconnectGraceTask() {
        disconnectGraceTask?.cancel()
        disconnectGraceTask = nil
    }

    // MARK: - Periodic emission

    public func broadcastTelemetry() async {
        guard let session else { return }
        let snapshot = await port.snapshot()
        await send(envelope: makeEnvelope(type: OutboundEventType.telemetryState.rawValue,
                                          payload: snapshot),
                   to: session.channel)
    }

    // MARK: - Internal helpers

    private func acceptHello(channel: RelayClientChannel,
                             hello: RelayEnvelope<HelloPayload>) async throws {
        // **V291-11** — 재연결 grace timer cancel. WiFi 깜빡임 후 정상 복귀 시
        // pending disconnect stop 을 회피.
        cancelDisconnectGraceTask()
        // single-authority check
        if let existing = session {
            if existing.channel.clientId == channel.clientId {
                // Reconnecting same client — refresh session.
                self.session = Session(channel: channel,
                                       sessionId: existing.sessionId,
                                       deviceName: hello.payload.deviceName,
                                       connectedAt: clock(),
                                       lastHeartbeatAt: clock(),
                                       activeCommandId: nil)
            } else {
                try await sendSessionRejected(channel: channel, id: hello.id,
                                              reason: "alreadyOwned",
                                              message: "Another iPhone is paired.")
                await channel.disconnect(reason: "alreadyOwned")
                return
            }
        }

        if hello.payload.protocolVersion != MobileRelayWireProtocol.version {
            try await sendSessionRejected(channel: channel, id: hello.id,
                                          reason: "protocolMismatch",
                                          message: "Server expects v\(MobileRelayWireProtocol.version)")
            await channel.disconnect(reason: "protocolMismatch")
            return
        }

        let outcome = pairing.validate(hello.payload.pairingCode, now: clock())
        switch outcome {
        case .ok:
            break
        case .mismatch(let remaining):
            try await sendSessionRejected(channel: channel, id: hello.id,
                                          reason: "pairingMismatch",
                                          message: "남은 시도 횟수: \(remaining)")
            await channel.disconnect(reason: "pairingMismatch")
            await emitTelemetry(.mobilePilotPairingRejected, level: .warn, actor: .system,
                                data: ["attemptsRemaining": AnyCodable(remaining),
                                       "reason": "pairingMismatch"])
            return
        case .locked(let until):
            let secs = Int(until.timeIntervalSince(clock()))
            try await sendSessionRejected(channel: channel, id: hello.id,
                                          reason: "pairingMismatch",
                                          message: "잠겨 있어요. \(secs)초 뒤 다시 시도하세요.")
            await channel.disconnect(reason: "pairingLocked")
            await emitTelemetry(.mobilePilotLockoutTriggered, level: .warn, actor: .system,
                                data: ["lockedUntil": AnyCodable(until.timeIntervalSince1970),
                                       "reason": "maxAttempts"])
            await emitTelemetry(.mobilePilotPairingRejected, level: .warn, actor: .system,
                                data: ["attemptsRemaining": AnyCodable(0),
                                       "reason": "pairingLocked"])
            return
        }

        // Accept
        let sessionId = makeSessionId()
        self.session = Session(channel: channel,
                               sessionId: sessionId,
                               deviceName: hello.payload.deviceName,
                               connectedAt: clock(),
                               lastHeartbeatAt: clock(),
                               activeCommandId: nil)
        commandIdsSeen.removeAll(keepingCapacity: true)

        let welcome = WelcomePayload(
            macName: configuration.macName,
            macVersion: configuration.macVersion,
            relayProtocolVersion: MobileRelayWireProtocol.version,
            sessionId: sessionId,
            heartbeatIntervalMs: configuration.heartbeatIntervalMs,
            watchdogTimeoutMs: configuration.watchdogTimeoutMs)
        await send(envelope: makeEnvelope(type: OutboundEventType.sessionWelcome.rawValue,
                                          payload: welcome),
                   to: channel)
        await emitLog(level: "info", category: "connection",
                      message: "Paired: \(hello.payload.deviceName)")
        await emitTelemetry(.mobilePilotPairingSuccess, level: .info, actor: .user,
                            data: ["deviceName": AnyCodable(hello.payload.deviceName),
                                   "sessionId": AnyCodable(sessionId)])
        await broadcastTelemetry()
        startWatchdog()
    }

    private func handleHeartbeat(data: Data) async {
        guard let session else { return }
        guard let env = try? RelayCodec.decoder.decode(RelayEnvelope<HeartbeatPayload>.self,
                                                       from: data) else { return }
        self.session?.lastHeartbeatAt = clock()
        self.session?.activeCommandId = env.payload.activeCommandId
        _ = session
    }

    private func handleArm(data: Data) async {
        guard let session,
              let env = try? RelayCodec.decoder.decode(RelayEnvelope<ArmPayload>.self,
                                                      from: data) else { return }
        let commandId = env.id

        // ── Battery gate (V291-10, defense-in-depth) ─────────────────────────
        // iOS preflight 가 1차 방어지만, stale/spoofed voltage 시나리오에 대비해
        // Mac 측에서 최신 전압을 재검증한다. 연료 게이지 0 = 시동 거부.
        let voltage = await batteryVoltage()
        if let v = voltage {
            if v < MobileRelayServer.armBatteryThreshold {
                let voltStr = String(format: "%.1f", v)
                let threshStr = String(format: "%.1f", MobileRelayServer.armBatteryThreshold)
                let msg = "배터리 \(voltStr) V — 임계(\(threshStr) V) 미만, 즉시 충전 필요"
                await sendCommandRejected(commandId: commandId, reason: "lowBattery",
                                          message: msg)
                await emitTelemetry(.mobilePilotCommandRejected, level: .warn, actor: .user,
                                    data: ["commandType": "arm",
                                           "commandId": AnyCodable(commandId),
                                           "reason": "lowBattery",
                                           "voltage": AnyCodable(v)])
                return
            }
        } else {
            // 전압 측정 불가 → 보수 정책: reject
            let threshStr = String(format: "%.1f", MobileRelayServer.armBatteryThreshold)
            let msg = "배터리 전압 측정 불가 — 임계(\(threshStr) V) 미만으로 간주, 즉시 충전 필요"
            await sendCommandRejected(commandId: commandId, reason: "lowBattery",
                                      message: msg)
            await emitTelemetry(.mobilePilotCommandRejected, level: .warn, actor: .user,
                                data: ["commandType": "arm",
                                       "commandId": AnyCodable(commandId),
                                       "reason": "lowBattery",
                                       "voltage": AnyCodable("nil")])
            return
        }
        // ─────────────────────────────────────────────────────────────────────

        await send(envelope: makeEnvelope(id: commandId,
                                          type: OutboundResponseType.commandAccepted.rawValue,
                                          payload: EmptyPayload()),
                   to: session.channel)
        do {
            let latency = try await port.arm(
                cradleConfirmed: env.payload.cradleConfirmed,
                operator: env.payload.operator_,
                progress: { [weak self] stage, progress in
                    await self?.emitArmingProgress(commandId: commandId,
                                                    stage: stage, progress: progress)
                })
            await sendCommandAck(commandId: commandId, latencyMs: latency)
            await emitLog(level: "info", category: "safety",
                          message: "ARM 완료", commandId: commandId)
            await emitTelemetry(.mobilePilotCommandAccepted, level: .info, actor: .user,
                                data: ["commandType": "arm",
                                       "commandId": AnyCodable(commandId),
                                       "latencyMs": AnyCodable(latency)])
            await broadcastTelemetry()
        } catch let RelayServerError.rejected(reason) {
            await sendCommandRejected(commandId: commandId, reason: reason,
                                      message: reason)
            await emitTelemetry(.mobilePilotCommandRejected, level: .warn, actor: .user,
                                data: ["commandType": "arm",
                                       "commandId": AnyCodable(commandId),
                                       "reason": AnyCodable(reason)])
        } catch {
            await sendCommandFailed(commandId: commandId,
                                    reason: "internalError",
                                    message: String(describing: error))
            await emitTelemetry(.mobilePilotCommandRejected, level: .error, actor: .user,
                                data: ["commandType": "arm",
                                       "commandId": AnyCodable(commandId),
                                       "reason": "internalError"])
        }
    }

    private func handleDisarm(data: Data) async {
        guard let session,
              let env = try? RelayCodec.decoder.decode(RelayEnvelope<DisarmPayload>.self,
                                                      from: data) else { return }
        _ = session
        do {
            let latency = try await port.disarm(reason: env.payload.reason)
            // P1-3 fix: DISARM clears watchdog tracking too.
            self.session?.activeCommandId = nil
            await sendCommandAck(commandId: env.id, latencyMs: latency)
            await broadcastTelemetry()
        } catch {
            await sendCommandFailed(commandId: env.id, reason: "internalError",
                                    message: String(describing: error))
        }
    }

    private func handleEstop(data: Data) async {
        guard let session,
              let env = try? RelayCodec.decoder.decode(RelayEnvelope<EStopPayload>.self,
                                                      from: data) else { return }
        _ = session
        // E-stop has priority: ack as soon as the safety chain reports done.
        do {
            let latency = try await port.emergencyStop(reason: env.payload.reason)
            // P1-3 fix: E-stop clears watchdog tracking.
            self.session?.activeCommandId = nil
            await sendCommandAck(commandId: env.id, latencyMs: latency)
            await emitLog(level: "warning", category: "safety",
                          message: "E-stop 실행 (\(env.payload.reason))",
                          commandId: env.id)
            await broadcastTelemetry()
        } catch {
            await sendCommandFailed(commandId: env.id, reason: "safetyAbort",
                                    message: String(describing: error))
            await emitLog(level: "error", category: "safety",
                          message: "E-stop 실패: \(error)",
                          commandId: env.id)
        }
    }

    /// Latency 를 측정하고 임계치 초과 시 commandRejected 를 반환한다.
    ///
    /// # 비유: 리모컨 버튼을 눌렀는데 1초 뒤에 TV가 반응하면?
    /// 이미 TV 화면을 못 보고 누른 셈이다 — 로봇이 지금 어디 있는지 모르는 상태에서
    /// 걷기 명령이 실행되면 넘어지거나 충돌할 수 있다.
    /// 네트워크 지연(iPhone→Mac end-to-end)이 임계치를 넘으면 명령을 거절해
    /// 오래된 의도가 실행되는 위험을 차단한다.
    ///
    /// - Parameters:
    ///   - env: 수신된 RelayEnvelope (sentAt 이 iPhone 전송 시각).
    ///   - thresholdMs: 허용 최대 latency (밀리초).
    ///   - commandType: 텔레메트리 로그용 명령 타입 문자열.
    /// - Returns: 게이트가 트리거됐으면 거절 사유 문자열, 통과면 nil.
    private func checkLatencyGate<P: Codable & Sendable>(
        env: RelayEnvelope<P>,
        thresholdMs: Int,
        commandType: String
    ) async -> String? {
        let now = clock()
        let rawLatencyMs = now.timeIntervalSince(env.sentAt) * 1000
        // 음수 latency = clock skew 의심 → 관대 정책으로 통과 (clamp to 0).
        // `.rounded()` 로 부동소수점 오차(예: 149.9999... → 150) 를 보정한다.
        let latencyMs = max(0.0, rawLatencyMs)
        let latencyMsRounded = Int(latencyMs.rounded())
        // 10초 초과 = clock skew 확실 → clockSkew 거절.
        if rawLatencyMs > 10_000 {
            await sendCommandRejected(commandId: env.id, reason: "clockSkew",
                                      message: "Envelope sentAt deviates > 10s from Mac clock.")
            await emitTelemetry(.mobilePilotCommandRejected, level: .warn, actor: .user,
                                data: ["commandType": AnyCodable(commandType),
                                       "commandId": AnyCodable(env.id),
                                       "reason": "clockSkew",
                                       "measuredLatencyMs": AnyCodable(latencyMsRounded)])
            return "clockSkew"
        }
        if latencyMsRounded >= thresholdMs {
            await sendCommandRejected(commandId: env.id, reason: "latencyGate",
                                      message: "Measured latency \(latencyMsRounded)ms >= \(thresholdMs)ms threshold.")
            await emitTelemetry(.mobilePilotCommandRejected, level: .warn, actor: .user,
                                data: ["commandType": AnyCodable(commandType),
                                       "commandId": AnyCodable(env.id),
                                       "reason": "latencyGate",
                                       "measuredLatencyMs": AnyCodable(latencyMsRounded)])
            return "latencyGate"
        }
        return nil
    }

    private func handleMotion(data: Data) async {
        guard let session,
              let env = try? RelayCodec.decoder.decode(RelayEnvelope<MotionPayload>.self,
                                                      from: data) else { return }
        let payload = env.payload
        _ = session
        // Latency gate: motion 은 200ms 초과 시 거절 (caution/highRisk 특성).
        if let _ = await checkLatencyGate(env: env, thresholdMs: 200, commandType: "motion") { return }
        // MVP-safe gate. P0-4 fix (truth-gap report, 2026-05-25): `bow` removed
        // — slot 41 is `talk2` long-chain per docs/motion-format/page-catalog-motion4096.md,
        // not bow. Re-add only after a verified slot mapping is confirmed.
        let allowedLabels: Set<String> = ["walkReady", "basicPosture", "sit", "greeting"]
        guard allowedLabels.contains(payload.label) else {
            await sendCommandRejected(commandId: env.id, reason: "riskNotConfirmed",
                                      message: "이 동작은 MVP에서 비활성화됐어요.")
            await emitTelemetry(.mobilePilotCommandRejected, level: .warn, actor: .user,
                                data: ["commandType": "motion",
                                       "commandId": AnyCodable(env.id),
                                       "reason": "riskNotConfirmed"])
            return
        }
        do {
            let latency = try await port.runMotion(slot: payload.slot,
                                                   label: payload.label,
                                                   confirmRisk: payload.confirmRisk)
            await sendCommandAck(commandId: env.id, latencyMs: latency)
            await emitTelemetry(.mobilePilotCommandAccepted, level: .info, actor: .user,
                                data: ["commandType": "motion",
                                       "commandId": AnyCodable(env.id),
                                       "latencyMs": AnyCodable(latency)])
        } catch let RelayServerError.rejected(reason) {
            await sendCommandRejected(commandId: env.id, reason: reason, message: nil)
            await emitTelemetry(.mobilePilotCommandRejected, level: .warn, actor: .user,
                                data: ["commandType": "motion",
                                       "commandId": AnyCodable(env.id),
                                       "reason": AnyCodable(reason)])
        } catch {
            await sendCommandFailed(commandId: env.id, reason: "internalError",
                                    message: String(describing: error))
            await emitTelemetry(.mobilePilotCommandRejected, level: .error, actor: .user,
                                data: ["commandType": "motion",
                                       "commandId": AnyCodable(env.id),
                                       "reason": "internalError"])
        }
    }

    private func handleWalk(data: Data) async {
        guard let session,
              let env = try? RelayCodec.decoder.decode(RelayEnvelope<WalkPayload>.self,
                                                      from: data) else { return }
        _ = session
        // Latency gate: walk 는 150ms 초과 시 거절.
        if let _ = await checkLatencyGate(env: env, thresholdMs: 150, commandType: "walk") { return }
        do {
            let result = try await port.sendWalk(payload: env.payload)
            // P1-3 fix (truth-gap report, 2026-05-25): track active walk
            // server-side so the watchdog can stop even if iOS heartbeat
            // never arrives. Stop preset / enabled=false → clear immediately.
            if env.payload.enabled && env.payload.preset != .stop {
                self.session?.activeCommandId = env.id
            } else {
                self.session?.activeCommandId = nil
            }
            await sendCommandAck(commandId: env.id, latencyMs: result.latencyMs,
                                 robotAckId: result.robotAckId)
            await emitTelemetry(.mobilePilotCommandAccepted, level: .info, actor: .user,
                                data: ["commandType": "walk",
                                       "commandId": AnyCodable(env.id),
                                       "latencyMs": AnyCodable(result.latencyMs)])
        } catch let RelayServerError.rejected(reason) {
            await sendCommandRejected(commandId: env.id, reason: reason, message: nil)
            await emitTelemetry(.mobilePilotCommandRejected, level: .warn, actor: .user,
                                data: ["commandType": "walk",
                                       "commandId": AnyCodable(env.id),
                                       "reason": AnyCodable(reason)])
        } catch {
            await sendCommandFailed(commandId: env.id, reason: "noAck",
                                    message: String(describing: error))
            await emitTelemetry(.mobilePilotCommandRejected, level: .error, actor: .user,
                                data: ["commandType": "walk",
                                       "commandId": AnyCodable(env.id),
                                       "reason": "noAck"])
        }
    }

    private func handleStop(data: Data) async {
        guard let session,
              let env = try? RelayCodec.decoder.decode(RelayEnvelope<StopPayload>.self,
                                                      from: data) else { return }
        _ = session
        do {
            let latency = try await port.sendStop(reason: env.payload.reason)
            // P1-3 fix: explicit stop clears watchdog tracking.
            self.session?.activeCommandId = nil
            await sendCommandAck(commandId: env.id, latencyMs: latency)
            await emitTelemetry(.mobilePilotCommandAccepted, level: .info, actor: .user,
                                data: ["commandType": "stop",
                                       "commandId": AnyCodable(env.id),
                                       "latencyMs": AnyCodable(latency)])
        } catch {
            await sendCommandFailed(commandId: env.id, reason: "internalError",
                                    message: String(describing: error))
            await emitTelemetry(.mobilePilotCommandRejected, level: .error, actor: .user,
                                data: ["commandType": "stop",
                                       "commandId": AnyCodable(env.id),
                                       "reason": "internalError"])
        }
    }

    private func handleHead(data: Data) async {
        guard let session,
              let env = try? RelayCodec.decoder.decode(RelayEnvelope<HeadPayload>.self,
                                                      from: data) else { return }
        _ = session
        do {
            let latency = try await port.setHead(payload: env.payload)
            await sendCommandAck(commandId: env.id, latencyMs: latency)
        } catch let RelayServerError.rejected(reason) {
            await sendCommandRejected(commandId: env.id, reason: reason, message: reason)
        } catch {
            await sendCommandFailed(commandId: env.id, reason: "internalError",
                                    message: String(describing: error))
        }
    }

    // MARK: - Send helpers

    private func sendCommandAck(commandId: String, latencyMs: Int,
                                robotAckId: String? = nil) async {
        guard let session else { return }
        await send(envelope: makeEnvelope(id: commandId,
                                          type: OutboundResponseType.commandAck.rawValue,
                                          payload: AckPayload(latencyMs: latencyMs,
                                                              robotAckId: robotAckId)),
                   to: session.channel)
    }

    private func sendCommandRejected(commandId: String, reason: String,
                                     message: String?) async {
        guard let session else { return }
        await send(envelope: makeEnvelope(id: commandId,
                                          type: OutboundResponseType.commandRejected.rawValue,
                                          payload: RejectedPayload(reason: reason, message: message)),
                   to: session.channel)
    }

    private func sendCommandFailed(commandId: String, reason: String,
                                   message: String?) async {
        guard let session else { return }
        await send(envelope: makeEnvelope(id: commandId,
                                          type: OutboundResponseType.commandFailed.rawValue,
                                          payload: FailedPayload(reason: reason,
                                                                 message: message,
                                                                 lastErrorAtMs: nil)),
                   to: session.channel)
    }

    private func respondRejected(channel: RelayClientChannel, id: String,
                                 reason: String, message: String) async {
        let env = makeEnvelope(id: id,
                               type: OutboundResponseType.commandRejected.rawValue,
                               payload: RejectedPayload(reason: reason, message: message))
        await send(envelope: env, to: channel)
    }

    private func sendSessionRejected(channel: RelayClientChannel, id: String,
                                     reason: String, message: String) async throws {
        let env = makeEnvelope(id: id,
                               type: OutboundEventType.sessionRejected.rawValue,
                               payload: SessionRejectedPayload(reason: reason, message: message))
        await send(envelope: env, to: channel)
    }

    private func emitArmingProgress(commandId: String, stage: String, progress: Double) async {
        guard let session else { return }
        await send(envelope: makeEnvelope(type: OutboundEventType.armingProgress.rawValue,
                                          payload: ArmingProgressPayload(commandId: commandId,
                                                                         stage: stage,
                                                                         progress: progress)),
                   to: session.channel)
    }

    private func emitWatchdogStop(reason: String, lastHeartbeatAgeMs: Int?) async {
        guard let session else { return }
        await send(envelope: makeEnvelope(type: OutboundEventType.watchdogStop.rawValue,
                                          payload: WatchdogStopPayload(reason: reason,
                                                                       lastHeartbeatAgeMs: lastHeartbeatAgeMs)),
                   to: session.channel)
    }

    private func emitTransportWarning(kind: String, message: String?) async {
        guard let session else { return }
        await send(envelope: makeEnvelope(type: OutboundEventType.transportWarning.rawValue,
                                          payload: TransportWarningPayload(kind: kind,
                                                                           latencyMs: nil,
                                                                           message: message)),
                   to: session.channel)
    }

    private func emitLog(level: String, category: String,
                         message: String, commandId: String? = nil) async {
        guard let session else { return }
        await send(envelope: makeEnvelope(type: OutboundEventType.logEvent.rawValue,
                                          payload: LogEventPayload(level: level,
                                                                   category: category,
                                                                   message: message,
                                                                   commandId: commandId)),
                   to: session.channel)
    }

    // MARK: - Telemetry emit (Harness bridge)

    /// Harness 에 TelemetryEvent 를 기록한다.
    /// MobileRelayServer 는 actor 격리, Harness 는 @MainActor 격리이므로
    /// `MainActor.run` 을 통해 hop 전환 후 기록.
    /// handleHeartbeat 는 100Hz noise 회피를 위해 emit 하지 않는다.
    private func emitTelemetry(_ kind: TelemetryKind,
                               level: TelemetryLevel,
                               actor telemetryActor: TelemetryActor,
                               data: [String: AnyCodable]) async {
        guard let harness else { return }
        await MainActor.run {
            harness.record(kind, level: level, actor: telemetryActor, data: data)
        }
    }

    private func send<P: Codable & Sendable>(envelope: RelayEnvelope<P>,
                                             to channel: RelayClientChannel) async {
        do {
            let data = try RelayCodec.encoder.encode(envelope)
            try await channel.deliver(data)
        } catch {
            // Drop session if delivery fails repeatedly. For now log it.
        }
    }

    // MARK: - Watchdog

    public func startWatchdog() {
        watchdogTask?.cancel()
        let timeoutMs = configuration.watchdogTimeoutMs
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMs / 2) * 1_000_000)
                await self?.tickWatchdog()
            }
        }
    }

    public func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func tickWatchdog() async {
        guard let session else { return }
        let ageSec = clock().timeIntervalSince(session.lastHeartbeatAt)
        let ageMs = Int(ageSec * 1000)
        if ageMs >= configuration.watchdogTimeoutMs {
            // Only force-stop if there was an active command (deadman walk / motion).
            if let activeId = session.activeCommandId {
                _ = try? await port.sendStop(reason: "heartbeatTimeout")
                self.session?.activeCommandId = nil
                await emitWatchdogStop(reason: "heartbeatTimeout",
                                       lastHeartbeatAgeMs: ageMs)
                await emitTelemetry(.mobilePilotWatchdogStop, level: .warn, actor: .system,
                                    data: ["lastHeartbeatAgeMs": AnyCodable(ageMs),
                                           "activeCommandId": AnyCodable(activeId)])
                await emitLog(level: "warning", category: "safety",
                              message: "Heartbeat timeout (\(ageMs)ms) — stop sent")
            }
        }
    }

    // MARK: - Session lifecycle

    public func closeSession(reason: String) async {
        guard let s = session else { return }
        await s.channel.disconnect(reason: reason)
        self.session = nil
        stopWatchdog()
    }

    // MARK: - ID utilities

    private func makeEnvelope<P: Codable & Sendable>(id: String? = nil,
                                                     type: String,
                                                     payload: P) -> RelayEnvelope<P> {
        let realId = id ?? nextEventId()
        return RelayEnvelope(id: realId, type: type, sentAt: clock(), payload: payload)
    }

    private func nextEventId() -> String {
        eventIdCounter &+= 1
        return String(format: "evt_%06llu", eventIdCounter)
    }

    private func makeSessionId() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let suffix = String(raw.prefix(6))
        return "ses_\(suffix)"
    }
}
