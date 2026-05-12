import Foundation
import ForgeCore

/// 앱 전체에 공유되는 연결 상태. 한 번에 하나의 Bus만 활성.
@MainActor
public final class ConnectionStore: ObservableObject {
    public enum Status: Equatable {
        case disconnected
        case connecting(String)
        case connected(BoardSnapshot)
        case error(String)
    }

    public enum TelemetryCadence: Sendable, Equatable {
        case off
        /// 보드 1 Hz + 4 샘플 관절 5 Hz.
        case light
        /// 16 관절 5 Hz.
        case full
    }

    @Published public var availablePorts: [String] = []
    @Published public var selectedPort: String?
    @Published public var status: Status = .disconnected
    @Published public var bus: Bus?
    @Published public var jointStates: [JointID: JointState] = [:]

    /// 현재 활성 endpoint (.usbSerial 또는 .network). 연결 해제 시 nil.
    @Published public var activeEndpoint: Endpoint?

    // ── 네트워크 endpoint (Manual entry) ──
    /// 사용자가 입력한 호스트 (예: "10.0.0.42" 또는 "op2.local").
    @Published public var networkHost: String = ""
    /// 사용자가 입력한 포트 (default 5530 — `forge serve`).
    @Published public var networkPort: UInt16 = 5530

    /// 가장 최근 폴링 텔레메트리 (StatusBar / Studio 등 위젯이 구독).
    @Published public var lastTelemetry: TelemetrySnapshot?

    /// 가장 최근 성공한 boardSnapshot 호출의 wall-clock 시점.
    /// 대시보드의 "마지막 통신" 표시용. 연결됨 상태에서 매 1초 갱신.
    @Published public private(set) var lastSuccessAt: Date?
    /// 연결 시작 시각 — uptime 계산용.
    @Published public private(set) var connectedAt: Date?
    /// 누적 통신 통계 (대시보드 카드).
    @Published public private(set) var successCount: Int = 0
    @Published public private(set) var failureCount: Int = 0
    /// 마지막 boardSnapshot 호출의 측정 latency (ms). 없으면 nil.
    @Published public private(set) var lastRoundTripMs: Double?

    /// 모터 이동 속도 프로파일 — Studio/Teach 의 자세 변경 시 사용.
    /// 기본: smooth (1초 보간).
    @Published public var motorSpeedProfile: MotorSpeedProfile = .smooth

    /// 부드러운 자세 적용 중인지 — UI 에서 표시.
    @Published public private(set) var isMovingPose: Bool = false

    /// 배터리 sparkline용 - 최근 60 sample (1 Hz 폴링 시 1분).
    @Published public private(set) var voltageHistory: [Double] = []
    @Published public private(set) var avgTempHistory: [Double] = []

    private var pollTask: Task<Void, Never>?
    private var cadence: TelemetryCadence = .off

    /// P0-D: bus drop watchdog. 연속 read/write 실패 카운터.
    /// 누적 임계 도달 시 bus = nil + status = .error 로 전환. 사용자에게 즉시 알림.
    ///
    /// USB와 네트워크 endpoint는 jitter 특성이 매우 다르다 — 임계와 폴링 주기를 분리.
    private var consecutiveBusFailures: Int = 0
    /// 연결 직후 안정화 grace — 이 시점까지는 watchdog disable.
    /// 첫 boardSnapshot 직후 TCP 큐가 비기 전 read를 시도하면 false-positive 가 잦다.
    private var stabilityGraceUntil: Date?

    /// endpoint 종류에 따른 임계. 네트워크는 nagle/fragmentation jitter를 감안해 더 관대.
    private var busFailureThreshold: Int {
        if let ep = activeEndpoint, case .network = ep { return 8 }
        return 3
    }
    /// endpoint 종류에 따른 폴링 주기.
    /// USB: 200ms (반응성 우선). 네트워크: 500ms (jitter 흡수).
    private func pollPeriodNs() -> UInt64 {
        if let ep = activeEndpoint, case .network = ep { return 500_000_000 }
        return 200_000_000
    }

    /// UserDefaults 키 — 마지막 성공 endpoint 영구 저장 (앱 재시작 후 자동 재연결).
    private static let lastEndpointKey = "df.lastSuccessfulEndpoint"

    public init() {
        // 앱 시작 시 마지막 성공 endpoint 복원.
        if let data = UserDefaults.standard.data(forKey: Self.lastEndpointKey),
           let ep = try? JSONDecoder().decode(Endpoint.self, from: data) {
            self.lastSuccessfulEndpoint = ep
        }
    }

    /// 마지막 성공 endpoint 영구 저장 — 다음 앱 실행 시 자동 재연결의 후보.
    private func persistLastEndpoint() {
        if let ep = lastSuccessfulEndpoint,
           let data = try? JSONEncoder().encode(ep) {
            UserDefaults.standard.set(data, forKey: Self.lastEndpointKey)
        }
    }

    /// 앱 진입 시 자동 재연결 시도 — 마지막 성공 endpoint 가 있으면 그것으로 연결.
    /// 호출자는 결과 (성공 여부) 받아 마법사 표시 여부 결정.
    public func autoReconnectIfPossible() async -> Bool {
        guard bus == nil, let ep = lastSuccessfulEndpoint else { return false }
        connect(endpoint: ep)
        try? await Task.sleep(nanoseconds: 800_000_000)
        if case .connected = status { return true }
        return false
    }

    // MARK: - Port management

    /// `/dev/cu.*` 후보 새로고침. 실패하면 에러 set.
    public func refreshPorts() {
        do {
            self.availablePorts = try SerialPortEnumerator.available()
            if selectedPort == nil {
                selectedPort = AutoConnect.bestGuess(among: availablePorts) ?? availablePorts.first
            } else if let p = selectedPort, !availablePorts.contains(p) {
                selectedPort = AutoConnect.bestGuess(among: availablePorts) ?? availablePorts.first
            }
        } catch {
            self.status = .error("포트 열거 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - Connection lifecycle

    /// 선택된 USB 포트로 연결 시도 (backward-compat).
    public func connect() {
        guard let port = selectedPort, !port.isEmpty else {
            status = .error("포트 선택 필요")
            return
        }
        connect(endpoint: .usbSerial(path: port))
    }

    /// 임의 endpoint(USB / TCP)로 연결. 비동기 + 3회 재시도 (stale buffer/misalignment 보정).
    /// 메인 스레드 block 없음. UI 는 status 변화로 즉시 반영.
    public func connect(endpoint: Endpoint) {
        cancelReconnect()
        status = .connecting(endpoint.displayName)
        Task { @MainActor in
            await performConnect(endpoint: endpoint, maxAttempts: 3)
        }
    }

    /// 내부 재시도 루프. 한 번 실패해도 200ms 후 다시 — Dynamixel byte sync slide 가
    /// 한 차례의 stale data 를 흡수하지 못하는 케이스 보정.
    private func performConnect(endpoint: Endpoint, maxAttempts: Int) async {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                let bus = try Bus(endpoint: endpoint)
                let t0 = Date()
                let snap = try bus.boardSnapshot()
                let rtt = Date().timeIntervalSince(t0) * 1000
                self.bus = bus
                self.activeEndpoint = endpoint
                self.lastSuccessfulEndpoint = endpoint
                self.persistLastEndpoint()
                self.reconnectAttempt = 0
                self.status = .connected(snap)
                self.lastTelemetry = TelemetrySnapshot(board: snap, joints: [:])
                self.connectedAt = Date()
                self.lastSuccessAt = Date()
                self.successCount = 1
                self.failureCount = 0
                self.lastRoundTripMs = rtt
                startTelemetry(cadence: .light)
                return
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    self.status = .connecting("\(endpoint.displayName) — 재시도 \(attempt + 1)/\(maxAttempts)")
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        let msg = (lastError as? ForgeError)?.localizedDescription
              ?? lastError?.localizedDescription ?? "원인 불명"
        self.status = .error("연결 실패 (\(maxAttempts)회 시도): \(msg)")
    }

    // MARK: - Auto-reconnect (네트워크 drop 시 백오프 재시도)

    /// 연결이 마지막으로 성공한 endpoint. 자동 재연결의 후보.
    @Published public private(set) var lastSuccessfulEndpoint: Endpoint?
    /// 현재까지 시도한 재연결 횟수 (0 = 아직 안 함).
    @Published public private(set) var reconnectAttempt: Int = 0
    /// 자동 재연결 active 여부 (UI 배너 표시용).
    @Published public private(set) var isReconnecting: Bool = false

    private var reconnectTask: Task<Void, Never>?
    private static let maxReconnectAttempts: Int = 5

    /// 자동 재연결 비활성화 (사용자가 명시적으로 끊기 누름 등).
    public func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        reconnectAttempt = 0
    }

    /// watchdog 또는 명시 호출로 끊긴 후 재연결 시도 (1, 2, 4, 8, 16초 백오프).
    public func startReconnectIfPossible() {
        guard let endpoint = lastSuccessfulEndpoint else { return }
        guard reconnectTask == nil else { return }
        isReconnecting = true
        let target = endpoint
        reconnectTask = Task { [weak self] in
            for attempt in 1...Self.maxReconnectAttempts {
                if Task.isCancelled { break }
                let delaySeconds = Double(1 << (attempt - 1))   // 1, 2, 4, 8, 16
                self?.reconnectAttempt = attempt
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                if Task.isCancelled { break }
                guard let self else { break }

                // 빠른 sanity check — 연결 시도.
                self.status = .connecting("자동 재연결 \(attempt)/\(Self.maxReconnectAttempts)")
                do {
                    let bus = try Bus(endpoint: target)
                    let snap = try bus.boardSnapshot()
                    self.bus = bus
                    self.activeEndpoint = target
                    self.status = .connected(snap)
                    self.lastTelemetry = TelemetrySnapshot(board: snap, joints: [:])
                    self.startTelemetry(cadence: .light)
                    self.isReconnecting = false
                    self.reconnectAttempt = 0
                    self.reconnectTask = nil
                    return
                } catch {
                    // 다음 attempt — 백오프.
                    continue
                }
            }
            // 모든 시도 실패.
            self?.isReconnecting = false
            self?.reconnectTask = nil
            self?.status = .error(
                "자동 재연결 \(Self.maxReconnectAttempts)회 모두 실패. 케이블·네트워크를 확인 후 수동으로 다시 연결해 주세요."
            )
        }
    }

    /// 사용자가 입력한 네트워크 정보로 연결.
    public func connectNetwork() {
        let host = networkHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            status = .error("호스트(IP 또는 이름)을 입력해 주세요. 예: 10.0.0.42 또는 op2.local")
            return
        }
        connect(endpoint: .network(host: host, port: networkPort))
    }

    /// 자동 USB 포트 추정 후 연결.
    public func autoConnect() {
        refreshPorts()
        guard let port = AutoConnect.bestGuess(among: availablePorts) ?? availablePorts.first else {
            status = .error("USB 직렬 포트가 보이지 않아요. 케이블·전원·드라이버를 확인해 주세요.")
            return
        }
        selectedPort = port
        connect()
    }

    /// 연결 해제 — 사용자 명시 호출. 자동 재연결도 취소.
    public func disconnect() {
        cancelReconnect()
        lastSuccessfulEndpoint = nil   // 명시적 disconnect는 자동 재연결 후보 제거.
        stopTelemetry()
        bus = nil
        activeEndpoint = nil
        jointStates.removeAll()
        lastTelemetry = nil
        voltageHistory.removeAll()
        avgTempHistory.removeAll()
        connectedAt = nil
        lastSuccessAt = nil
        lastRoundTripMs = nil
        status = .disconnected
    }

    // MARK: - Smooth pose apply

    /// 마지막 안전 이벤트 — UI 토스트 / 알림 표시용.
    @Published public private(set) var lastSafetyEvent: String?

    public func clearSafetyEvent() {
        lastSafetyEvent = nil
    }

    /// 자세 적용 — 안전 검증 + Mac 측 큰 변화 분할 + 부하 watchdog.
    ///
    /// 흐름 (ROBOTIS 포럼 + DARwIn-OP MotionManager 패턴):
    ///   1. SafeMotion.verify — voltage / load / angle limits 검증
    ///   2. requireSplit 이면 거리가 maxStepDegrees(60°) 이하가 되도록 중간 자세 단계 추가
    ///   3. 각 단계마다 moving_speed 설정 후 setPosition 일괄 전송
    ///   4. 단계 사이 대기 중 부하 watchdog — critical 부하 감지 시 즉시 e-stop
    public func applyPoseSmoothly(_ target: RobotPose, profile: MotorSpeedProfile? = nil) async {
        let p = profile ?? motorSpeedProfile
        guard let bus = bus else { return }

        // 1) 현재 자세 read — 안전 검증의 기준.
        var currentPositions: [JointID: Int] = [:]
        var loads: [JointID: Int] = [:]
        for j in JointID.allCases {
            if let s = try? bus.readState(j) {
                currentPositions[j] = Int(s.presentPosition)
                loads[j] = Int(s.presentLoad)
            } else {
                currentPositions[j] = target.positions[j] ?? 2048
            }
        }
        let currentPose = RobotPose(positions: currentPositions)
        let voltage = lastTelemetry?.board?.voltageVolts

        // 2) 안전 검증.
        let verdict = SafeMotion.verify(
            from: currentPose, to: target,
            voltageVolts: voltage, loads: loads
        )
        if !verdict.allowsProceed {
            self.lastSafetyEvent = "⚠ 자세 변경 거부 — \(verdict.message)"
            return
        }

        isMovingPose = true
        isMovingPoseCancelled = false
        defer { isMovingPose = false }

        // 3) 큰 변화면 분할. 60°를 단위로 중간 자세 만들기.
        let steps: [RobotPose] = Self.makeSafeSteps(
            from: currentPose, to: target,
            maxDeltaDeg: SafeMotion.maxStepDegrees
        )

        let speed = p.rawSpeedValue
        let stepDuration = max(0.3, p.durationSeconds / Double(steps.count))

        for (stepIdx, step) in steps.enumerated() {
            if isMovingPoseCancelled { break }

            // 4) 단계별 moving_speed 설정 후 전송.
            for j in step.positions.keys {
                _ = try? bus.setMovingSpeed(j, speed: speed)
            }
            for (j, raw) in step.positions {
                _ = try? bus.setPosition(j, raw: UInt16(clamping: raw))
            }

            // 5) 부하 watchdog — 단계 대기 중 100ms 마다 critical 부하 체크.
            let watchdogTicks = max(1, Int(stepDuration * 10))
            for _ in 0..<watchdogTicks {
                if isMovingPoseCancelled { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let dangerJoint = await checkCriticalLoad() {
                    // 즉시 토크 해제 — soft e-stop.
                    self.lastSafetyEvent = "🛑 \(dangerJoint.koreanLabel) 부하 위험 — 자세 변경 중단"
                    _ = try? bus.emergencyStop()
                    isMovingPoseCancelled = true
                    return
                }
            }

            if stepIdx < steps.count - 1 {
                // 단계 사이 짧은 정착 시간 — 모터가 trapezoidal motion 완료.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        self.lastSafetyEvent = nil
    }

    /// 부하 watchdog — 폴링 telemetry 의 load 값 검사. critical 이면 해당 관절 반환.
    private func checkCriticalLoad() async -> JointID? {
        guard let joints = lastTelemetry?.joints else { return nil }
        for (j, s) in joints {
            let pct = SafeMotion.loadPercent(Int(s.presentLoad))
            if pct >= SafeMotion.LoadLevel.critical {
                return j
            }
        }
        return nil
    }

    /// 큰 자세 변화를 maxDeltaDeg (=60°) 단위로 분할.
    private static func makeSafeSteps(from current: RobotPose,
                                      to target: RobotPose,
                                      maxDeltaDeg: Double) -> [RobotPose] {
        // 모든 관절 중 max delta 계산.
        var maxDelta: Double = 0
        for j in JointID.allCases {
            let from = Kinematics.degrees(fromRaw: current.positions[j] ?? 2048)
            let to   = Kinematics.degrees(fromRaw: target.positions[j] ?? 2048)
            let d = abs(to - from)
            if d > maxDelta { maxDelta = d }
        }
        let stepCount = max(1, Int((maxDelta / maxDeltaDeg).rounded(.up)))
        var steps: [RobotPose] = []
        for i in 1...stepCount {
            let frac = Double(i) / Double(stepCount)
            var dict: [JointID: Int] = [:]
            for j in JointID.allCases {
                let from = Double(current.positions[j] ?? 2048)
                let to   = Double(target.positions[j] ?? 2048)
                dict[j] = Int(from + (to - from) * frac)
            }
            steps.append(RobotPose(positions: dict))
        }
        return steps
    }

    /// 보간 중 중지 요청 (e.g. e-stop, 또 다른 자세 적용).
    @Published public private(set) var isMovingPoseCancelled: Bool = false
    public func cancelMovingPose() {
        if isMovingPose { isMovingPoseCancelled = true }
    }

    /// ease-in-out cubic.
    private static func easeInOut(_ t: Double) -> Double {
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    // MARK: - E-stop

    // MARK: - Bus failure tracking (P0-D)

    /// 외부 모듈 (StudioView, MotionStudioView 등)에서 bus 호출 throw를 보고하면 카운터 +1.
    /// 임계 도달 시 disconnect + status .error.
    public func handleBusError(_ error: Error) {
        // 안정화 grace 기간엔 카운터를 늘리지 않는다 — 연결 직후 false-positive 방지.
        if let until = stabilityGraceUntil, Date() < until { return }
        consecutiveBusFailures += 1
        if consecutiveBusFailures >= busFailureThreshold {
            let msg: String = {
                if let ep = activeEndpoint, case .network = ep {
                    return "네트워크 연결이 끊겼어요. socat이 종료되거나 네트워크가 불안정합니다. 자동 재연결을 시도합니다."
                }
                return "로봇과의 연결이 끊겼어요. USB 케이블·전원·드라이버를 확인한 뒤 다시 연결해 주세요."
            }()
            forceDisconnectWithError(msg)
        }
    }

    /// 폴링 또는 호출 성공 시 카운터 리셋.
    private func resetBusFailureCounter() {
        if consecutiveBusFailures > 0 { consecutiveBusFailures = 0 }
    }

    /// 강제 연결 종료 + 에러 상태 설정. e-stop 우선 시도하지만 bus가 이미 죽어 있으면 silently 진행.
    private func forceDisconnectWithError(_ message: String) {
        // 이미 disconnected/error 면 noop.
        if case .error = status { return }
        if bus != nil {
            // 마지막 안전 시도 — 토크 끄기. throw 무시 (어차피 끊긴 상태).
            try? bus?.emergencyStop()
        }
        stopTelemetry()
        bus = nil
        activeEndpoint = nil
        jointStates.removeAll()
        lastTelemetry = nil
        voltageHistory.removeAll()
        avgTempHistory.removeAll()
        status = .error(message)
        consecutiveBusFailures = 0

        // 네트워크 endpoint가 떨어진 경우 자동 재연결 시도 (USB는 사용자 개입 필요 — 케이블).
        if let last = lastSuccessfulEndpoint, last.isNetwork {
            startReconnectIfPossible()
        }
    }

    /// 응급 e-stop — 모든 관절 토크 OFF.
    public func emergencyStop() {
        guard let bus else { return }
        do {
            try bus.emergencyStop()
        } catch {
            status = .error("e-stop 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - Per-joint helpers (sync)

    /// 한 관절 상태 갱신 (sync, 메인 스레드).
    public func refreshJointState(_ joint: JointID) {
        guard let bus else { return }
        do {
            jointStates[joint] = try bus.readState(joint)
        } catch {
            print("readState(\(joint.name)) failed: \(error)")
        }
    }

    // MARK: - Telemetry polling (메인 스레드 안전)

    public func startTelemetry(cadence: TelemetryCadence) {
        stopTelemetry()
        guard cadence != .off else { return }
        self.cadence = cadence
        // 연결 직후 1초간 watchdog mask — TCP/serial 안정화 시간.
        self.stabilityGraceUntil = Date().addingTimeInterval(1.0)
        let pollNs = pollPeriodNs()
        pollTask = Task { [weak self] in
            await self?.runTelemetryLoop(periodNs: pollNs)
        }
    }

    public func stopTelemetry() {
        pollTask?.cancel()
        pollTask = nil
        cadence = .off
    }

    private static let lightSampleJoints: [JointID] =
        [.headPan, .headTilt, .rShoulderPitch, .rKnee]

    private func runTelemetryLoop(periodNs: UInt64) async {
        var tick = 0
        while !Task.isCancelled, let bus = self.bus {
            // P0-D: 보드 read는 매 5 tick (1 Hz). throw 감지 시 watchdog 카운터 +1.
            // 연속 임계 도달 시 forceDisconnectWithError 가 status를 .error로 전환.
            var didFail = false
            var board: BoardSnapshot? = lastTelemetry?.board
            if tick % 5 == 0 {
                let t0 = Date()
                do {
                    board = try bus.boardSnapshot()
                    let rtt = Date().timeIntervalSince(t0) * 1000
                    self.lastRoundTripMs = rtt
                    self.lastSuccessAt = Date()
                    self.successCount &+= 1
                } catch {
                    didFail = true
                    self.failureCount &+= 1
                    handleBusError(error)
                }
            }

            // 카운터 임계 도달 시 self.bus가 nil이 되어 다음 iteration의 while 조건에서 종료.
            if self.bus == nil { return }

            let joints: [JointID: JointState]
            switch cadence {
            case .full:
                joints = readJoints(bus: bus, list: JointID.allCases, didFail: &didFail)
            case .light:
                joints = readJoints(bus: bus, list: Self.lightSampleJoints, didFail: &didFail)
            case .off:
                return
            }

            // 이 사이에 watchdog가 trigger됐으면 종료.
            if self.bus == nil { return }

            // 한 사이클 내 모든 호출이 성공하면 카운터 reset.
            if !didFail { resetBusFailureCounter() }

            let snap = TelemetrySnapshot(board: board, joints: joints)
            self.lastTelemetry = snap
            // 주요 관절 캐시 업데이트.
            for (j, s) in joints { self.jointStates[j] = s }

            // 1초당 1회 sparkline에 추가.
            if tick % 5 == 0 {
                if let v = board?.voltageVolts {
                    voltageHistory.append(v)
                    if voltageHistory.count > 60 { voltageHistory.removeFirst() }
                }
                if let t = snap.avgTemperature {
                    avgTempHistory.append(t)
                    if avgTempHistory.count > 60 { avgTempHistory.removeFirst() }
                }
            }

            tick += 1
            try? await Task.sleep(nanoseconds: periodNs)
        }
    }

    /// 관절 상태 일괄 read. 실패가 1회라도 발생하면 didFail=true로 표시 — 호출자가 watchdog 카운터에 반영.
    private func readJoints(bus: Bus, list: [JointID], didFail: inout Bool) -> [JointID: JointState] {
        var out: [JointID: JointState] = [:]
        for j in list {
            do {
                out[j] = try bus.readState(j)
            } catch {
                didFail = true
                handleBusError(error)
                if self.bus == nil { return out }    // watchdog trigger 시 즉시 중단
            }
        }
        return out
    }
}
