import Foundation
import SwiftUI
import Combine
import MobilePilotKit
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class AppState: ObservableObject {

    // MARK: - Connection state

    public enum ConnectionMode: String, Sendable, CaseIterable, Identifiable {
        case mockReview = "Mock / Review"
        case realRelay  = "Real Mac Relay"
        public var id: String { rawValue }
    }

    // MARK: - Published state

    @Published public private(set) var connectionMode: ConnectionMode = .mockReview
    @Published public private(set) var pilotState: PilotState = .notPaired
    @Published public private(set) var telemetry: TelemetryStatePayload?
    @Published public private(set) var telemetryHistory: [TelemetrySample] = []
    @Published public private(set) var transport: TransportState = .idle
    @Published public private(set) var pairedEndpoint: RelayEndpoint?
    @Published public private(set) var discovered: [RelayDiscoveryResult] = []
    @Published public private(set) var lastReceipt: CommandReceipt?
    @Published public private(set) var recoveryBanner: RecoveryBanner?
    @Published public private(set) var logs: [LogEntry] = []
    @Published public private(set) var lastError: String?
    @Published public var cradleConfirmed: Bool = false
    // P1-4 fix (truth-gap report, 2026-05-25): real ARM gate requires three
    // operator confirmations. Mock mode shows them as informational only.
    @Published public var physicalEStopConfirmed: Bool = false
    @Published public var lineOfSightConfirmed: Bool = false
    @Published public private(set) var armProgressStage: ArmingStage?
    @Published public private(set) var activeWalkPreset: WalkPreset?
    @Published public private(set) var pendingCommandLabel: String?

    public struct LogEntry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let level: LogLevel
        public let category: LogCategory
        public let message: String
        public let commandId: String?

        public init(level: LogLevel, category: LogCategory, message: String,
                    commandId: String? = nil, timestamp: Date = Date()) {
            self.id = UUID()
            self.level = level
            self.category = category
            self.message = message
            self.commandId = commandId
            self.timestamp = timestamp
        }
    }

    public struct RecoveryBanner: Equatable, Sendable {
        public let kind: Kind
        public let message: String

        public enum Kind: String, Sendable {
            case estop
            case staleStop
            case watchdog
            case transport
        }
    }

    public struct TelemetrySample: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let batteryV: Double?
        public let maxTempC: Double?
        public let latencyMs: Int
        public let lastAckAgeMs: Int?
        public let robot: RobotConnectionState
        public let safety: SafetyState

        public init(timestamp: Date, payload: TelemetryStatePayload) {
            self.id = UUID()
            self.timestamp = timestamp
            self.batteryV = payload.batteryV
            self.maxTempC = payload.maxTempC
            self.latencyMs = payload.latencyMs
            self.lastAckAgeMs = payload.lastAckAgeMs
            self.robot = payload.robot
            self.safety = payload.safety
        }
    }

    // MARK: - Dependencies

    private var relayClient: MobileRelayClient
    private let commandBuilder: CommandBuilder
    private var stateMachine = MobilePilotStateMachine()
    private var browser: RelayBrowser?
    private var eventTask: Task<Void, Never>?
    private var transportTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var browserTimeoutTask: Task<Void, Never>?
    /// V292-3: Bonjour 30초 탐색 타임아웃. true 이면 "안 보여요?" 패널 자동 펼침.
    @Published public private(set) var discoveryTimedOut: Bool = false
    /// P2-1 (검수 2026-05-26): Bonjour 가 권한 거부로 .waiting 상태 진입.
    /// ConnectScreen 이 이 값으로 permissionDeniedCard 표시.
    @Published public private(set) var bonjourPermissionDenied: Bool = false
    /// 일반 네트워크 실패 (firewall, no route 등) — 사용자 안내용.
    @Published public private(set) var bonjourFailureReason: String?
    private var browserFailureTask: Task<Void, Never>?
    /// V292-B: 페어링 성공 후 ARM 게이트 상태.
    /// none → brief → preflight → drill(첫 페어링 only) → ready.
    @Published public private(set) var safetyGateState: SafetyGateState = .none
    private var heartbeat: HeartbeatController?
    private let deviceId: String

    public var appVersion: String {
        let bundle = Bundle.main
        let v = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let b = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v)+\(b)"
    }

    public var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    // MARK: - Init

    public init(initialMode: ConnectionMode = .mockReview) {
        self.connectionMode = initialMode
        self.commandBuilder = CommandBuilder()
        self.deviceId = UserDefaults.standard.string(forKey: "darwinforge.deviceId")
            ?? {
                let id = UUID().uuidString
                UserDefaults.standard.set(id, forKey: "darwinforge.deviceId")
                return id
            }()
        switch initialMode {
        case .mockReview:
            self.relayClient = MockRelayClient(ackLatencyMs: 40)
        case .realRelay:
            self.relayClient = WebSocketRelayClient()
        }
    }

    // MARK: - Lifecycle

    public func bootstrap() {
        bindClient(relayClient)
    }

    public func setConnectionMode(_ mode: ConnectionMode) async {
        guard mode != connectionMode else { return }
        await disconnect(reason: "modeSwitch")
        connectionMode = mode
        switch mode {
        case .mockReview:
            relayClient = MockRelayClient(ackLatencyMs: 40)
        case .realRelay:
            relayClient = WebSocketRelayClient()
        }
        bindClient(relayClient)
        appendLog(level: .info, category: .system,
                  message: "모드 전환: \(mode.rawValue)")
    }

    public func startDiscovery() {
        browserTask?.cancel()
        browserTimeoutTask?.cancel()
        browserFailureTask?.cancel()
        browser?.stop()
        discoveryTimedOut = false
        bonjourPermissionDenied = false
        bonjourFailureReason = nil
        let b: RelayBrowser
        #if canImport(Network)
        if connectionMode == .realRelay {
            b = BonjourRelayBrowser()
        } else {
            b = FixedRelayBrowser(results: [])
        }
        #else
        b = FixedRelayBrowser(results: [])
        #endif
        browser = b
        browserTask = Task { [weak self] in
            for await results in b.resultsStream {
                await MainActor.run { self?.discovered = results }
            }
        }
        // V292-3: 30초 타임아웃 스트림 구독
        browserTimeoutTask = Task { [weak self] in
            for await _ in b.timeoutStream {
                await MainActor.run { self?.discoveryTimedOut = true }
            }
        }
        // P2-1 (검수 2026-05-26): 권한 거부 / 네트워크 실패 stream 구독.
        browserFailureTask = Task { [weak self] in
            for await failure in b.failureStream {
                await MainActor.run {
                    switch failure {
                    case .permissionDenied:
                        self?.bonjourPermissionDenied = true
                        self?.appendLog(level: .warning, category: .connection,
                                        message: "로컬 네트워크 권한 거부 — 설정에서 허용 필요")
                    case .networkUnavailable(let reason):
                        self?.bonjourFailureReason = reason
                        self?.appendLog(level: .warning, category: .connection,
                                        message: "Bonjour 실패: \(reason)")
                    }
                }
            }
        }
        b.start()
    }

    // MARK: - Safety Gate (V292-B)

    /// 페어링 성공 직후 호출 — Safety Brief 게이트 시작.
    public func beginSafetyGate() {
        safetyGateState = .brief
    }

    /// Safety Brief 3개 체크 완료 시 호출 → Preflight 로 진행.
    public func completeSafetyBrief() {
        guard safetyGateState == .brief else { return }
        safetyGateState = .preflight
    }

    /// Preflight Checklist 완료 시 호출 → E-Stop Drill 또는 ready 로 진행.
    public func completePreflightChecklist() {
        guard safetyGateState == .preflight else { return }
        let drillDone = UserDefaults.standard.bool(forKey: SafetyGateKeys.eStopDrillCompleted)
        safetyGateState = drillDone ? .ready : .drill
    }

    /// E-Stop Drill 완료 시 호출 → ready 상태로 전환 + UserDefaults 저장.
    public func completeEStopDrill() {
        guard safetyGateState == .drill else { return }
        UserDefaults.standard.set(true, forKey: SafetyGateKeys.eStopDrillCompleted)
        safetyGateState = .ready
        appendLog(level: .info, category: .safety,
                  message: "E-Stop Drill 완료 — ARM 가능 상태")
    }

    /// 페어링 해제 또는 연결 끊김 시 게이트 리셋.
    public func resetSafetyGate() {
        safetyGateState = .none
    }

    public func stopDiscovery() {
        browser?.stop()
        browser = nil
        browserTask?.cancel()
        browserTask = nil
        browserTimeoutTask?.cancel()
        browserTimeoutTask = nil
        browserFailureTask?.cancel()
        browserFailureTask = nil
        discoveryTimedOut = false
        bonjourPermissionDenied = false
        bonjourFailureReason = nil
    }

    // MARK: - Pairing / connection

    static func desiredConnectionMode(for endpoint: RelayEndpoint) -> ConnectionMode {
        isMockEndpoint(endpoint) ? .mockReview : .realRelay
    }

    private static func isMockEndpoint(_ endpoint: RelayEndpoint) -> Bool {
        endpoint.host == "mock" && endpoint.port == 0
    }

    public func connect(to endpoint: RelayEndpoint) async {
        let desiredMode = Self.desiredConnectionMode(for: endpoint)
        if desiredMode != connectionMode {
            await setConnectionMode(desiredMode)
        }
        await disconnect(reason: "reconnect")
        telemetryHistory.removeAll()
        serverCapabilities = nil
        let hello = HelloPayload(appVersion: appVersion,
                                 deviceName: deviceName,
                                 deviceId: deviceId,
                                 pairingCode: endpoint.pairingCode)
        let request = RelayConnectRequest(endpoint: endpoint, hello: hello)
        stateMachine.apply(.pairingStarted)
        pilotState = stateMachine.state
        // iOS-I1 timeline: helloSent (실제 송신은 client 내부지만 user 관점에선 connect 시도 직후).
        appendLog(level: .debug, category: .connection,
                  message: "→ hello 전송 (host=\(endpoint.host):\(endpoint.port))")
        do {
            try await relayClient.connect(request)
            pairedEndpoint = endpoint
            stateMachine.apply(.pairingSucceeded)
            pilotState = stateMachine.state
            // iOS-C1 fix (truth-gap report, 2026-05-25): `transport = .connected(sessionId: "ses_pending")`
            // 직접 set 제거. `WebSocketRelayClient` (또는 Mock) 가 transport stream 에서
            // 실 `WelcomePayload.sessionId` 로 `.connected` yield 하는 것만 truth source.
            // 그 사이 짧은 idle/handshaking 상태는 `isMacHandshaking` 으로 노출 → UI 가
            // "Mac 확인 중" 표시.
            appendLog(level: .info, category: .connection,
                      message: "← welcome 수신 (Mac=\(endpoint.host):\(endpoint.port))")
        } catch {
            stateMachine.apply(.pairingFailed)
            pilotState = stateMachine.state
            lastError = String(describing: error)
            appendLog(level: .error, category: .connection,
                      message: "연결 실패: \(lastError ?? "?")")
        }
    }

    public func connectMockReview() async {
        await connect(to: RelayEndpoint(host: "mock", port: 0, pairingCode: "000000"))
    }

    public func disconnect(reason: String = "user") async {
        await heartbeat?.stop(sendStop: false, reason: .user)
        heartbeat = nil
        await relayClient.close(reason: reason)
        pairedEndpoint = nil
        telemetry = nil
        telemetryHistory.removeAll()
        serverCapabilities = nil
        if case .commandActive = pilotState {
            stateMachine.apply(.transportClosed)
        }
        pilotState = stateMachine.state
        safetyGateState = .none
    }

    // MARK: - Commands

    /// All three operator-confirmed safety items must be true in real relay
    /// mode. Mock/Review mode only requires cradleConfirmed for product preview.
    public var armChecklistPassed: Bool {
        if connectionMode == .realRelay {
            return cradleConfirmed && physicalEStopConfirmed && lineOfSightConfirmed
        }
        return cradleConfirmed
    }

    /// P2-2 fix (검수 2026-05-26): 서버가 welcome 에 보낸 capabilities 를 저장.
    /// real relay 의 head/freeform UI 노출 정책의 source of truth.
    @Published public private(set) var serverCapabilities: WelcomeCapabilities?

    /// Head pan/tilt is a UI preview in the first build. The current macOS
    /// relay has no verified production adapter for head servos, so real
    /// relay mode must not send `pilot.head` and then present a fake ACK.
    ///
    /// P2-2: real relay 에서는 서버 capabilities.head 가 true 인 경우에만 허용.
    /// Mock 모드는 항상 시뮬레이션으로 허용.
    public var headControlSupported: Bool {
        if connectionMode == .mockReview { return true }
        return serverCapabilities?.head == true
    }

    public var armStartDisabledReason: DisabledReason? {
        let reason = CommandPermission.reason(forArm: pilotState,
                                               telemetry: telemetry)
        if connectionMode == .mockReview,
           case .robotDisconnected(simAvailable: true) = reason {
            return nil
        }
        return reason
    }

    public func performArm() async {
        // **V292-C critic CRITICAL fix** — 3-gate 데이터 레이어 강제.
        // UI flow 우회 (tab 전환 등) 로 safetyGateState 미통과 시 ARM 차단.
        // V292-B 의 Brief/Preflight/Drill 이 모두 통과 (.ready) 해야만 진행.
        guard safetyGateState == .ready else {
            appendLog(level: .warning, category: .safety,
                      message: "안전 점검 미완료 — Connect 탭에서 Brief / Preflight / E-Stop 확인을 완료하세요 (현재: \(safetyGateState))")
            return
        }
        guard armChecklistPassed else {
            appendLog(level: .warning, category: .safety,
                      message: "잠금 해제 전 확인 미완료: 크래들=\(cradleConfirmed), 물리 정지 버튼=\(physicalEStopConfirmed), 시야=\(lineOfSightConfirmed)")
            return
        }
        guard isMacReady else {
            appendLog(level: .warning, category: .safety,
                      message: "Mac이 연결되지 않았어요.")
            return
        }
        // P1-2 fix (검수 2026-05-26): UI disable 만 의존하지 않고 데이터 레이어에서도
        // CommandPermission 게이트 통과. robot == .sim / .disconnected / .busBusy /
        // .stale 같은 telemetry-driven 조건이 race 로 통과되는 것을 막는다.
        if let reason = CommandPermission.reason(forArm: pilotState, telemetry: telemetry) {
            appendLog(level: .warning, category: .safety,
                      message: "잠금 해제 차단: \(reason.koreanCopy)")
            return
        }
        let env = commandBuilder.arm(ArmPayload(cradleConfirmed: true,
                                                operator: deviceName))
        pendingCommandLabel = "잠금 해제"
        stateMachine.apply(.armRequested)
        pilotState = stateMachine.state
        do {
            let receipt = try await relayClient.send(env)
            lastReceipt = receipt
            switch receipt.outcome {
            case .acked:
                stateMachine.apply(.armed)
                appendLog(level: .info, category: .safety,
                          message: "잠금 해제 완료", commandId: receipt.commandId)
            case .rejected(let reason, let message):
                stateMachine.apply(.disarmed)
                appendLog(level: .warning, category: .safety,
                          message: "잠금 해제 거부: \(reason.rawValue) — \(message ?? "")",
                          commandId: receipt.commandId)
            case .failed(let reason, _):
                stateMachine.apply(.disarmed)
                appendLog(level: .error, category: .safety,
                          message: "잠금 해제 실패: \(reason.rawValue)",
                          commandId: receipt.commandId)
            case .accepted:
                break
            }
        } catch {
            stateMachine.apply(.disarmed)
            appendLog(level: .error, category: .safety,
                      message: "잠금 해제 오류: \(error)")
        }
        pendingCommandLabel = nil
        pilotState = stateMachine.state
    }

    public func performDisarm() async {
        let env = commandBuilder.disarm()
        stateMachine.apply(.disarmed)
        pilotState = stateMachine.state
        _ = try? await relayClient.send(env)
        appendLog(level: .info, category: .safety, message: "로봇 잠금")
    }

    public func performEStop(reason: EStopReason = .user) async {
        let env = commandBuilder.estop(EStopPayload(reason: reason))
        let result = stateMachine.apply(.estopRequested)
        pilotState = stateMachine.state
        recoveryBanner = RecoveryBanner(kind: .estop,
                                        message: "긴급 정지됨. 물리 긴급 정지 버튼도 확인하세요.")
        appendLog(level: .warning, category: .safety,
                  message: "긴급 정지 발동 (\(reason.rawValue))",
                  commandId: env.id)
        do {
            try await relayClient.sendFireAndForget(env)
        } catch {
            appendLog(level: .error, category: .safety,
                      message: "긴급 정지 전송 실패: \(error). 물리 긴급 정지 버튼을 사용하세요.")
        }
        _ = result
    }

    public func performMotion(label: String) async {
        guard let entry = SafeMotionCatalog.entry(forLabel: label) else { return }
        guard SafeMotionCatalog.mvpEnabledLabels.contains(label) else {
            appendLog(level: .warning, category: .safety,
                      message: "\(entry.koreanName)는 MVP에서 비활성화돼 있어요.")
            return
        }
        // P1-2 fix (검수 2026-05-26): UI disable race 회피 — notArmed / busBusy /
        // stale / robotDisconnected / latencyGate 모두 데이터 레이어에서 재검사.
        if let reason = CommandPermission.reason(forSafeAction: pilotState, telemetry: telemetry) {
            appendLog(level: .warning, category: .safety,
                      message: "\(entry.koreanName) 차단: \(reason.koreanCopy)")
            return
        }
        let env = commandBuilder.motion(MotionPayload(slot: entry.slot, label: entry.label,
                                                      confirmRisk: entry.risk != .safe))
        pendingCommandLabel = entry.koreanName
        stateMachine.apply(.commandStarted(commandId: env.id))
        pilotState = stateMachine.state
        appendLog(level: .info, category: .command,
                  message: "\(entry.koreanName) 시작", commandId: env.id)
        do {
            let receipt = try await relayClient.send(env)
            lastReceipt = receipt
            switch receipt.outcome {
            case .acked(let ms):
                appendLog(level: .info, category: .command,
                          message: "\(entry.koreanName) 응답 \(ms)ms",
                          commandId: receipt.commandId)
            case .rejected(let r, let m):
                appendLog(level: .warning, category: .command,
                          message: "\(entry.koreanName) 거부 (\(r.rawValue)) \(m ?? "")",
                          commandId: receipt.commandId)
            case .failed(let r, _):
                appendLog(level: .error, category: .command,
                          message: "\(entry.koreanName) 실패 (\(r.rawValue))",
                          commandId: receipt.commandId)
            case .accepted:
                break
            }
        } catch {
            appendLog(level: .error, category: .command,
                      message: "\(entry.koreanName) 오류: \(error)")
        }
        stateMachine.apply(.commandFinished)
        pilotState = stateMachine.state
        pendingCommandLabel = nil
    }

    public func startWalk(_ preset: WalkPreset) async {
        guard preset != .stop else { await stopWalk(reason: .user); return }
        if let reason = CommandPermission.reason(forWalk: pilotState,
                                                  telemetry: telemetry) {
            if connectionMode == .mockReview,
               case .robotDisconnected(simAvailable: true) = reason {
                // Review mode intentionally runs without a physical robot.
            } else {
                lastError = reason.koreanCopy
                appendLog(level: .warning, category: .command,
                          message: "보행 시작 차단: \(reason.koreanCopy)")
                return
            }
        }
        let env = commandBuilder.walk(preset)
        activeWalkPreset = preset
        pendingCommandLabel = label(for: preset)
        stateMachine.apply(.commandStarted(commandId: env.id))
        pilotState = stateMachine.state
        appendLog(level: .info, category: .command,
                  message: "보행 시작: \(label(for: preset))",
                  commandId: env.id)
        await ensureHeartbeat(activeCommandId: env.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let receipt = try await self.relayClient.send(env)
                self.lastReceipt = receipt
                switch receipt.outcome {
                case .acked:
                    self.appendLog(level: .info, category: .command,
                                   message: "보행 명령 응답 \(self.shortReceiptOutcome(receipt))",
                                   commandId: receipt.commandId)
                case .rejected(let reason, let message):
                    self.appendLog(level: .warning, category: .command,
                                   message: "보행 명령 거부 (\(reason.rawValue)) \(message ?? "")",
                                   commandId: receipt.commandId)
                    await self.clearActiveWalkAfterFailure(commandId: env.id)
                case .failed(let reason, let message):
                    self.appendLog(level: .error, category: .command,
                                   message: "보행 명령 실패 (\(reason.rawValue)) \(message ?? "")",
                                   commandId: receipt.commandId)
                    await self.clearActiveWalkAfterFailure(commandId: env.id)
                case .accepted:
                    break
                }
            } catch {
                self.appendLog(level: .error, category: .command,
                               message: "보행 명령 오류: \(error)")
                await self.clearActiveWalkAfterFailure(commandId: env.id)
            }
        }
    }

    public func stopWalk(reason: StopReason) async {
        let env = commandBuilder.stop(StopPayload(reason: reason))
        activeWalkPreset = nil
        pendingCommandLabel = nil
        stateMachine.apply(.stopRequested)
        pilotState = stateMachine.state
        await heartbeat?.stop(sendStop: false, reason: reason)
        appendLog(level: .info, category: .command,
                  message: "보행 정지 (\(reason.rawValue))", commandId: env.id)
        _ = try? await relayClient.send(env)
    }

    // MARK: - Freeform analog walk streaming

    /// Whether analog freeform walking is actually executable in the current
    /// session. The first build only supports it in Mock/Review mode; on the
    /// real Mac relay the server rejects `freeform` (highRiskNotAllowed) so
    /// the iOS side refuses to send and surfaces a clear reason.
    ///
    /// P2-2 fix (검수 2026-05-26): real relay 는 서버 capabilities.walkFreeform
    /// 이 true 여야 허용. 현재 ConnectionStoreSafetyPort 가 false 반환하므로
    /// 실제로는 mock 모드에서만 활성.
    public var freeformWalkSupported: Bool {
        if connectionMode == .mockReview { return true }
        return serverCapabilities?.walkFreeform == true
    }

    /// Stream a single analog walk frame. Throttled in the joystick view at
    /// ~10Hz to stay aligned with Mac watchdog (5Hz send to robot).
    ///
    /// P0-2 fix (truth-gap report, 2026-05-25): real relay mode no longer
    /// dispatches `freeform` to the server. UI continues to render visual
    /// feedback in Mock mode for product preview, but no fake "ACK" path on
    /// real hardware.
    public func streamWalk(_ input: WalkFreeformInput) async {
        guard pilotState.isArmed else { return }
        guard freeformWalkSupported else {
            // One-shot log per "active gesture" — flag and stop sending.
            if lastError != "freeformUnsupportedInMVP" {
                lastError = "freeformUnsupportedInMVP"
                appendLog(level: .warning, category: .command,
                          message: "자유 조종은 실 로봇에서 비활성 — 동작 탭의 버튼을 사용하세요.")
            }
            return
        }
        let env = commandBuilder.walkFreeform(input)
        if input.isMoving && activeWalkPreset == nil {
            stateMachine.apply(.commandStarted(commandId: env.id))
            pilotState = stateMachine.state
            activeWalkPreset = .freeform
            pendingCommandLabel = "조종 중 (시뮬)"
            await ensureHeartbeat(activeCommandId: env.id)
        }
        try? await relayClient.sendFireAndForget(env)
    }

    public func releaseWalk() async {
        guard activeWalkPreset != nil else { return }
        await stopWalk(reason: .deadmanRelease)
    }

    // MARK: - Head control

    public func sendHead(enabled: Bool, panDeg: Double, tiltDeg: Double,
                        tracking: Bool) async {
        guard headControlSupported else {
            lastError = "headUnsupportedInMVP"
            appendLog(level: .warning, category: .command,
                      message: "머리 방향 조절은 첫 빌드 실 로봇 모드에서 비활성 — 연습 모드에서만 미리보기 가능합니다.")
            return
        }
        guard isMacReady else {
            appendLog(level: .warning, category: .command,
                      message: "Mac 연결 후 헤드 미리보기를 사용할 수 있어요.")
            return
        }
        let payload = HeadPayload(enabled: enabled,
                                  panDeg: panDeg,
                                  tiltDeg: tiltDeg,
                                  tracking: tracking)
        let env = commandBuilder.head(payload)
        do {
            let receipt = try await relayClient.send(env)
            lastReceipt = receipt
            switch receipt.outcome {
            case .acked(let ms):
                appendLog(level: .debug, category: .command,
                          message: "헤드 \(enabled ? "ON" : "OFF") pan=\(Int(panDeg)) tilt=\(Int(tiltDeg)) (\(ms)ms)",
                          commandId: receipt.commandId)
            case .rejected(let r, let m):
                appendLog(level: .warning, category: .command,
                          message: "헤드 거부 (\(r.rawValue)) \(m ?? "")",
                          commandId: receipt.commandId)
            case .failed(let r, _):
                appendLog(level: .error, category: .command,
                          message: "헤드 실패 (\(r.rawValue))",
                          commandId: receipt.commandId)
            case .accepted:
                break
            }
        } catch {
            appendLog(level: .error, category: .command,
                      message: "헤드 오류: \(error)")
        }
    }

    public func acknowledgeRecovery() {
        stateMachine.apply(.recoveryAcknowledged)
        pilotState = stateMachine.state
        recoveryBanner = nil
    }

    public func clearError() { lastError = nil }

    // MARK: - Heartbeat

    private func ensureHeartbeat(activeCommandId: String) async {
        if heartbeat == nil {
            heartbeat = HeartbeatController(
                send: { [weak self] payload in
                    guard let self else { return }
                    let env = self.commandBuilder.heartbeat(payload)
                    try? await self.relayClient.sendFireAndForget(env)
                },
                onStop: { [weak self] reason in
                    await self?.stopWalk(reason: reason)
                })
        }
        await heartbeat?.start(uiState: .commandActive, activeCommandId: activeCommandId)
    }

    private func clearActiveWalkAfterFailure(commandId: String) async {
        guard case .commandActive(let currentId) = pilotState,
              currentId == commandId else { return }
        await heartbeat?.stop(sendStop: false, reason: .latencyGate)
        activeWalkPreset = nil
        pendingCommandLabel = nil
        stateMachine.apply(.commandFinished)
        pilotState = stateMachine.state
    }

    // MARK: - Bind

    private func bindClient(_ client: MobileRelayClient) {
        eventTask?.cancel()
        transportTask?.cancel()
        eventTask = Task { [weak self] in
            for await message in client.eventStream {
                await MainActor.run { self?.handle(message) }
            }
        }
        transportTask = Task { [weak self] in
            for await state in client.transportStream {
                await MainActor.run { self?.handleTransport(state) }
            }
        }
    }

    /// iOS-I1 timeline: transport state 전이마다 timeline 이벤트 로그.
    /// `bindClient` 가 stream 으로부터 모든 transitions 를 받아 처리한다.
    private func handleTransport(_ state: TransportState) {
        let previous = transport
        transport = state
        switch state {
        case .idle:
            break
        case .connecting:
            appendLog(level: .debug, category: .connection,
                      message: "🔌 socket open 시도")
        case .handshaking:
            appendLog(level: .debug, category: .connection,
                      message: "🤝 handshake 진행")
        case .connected(let sessionId):
            // welcome 자체는 connect() 에서 한 번 더 로그. 여기는 sessionId 확정 시각.
            let suffix = String(sessionId.suffix(8))
            appendLog(level: .info, category: .connection,
                      message: "✅ 세션 확정 — id=...\(suffix)")
        case .disconnected(let reason):
            // 직전이 connected 였다면 사용자에겐 끊김으로 명시.
            if case .connected = previous {
                appendLog(level: .warning, category: .connection,
                          message: "⛔️ 연결 끊김 — \(reason)")
            } else {
                appendLog(level: .debug, category: .connection,
                          message: "transport closed (\(reason))")
            }
            // P1-1 fix (검수 2026-05-26): 명시적 disconnect() 가 정리하던 상태들을
            // 외부 disconnect (Mac 종료/네트워크 끊김) 에서도 동일하게 정리. truth
            // gap 방지 — Mac 은 끊김인데 iOS 는 이전 telemetry/walk/ARM 그대로 표시.
            if case .connected = previous {
                Task { await self.handleExternalDisconnect(reason: reason) }
            }
        }
    }

    /// External transport closure cleanup — Mac 앱 종료/네트워크 끊김/socket close
    /// 모두 같은 경로. 명시적 `disconnect()` 와 의도적으로 분리: 후자는 사용자가
    /// 직접 트리거하므로 reconnect/modeSwitch 와 race 가능, 전자는 stream side
    /// effect 이므로 idempotent 정리만.
    private func handleExternalDisconnect(reason: String) async {
        await heartbeat?.stop(sendStop: false, reason: .user)
        heartbeat = nil
        pairedEndpoint = nil
        telemetry = nil
        telemetryHistory.removeAll()
        serverCapabilities = nil
        activeWalkPreset = nil
        pendingCommandLabel = nil
        // 상태 머신에 외부 transport 닫힘 통지 — active command 면 latencyGate
        // 사이드 이펙트 (stop active command) 발화.
        stateMachine.apply(.transportClosed)
        pilotState = stateMachine.state
        safetyGateState = .none
        // 사용자가 ARM 해두었던 체크리스트는 재연결 시 다시 확인할 수 있게 reset.
        cradleConfirmed = false
        physicalEStopConfirmed = false
        lineOfSightConfirmed = false
        recoveryBanner = RecoveryBanner(kind: .transport,
                                        message: "Mac 앱과 연결이 끊겼어요. 다시 연결하세요. (\(reason))")
    }

    private func handle(_ message: InboundMessage) {
        switch message {
        case .sessionWelcome(let env):
            appendLog(level: .info, category: .connection,
                      message: "Welcome from \(env.payload.macName) (\(env.payload.macVersion))")
            // P2-2 (검수 2026-05-26): 서버 capabilities 저장 → headControlSupported /
            // freeformWalkSupported 가 real relay 모드에서 이 값을 truth source 로.
            serverCapabilities = env.payload.capabilities
            if let cap = env.payload.capabilities {
                appendLog(level: .debug, category: .connection,
                          message: "Server caps — head=\(cap.head) freeform=\(cap.walkFreeform) speedScale=\(cap.speedScale)")
            }
        case .sessionRejected(let env):
            appendLog(level: .error, category: .connection,
                      message: "거부됨: \(env.payload.reason.rawValue)")
        case .telemetryState(let env):
            // iOS-I1 timeline: 첫 telemetry 도착은 별도 이벤트.
            let isFirst = (telemetry == nil)
            telemetry = env.payload
            recordTelemetry(env.payload, sentAt: env.sentAt)
            stateMachine.apply(.telemetry(env.payload))
            pilotState = stateMachine.state
            if isFirst {
                appendLog(level: .info, category: .connection,
                          message: "📡 첫 telemetry 수신 (Mac 확정 연결)")
            }
        case .armingProgress(let env):
            armProgressStage = env.payload.stage
            stateMachine.apply(.armingProgress(env.payload.stage))
            pilotState = stateMachine.state
        case .transportWarning(let env):
            if env.payload.kind == .highLatency {
                appendLog(level: .warning, category: .connection,
                          message: env.payload.message ?? "응답 지연")
            }
        case .watchdogStop(let env):
            recoveryBanner = RecoveryBanner(kind: .watchdog,
                                            message: "Mac 안전 감시가 정지를 보냈어요 (\(env.payload.reason.rawValue))")
            stateMachine.apply(.watchdogStopped(env.payload.reason))
            pilotState = stateMachine.state
            appendLog(level: .warning, category: .safety,
                      message: "안전 감시 정지: \(env.payload.reason.rawValue)")
        case .logEvent(let env):
            appendLog(level: env.payload.level, category: env.payload.category,
                      message: env.payload.message, commandId: env.payload.commandId)
        case .commandAccepted(let env):
            appendLog(level: .debug, category: .command,
                      message: "명령 수신 확인", commandId: env.id)
        case .commandRejected(let env):
            appendLog(level: .warning, category: .command,
                      message: "거부 (\(env.payload.reason.rawValue)) \(env.payload.message ?? "")",
                      commandId: env.id)
        case .commandAck(let env):
            appendLog(level: .info, category: .command,
                      message: "응답 \(env.payload.latencyMs)ms", commandId: env.id)
        case .commandFailed(let env):
            appendLog(level: .error, category: .command,
                      message: "실패 (\(env.payload.reason.rawValue)) \(env.payload.message ?? "")",
                      commandId: env.id)
        case .unknown(let head, _):
            appendLog(level: .debug, category: .system,
                      message: "알 수 없는 메시지 \(head.type)")
        }
    }

    // MARK: - Computed

    /// V292-handshake-fix (2026-05-25): transport `.connected` 만으로는 부족하다.
    /// Mac 측 `MobileRelayBootstrap` wiring 이 되지 않은 build (placeholder port)
    /// 또는 Mac 앱 강제 종료 직후엔 WebSocket handshake 만 통과하고 telemetry 가
    /// 한 프레임도 오지 않을 수 있다. 그 상태에서 "Mac 연결됨" 표시는 거짓.
    /// 첫 telemetry 가 도착해야 진짜 ready.
    public var isMacReady: Bool {
        if case .connected = transport, telemetry != nil { return true }
        return false
    }

    /// transport 가 .connected 인데 telemetry 가 아직이면 "확인 중" 으로 표시.
    /// MacChip 라벨 결정에 사용.
    public var isMacHandshaking: Bool {
        if case .connected = transport, telemetry == nil { return true }
        return false
    }

    /// iOS-C2 (truth-gap report, 2026-05-25): 현재 transport 의 실 sessionId.
    /// `WebSocketRelayClient` 또는 `MockRelayClient` 가 yield 한 값 그대로.
    /// `nil` = 아직 확정 안 됨 (handshaking 중이거나 disconnected).
    public var currentSessionId: String? {
        if case .connected(let id) = transport { return id }
        return nil
    }

    /// 마지막 telemetry 수신 후 경과 ms. nil = 아직 한 번도 수신 안 함.
    public var lastTelemetryAgeMs: Int? {
        guard let last = telemetryHistory.last else { return nil }
        return Int(Date().timeIntervalSince(last.timestamp) * 1000)
    }

    public var isMockMode: Bool { connectionMode == .mockReview }

    public var statusRail: StatusRailModel {
        StatusRailModel(transport: transport, telemetry: telemetry, pilotState: pilotState)
    }

    private func label(for preset: WalkPreset) -> String {
        switch preset {
        case .slowForward: return "천천히 전진"
        case .turnLeft: return "좌회전"
        case .turnRight: return "우회전"
        case .stop: return "정지"
        case .freeform: return "조종 중"
        }
    }

    private func shortReceiptOutcome(_ receipt: CommandReceipt) -> String {
        switch receipt.outcome {
        case .accepted: return "접수"
        case .acked(let ms): return "\(ms)ms"
        case .rejected(let r, _): return "거부 \(r.rawValue)"
        case .failed(let r, _): return "실패 \(r.rawValue)"
        }
    }

    private func appendLog(level: LogLevel, category: LogCategory,
                           message: String, commandId: String? = nil) {
        logs.insert(LogEntry(level: level, category: category,
                             message: message, commandId: commandId),
                    at: 0)
        if logs.count > 200 { logs.removeLast(logs.count - 200) }
    }

    private func recordTelemetry(_ payload: TelemetryStatePayload, sentAt: Date) {
        telemetryHistory.append(TelemetrySample(timestamp: sentAt, payload: payload))
        if telemetryHistory.count > 48 {
            telemetryHistory.removeFirst(telemetryHistory.count - 48)
        }
    }

    // MARK: - App lifecycle

    public func appWillResignActive() {
        Task { @MainActor in
            if case .commandActive = pilotState {
                appendLog(level: .warning, category: .safety,
                          message: "앱이 화면 밖으로 이동 — 정지를 보냅니다.")
                await stopWalk(reason: .appBackground)
            }
        }
    }
}

public struct StatusRailModel: Equatable, Sendable {
    public let transport: TransportState
    public let telemetry: TelemetryStatePayload?
    public let pilotState: PilotState

    public var macLabel: String {
        switch transport {
        case .connected:
            // V292-handshake-fix: telemetry 한 프레임이라도 도착해야 진짜 "연결됨".
            // handshake 만 통과한 상태는 "확인 중" — Mac 측 wiring 미완 또는
            // 강제 종료 직후 false positive 방지.
            return telemetry == nil ? "Mac 확인 중" : "Mac 연결됨"
        case .connecting, .handshaking: return "Mac 찾는 중"
        case .disconnected: return "Mac 끊김"
        case .idle: return "Mac 대기"
        }
    }

    public var robotLabel: String {
        guard let t = telemetry else { return "로봇 미연결" }
        switch t.robot {
        case .connected: return "로봇 연결됨"
        case .sim: return "연습 중"
        case .stale: return "응답 지연"
        case .busBusy: return "데모 점유"
        case .disconnected: return "로봇 미연결"
        case .estopped: return "정지됨"
        }
    }

    public var armLabel: String {
        switch pilotState {
        case .armedReady, .commandActive: return "해제됨"
        case .arming: return "준비 중"
        case .estopped, .staleStop: return "정지됨"
        default: return "잠김"
        }
    }

    public var latencyLabel: String {
        guard let t = telemetry else { return "–" }
        return "\(t.latencyMs)ms"
    }

    public var latencyWarning: Bool {
        (telemetry?.latencyMs ?? 0) >= 150
    }
}
