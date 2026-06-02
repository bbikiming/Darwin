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
    // V297-8 (P3-iOS): E-Stop ack 검증 결과 문자열. nil = 정상 / non-nil = 경고 메시지.
    @Published public private(set) var estopVerificationStatus: String?

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

    // MARK: - PersistedRelayEndpoint (S2.2)

    // V297-6 (PM Story S2.2): 마지막 성공 페어링의 endpoint + code 를 UserDefaults 에 보관.
    // 앱 재시작 또는 재접속 시 자동 페어링 시도에 사용 (S2.3).
    public struct PersistedRelayEndpoint: Codable, Equatable, Sendable {
        public let host: String
        public let port: Int
        public let pairingCode: String
        public let macName: String

        public init(host: String, port: Int, pairingCode: String, macName: String) {
            self.host = host
            self.port = port
            self.pairingCode = pairingCode
            self.macName = macName
        }
    }

    private enum PersistKeys {
        static let lastRelayEndpoint = "darwinforge.lastRelayEndpoint"
        static let autoPairCancelled = "darwinforge.autoPairCancelled"
    }

    /// 마지막 성공 페어링 endpoint 를 UserDefaults 에서 읽어 반환 (없으면 nil).
    public var persistedEndpoint: PersistedRelayEndpoint? {
        guard let data = UserDefaults.standard.data(forKey: PersistKeys.lastRelayEndpoint),
              let decoded = try? JSONDecoder().decode(PersistedRelayEndpoint.self, from: data)
        else { return nil }
        return decoded
    }

    private func saveEndpoint(_ endpoint: RelayEndpoint, macName: String) {
        let persisted = PersistedRelayEndpoint(host: endpoint.host,
                                               port: endpoint.port,
                                               pairingCode: endpoint.pairingCode,
                                               macName: macName)
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: PersistKeys.lastRelayEndpoint)
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
    // V297-6 (PM Story S2.3): 자동 페어링 시도 중 여부. ConnectScreen spinner 표시용.
    @Published public private(set) var isAutoPairing: Bool = false
    // V297-8 (P3-iOS): transport 끊김 시 자동 재시도 횟수 (0=미시도, 1.. 진행 중).
    @Published public private(set) var autoReconnectAttempt: Int = 0
    // 자동 재연결 루프가 활성인지 (UI "재연결 중…" 배너 표시용).
    @Published public private(set) var isReconnecting: Bool = false
    // V297-8 (P3-iOS): 사용자가 명시적으로 disconnect 했으면 true → 자동 재시도 skip.
    private var userInitiatedDisconnect: Bool = false
    // V297-8 (P3-iOS): 진행 중인 자동 재시도 Task (취소용).
    private var autoReconnectTask: Task<Void, Never>?
    // 자동 재연결 backoff 정책 (순수, 테스트됨).
    private let reconnectPolicy = ReconnectPolicy.standard
    // 네트워크 경로 모니터 — 오프라인 동안 재시도 소진 방지 + 복구 즉시 재연결.
    private let pathMonitor = NetworkPathMonitor()
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
        // 네트워크 복구 시 즉시 재연결 트리거.
        pathMonitor.onRestored = { [weak self] in
            self?.kickReconnectNow(trigger: "네트워크 복구")
        }
        pathMonitor.start()
    }

    // V297-6 (PM Story S2.3): 자동 페어링 시도.
    // RootView.task { state.bootstrap() } 직후 attemptAutoPair() 를 호출한다.
    // 저장된 endpoint 가 없거나 사용자가 cancel 누른 경우 즉시 반환.
    public func attemptAutoPair() async {
        guard let saved = persistedEndpoint else { return }
        guard !UserDefaults.standard.bool(forKey: PersistKeys.autoPairCancelled) else {
            // 사용자가 명시적으로 취소한 적 있으면 자동 시도 안 함.
            UserDefaults.standard.removeObject(forKey: PersistKeys.autoPairCancelled)
            return
        }
        // realRelay 모드 전환 (필요 시)
        if connectionMode != .realRelay {
            await setConnectionMode(.realRelay)
        }
        isAutoPairing = true
        appendLog(level: .info, category: .connection,
                  message: "자동 페어링 시도: \(saved.macName) (\(saved.host):\(saved.port))")
        let endpoint = RelayEndpoint(host: saved.host, port: saved.port,
                                     pairingCode: saved.pairingCode)
        await connect(to: endpoint)
        // connect() 가 실패했거나 isAutoPairing 이 welcome 핸들러에서 이미 false 됐을 수 있음.
        isAutoPairing = false
    }

    /// ConnectScreen 수동 취소 시 호출 — 자동 재시도 방지.
    public func cancelAutoPair() {
        isAutoPairing = false
        UserDefaults.standard.set(true, forKey: PersistKeys.autoPairCancelled)
    }

    /// transport 끊김 후 **무한 자동 재시도** (포그라운드 + 온라인 동안).
    ///
    /// 종전 5회(31초) 제한 → 실제 WiFi 끊김이 31초를 넘기면 포기해 수동 재연결을
    /// 강요했다. 신규 정책:
    /// - 멈춤 조건: 사용자 명시 disconnect / Task 취소 / 연결 성공뿐.
    /// - 오프라인 동안에는 시도를 소진하지 않고 `NetworkPathMonitor` 복구 신호를 대기.
    /// - backoff 는 `ReconnectPolicy`(equal jitter, cap 5초).
    /// - **`connect(to:)`/`setConnectionMode` 미사용** — 둘 다 내부에서 disconnect 로
    ///   `autoReconnectTask` 를 cancel 하므로 루프가 자기 자신을 끊는다. 대신
    ///   `performConnect(to:)` 직접 호출 (이미 닫힌 소켓 위에서 안전).
    private func scheduleAutoReconnect() {
        guard let saved = persistedEndpoint else { return }
        guard !userInitiatedDisconnect else { return }
        autoReconnectTask?.cancel()
        isReconnecting = true
        autoReconnectTask = Task { [weak self] in
            await self?.runReconnectLoop(host: saved.host,
                                         port: saved.port,
                                         pairingCode: saved.pairingCode)
        }
    }

    /// 자동 재연결 루프 본문. `Task { [weak self] in await self?.runReconnectLoop() }`
    /// 형태로만 호출되므로 클로저는 self 를 약하게 캡처 → cancel 시 정상 해제.
    private func runReconnectLoop(host: String, port: Int, pairingCode: String) async {
        var attempt = 0
        while !Task.isCancelled {
            if userInitiatedDisconnect { break }

            // 오프라인이면 시도를 소진하지 않고 네트워크 복구까지 대기.
            if !pathMonitor.isOnline {
                appendLog(level: .info, category: .connection,
                          message: "네트워크 끊김 — 복구를 기다립니다")
                while !Task.isCancelled, !pathMonitor.isOnline, !userInitiatedDisconnect {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if Task.isCancelled || userInitiatedDisconnect { break }
                attempt = 0   // 복구 직후엔 최소 지연으로 빠르게 재시도
            }

            attempt += 1
            autoReconnectAttempt = attempt
            let delayMs = reconnectPolicy.delayMs(attempt: attempt)
            appendLog(level: .info, category: .connection,
                      message: "자동 재연결 시도 \(attempt)회 (\(delayMs)ms 후)")
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            if Task.isCancelled || userInitiatedDisconnect { break }

            // 외부 끊김은 realRelay 모드에서만 발생. 모드가 다르면 (mock 등) 자동
            // 재연결 대상이 아니므로 종료. (setConnectionMode 는 disconnect 를 호출해
            // 이 루프를 cancel 하므로 여기서 호출하지 않는다.)
            guard connectionMode == .realRelay else { break }

            // 이전 소켓이 남아있을 수 있으니 idempotent close 로 정리 후 재연결.
            await relayClient.close(reason: "reconnectRetry")
            let endpoint = RelayEndpoint(host: host, port: port, pairingCode: pairingCode)
            let ok = await performConnect(to: endpoint)
            if ok {
                autoReconnectAttempt = 0
                isReconnecting = false
                appendLog(level: .info, category: .connection,
                          message: "자동 재연결 성공 (\(attempt)회 시도)")
                return
            }
        }
        isReconnecting = false
        autoReconnectAttempt = 0
    }

    /// 네트워크 복구 / 앱 포그라운드 복귀 시 즉시 재연결을 트리거.
    private func kickReconnectNow(trigger: String) {
        guard !userInitiatedDisconnect else { return }
        guard persistedEndpoint != nil else { return }
        if case .connected = transport { return }
        appendLog(level: .info, category: .connection,
                  message: "\(trigger) — 재연결 시도")
        autoReconnectAttempt = 0
        scheduleAutoReconnect()   // 기존 루프 cancel 후 새로 시작 (중복 안전)
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

    /// 사용자/자동 페어링 진입점. 모드 전환 + 기존 세션 정리 후 실제 연결.
    ///
    /// **자동 재연결 루프는 이 메서드를 호출하지 않는다** — 내부 `disconnect()` 가
    /// `autoReconnectTask` 를 cancel 해 루프가 자기 자신을 끊는 버그가 있었기 때문.
    /// 루프는 정리 단계 없이 `performConnect(to:)` 를 직접 호출한다.
    @discardableResult
    public func connect(to endpoint: RelayEndpoint) async -> Bool {
        let desiredMode = Self.desiredConnectionMode(for: endpoint)
        if desiredMode != connectionMode {
            await setConnectionMode(desiredMode)
        }
        await disconnect(reason: "reconnect")
        // 사용자/자동 페어링은 "연결을 원함" 의사 표명 — 이후 외부 끊김 시 자동
        // 재연결이 다시 동작하도록 플래그 해제 (disconnect 가 true 로 만든 직후).
        userInitiatedDisconnect = false
        return await performConnect(to: endpoint)
    }

    /// 실제 hello/welcome 핸드셰이크만 수행 (정리/모드전환 없음). 성공 시 true.
    @discardableResult
    private func performConnect(to endpoint: RelayEndpoint) async -> Bool {
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
            return true
        } catch {
            stateMachine.apply(.pairingFailed)
            pilotState = stateMachine.state
            lastError = String(describing: error)
            appendLog(level: .error, category: .connection,
                      message: "연결 실패: \(lastError ?? "?")")
            return false
        }
    }

    public func connectMockReview() async {
        await connect(to: RelayEndpoint(host: "mock", port: 0, pairingCode: "000000"))
    }

    public func disconnect(reason: String = "user") async {
        // V297-8 (P3-iOS): 사용자/시스템 명시 disconnect — 자동 재시도 방지.
        userInitiatedDisconnect = true
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        autoReconnectAttempt = 0
        isReconnecting = false
        await heartbeat?.stop(sendStop: false, reason: .user)
        heartbeat = nil
        await relayClient.close(reason: reason)
        pairedEndpoint = nil
        telemetry = nil
        telemetryHistory.removeAll()
        serverCapabilities = nil
        estopVerificationStatus = nil
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
    /// P2-2 / V297-5 MEDIUM-4: real relay 에서는 서버 capabilities.head 가 true 인
    /// 경우에만 허용. **nil 정책**: legacy Mac (capabilities 자체 미송신) 도 안전 우선
    /// 으로 false 로 취급 — 종전 주석 "legacy 로 시도" 가 실제 코드와 불일치였음.
    /// legacy Mac 으로 head 보내면 unknownType 또는 internalError 응답을 받아 UX 가
    /// 일관되지 않으므로 차단이 안전.
    public var headControlSupported: Bool {
        if connectionMode == .mockReview { return true }
        return serverCapabilities?.head == true   // nil → false (conservative)
    }

    /// 볼 트래킹 (2026-06-02) — 로봇 온보드 자동 헤드 추적. head 와 달리 robot 측에서
    /// 처리하므로 MVP 지원. Mac 이 capabilities.ballTracking=true 면 버튼 노출.
    public var ballTrackingSupported: Bool {
        if connectionMode == .mockReview { return true }
        return serverCapabilities?.ballTracking == true   // nil → false (conservative)
    }

    /// 볼 트래킹 현재 on/off 상태 (화면 토글 + 조종기 버튼이 공유하는 source of truth).
    /// sendBallTrack 이 낙관적으로 갱신, reject/fail 시 롤백.
    @Published public private(set) var ballTrackingActive: Bool = false

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
        // V297-8 (P3-iOS): send() 로 receipt 수신 후 outcome 분기 처리.
        // Mac safetyAbort 검증 실패 시 사용자에게 즉시 경고.
        do {
            let receipt = try await relayClient.send(env)
            lastReceipt = receipt
            switch receipt.outcome {
            case .acked:
                appendLog(level: .info, category: .safety,
                          message: "긴급 정지 확인", commandId: receipt.commandId)
                estopVerificationStatus = nil
            case .rejected(let rejReason, let message):
                estopVerificationStatus = "정지 검증 실패: \(rejReason.rawValue) — \(message ?? "")"
                appendLog(level: .error, category: .safety,
                          message: "정지 검증 실패: \(rejReason.rawValue) — 물리 정지 버튼 즉시 누르세요!",
                          commandId: receipt.commandId)
            case .failed(let failReason, let message):
                estopVerificationStatus = "정지 실패: \(failReason.rawValue) — \(message ?? "")"
                appendLog(level: .error, category: .safety,
                          message: "정지 실패: \(failReason.rawValue) (\(message ?? "")) — 즉시 물리 정지 버튼!",
                          commandId: receipt.commandId)
            case .accepted:
                break
            }
        } catch {
            appendLog(level: .error, category: .safety,
                      message: "긴급 정지 전송 실패: \(error). 물리 긴급 정지 버튼을 사용하세요.")
        }
        _ = result
    }

    // V297-6 / V297-7 / V297-9 CRITICAL-1: E-Stop 이후 복구 흐름.
    //
    // V297-9: pilot.arm 재사용에서 **pilot.recover 전용 명령** 으로 분리.
    // 이유: arm → recover 자동 분기가 stale ARM 의 자동 복구로 둔갑 가능 (race).
    // 명령 type 자체를 분리해 의도를 명확히.
    //
    // Flow:
    //   estopped + armRequested → arming  (state machine V297-7)
    //   arming  + armed         → armedReady (recover ack)
    //   arming  + 실패 path     → estopped 유지 (.recoveryFailed apply — V297-7 P2)
    public func performRecover() async {
        let localEstopped = (pilotState == .estopped)
        let remoteEstopped = (telemetry?.uiState == .estopped)
        guard localEstopped || remoteEstopped else { return }
        // V297-9: 별도 pilot.recover 명령.
        let env = commandBuilder.recover(RecoverPayload(cradleConfirmed: true,
                                                        operator: deviceName))
        pendingCommandLabel = "복구"
        stateMachine.apply(.armRequested)
        pilotState = stateMachine.state
        do {
            let receipt = try await relayClient.send(env)
            lastReceipt = receipt
            switch receipt.outcome {
            case .acked:
                stateMachine.apply(.armed)
                recoveryBanner = nil
                appendLog(level: .info, category: .safety,
                          message: "복구 완료", commandId: receipt.commandId)
            case .rejected(let reason, let message):
                // V297-7 재검증 P2: 복구 실패는 .recoveryFailed 로 — .estopRequested 의
                // 사이드이펙트 (가짜 "E-stop requested by user" 로그, banner 중복) 회피.
                stateMachine.apply(.recoveryFailed(reason: "rejected:\(reason.rawValue)"))
                appendLog(level: .warning, category: .safety,
                          message: "복구 거부: \(reason.rawValue) — \(message ?? "") · 다시 시도하세요",
                          commandId: receipt.commandId)
            case .failed(let reason, let message):
                stateMachine.apply(.recoveryFailed(reason: "failed:\(reason.rawValue)"))
                appendLog(level: .error, category: .safety,
                          message: "복구 실패: \(reason.rawValue) — \(message ?? "") · 케이블/전원 확인 후 재시도",
                          commandId: receipt.commandId)
            case .accepted:
                break
            }
            pilotState = stateMachine.state
        } catch {
            // V297-7 재검증 P2: 송신 자체 실패 — recoveryFailed.
            stateMachine.apply(.recoveryFailed(reason: "sendError"))
            pilotState = stateMachine.state
            appendLog(level: .error, category: .safety,
                      message: "복구 송신 실패: \(error) · 연결 확인 후 재시도")
        }
        pendingCommandLabel = nil
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

    /// V297-9 HIGH: speedScale 전달 path. 호출자는 0.5~1.5 범위 (1.0 default).
    /// 기존 startWalk(_:) 와 호환 위해 default speedScale=1.0.
    public func startWalk(_ preset: WalkPreset, speedScale: Double = 1.0) async {
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
        // V297-9 HIGH: speedScale 실 전송 — 0.5~1.5 clamp 후 builder 에 전달.
        let clampedScale = min(max(0.5, speedScale), 1.5)
        let env = commandBuilder.walk(preset, speedScale: clampedScale)
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

    /// Whether analog freeform walking is executable in the current session.
    /// Real relay mode requires an explicit server capability so older Mac
    /// builds still fail closed.
    public var freeformWalkSupported: Bool {
        if connectionMode == .mockReview { return true }
        return serverCapabilities?.walkFreeform == true   // nil → false
    }

    /// V297-9 HIGH: Mac 서버가 WalkPayload.speedScale 을 실 적용하는지.
    /// V297-8 부터 Mac WalkLabSession.start(speedScale:) 로 amplitude 곱셈 적용.
    /// nil/false → false (보수). iOS UI 의 medium/fast 활성 여부.
    public var speedScaleSupported: Bool {
        if connectionMode == .mockReview { return true }
        return serverCapabilities?.speedScaleAccepted == true
    }

    /// Stream a single analog walk frame. The joystick view throttles to
    /// ~10Hz; the Mac relay applies each update to the active freeform walk
    /// loop and the heartbeat watchdog still owns deadman safety.
    public func streamWalk(_ input: WalkFreeformInput) async {
        guard pilotState.isArmed else { return }
        if let reason = CommandPermission.reason(forWalk: pilotState,
                                                 telemetry: telemetry) {
            appendLog(level: .warning, category: .command,
                      message: "자유 조종 대기: \(reason.koreanCopy)")
            return
        }
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
            pendingCommandLabel = "조종 중"
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

    /// 볼 트래킹 (2026-06-02) — 로봇 온보드 자동 헤드 추적 on/off 전송.
    /// 조종기 버튼/화면 토글이 호출. head 와 달리 robot 측 처리라 capabilities.ballTracking
    /// 로 gate (mockReview 는 항상 허용).
    public func sendBallTrack(enabled: Bool) async {
        guard ballTrackingSupported else {
            appendLog(level: .warning, category: .command,
                      message: "볼 트래킹은 이 Mac 빌드에서 지원되지 않아요.")
            return
        }
        guard isMacReady else {
            appendLog(level: .warning, category: .command,
                      message: "Mac 연결 후 볼 트래킹을 사용할 수 있어요.")
            return
        }
        let previous = ballTrackingActive
        ballTrackingActive = enabled   // 낙관적 — UI 토글 즉시 반영, reject/fail 시 롤백.
        let env = commandBuilder.ballTrack(enabled: enabled)
        do {
            let receipt = try await relayClient.send(env)
            lastReceipt = receipt
            switch receipt.outcome {
            case .acked(let ms):
                appendLog(level: .debug, category: .command,
                          message: "볼 트래킹 \(enabled ? "ON" : "OFF") (\(ms)ms)",
                          commandId: receipt.commandId)
            case .rejected(let r, let m):
                ballTrackingActive = previous
                appendLog(level: .warning, category: .command,
                          message: "볼 트래킹 거부 (\(r.rawValue)) \(m ?? "")",
                          commandId: receipt.commandId)
            case .failed(let r, _):
                ballTrackingActive = previous
                appendLog(level: .error, category: .command,
                          message: "볼 트래킹 실패 (\(r.rawValue))",
                          commandId: receipt.commandId)
            case .accepted:
                break
            }
        } catch {
            ballTrackingActive = previous
            appendLog(level: .error, category: .command,
                      message: "볼 트래킹 오류: \(error)")
        }
    }

    /// 조종기 버튼(X) 토글 — 현재 상태를 뒤집어 전송.
    public func toggleBallTracking() async {
        await sendBallTrack(enabled: !ballTrackingActive)
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
        estopVerificationStatus = nil
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
        // V297-8 (P3-iOS): 사용자 비명시 끊김이면 자동 재연결 시도.
        if !userInitiatedDisconnect {
            scheduleAutoReconnect()
        }
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
                          message: "Server caps — head=\(cap.head) freeform=\(cap.walkFreeform) speedScaleAccepted=\(cap.speedScaleAccepted)")
            }
            // V297-6 (PM Story S2.2): welcome 수신 직후 endpoint persist.
            // pairedEndpoint 는 connect() 에서 이미 set 돼 있음.
            if let ep = pairedEndpoint {
                saveEndpoint(ep, macName: env.payload.macName)
            }
            // S2.3: 자동 페어링 성공 → 플래그 해제.
            isAutoPairing = false
            // V297-8 (P3-iOS): 페어링 성공 — 자동 재시도 상태 reset.
            userInitiatedDisconnect = false
            autoReconnectAttempt = 0
            autoReconnectTask?.cancel()
            autoReconnectTask = nil
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

    /// 앱이 포그라운드로 복귀했을 때 호출 (RootView scenePhase `.active`).
    ///
    /// iOS 는 백그라운드 진입 수초 내 WebSocket 을 정지시키므로, 복귀 시 죽은 연결을
    /// 되살린다. 저장된 세션이 있고 사용자가 끊은 게 아니며 현재 미연결이면 즉시 재연결.
    ///
    /// **안전**: 전송만 복구하며 자동 ARM/보행 재개는 없다 (`handleExternalDisconnect`
    /// 가 ARM/safetyGate 를 이미 reset). 재연결 후 사용자가 다시 ARM 해야 한다.
    public func appDidBecomeActive() {
        kickReconnectNow(trigger: "앱 활성화")
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
