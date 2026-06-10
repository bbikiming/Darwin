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
        /// V297-4: iPhone 의 고정 식별자 (HelloPayload.deviceId). Wi-Fi 깜빡임 등으로
        /// 재연결 시 WSChannel.clientId 는 새 UUID 라 동일성 판별 불가. deviceId 는
        /// iPhone 측이 lifetime 일관 유지 → 동일 클라이언트 재연결 매칭의 단일 기준.
        let deviceId: String
        let deviceName: String
        let connectedAt: Date
        var lastHeartbeatAt: Date
        var activeCommandId: String?
    }

    /// V297-4/5/8/9: 서버 capabilities — Welcome 에 첨부.
    /// head=false: ConnectionStoreSafetyPort.setHead 가 reject (MVP).
    /// walkFreeform=true: production sendWalk hook maps iOS joystick frames into
    /// the WalkLabSession mobile freeform loop.
    /// speedScaleAccepted=true: **V297-8 부터 실 적용** — WalkLabSession.start(speedScale:)
    /// 가 amplitude(cmd.x/y/a) 에 0.5~1.5 clamp 후 곱. period 보존.
    private let serverCapabilities = WelcomeCapabilities(
        head: false, walkFreeform: true, speedScaleAccepted: true,
        ballTracking: true)

    private let configuration: Configuration
    private let pairing: MobileRelayPairing
    private let port: RobotSafetyPort
    private let clock: () -> Date
    private let harness: (any HarnessFacade)?
    /// Mac-side 최신 배터리 전압을 반환하는 클로저.
    /// nil → 전압 측정 불가 (보수 정책: ARM reject).
    private let batteryVoltage: @Sendable () async -> Double?
    /// **V292-D fix (사용자 보고)** — 페어링 즉시 controller 에 push 통보.
    /// 1Hz polling 만 의존하면 sandbox 환경 / Task scheduling delay 로
    /// Mac UI 가 무한 "대기" 표시. callback 으로 즉시 main actor 동기화.
    /// nil = test/production fallback (polling 만 동작).
    private let onPaired: (@Sendable (String, String) async -> Void)?
    private let onUnpaired: (@Sendable () async -> Void)?
    /// **V295-2** — connection lifecycle events → controller timeline push.
    /// label: 한글 라벨, detail: 추가 메타(optional).
    private let onLifecycleEvent: (@Sendable (String, String?) async -> Void)?
    private var session: Session?
    private var watchdogTask: Task<Void, Never>?
    /// V296-1: consecutive send-failure counter. Reset on success; triggers
    /// closeSession when it reaches maxConsecutiveSendFailures.
    private var consecutiveSendFailures: Int = 0
    private static let maxConsecutiveSendFailures: Int = 3
    /// **V291-11** — transport disconnect grace period timer.
    /// 1.5s 안에 새 hello 들어오면 cancel. 만료 시 stop + disarm + close.
    private var disconnectGraceTask: Task<Void, Never>?
    private var eventIdCounter: UInt64 = 0
    private var commandIdsSeen: Set<String> = []
    /// V297-9 CRITICAL-1: **safety epoch** — handleArm 같이 await suspension 이 긴 명령이
    /// 진행 중 다른 안전 이벤트 (E-stop / disconnect / recoverFromEStop) 가 처리되면
    /// epoch 증가. await 후 깨어난 명령이 epoch 변화 감지 시 stale 로 분류해 staleCommand
    /// 실패 처리. ARM 의 battery grace 2초 동안 E-stop 도착 → epoch 변화 → ARM 이
    /// recoverFromEStop 으로 자동 분기되는 회로 차단.
    ///
    /// # 비유
    ///
    /// 항공 관제탑의 비행허가 시리얼. ATC 가 비행기 A 에게 이륙 허가를 줬는데
    /// (await), 그 사이 비상 (활주로 폐쇄 — E-stop) 발생 → 시리얼 증가.
    /// A 가 시동 끝나고 이륙하려 할 때 시리얼 체크 → 변화 감지 → 이륙 중단.
    private var safetyEpoch: UInt64 = 0

    /// V297-9: 안전 이벤트 발생 시 호출 — pending command 들이 stale 로 분류되도록.
    private func bumpSafetyEpoch() {
        safetyEpoch &+= 1
    }

    /// V297-9: 명령이 await 후 깨어났을 때 stale 검증.
    /// - epoch 가 snapshot 이후 변경됐거나
    /// - 세션이 nil 이거나
    /// - 세션의 channel.clientId 가 snapshot 과 다르면 stale.
    private func isStale(armEpoch: UInt64, armChannelId: String) -> Bool {
        if safetyEpoch != armEpoch { return true }
        guard let session else { return true }
        if session.channel.clientId != armChannelId { return true }
        return false
    }
    /// V297-4 — 최근 robot ACK round-trip (ms). 서버측 측정. iOS clock 드리프트와
    /// 무관하므로 latency gate 의 신뢰성 있는 입력. 프로토콜 §4 "robot ACK round-trip"
    /// 권장 사항과 정합.
    ///
    /// 갱신 시점: handleArm / handleMotion / handleWalk / handleStop 성공 후
    /// `port.*` 가 반환한 latencyMs 로 set. 명령 사이 갱신 안 되면 stale → gate
    /// 가 결정에 사용하지 않도록 nil 일 때 게이트 통과 (관대 정책 — 첫 명령 직전
    /// 사용자가 alreadyOwned 같이 다른 reject 를 받지 않도록).
    private var lastRobotRttMs: Int?
    /// V297-4 — 마지막 RTT 갱신 시각. 5초 이상 stale 이면 게이트가 무시.
    private var lastRobotRttAt: Date?

    public init(configuration: Configuration = .init(),
                pairing: MobileRelayPairing,
                port: RobotSafetyPort,
                clock: @escaping () -> Date = Date.init,
                harness: (any HarnessFacade)? = nil,
                batteryVoltage: @escaping @Sendable () async -> Double? = { nil },
                onPaired: (@Sendable (String, String) async -> Void)? = nil,
                onUnpaired: (@Sendable () async -> Void)? = nil,
                onLifecycleEvent: (@Sendable (String, String?) async -> Void)? = nil) {
        self.configuration = configuration
        self.pairing = pairing
        self.port = port
        self.clock = clock
        // nil 이면 production 경로 — MobileRelayController 가 LiveHarness.shared 를
        // 명시 주입하므로 실제로 nil 상태로 사용되지 않음. 테스트는 항상 주입.
        self.harness = harness
        self.batteryVoltage = batteryVoltage
        self.onPaired = onPaired
        self.onUnpaired = onUnpaired
        self.onLifecycleEvent = onLifecycleEvent
    }

    public func currentSessionId() -> String? { session?.sessionId }
    public func hasActiveSession() -> Bool { session != nil }
    /// P1-2 fix (truth-gap report, 2026-05-25): expose the paired iPhone's
    /// device name so the Mac toolbar chip can render `연결됨 — <iPhone>`
    /// while a session is owned. Returns nil when no session is active.
    public func currentDeviceName() -> String? { session?.deviceName }
    /// V295-4: 세션 연결 시각 — popover 진단 섹션의 "연결 시작" 표시용.
    public func currentConnectedAt() -> Date? { session?.connectedAt }
    /// V295-4: 마지막 heartbeat 수신 시각 — popover 진단 섹션의 "마지막 신호" 표시용.
    public func currentLastHeartbeatAt() -> Date? { session?.lastHeartbeatAt }

    // MARK: - Transport callbacks

    /// Called by the transport when a new client opens the WebSocket.
    /// Returns after the welcome / rejection envelope has been delivered.
    public func handleClientConnected(_ channel: RelayClientChannel,
                                      handshake firstFrame: Data) async {
        // V295-2: TCP 수락 즉시 기록 — handshake 시작 전 첫 타임라인 이벤트.
        await emitTelemetry(.mobilePilotSocketOpened, level: .info, actor: .system,
                            data: ["channelId": AnyCodable(channel.clientId)])
        if let onLifecycleEvent {
            await onLifecycleEvent("WebSocket 연결됨", channel.clientId)
        }
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
        case InboundCommandType.pilotBallTrack.rawValue:
            await handleBallTrack(data: data)
        case InboundCommandType.pilotRecover.rawValue:
            await handleRecover(data: data)
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
        // V297-9 CRITICAL-1: 어떤 disconnect 든 진행 중인 명령은 stale.
        bumpSafetyEpoch()
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

    /// 실 robot 자세를 활성 세션에 전송. payload는 호출자(MobileRelayBootstrap)가
    /// WalkLabSession 에서 채워 넘긴다(IMU 는 RobotSafetyPort 계약 밖이라 주입 방식).
    public func broadcastCockpitTelemetry(_ payload: RobotAttitudePayload) async {
        guard let session else { return }
        await send(envelope: makeEnvelope(type: OutboundEventType.cockpitTelemetry.rawValue,
                                          payload: payload),
                   to: session.channel)
    }

    // MARK: - Internal helpers

    private func acceptHello(channel: RelayClientChannel,
                             hello: RelayEnvelope<HelloPayload>) async throws {
        // V295-2: hello payload 파싱 성공 — 코드 검증 직전.
        let codeHint = String(hello.payload.pairingCode.prefix(2)) + "****"
        await emitTelemetry(.mobilePilotHelloReceived, level: .info, actor: .system,
                            data: ["deviceName": AnyCodable(hello.payload.deviceName),
                                   "codePrefixHint": AnyCodable(codeHint)])
        if let onLifecycleEvent {
            await onLifecycleEvent("Hello 수신", hello.payload.deviceName)
        }

        // ── V297-5 CRITICAL-2/4 — 모든 검증을 session mutate 전에 ──────────────
        //
        // 종전: cancelDisconnectGraceTask + session 교체 가 protocol/pairing 검증 전
        // 발생 → 검증 실패 시 grace 도 사라지고 session 도 부분 mutate. 정합 깨짐.
        //
        // 신규 순서:
        //   1. protocol version check  (검증 1)
        //   2. pairing.validate         (검증 2)
        //   3. single-authority check  (existing session vs deviceId)
        //   4. (확정 후) grace cancel + session mutate
        // ──────────────────────────────────────────────────────────────────────

        // 검증 1 — protocol version.
        if hello.payload.protocolVersion != MobileRelayWireProtocol.version {
            try await sendSessionRejected(channel: channel, id: hello.id,
                                          reason: "protocolMismatch",
                                          message: "Server expects v\(MobileRelayWireProtocol.version)")
            await channel.disconnect(reason: "protocolMismatch")
            return
        }

        // 검증 2 — pairing.
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

        // 검증 3 — single-authority (existing session vs deviceId).
        //
        // V297-4 + V297-5 CRITICAL-3: same deviceId 면 reconnect 로 인정, 다른
        // deviceId 면 alreadyOwned 거절. grace timer 는 reconnect 확정 분기에서만 cancel.
        var isReconnect = false
        var preservedSessionId: String? = nil
        var preservedEventCounter: UInt64 = 0
        var oldChannelToClose: RelayClientChannel? = nil
        if let existing = session {
            if existing.deviceId == hello.payload.deviceId {
                isReconnect = true
                preservedSessionId = existing.sessionId
                // V297-5 MEDIUM-3: same-device reconnect 시 evt counter 유지 →
                // sessionId 보존 하면서 evt_000001 중복 발급 방지.
                preservedEventCounter = eventIdCounter
                if existing.channel.clientId != channel.clientId {
                    oldChannelToClose = existing.channel
                }
            } else {
                // 다른 deviceId — alreadyOwned. grace 보존 (다른 폰 시도일 뿐).
                try await sendSessionRejected(channel: channel, id: hello.id,
                                              reason: "alreadyOwned",
                                              message: "Another iPhone is paired.")
                await channel.disconnect(reason: "alreadyOwned")
                return
            }
        }

        // ── 모든 검증 통과 — 여기서부터 session mutate 안전 ────────────────────
        //
        // V297-5 CRITICAL-4: grace timer cancel 도 여기서. (검증 실패 path 들이
        // 모두 early return 했으니 도달 == 확정 reconnect 또는 새 세션.)
        cancelDisconnectGraceTask()

        // V297-5 CRITICAL-3: old channel 의 disconnect 는 fire-and-forget detached Task.
        //
        // 종전: await existing.channel.disconnect(...) 가 actor suspension point →
        // disconnect callback (handleClientDisconnected) 이 도착하면 session.channel
        // 이 still old channel 이라 guard 통과 → 새 session 까지 닫음.
        //
        // 신규: session 을 먼저 새 channel 로 교체 (synchronous, actor 안 suspension 없음).
        // 그 다음 Task.detached 로 old channel 닫기. callback 도착 시점에는 이미
        // session.channel = 새 channel → guard 실패 → 자동 무시.
        //
        // 비유: 직장 인수인계 — 후임 채용 + 권한 이양 끝낸 다음 전임 퇴사 처리.
        // 후임 자리 잡기 전에 전임 보내면 공석 위험.

        let sessionId = preservedSessionId ?? makeSessionId()
        self.session = Session(channel: channel,
                               sessionId: sessionId,
                               deviceId: hello.payload.deviceId,
                               deviceName: hello.payload.deviceName,
                               connectedAt: clock(),
                               lastHeartbeatAt: clock(),
                               activeCommandId: nil)
        commandIdsSeen.removeAll(keepingCapacity: true)
        // V297-5 MEDIUM-3: reconnect 시 counter 유지, fresh 세션이면 0 reset.
        eventIdCounter = isReconnect ? preservedEventCounter : 0
        // V297-4: 새 세션 시작 시 RTT 캐시 reset — 이전 세션 잔여값으로 잘못 reject 방지.
        lastRobotRttMs = nil
        lastRobotRttAt = nil

        // V297-5 CRITICAL-3: old channel close — actor 외부 detached Task.
        if let oldChannel = oldChannelToClose {
            Task.detached {
                await oldChannel.disconnect(reason: "replacedByReconnect")
            }
        }

        let welcome = WelcomePayload(
            macName: configuration.macName,
            macVersion: configuration.macVersion,
            relayProtocolVersion: MobileRelayWireProtocol.version,
            sessionId: sessionId,
            heartbeatIntervalMs: configuration.heartbeatIntervalMs,
            watchdogTimeoutMs: configuration.watchdogTimeoutMs,
            capabilities: serverCapabilities)
        await send(envelope: makeEnvelope(type: OutboundEventType.sessionWelcome.rawValue,
                                          payload: welcome),
                   to: channel)
        // V295-2: welcome 송신 완료 — 페어링 확정 직전.
        await emitTelemetry(.mobilePilotWelcomeSent, level: .info, actor: .system,
                            data: ["sessionId": AnyCodable(sessionId),
                                   "deviceName": AnyCodable(hello.payload.deviceName)])
        if let onLifecycleEvent {
            await onLifecycleEvent("Welcome 송신", sessionId)
        }
        await emitLog(level: "info", category: "connection",
                      message: "Paired: \(hello.payload.deviceName)")
        await emitTelemetry(.mobilePilotPairingSuccess, level: .info, actor: .user,
                            data: ["deviceName": AnyCodable(hello.payload.deviceName),
                                   "sessionId": AnyCodable(sessionId)])
        // **V293 fix** — controller 에 즉시 push 통보. 1Hz polling 의존성 제거.
        // 사용자 보고: 폰 연결됨 / Mac 대기 mismatch — sandbox 환경에서
        // telemetryPump 의 polling 이 지연되거나 race 시 발생.
        if let onPaired {
            await onPaired(hello.payload.deviceName, sessionId)
        }
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
        // V297-9 CRITICAL-1: safety epoch snapshot — battery grace 또는 progress
        // callback 등 await 후 epoch 가 변했으면 (E-stop / disconnect 가 끼어듬)
        // stale ARM 으로 즉시 실패 처리. 종전 회로:
        //   ARM 송신 → battery grace 1초 await → 그 사이 E-stop 처리 →
        //   emergencyStopActive=true → 깨어난 ARM 이 Bootstrap.armAsync hook 의
        //   분기로 가서 recoverFromEStop 실행 → "비상정지가 자동 복구로 둔갑".
        let armEpoch = safetyEpoch
        // ARM 시작 시 session 의 channel.clientId 도 snapshot — 그 사이 reconnect
        // 로 session 이 다른 채널로 교체되면 stale.
        let armChannelId = session.channel.clientId

        // ── Battery gate (V291-10 defense-in-depth + V297-4 cold-boot grace) ──
        // iOS preflight 가 1차 방어지만, stale/spoofed voltage 시나리오에 대비해
        // Mac 측에서 최신 전압을 재검증한다. 연료 게이지 0 = 시동 거부.
        //
        // V297-4 cold-boot grace: voltage 가 nil (첫 telemetry tick 전) 일 때
        // 즉시 reject 하지 않고 최대 2초간 100ms 간격 polling 후 재평가. 페어링
        // 직후 사용자가 ARM 을 누르면 첫 board snapshot (~200-500ms) 이 도착하기
        // 전이라 nil 이 잠시 반환되는 정상 상황. 종전엔 이걸 lowBattery 로 잘못 reject.
        let voltage = await waitForBatteryVoltage(maxAttempts: 20, intervalMs: 100)
        // V297-9 CRITICAL-1: 안전 epoch 재검증 #1 — battery grace 후. epoch 바뀌었거나
        // 세션 channel 이 바뀌었으면 (또는 sessionId 가 nil) stale.
        if isStale(armEpoch: armEpoch, armChannelId: armChannelId) {
            await sendCommandFailed(commandId: commandId, reason: "staleCommand",
                                    message: "ARM stale — 비상정지/끊김 발생 후 무효")
            return
        }
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
            // grace 후에도 nil → 진짜 측정 불가 → 보수 정책 reject.
            let threshStr = String(format: "%.1f", MobileRelayServer.armBatteryThreshold)
            let msg = "배터리 전압 측정 불가 (2초 grace 후에도 nil) — 임계(\(threshStr) V) 미만으로 간주, 즉시 충전 필요"
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

        await sendCommandAccepted(commandId: commandId)
        do {
            let latency = try await port.arm(
                cradleConfirmed: env.payload.cradleConfirmed,
                operator: env.payload.operator_,
                progress: { [weak self] stage, progress in
                    await self?.emitArmingProgress(commandId: commandId,
                                                    stage: stage, progress: progress)
                })
            // V297-9 CRITICAL-1: 안전 epoch 재검증 #2 — port.arm 완료 후. ARM stage
            // polling task (ConnectionStoreSafetyPort) 이 수십 ms ~ 수 초 걸릴 수 있어
            // 그 동안 E-stop 가능. 깨어난 시점에 epoch 변경 감지 시 stale.
            // port.arm 자체는 이미 robot 에 명령 보냈으므로 추가 cancel 불가지만,
            // command.ack 대신 staleCommand 로 응답해 iOS 가 "ARM 성공" 잘못 표시 못 함.
            if isStale(armEpoch: armEpoch, armChannelId: armChannelId) {
                await sendCommandFailed(commandId: commandId, reason: "staleCommand",
                                        message: "ARM 진행 중 비상정지/끊김 발생 — 결과 무효")
                return
            }
            recordRobotRtt(latency)
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
        // V297-4: 프로토콜 §7.1 — 모든 명령에 accepted 선발사.
        await sendCommandAccepted(commandId: env.id)
        do {
            let latency = try await port.disarm(reason: env.payload.reason)
            // V297-5 HIGH-2: disarm 은 local TeleopChannel.disarm() 동기 호출.
            // 실제 robot ACK round-trip 아니므로 RTT 캐시에 넣지 않는다 — 다음 walk
            // gate 가 0ms 같은 misleading 값으로 false-pass 되는 회로 차단.
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
        // V297-9 CRITICAL-1: E-stop 진입 즉시 safety epoch 증가 — 진행 중인 ARM 등이
        // await 후 깨어나면 stale 분류돼 staleCommand 로 실패. 자동 복구 분기 차단.
        bumpSafetyEpoch()
        // **S3 (2026-06-11) — E-STOP 즉시발화 불변식 복원**: 종전엔 `accepted` 송신을
        // await 한 *뒤에야* torque-off 를 호출 → TCP 송신 버퍼 포화 시 정지가 네트워크에
        // 인질이 됐다. 이제 accepted 는 fire-and-forget Task 로 분리해 torque-off 가
        // 첫 실행 라인이 되게 한다. MobileRelayServer 는 actor 이므로 이 Task 는
        // 아래 `port.emergencyStop` 의 첫 await suspension 사이에 직렬 실행돼
        // iOS "정지 처리 중" 즉시 표시 UX 는 유지된다(순서 보장만 해제).
        let acceptedId = env.id
        Task { [weak self] in await self?.sendCommandAccepted(commandId: acceptedId) }
        // E-stop has priority: ack as soon as the safety chain reports done.
        do {
            let latency = try await port.emergencyStop(reason: env.payload.reason)
            // V297-5 HIGH-2: E-stop 은 verification 결과로 RTT 캐시 안 함
            // (bus write 시간이 일관 RTT 아님 — torque-off 만 단발 호출).
            self.session?.activeCommandId = nil
            await sendCommandAck(commandId: env.id, latencyMs: latency)
            await emitLog(level: "warning", category: "safety",
                          message: "E-stop 실행 (\(env.payload.reason))",
                          commandId: env.id)
            await broadcastTelemetry()
        } catch let RelayServerError.failed(reason) {
            // V297-5 CRITICAL-5: estopVerificationFailed 등 verification 실패 →
            // command.failed(safetyAbort) 로 iOS 에 명시 통보.
            await sendCommandFailed(commandId: env.id, reason: "safetyAbort",
                                    message: reason)
            await emitLog(level: "error", category: "safety",
                          message: "E-stop 검증 실패 (\(reason)) — bus 미연결 또는 torque-off 미확인",
                          commandId: env.id)
            await emitTelemetry(.mobilePilotCommandRejected, level: .error, actor: .system,
                                data: ["commandType": "estop",
                                       "commandId": AnyCodable(env.id),
                                       "reason": "safetyAbort",
                                       "verificationDetail": AnyCodable(reason)])
        } catch {
            await sendCommandFailed(commandId: env.id, reason: "safetyAbort",
                                    message: String(describing: error))
            await emitLog(level: "error", category: "safety",
                          message: "E-stop 실패: \(error)",
                          commandId: env.id)
        }
    }

    /// V297-4 — Latency gate. 프로토콜 §4 정합 수정.
    ///
    /// # 종전 (잘못된 구현)
    ///
    /// `env.sentAt` (iOS clock) 과 Mac clock 의 차이로 latency 계산 → iPhone-Mac 사이의
    /// 시계 드리프트가 150ms 만 되어도 모든 보행 명령이 거짓 latencyGate 거절. 프로토콜
    /// §4 가 명시한 금지 패턴 ("receivedAt − sentAt 가 아니라 robot ACK round-trip").
    ///
    /// # 신규 (서버측 RTT 기반)
    ///
    /// 게이트 입력: **서버측 측정한 마지막 robot ACK round-trip** (`lastRobotRttMs`).
    /// 시계 드리프트와 무관. iOS clock 도 비교용으로만 사용 — 임계 초과시 `highLatency`
    /// **warning** (informational, reject 아님) 발사. clock skew 가 명백한 10초 초과만
    /// `clockSkew` reject (방어).
    ///
    /// # 비유
    ///
    /// 종전: 손목시계 보고 "내 시계 기준 너무 늦었어" (시계 다른 사람한테 적용 부당).
    /// 신규: 실제 메아리 돌아오는 시간 측정 → 같은 환경, 같은 기준.
    ///
    /// - Parameters:
    ///   - env: 수신된 RelayEnvelope (sentAt 는 highLatency warning 산출용으로만 사용).
    ///   - thresholdMs: 서버측 RTT 임계. 초과시 reject.
    ///   - warningThresholdMs: 정보성 highLatency warning 임계 (보통 threshold * 2/3).
    ///   - commandType: 텔레메트리 로그용 명령 타입 문자열.
    /// - Returns: 게이트가 트리거됐으면 거절 사유 문자열, 통과면 nil.
    private func checkLatencyGate<P: Codable & Sendable>(
        env: RelayEnvelope<P>,
        thresholdMs: Int,
        warningThresholdMs: Int? = nil,
        commandType: String
    ) async -> String? {
        let now = clock()
        let rawIOSLatencyMs = now.timeIntervalSince(env.sentAt) * 1000

        // V297-5 HIGH-4: clockSkew 양방향 검사. 종전 `rawIOSLatencyMs > 10_000` 만
        // 봐서 iOS clock 이 Mac 보다 10초 이상 앞선 음수 skew 가 통과됐다.
        // abs() 로 양방향 차단.
        if abs(rawIOSLatencyMs) > 10_000 {
            await sendCommandRejected(commandId: env.id, reason: "clockSkew",
                                      message: "iOS envelope sentAt deviates > 10s from Mac clock (skew \(Int(rawIOSLatencyMs))ms).")
            await emitTelemetry(.mobilePilotCommandRejected, level: .warn, actor: .user,
                                data: ["commandType": AnyCodable(commandType),
                                       "commandId": AnyCodable(env.id),
                                       "reason": "clockSkew",
                                       "iosLatencyMs": AnyCodable(Int(rawIOSLatencyMs))])
            return "clockSkew"
        }

        // 서버측 RTT 기반 reject — 프로토콜 §4 정합.
        // RTT 미측정 (nil) 또는 5초 이상 stale 이면 게이트 통과 (관대 정책).
        // 첫 명령 직전이거나 잠시 idle 후의 재진입 시 false reject 회피.
        let rttFresh: Bool = {
            guard let at = lastRobotRttAt else { return false }
            return now.timeIntervalSince(at) <= 5.0
        }()
        let rttMs = rttFresh ? (lastRobotRttMs ?? 0) : 0

        // 정보성 highLatency warning — reject 직전 단계.
        let warnAt = warningThresholdMs ?? max(1, thresholdMs * 2 / 3)
        if rttFresh, rttMs >= warnAt, rttMs < thresholdMs {
            await emitHighLatencyWarning(latencyMs: rttMs)
        }

        if rttFresh, rttMs >= thresholdMs {
            await sendCommandRejected(commandId: env.id, reason: "latencyGate",
                                      message: "최근 robot RTT \(rttMs)ms ≥ \(thresholdMs)ms 임계 — 보행 보호")
            await emitTelemetry(.mobilePilotCommandRejected, level: .warn, actor: .user,
                                data: ["commandType": AnyCodable(commandType),
                                       "commandId": AnyCodable(env.id),
                                       "reason": "latencyGate",
                                       "robotRttMs": AnyCodable(rttMs)])
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
        // V297-4: Latency gate — 서버측 RTT 기반. motion 은 450ms RTT 임계 (caution
        // 특성 + USB/network jitter 마진). 300ms 부근부터 highLatency warning.
        if let _ = await checkLatencyGate(env: env, thresholdMs: 450,
                                          warningThresholdMs: 300,
                                          commandType: "motion") { return }
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
        // V297-4: 프로토콜 §7.1 — accepted 선발사.
        await sendCommandAccepted(commandId: env.id)
        do {
            let latency = try await port.runMotion(slot: payload.slot,
                                                   label: payload.label,
                                                   confirmRisk: payload.confirmRisk)
            recordRobotRtt(latency)
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
        // V297-4: Latency gate — 서버측 RTT 기반. walk 는 350ms RTT 임계
        // (보행 중 명령 적시성 vs USB/network jitter 마진). 220ms 부근부터 highLatency.
        if let _ = await checkLatencyGate(env: env, thresholdMs: 350,
                                          warningThresholdMs: 220,
                                          commandType: "walk") { return }
        // V297-4: 프로토콜 §7.1 — accepted 선발사.
        await sendCommandAccepted(commandId: env.id)
        do {
            let result = try await port.sendWalk(payload: env.payload)
            recordRobotRtt(result.latencyMs)
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
        // V297-4: 프로토콜 §7.1 — stop 도 accepted 선발사.
        await sendCommandAccepted(commandId: env.id)
        do {
            let latency = try await port.sendStop(reason: env.payload.reason)
            // V297-5 HIGH-2: stop hook (Bootstrap line 141) 은 walkSession.stop() 만 호출하고
            // 실제 robot ACK 확인 없이 true 반환 → RTT 캐시 불가. 캐시 skip.
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

    /// V297-9 CRITICAL-1: 복구 전용 명령 핸들러. pilot.arm 과 분리되어 의도 명확.
    /// hook 가 emergencyStopActive 무관하게 항상 recoverFromEStop 시도.
    private func handleRecover(data: Data) async {
        guard let session,
              let env = try? RelayCodec.decoder.decode(RelayEnvelope<RecoverPayload>.self,
                                                      from: data) else { return }
        _ = session
        let commandId = env.id
        let armEpoch = safetyEpoch
        let armChannelId = session.channel.clientId
        await sendCommandAccepted(commandId: commandId)
        do {
            // port.recover 가 별도 정의되지 않음 → 기존 arm hook 재사용 (실 동작은
            // ConnectionStoreSafetyPort.arm 의 store.emergencyStopActive 분기).
            // 이 명령은 명시적 복구 의도이므로 cradleConfirmed=true 강제 전달.
            let latency = try await port.arm(
                cradleConfirmed: env.payload.cradleConfirmed,
                operator: env.payload.operator_,
                progress: { [weak self] stage, progress in
                    await self?.emitArmingProgress(commandId: commandId,
                                                    stage: stage, progress: progress)
                })
            if isStale(armEpoch: armEpoch, armChannelId: armChannelId) {
                await sendCommandFailed(commandId: commandId, reason: "staleCommand",
                                        message: "복구 진행 중 비상정지/끊김 발생 — 결과 무효")
                return
            }
            recordRobotRtt(latency)
            await sendCommandAck(commandId: commandId, latencyMs: latency)
            await emitLog(level: "info", category: "safety",
                          message: "복구 완료", commandId: commandId)
            await broadcastTelemetry()
        } catch let RelayServerError.rejected(reason) {
            await sendCommandRejected(commandId: commandId, reason: reason, message: reason)
        } catch {
            await sendCommandFailed(commandId: commandId, reason: "internalError",
                                    message: String(describing: error))
        }
    }

    private func handleHead(data: Data) async {
        guard let session,
              let env = try? RelayCodec.decoder.decode(RelayEnvelope<HeadPayload>.self,
                                                      from: data) else { return }
        _ = session
        // V297-4: head 는 capabilities.head=false 면 iOS UI 에서 진입 막혀야 함.
        // 그래도 도달하면 accepted 선발사 후 port 가 결정.
        await sendCommandAccepted(commandId: env.id)
        do {
            let latency = try await port.setHead(payload: env.payload)
            recordRobotRtt(latency)
            await sendCommandAck(commandId: env.id, latencyMs: latency)
        } catch let RelayServerError.rejected(reason) {
            await sendCommandRejected(commandId: env.id, reason: reason, message: reason)
        } catch {
            await sendCommandFailed(commandId: env.id, reason: "internalError",
                                    message: String(describing: error))
        }
    }

    /// **볼 트래킹 (2026-06-02)** — 로봇 온보드 자동 헤드 추적 on/off.
    /// port.setBallTracking → session.ballTrackingEnabled set → OnboardBridge 전달.
    /// head 와 달리 robot 측 처리라 MVP 지원 (capabilities.ballTracking=true).
    private func handleBallTrack(data: Data) async {
        guard let session,
              let env = try? RelayCodec.decoder.decode(
                  RelayEnvelope<BallTrackPayload>.self, from: data) else { return }
        _ = session
        await sendCommandAccepted(commandId: env.id)
        do {
            let latency = try await port.setBallTracking(payload: env.payload)
            recordRobotRtt(latency)
            await sendCommandAck(commandId: env.id, latencyMs: latency)
            await emitTelemetry(.mobilePilotCommandAccepted, level: .info, actor: .user,
                                data: ["commandType": "ballTrack",
                                       "commandId": AnyCodable(env.id),
                                       "enabled": AnyCodable(env.payload.enabled)])
        } catch let RelayServerError.rejected(reason) {
            await sendCommandRejected(commandId: env.id, reason: reason, message: reason)
        } catch {
            await sendCommandFailed(commandId: env.id, reason: "internalError",
                                    message: String(describing: error))
        }
    }

    // MARK: - Send helpers

    /// V297-4: 모든 명령에 command.accepted emit — 프로토콜 §7.1.
    /// 검증 통과 직후, robot 통신 시작 전. iOS UI 의 "처리 중" 단계 진입 hint.
    private func sendCommandAccepted(commandId: String) async {
        guard let session else { return }
        await send(envelope: makeEnvelope(id: commandId,
                                          type: OutboundResponseType.commandAccepted.rawValue,
                                          payload: EmptyPayload()),
                   to: session.channel)
    }

    /// V297-4: high-latency informational warning — 프로토콜 §8.5.
    /// reject 직전 단계 (정보성). iOS 가 "응답이 늦어 조작 제한" 토스트 표시 가능.
    private func emitHighLatencyWarning(latencyMs: Int) async {
        guard let session else { return }
        await send(envelope: makeEnvelope(type: OutboundEventType.transportWarning.rawValue,
                                          payload: TransportWarningPayload(
                                              kind: "highLatency",
                                              latencyMs: latencyMs,
                                              message: "응답이 늦어요 (\(latencyMs)ms) — 다음 명령부터 제한될 수 있어요.")),
                   to: session.channel)
        // V297-5 LOW-1: 별도 telemetry kind — rejected 카운터 오염 방지.
        await emitTelemetry(.mobilePilotHighLatency, level: .warn, actor: .system,
                            data: ["latencyMs": AnyCodable(latencyMs)])
    }

    /// V297-4 + V297-5 HIGH-2: 서버측 측정 RTT 캐시 갱신.
    ///
    /// real robot ACK round-trip 이 실제로 측정된 명령만 호출 (arm / motion / walk).
    /// stop / disarm / estop 은 local no-op 또는 verification 결과라 RTT 의미 없음 — 호출 skip.
    ///
    /// 0/음수 latency 는 measurement noise — 캐시 거부.
    private func recordRobotRtt(_ ms: Int) {
        guard ms > 0 else { return }
        lastRobotRttMs = ms
        lastRobotRttAt = clock()
    }

    /// V297-4 cold-boot grace — voltage closure 가 첫 telemetry tick 전에 nil 을
    /// 반환할 때 짧게 polling. 페어링 직후 ARM 즉시 누르는 정상 시나리오 대응.
    ///
    /// - Parameters:
    ///   - maxAttempts: 최대 시도 횟수 (default 20).
    ///   - intervalMs: 시도 간격 (default 100ms).
    /// - Returns: voltage 값. maxAttempts 후에도 nil 이면 nil 반환.
    ///
    /// 총 대기시간 = maxAttempts × intervalMs. default = 2000ms.
    private func waitForBatteryVoltage(maxAttempts: Int, intervalMs: Int) async -> Double? {
        for attempt in 0..<maxAttempts {
            if let v = await batteryVoltage() { return v }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            }
        }
        return nil
    }

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
            consecutiveSendFailures = 0
        } catch {
            consecutiveSendFailures += 1
            let errorKind = String(describing: type(of: error))
            await emitTelemetry(.mobilePilotSendFailed, level: .warn, actor: .system,
                                data: ["errorKind": AnyCodable(errorKind),
                                       "consecutive": AnyCodable(consecutiveSendFailures)])
            if consecutiveSendFailures >= Self.maxConsecutiveSendFailures {
                // Close session first (sets session = nil) so any downstream send
                // attempts (e.g. from emitLog) are no-ops rather than recursive calls.
                await closeSession(reason: "deliveryFailed")
            }
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
        // V297-9 CRITICAL-1: session close → 진행 명령 stale.
        bumpSafetyEpoch()
        await s.channel.disconnect(reason: reason)
        self.session = nil
        consecutiveSendFailures = 0
        stopWatchdog()
        // **V293 fix** — controller 에 즉시 unpaired 통보.
        if let onUnpaired {
            await onUnpaired()
        }
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
