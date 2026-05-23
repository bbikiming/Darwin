import AppKit
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
    /// **v1.14.8 (2026-05-21) perf #5**: status 전환 시 Harness heartbeat start/stop.
    /// 종전: DarwinForgeApp 가 launch 시 always-on startHeartbeat → 미연결 idle 에서
    ///       매 1s Timer wake-up + record() 호출 (v1.14.4 guard 안에서 즉시 return 하지만
    ///       wake-up 자체가 main actor 부담).
    /// 신규: connected 전환 시만 heartbeat. disconnected/error/connecting 으로
    ///       복귀하면 Timer 자체를 invalidate. didSet 은 동일 case 라도 발화하므로
    ///       wasConnected vs isConnected boolean transition 으로 idempotent.
    @Published public var status: Status = .disconnected {
        didSet {
            let wasConnected: Bool
            if case .connected = oldValue { wasConnected = true } else { wasConnected = false }
            let isConnected: Bool
            if case .connected = status { isConnected = true } else { isConnected = false }
            guard wasConnected != isConnected else { return }
            if isConnected {
                harness.startHeartbeat()
            } else {
                harness.stopHeartbeat()
            }
        }
    }
    /// 사이클 255 — `Bus` 구체 클래스 대신 `BusInterface` protocol 로 추상화.
    /// recovery / preflight / poseApply 의 unit test 에서 `MockBus` 주입 가능.
    /// 메서드 호출은 동일 (Bus 가 BusInterface conformance) — caller 코드 변경 없음.
    @Published public var bus: (any BusInterface)?
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

    /// **Wave 4.2.1 (사이클 V260-1)** — telemetry / IMU / FSR / sparkline health state.
    /// 종전: 17개 @Published 가 본 store 에 산재 → SwiftUI 가 작은 통계 갱신에도
    ///       전체 view graph 재평가 + god object 화. 신규: 별도 ObservableObject 로 격리.
    /// `health` 직접 노출은 새 코드용. 기존 view 의 `store.lastSuccessAt` 등은 아래
    /// backward-compat computed property 로 delegate 유지 — view migration 불필요.
    @Published public private(set) var health: ConnectionHealthStore

    // MARK: - Backward-compat delegate (view migration 없이 transparent)
    //
    // 모든 health-related property 는 `health` 로 위임. 외부 view/test 코드가 path
    // `store.lastSuccessAt` 등을 그대로 사용 가능. Wave 5 의 @Observable migration 이후
    // 단계적으로 `store.health.lastSuccessAt` 로 callsite 갱신 가능.

    /// 가장 최근 성공한 boardSnapshot 호출의 wall-clock 시점.
    public var lastSuccessAt: Date? { health.lastSuccessAt }
    /// 연결 시작 시각 — uptime 계산용.
    public var connectedAt: Date? { health.connectedAt }
    /// 누적 통신 통계 (대시보드 카드).
    public var successCount: Int { health.successCount }
    public var failureCount: Int { health.failureCount }
    /// 마지막 boardSnapshot 호출의 측정 latency (ms). 없으면 nil.
    public var lastRoundTripMs: Double? { health.lastRoundTripMs }

    // MARK: - IMU 전용 health (Codex 권고 — 잔여 2 잔여 4)
    //
    // IMU 는 board snapshot 과 별도 read — 같은 bus 라도 일부 펌웨어 / 모델은 IMU register
    // 응답 안 함. 전체 watchdog 에 합치면 "연결 끊김" 으로 오진. 별도 카운터로 추적.
    public var lastImuSuccessAt: Date? { health.lastImuSuccessAt }
    public var imuConsecutiveFailures: Int { health.imuConsecutiveFailures }
    public var lastImuError: String? { health.lastImuError }

    // MARK: - §4 wiring (2026-05-17 handoff)
    //
    // v2 pipeline 의 quality analyzer 는 IMU duplicate ratio (동일 sequence 중복 push)
    // 와 bus 실패율을 계산해서 grade A..F + useClass 를 결정. 이 wiring 포인트로
    // session 에 그 raw counter 노출.

    /// **Mac-side** successful-read counter — IMU read 성공할 때마다 ++.
    /// **주의 (Codex review 2026-05-18 MEDIUM-3)**: 이 값은 firmware 가 발행하는
    /// 진짜 sensor sequence 가 아니라, Mac 이 polling 으로 새 packet 받았다는 횟수.
    /// 따라서:
    ///   - **유의미**: "이 tick 사이 새 IMU read 가 있었나?" (값이 변했는지 비교)
    ///   - **무의미**: "같은 hardware sample 이 중복 push 됐나?" (Mac counter 는
    ///     매번 다른 값이라 packet-level duplicate 검출 불가)
    /// 진짜 duplicate ratio 가 필요하면 firmware 에 sequence field 추가 + ImuRaw 에
    /// 노출 후 그 값으로 교체.
    public var imuSequenceCount: UInt32 { health.imuSequenceCount }
    /// 누적 bus write 실패 (setPosition / setTorque / setPGain 등). 시작 시점 0 가정.
    public var busWriteFailureCount: Int { health.busWriteFailureCount }
    /// 누적 bus read 실패 (readImu / boardSnapshot / readState).
    public var busReadFailureCount: Int { health.busReadFailureCount }

    /// **v1.11.1 (2026-05-18 사용자 review MEDIUM-5)**: WalkLabSession 의 setPosition
    /// catch 경로에서 호출. underscore prefix 는 internal API 표시. external 직접 호출 X.
    public func _bumpBusWriteFailureCount() {
        health.bumpBusWriteFailure()
    }
    /// Mac-side complementary filter (Sprint 18 Phase E, Codex 잔여 4 v1.5 minimal viable).
    /// 5Hz IMU polling × tau=0.5s — alpha ≈ 0.71. 정적 tilt 보다 약간 개선.
    public var imuFilter: ImuFilter { health.imuFilter }

    /// 사이클 159 (P0-1, gyro closed-loop review fix):
    /// IMU polling 동적 모드. walk 활성 시 fast (50ms = 20Hz), idle 시 slow (200ms = 5Hz).
    ///
    /// # 비유
    ///
    /// 운전 중에는 거울을 자주 보고, 주차 중에는 가끔 본다. IMU 도 walk 중 자주 read 해야
    /// 보정 closed-loop 가 즉각 반응. idle 시는 5Hz 면 UI 게이지 충분 + CPU 절약.
    ///
    /// # 정책
    ///
    /// - `false` (default): 200ms = 5Hz — UI 표시 + fall-risk detection 용도.
    /// - `true` (WalkLabSession 가 walk 활성 시 set): 50ms = 20Hz — applyBalanceCorrection 의
    ///   freshness gate (250ms) 와 4 step 마진.
    ///
    /// 본 사이클은 종전 cycle 64 의 "perf optimization 5Hz" 결정을 walk-active 동안만 부분
    /// 무효화. idle 시 perf 유지.
    @Published public var imuFastPollActive: Bool = false

    /// **v1.11.17 (2026-05-19) — LiveGyroPanel 용**: 최신 raw IMU sample.
    /// 종전: imuFilter 만 expose 라 gyro 각속도 (X/Y/Z dps) UI 노출 불가.
    /// runImuLoop 가 매 polling 마다 갱신. UI 가 자이로 패널에서 직접 read.
    public var lastImuRaw: ImuRaw? { health.lastImuRaw }

    /// **v1.11.25 (2026-05-21) audit P0 robot-D** — 좌/우 FSR (foot pressure) 측정값.
    /// telemetry loop 가 1Hz 로 polling (board read 와 같은 cadence). board 미장착 시 nil.
    public var lastFsrLeft: FsrReading? { health.lastFsrLeft }
    public var lastFsrRight: FsrReading? { health.lastFsrRight }
    /// FSR 마지막 성공 read 시각 — telemetry loop 가 update.
    public var lastFsrSuccessAt: Date? { health.lastFsrSuccessAt }
    /// FSR 연속 실패 카운터 — 3회 도달 시 polling stop (board 미장착으로 간주).
    public var fsrConsecutiveFailures: Int { health.fsrConsecutiveFailures }
    /// FSR polling 자동 비활성 — board 미장착 robot 에서 spam 차단.
    public var fsrPollingDisabled: Bool { health.fsrPollingDisabled }

    /// IMU 가 5초 이상 응답 없으면 stale — UI 가 "IMU 오래됨" 라벨 표시.
    public var isImuStale: Bool { health.isImuStale }

    /// IMU 가 3회 연속 실패 + 마지막 성공이 없거나 30초 이상 전이면 unavailable —
    /// 사용자에게 "IMU 사용 불가" 라고 명확히 표시.
    public var isImuUnavailable: Bool { health.isImuUnavailable }

    /// 모터 이동 속도 프로파일 — Studio/Teach 의 자세 변경 시 사용.
    /// 기본: smooth (1초 보간).
    @Published public var motorSpeedProfile: MotorSpeedProfile = .smooth

    /// 부드러운 자세 적용 중인지 — UI 에서 표시.
    @Published public private(set) var isMovingPose: Bool = false

    /// 배터리 sparkline용 - 최근 60 sample (1 Hz 폴링 시 1분).
    public var voltageHistory: [Double] { health.voltageHistory }
    public var avgTempHistory: [Double] { health.avgTempHistory }

    private var pollTask: Task<Void, Never>?
    private var cadence: TelemetryCadence = .off

    /// P0-D: bus drop watchdog. 연속 read/write 실패 카운터.
    /// 누적 임계 도달 시 bus = nil + status = .error 로 전환. 사용자에게 즉시 알림.
    ///
    /// USB와 네트워크 endpoint는 jitter 특성이 매우 다르다 — 임계와 폴링 주기를 분리.
    private var consecutiveBusFailures: Int = 0

    /// 2026-05-17 chaos audit #3 fix (HIGH): 개별 모터 timeout 격리 카운터.
    /// 종전: HeadPan 만 응답 안 함 → handleBusError 호출 → 3번 누적 → 전체 USB
    /// 끊김으로 오진 → 사용자는 "USB 케이블 확인" 메시지 받음 (실제는 모터 1개).
    /// 신규: timeout / deviceNotFound 은 per-joint counter, io / 그 외만 global watchdog.
    @Published public private(set) var jointConsecutiveFailures: [JointID: Int] = [:]
    /// 개별 모터 "응답 없음" 표시 임계 — 5회 연속 실패 시 UI 에 명시.
    private static let jointFailureDisplayThreshold = 5

    // MARK: - IMU plausibility 자동 진단 (2026-05-17 v1.7 정정)

    /// IMU raw 값 sanity 진단. v1.7 (2026-05-17) — cm.rs/lib.rs 10-bit ADC 정정 후의
    /// 의미체계:
    ///   - 10-bit ADC raw u16 (0..1023), center 512.
    ///   - 직립 idle 시 accel Z 의 1g 중력 → raw 약 768 (center + 256 LSB).
    ///   - centered = raw - 512. accel Z centered 절대값이 약 200-300 이면 1g 감지 OK.
    ///
    /// 종전 v1.6 의 i16 + ±32767 가정 시기 misleading 했던 case 이름 보존 (downstream
    /// 영향 최소화), 분류 임계만 새 의미체계 기준.
    public enum ImuScaleSuspicion: String, Equatable, Sendable {
        /// 진단 불가 — sample 부족 또는 robot 움직임 중.
        case unknown
        /// 정상 — 10-bit ADC raw 가 1g 중력 패턴 보임 (accel Z |centered| ≈ 150-350).
        case looksValid16Bit = "정상 (10-bit ADC, 1g 중력 감지됨)"
        /// 주의 — 1g 중력 미감지 (사실상 자유낙하 추정치 또는 센서 stuck).
        case suspectedLegacy10Bit = "주의 — 중력 신호 약함 (센서 응답 확인)"
        /// 범위 밖 — 10-bit ADC 범위 (0..1023) 밖, chip variant 또는 firmware 변형 의심.
        case outOfRange = "비정상 — raw 범위 외 (chip variant?)"
    }
    @Published public private(set) var imuScaleSuspicion: ImuScaleSuspicion = .unknown
    /// 마지막 N sample 의 accel Z |centered| 평균. 0 = 아직 수집 안 됨.
    @Published public private(set) var imuAccelZMagnitudeAvg: Double = 0
    private var imuAccelZSamples: [UInt16] = []
    private static let imuScaleSamplesRequired = 25  // 5Hz × 5초 = 안정 추정.

    /// IMU sample 별 호출 — accel Z raw 기반 plausibility 추정 (v1.7 의미체계).
    private func diagnoseImuScale(_ sample: ImuRaw) {
        imuAccelZSamples.append(sample.accelZ)
        if imuAccelZSamples.count > Self.imuScaleSamplesRequired {
            imuAccelZSamples.removeFirst(imuAccelZSamples.count - Self.imuScaleSamplesRequired)
        }
        guard imuAccelZSamples.count >= Self.imuScaleSamplesRequired else {
            // 아직 sample 부족 — unknown 유지.
            return
        }
        // accel Z raw 평균.
        let sumRaw = imuAccelZSamples.reduce(0.0) { $0 + Double($1) }
        let avgRaw = sumRaw / Double(imuAccelZSamples.count)
        // centered = raw - 512. 직립 idle 1g 시 약 +200~+300 또는 -200~-300 (mounting 따라).
        let centeredMag = abs(avgRaw - 512.0)
        imuAccelZMagnitudeAvg = centeredMag

        let newSuspicion: ImuScaleSuspicion
        if avgRaw < 0 || avgRaw > 1023 {
            // 10-bit ADC 범위 외 → 결함 / firmware 변형 의심.
            newSuspicion = .outOfRange
        } else if centeredMag >= 50 && centeredMag <= 500 {
            // 1g gravity 감지됨 (±10-bit ADC chip/firmware 변형 허용, 관대한 범위).
            // 구 임계 150-400 은 raw ~580 또는 ~950 케이스를 outOfRange 오분류.
            newSuspicion = .looksValid16Bit
        } else if centeredMag < 50 {
            // 중력 미감지 — 자유낙하 또는 sensor stuck.
            newSuspicion = .suspectedLegacy10Bit
        } else {
            // |centered| > 500 — 10-bit 범위(0-1023)에서 극단치. chip 결함 의심.
            newSuspicion = .outOfRange
        }
        if newSuspicion != imuScaleSuspicion {
            imuScaleSuspicion = newSuspicion
        }
    }
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

    // MARK: - Harness DI (Wave 3 Phase 3.2, 사이클 242)
    //
    // 종전: `harness.record(...)` 직접 호출 (30 사이트) → RecordingHarness 주입 불가.
    // 신규: init 시점에 HarnessFacade 주입 (default = LiveHarness.shared — 기존 호출
    //       site 무손상). 테스트는 RecordingHarness 주입으로 connect/disconnect/imu/bus
    //       fail 등 connection lifecycle telemetry 검증.
    //
    // **default arg = nil pattern**: LiveHarness.shared 는 @MainActor 격리. Swift 6
    // strict concurrency 에서 nonisolated default arg evaluation warning 회피용.
    private let harness: any HarnessFacade

    public init(harness: (any HarnessFacade)? = nil) {
        self.harness = harness ?? LiveHarness.shared
        // Wave 4.2.1 — health state 격리 store. init 시 빈 상태.
        self.health = ConnectionHealthStore()
        // 앱 시작 시 마지막 성공 endpoint 복원.
        if let data = UserDefaults.standard.data(forKey: Self.lastEndpointKey),
           let ep = try? JSONDecoder().decode(Endpoint.self, from: data) {
            self.lastSuccessfulEndpoint = ep
        }

        // 2026-05-17 chaos audit CRITICAL #2: macOS sleep 시 자동 emergency stop.
        // 종전: 보행 중 시스템 sleep → wake 시 walkCycleTask 가 마지막 step 이후
        //       자세로 갑작스러운 큰 변화 송출 → fall 위험. 또한 sleep 동안 robot
        //       이 외력에 의해 다른 자세 됐을 수 있음 — 그 상태에서 motor 명령 = 위험.
        // 신규: willSleep → emergencyStop (torque OFF + 정지). wake 후 사용자가
        //       명시적 재연결 (현재 자세부터 시작) 필요.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emergencyStop()
            }
        }

        // v1.12.0 (2026-05-20) — Harness 에 context provider 등록.
        // Heartbeat 와 모든 event 가 자동으로 이 store 의 현재 상태 스냅샷을 첨부.
        self.harness.registerContextProvider { [weak self] in
            self?.harnessContext()
        }
    }

    /// 2026-05-17 concurrency review (agent #1 CRITICAL): pollTask / reconnectTask
    /// 누수 차단 + NSWorkspace observer 해제.
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pollTask?.cancel()
        reconnectTask?.cancel()
        // **v1.14.8 (2026-05-21) perf #1**: imuPollTask 누수 차단.
        // 종전: deinit 누락 → ConnectionStore 해제 후에도 IMU loop 가
        //       weak self 가 nil 되기까지 (다음 iter) 살아있을 수 있음.
        imuPollTask?.cancel()
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
        // v1.12.2 (Codex P1-3 fix) — telemetry harness: 연결 시도 기록 (redacted).
        harness.record(
            .connectAttempt, level: .info, actor: .user,
            data: ["endpoint_kind": AnyCodable(HarnessRedaction.endpointKind(endpoint)),
                   "endpoint": AnyCodable(HarnessRedaction.endpoint(endpoint) ?? "—")],
            context: harnessContext()
        )
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
                self.health.recordConnected(rttMs: rtt)
                startTelemetry(cadence: .light)
                // v1.12.2 telemetry — 연결 성공 (redacted).
                harness.record(
                    .connectSuccess, level: .notice, actor: .system,
                    data: ["endpoint": AnyCodable(HarnessRedaction.endpoint(endpoint) ?? "—"),
                           "endpoint_kind": AnyCodable(HarnessRedaction.endpointKind(endpoint)),
                           "rtt_ms": AnyCodable(rtt),
                           "attempt": AnyCodable(attempt)],
                    context: harnessContext()
                )
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
        // v1.12.2 telemetry — 연결 실패 (endpoint redacted, error msg 도 길이+해시만).
        harness.record(
            .connectFailure, level: .error, actor: .system,
            data: ["endpoint": AnyCodable(HarnessRedaction.endpoint(endpoint) ?? "—"),
                   "endpoint_kind": AnyCodable(HarnessRedaction.endpointKind(endpoint)),
                   "attempts": AnyCodable(maxAttempts),
                   "error_len": AnyCodable(msg.count),
                   "error_hash": AnyCodable(Harness.shortHash(msg))],
            context: harnessContext()
        )
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
        // **v1.14.2 (2026-05-21)** — reconnect cycle 시작 발화.
        harness.record(
            .connectReconnectStart, level: .notice, actor: .system,
            data: ["endpoint": AnyCodable(HarnessRedaction.endpoint(target) ?? "—"),
                   "endpoint_kind": AnyCodable(HarnessRedaction.endpointKind(target)),
                   "max_attempts": AnyCodable(Self.maxReconnectAttempts)],
            context: harnessContext()
        )
        reconnectTask = Task { [weak self] in
            for attempt in 1...Self.maxReconnectAttempts {
                if Task.isCancelled { break }
                let delaySeconds = Double(1 << (attempt - 1))   // 1, 2, 4, 8, 16
                self?.reconnectAttempt = attempt
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                if Task.isCancelled { break }
                guard let self else { break }

                // **v1.14.2** — 매 attempt 발화 — 진단성 위해 어디서 실패했는지 추적.
                harness.record(
                    .connectReconnectAttempt, level: .info, actor: .system,
                    data: ["attempt": AnyCodable(attempt),
                           "delay_s": AnyCodable(delaySeconds),
                           "endpoint": AnyCodable(HarnessRedaction.endpoint(target) ?? "—")],
                    context: harnessContext()
                )

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
                    // **v1.14.2** — reconnect 성공도 connect_success 와 동일하게.
                    harness.record(
                        .connectSuccess, level: .notice, actor: .system,
                        data: ["endpoint": AnyCodable(HarnessRedaction.endpoint(target) ?? "—"),
                               "endpoint_kind": AnyCodable(HarnessRedaction.endpointKind(target)),
                               "via": AnyCodable("reconnect"),
                               "attempt": AnyCodable(attempt)],
                        context: self.harnessContext()
                    )
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
            // **v1.14.2** — reconnect 최종 실패 발화 (사용자 개입 필요).
            self?.harness.record(
                .connectFailure, level: .error, actor: .system,
                data: ["via": AnyCodable("reconnect"),
                       "attempts": AnyCodable(Self.maxReconnectAttempts),
                       "endpoint": AnyCodable(HarnessRedaction.endpoint(target) ?? "—")],
                context: self?.harnessContext()
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
    ///
    /// CRITIC P1-B (race fix): 복구 중 사용자가 disconnect 누르면 복구 task 의 5 초
    /// settling 루프가 끝까지 돌고 `finalizeRecoveryState` 가 `guard let bus` early-return
    /// 으로 플래그 안 해제 → `isRecovering=true` 잔류 → 버튼 영구 disabled. disconnect
    /// 가 복구 관련 flag 도 동기 리셋해야 함.
    public func disconnect() {
        // v1.12.0 telemetry — 사용자 명시 disconnect (uptime 함께 기록).
        let uptime: Double = connectedAt.map { Date().timeIntervalSince($0) } ?? 0
        harness.record(
            .connectDisconnect, level: .notice, actor: .user,
            data: ["uptime_s": AnyCodable(uptime),
                   "success_count": AnyCodable(successCount),
                   "failure_count": AnyCodable(failureCount)],
            context: harnessContext()
        )
        cancelReconnect()
        // 복구 진행 중이면 task 에 cancel 신호 + 플래그 즉시 해제.
        if isRecovering || isInRecoveryPath {
            isMovingPoseCancelled = true
            isRecovering = false
            isInRecoveryPath = false
        }
        // 진행 중 자세 적용이 있었으면 cancel.
        if isMovingPose { isMovingPoseCancelled = true }
        lastSuccessfulEndpoint = nil   // 명시적 disconnect는 자동 재연결 후보 제거.
        stopTelemetry()
        bus = nil
        activeEndpoint = nil
        jointStates.removeAll()
        lastTelemetry = nil
        health.resetConnectionStats()
        // 2026-05-17 disconnect 시 IMU scale 진단 reset — 다음 연결에서 재진단.
        imuAccelZSamples.removeAll()
        imuAccelZMagnitudeAvg = 0
        imuScaleSuspicion = .unknown
        jointConsecutiveFailures.removeAll()
        status = .disconnected
    }

    // MARK: - Smooth pose apply

    /// 마지막 안전 이벤트 — UI 토스트 / 알림 표시용.
    @Published public private(set) var lastSafetyEvent: String?

    public func clearSafetyEvent() {
        lastSafetyEvent = nil
    }

    /// 자세 적용의 결과 — 호출자가 성공/실패를 명확히 구분할 수 있게.
    ///
    /// Codex 권고 (2026-05-13 1·2차):
    ///   - 1차: SafeMotion 거부 / write 실패를 silently swallow 하지 말 것.
    ///   - 2차: "절반 이상 실패 → writeFailed" 너무 관대. 하체 관절 1개 실패도
    ///          fall risk → hardFail. partial 은 별도 case 로 분리.
    public enum PoseApplyResult: Equatable, Sendable {
        /// 모든 step 이 정상 송출 + critical 부하 없이 종료.
        case completed
        /// 상체 관절만 일부 쓰기 실패 — 시각적으로는 이상 가능, 안전 OK.
        case partialFailure(positionFailed: Int, speedFailed: Int, totalJoints: Int, sample: String?)
        /// bus 미연결 — sim 만 진행, 실 모터 송출 없음.
        case notConnected
        /// SafeMotion.verify 거부 (voltage / load / angle).
        case rejected(reason: String)
        /// 진행 중 cancel — emergencyStop 또는 disarm.
        case cancelled
        /// 하체 (hip/knee/ankle) 관절 position write 실패 OR 모든 write 절반 이상 실패.
        /// 균형 위험 → 호출자는 사용자에게 hard fail 로 표시.
        case writeFailed(positionFailed: Int, speedFailed: Int, totalJoints: Int, sample: String?)
        /// 단계 대기 중 critical 부하 감지 → soft e-stop.
        case criticalLoad(joint: String)

        public var isSuccess: Bool {
            if case .completed = self { return true } else { return false }
        }

        /// 부분 실패까지는 호출자가 "진행" 처리 가능 (사용자에게 경고만).
        public var allowsContinue: Bool {
            switch self {
            case .completed, .notConnected, .partialFailure: return true
            case .rejected, .cancelled, .writeFailed, .criticalLoad: return false
            }
        }

        public var userMessage: String {
            switch self {
            case .completed:                       return "완료"
            case .partialFailure(let p, let s, let t, let sample):
                let suffix = sample.map { " · 예: \($0)" } ?? ""
                return "상체 부분 실패 — 위치 \(p)개·속도 \(s)개 (관절 총 \(t))\(suffix)"
            case .notConnected:                    return "실 로봇 미연결 — 시뮬 미리보기만 실행됨"
            case .rejected(let reason):            return reason
            case .cancelled:                       return "동작이 중단됐어요"
            case .writeFailed(let p, let s, let t, let sample):
                let suffix = sample.map { " · 예: \($0)" } ?? ""
                if p > 0 {
                    return "하체 목표 위치 전송 \(p)개 실패 — 균형 위험. USB·전원·ID 확인 (관절 총 \(t), 목표 속도 전송 \(s)개)\(suffix)"
                }
                return "쓰기 절반 이상 실패 — 위치 \(p)개·속도 \(s)개 (관절 총 \(t))\(suffix)"
            case .criticalLoad(let j):             return "\(j) 부하 위험 — 자동 정지"
            }
        }
    }

    /// 하체 (균형에 critical) 관절 — hip/knee/ankle 12개.
    /// 이 중 하나라도 position write 실패하면 fall risk.
    private static let lowerBodyJoints: Set<JointID> = [
        .rHipYaw, .lHipYaw, .rHipRoll, .lHipRoll,
        .rHipPitch, .lHipPitch,
        .rKnee, .lKnee,
        .rAnklePitch, .lAnklePitch, .rAnkleRoll, .lAnkleRoll,
    ]

    /// 자세 적용 — 안전 검증 + Mac 측 큰 변화 분할 + 부하 watchdog + write 실패 집계.
    ///
    /// 흐름 (ROBOTIS 포럼 + DARwIn-OP MotionManager 패턴):
    ///   1. SafeMotion.verify — voltage / load / angle limits 검증
    ///   2. requireSplit 이면 거리가 maxStepDegrees(60°) 이하가 되도록 중간 자세 단계 추가
    ///   3. 각 단계마다 moving_speed 설정 후 setPosition 일괄 전송
    ///   4. 단계 사이 대기 중 부하 watchdog — critical 부하 감지 시 즉시 e-stop
    ///
    /// **반환값**: 결과 유형. `.completed` 만 성공. 호출자는 `result.isSuccess` 또는
    /// pattern match 로 분기해야 한다. 결과를 무시할 수 있도록 `@discardableResult`.
    @discardableResult
    public func applyPoseSmoothly(_ target: RobotPose, profile: MotorSpeedProfile? = nil) async -> PoseApplyResult {
        let p = profile ?? motorSpeedProfile
        // v1.12.0 telemetry — pose 적용 시작.
        let poseStartedAt = Date()
        harness.record(
            .poseApplyStart, level: .info, actor: .system,
            data: ["joints": AnyCodable(target.positions.count),
                   "profile": AnyCodable(String(describing: p))],
            context: harnessContext()
        )
        // v1.12.2 (Codex re-review #14 fix) — 모든 종료 경로에서 telemetry 발행.
        // 결과를 변수에 받아 함수 끝에서 한 번에 처리하면 새 return 가 추가돼도 누락 X.
        let result = await applyPoseSmoothlyImpl(target: target, profile: p)
        let elapsedMs = Date().timeIntervalSince(poseStartedAt) * 1000.0
        recordPoseTerminal(result: result, elapsedMs: elapsedMs)
        return result
    }

    private func recordPoseTerminal(result: PoseApplyResult, elapsedMs: Double) {
        switch result {
        case .completed:
            harness.record(
                .poseApplyComplete, level: .info, actor: .system,
                data: ["elapsed_ms": AnyCodable(elapsedMs)])
        case .notConnected:
            harness.record(
                .poseApplyFailed, level: .warn, actor: .system,
                data: ["reason": AnyCodable("notConnected"),
                       "elapsed_ms": AnyCodable(elapsedMs)])
        case .rejected(let reason):
            harness.record(
                .poseApplyFailed, level: .warn, actor: .system,
                data: ["reason": AnyCodable("rejected"),
                       "reason_hash": AnyCodable(Harness.shortHash(reason)),
                       "elapsed_ms": AnyCodable(elapsedMs)])
        case .cancelled:
            harness.record(
                .poseApplyCancel, level: .info, actor: .user,
                data: ["elapsed_ms": AnyCodable(elapsedMs)])
        case .writeFailed(let pos, let speed, let total, _):
            harness.record(
                .poseApplyFailed, level: .error, actor: .robot,
                data: ["reason": AnyCodable("writeFailed"),
                       "position_failed": AnyCodable(pos),
                       "speed_failed": AnyCodable(speed),
                       "total_joints": AnyCodable(total),
                       "elapsed_ms": AnyCodable(elapsedMs)])
        case .partialFailure(let pos, let speed, let total, _):
            harness.record(
                .poseApplyComplete, level: .warn, actor: .system,
                data: ["partial": AnyCodable(true),
                       "position_failed": AnyCodable(pos),
                       "speed_failed": AnyCodable(speed),
                       "total_joints": AnyCodable(total),
                       "elapsed_ms": AnyCodable(elapsedMs)])
        case .criticalLoad(let joint):
            harness.record(
                .poseApplyFailed, level: .error, actor: .robot,
                data: ["reason": AnyCodable("criticalLoad"),
                       "joint": AnyCodable(joint),
                       "elapsed_ms": AnyCodable(elapsedMs)])
        }
    }

    /// Internal implementation — pose 적용 본체. 외부 wrapper 가 결과를 텔레메트리로 발행.
    ///
    /// **W2.8 (2026-05-23)**: 133줄 god function → facade + 5 helpers (~25줄 facade).
    /// 동작 100% 보존: bus guard → SafeMotion.verify → step loop (speed/position write +
    /// watchdog) → result aggregation. helper prefix `aps` = applyPoseSmoothly.
    ///
    /// helpers:
    ///   - `apsBuildContext` — bus / current pose read / verdict / step gen / counter init
    ///   - `apsWriteStepSpeeds` — per-joint speed write + DFLog
    ///   - `apsWriteStepPositions` — per-joint position write + lowerBody check + DFLog
    ///   - `apsRunWatchdog` — async load watchdog (returns early-return signal or nil)
    ///   - `apsBuildResult` — 하체/통신/상체 분기 → lastSafetyEvent + PoseApplyResult
    private func applyPoseSmoothlyImpl(target: RobotPose, profile p: MotorSpeedProfile) async -> PoseApplyResult {
        // 1) 컨텍스트 구축 — bus / 현재 자세 / verdict / steps / 카운터 초기화.
        let ctxResult = apsBuildContext(target: target, profile: p)
        switch ctxResult {
        case .earlyReturn(let result): return result
        case .ok(let ctx):
            isMovingPose = true
            isMovingPoseCancelled = false
            defer { isMovingPose = false }

            // 2) step loop — 각 step 마다 cancel → speed write → position write → watchdog.
            for (stepIdx, step) in ctx.steps.enumerated() {
                if isMovingPoseCancelled { return .cancelled }
                apsWriteStepSpeeds(step, ctx: ctx)
                apsWriteStepPositions(step, ctx: ctx)
                if let earlyReturn = await apsRunWatchdog(ctx: ctx) {
                    return earlyReturn
                }
                if stepIdx < ctx.steps.count - 1 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }

            // 3) 결과 집계 — 하체/통신/상체 분기 + lastSafetyEvent 설정.
            return apsBuildResult(ctx)
        }
    }

    // MARK: - applyPoseSmoothly helpers (W2.8)

    /// `apsBuildContext` 결과 — 즉시 종료(notConnected/rejected) vs 정상 컨텍스트.
    private enum ApsContextResult {
        case earlyReturn(PoseApplyResult)
        case ok(ApsContext)
    }

    /// `applyPoseSmoothlyImpl` per-call 가변 상태. reference type 으로 step loop /
    /// watchdog 사이에서 inout 없이 누적 카운터 공유.
    ///
    /// 동시성: `@MainActor` 인 ConnectionStore 안에서만 만들어지고 사용되므로 main actor
    /// 안에서만 접근. `Sendable` 표기 없음 — actor boundary 를 넘지 않는다.
    private final class ApsContext {
        let bus: any BusInterface
        let steps: [RobotPose]
        let speed: UInt16
        let stepDuration: Double
        let totalJoints: Int
        // Codex 2차: position / speed 실패 분리 + 하체 (균형) 실패 별도 set.
        var positionFailureCount: Int = 0
        var speedFailureCount: Int = 0
        var lowerBodyPositionFails: Set<JointID> = []
        var failedJointsUnique: Set<JointID> = []
        var lastWriteError: String? = nil

        init(bus: any BusInterface, steps: [RobotPose], speed: UInt16, stepDuration: Double, totalJoints: Int) {
            self.bus = bus
            self.steps = steps
            self.speed = speed
            self.stepDuration = stepDuration
            self.totalJoints = totalJoints
        }
    }

    /// step 1) — bus 미연결 / SafeMotion.verify 거부면 즉시 종료, 아니면 컨텍스트 반환.
    ///
    /// 동작 보존:
    ///   - `bus == nil` → `.notConnected` (lastSafetyEvent 미설정).
    ///   - readState 실패 → 해당 관절은 target 값(또는 2048) fallback (원본과 동일).
    ///   - verdict 거부 → `lastSafetyEvent` 작성 후 `.rejected(reason:)`.
    private func apsBuildContext(target: RobotPose, profile p: MotorSpeedProfile) -> ApsContextResult {
        guard let bus = bus else {
            return .earlyReturn(.notConnected)
        }

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
            return .earlyReturn(.rejected(reason: verdict.message))
        }

        // 3) 큰 변화면 분할. 60°를 단위로 중간 자세 만들기.
        let steps: [RobotPose] = Self.makeSafeSteps(
            from: currentPose, to: target,
            maxDeltaDeg: SafeMotion.maxStepDegrees
        )

        let ctx = ApsContext(
            bus: bus,
            steps: steps,
            speed: p.rawSpeedValue,
            stepDuration: max(0.3, p.durationSeconds / Double(steps.count)),
            totalJoints: JointID.allCases.count
        )
        return .ok(ctx)
    }

    /// step 2-a) — 한 step 의 모든 관절에 setMovingSpeed 일괄 전송. 실패 시 카운터 누적
    /// + DFLog.connection.warning (W1.2 silent-failure 진단 trail 보존).
    private func apsWriteStepSpeeds(_ step: RobotPose, ctx: ApsContext) {
        for j in step.positions.keys {
            do { try ctx.bus.setMovingSpeed(j, speed: ctx.speed) }
            catch {
                ctx.speedFailureCount += 1
                ctx.failedJointsUnique.insert(j)
                ctx.lastWriteError = "\(j.name) 목표 속도 전송: \(error.localizedDescription)"
                // P0 (2026-05-23): silent failure → 진단 trail 없음. DFLog 추가.
                // 카테고리=connection (DFLog.swift: ConnectionStore/SerialPort/SSH/NetworkProbe).
                // privacy=.public: joint.name + bus error 는 PII X (precedent: line 1381 readState).
                DFLog.connection.warning("setMovingSpeed 실패 joint=\(j.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// step 2-b) — 한 step 의 모든 관절에 setPosition 일괄 전송. 하체 관절 실패는
    /// `lowerBodyPositionFails` 에 별도 누적 (balance-critical → 결과 분기에서 hard fail).
    private func apsWriteStepPositions(_ step: RobotPose, ctx: ApsContext) {
        for (j, raw) in step.positions {
            do { _ = try ctx.bus.setPosition(j, raw: UInt16(clamping: raw)) }
            catch {
                ctx.positionFailureCount += 1
                ctx.failedJointsUnique.insert(j)
                if Self.lowerBodyJoints.contains(j) {
                    ctx.lowerBodyPositionFails.insert(j)
                }
                ctx.lastWriteError = "\(j.name) 목표 위치 전송: \(error.localizedDescription)"
                // P0 (2026-05-23): silent failure → 진단 trail 없음. DFLog 추가.
                DFLog.connection.warning("setPosition 실패 joint=\(j.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// step 2-c) — stepDuration 동안 100 ms 폴링. critical 부하 감지 시 emergencyStop +
    /// cancel 플래그 + `.criticalLoad` 반환. cancel 감지 시 `.cancelled` 반환.
    ///
    /// 반환값: 즉시 종료 결과 (있으면), `nil` 이면 다음 step 진행 가능.
    /// 동작 보존:
    ///   - sleep 전 `isMovingPoseCancelled` 체크 → 100 ms sleep → checkCriticalLoad.
    ///   - critical 감지 순서: lastSafetyEvent 작성 → emergencyStop → cancel 플래그 → return.
    private func apsRunWatchdog(ctx: ApsContext) async -> PoseApplyResult? {
        let watchdogTicks = max(1, Int(ctx.stepDuration * 10))
        for _ in 0..<watchdogTicks {
            if isMovingPoseCancelled { return .cancelled }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let dangerJoint = await checkCriticalLoad() {
                self.lastSafetyEvent = "🛑 \(dangerJoint.koreanLabel) 부하 위험 — 자세 변경 중단"
                _ = try? ctx.bus.emergencyStop()
                isMovingPoseCancelled = true
                return .criticalLoad(joint: dangerJoint.koreanLabel)
            }
        }
        return nil
    }

    /// step 3) — 결과 분기 + `lastSafetyEvent` 설정.
    ///
    /// 분기 우선순위 (원본 보존):
    ///   1. lowerBodyPositionFails 있음 → `.writeFailed` (균형 위험, hard fail).
    ///   2. 총 실패 >= 절반 → `.writeFailed` (통신 자체가 죽음).
    ///   3. position OR speed 실패 > 0 → `.partialFailure` (상체 부분 실패, 진행 가능).
    ///   4. 모두 통과 → `lastSafetyEvent = nil` + `.completed`.
    private func apsBuildResult(_ ctx: ApsContext) -> PoseApplyResult {
        let totalWrites = ctx.totalJoints * 2 * ctx.steps.count

        // **하체 position write 실패 1개라도 → writeFailed (균형 위험)**.
        if !ctx.lowerBodyPositionFails.isEmpty {
            self.lastSafetyEvent = "🛑 하체 \(ctx.lowerBodyPositionFails.count)개 목표 위치 전송 실패 — 균형 위험"
            return .writeFailed(
                positionFailed: ctx.positionFailureCount,
                speedFailed: ctx.speedFailureCount,
                totalJoints: ctx.failedJointsUnique.count,
                sample: ctx.lastWriteError
            )
        }

        // 모든 write 절반 이상 실패 → writeFailed (통신 자체가 죽음).
        let totalFailures = ctx.positionFailureCount + ctx.speedFailureCount
        if totalFailures >= max(1, totalWrites / 2) {
            self.lastSafetyEvent = "통신 절반 이상 실패 — bus 점검 필요"
            return .writeFailed(
                positionFailed: ctx.positionFailureCount,
                speedFailed: ctx.speedFailureCount,
                totalJoints: ctx.failedJointsUnique.count,
                sample: ctx.lastWriteError
            )
        }

        // 상체만 부분 실패 → partialFailure (시각 이상 가능, fall risk 없음).
        if ctx.positionFailureCount > 0 || ctx.speedFailureCount > 0 {
            self.lastSafetyEvent = "상체 부분 실패 — 위치 \(ctx.positionFailureCount)개·속도 \(ctx.speedFailureCount)개"
            return .partialFailure(
                positionFailed: ctx.positionFailureCount,
                speedFailed: ctx.speedFailureCount,
                totalJoints: ctx.failedJointsUnique.count,
                sample: ctx.lastWriteError
            )
        }

        self.lastSafetyEvent = nil
        return .completed
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
    ///
    /// **v1.14.2 (2026-05-21)** — 진단 친화 인자 추가 (둘 다 optional, 기본 호출 site 영향 X).
    /// `op`: "read" | "write" | "snapshot" 등. `joint`: 어떤 motor 였는지.
    public func handleBusError(_ error: Error,
                                 op: String? = nil,
                                 joint: JointID? = nil) {
        // 안정화 grace 기간엔 카운터를 늘리지 않는다 — 연결 직후 false-positive 방지.
        if let until = stabilityGraceUntil, Date() < until { return }
        consecutiveBusFailures += 1
        // v1.12.2 telemetry — bus 읽기 실패 (error msg redacted).
        // v1.14.2 — joint / op 진단 정보 추가 (옵셔널 — 호출 site 가 알면 첨부).
        let errMsg = error.localizedDescription
        var payload: [String: AnyCodable] = [
            "consecutive": AnyCodable(consecutiveBusFailures),
            "error_len": AnyCodable(errMsg.count),
            "error_hash": AnyCodable(Harness.shortHash(errMsg))
        ]
        if let op = op { payload["op"] = AnyCodable(op) }
        if let j = joint { payload["joint"] = AnyCodable(String(describing: j)) }
        harness.record(
            .busReadFail, level: .warn, actor: .robot,
            data: payload,
            context: harnessContext()
        )
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
        if consecutiveBusFailures > 0 {
            // **v1.14.2 (2026-05-21)** — bus 일시 실패 → 회복 발화. 실 로봇 시나리오에서
            // "1-2회 read 실패 후 다시 정상" 패턴 추적 — 일시적 단선 / EMI / power 강하 등.
            let prior = consecutiveBusFailures
            consecutiveBusFailures = 0
            harness.record(
                .busRecovered, level: .notice, actor: .robot,
                data: ["prior_consecutive": AnyCodable(prior)],
                context: harnessContext()
            )
        }
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
        health.resetConnectionStats()
        // 2026-05-17 disconnect 시 IMU scale 진단 reset — 다음 연결에서 재진단.
        imuAccelZSamples.removeAll()
        imuAccelZMagnitudeAvg = 0
        imuScaleSuspicion = .unknown
        jointConsecutiveFailures.removeAll()
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
        // v1.12.0 telemetry — e-stop 발동 (사용자 액션).
        harness.record(
            .busEStop, level: .error, actor: .user,
            data: ["source": AnyCodable("ConnectionStore.emergencyStop")],
            context: harnessContext()
        )
        do {
            try bus.emergencyStop()
        } catch {
            status = .error("e-stop 실패: \(error.localizedDescription)")
            let errMsg = error.localizedDescription
            harness.record(
                .busWriteFail, level: .error, actor: .robot,
                data: ["op": AnyCodable("emergencyStop"),
                       "error_len": AnyCodable(errMsg.count),
                       "error_hash": AnyCodable(Harness.shortHash(errMsg))],
                context: harnessContext()
            )
        }
    }

    // MARK: - 로봇 복구 (E-stop 이후 액추에이터 재활성)

    /// 복구 진행 여부 — UI 가 spinner 로 표시.
    @Published public private(set) var isRecovering: Bool = false

    /// 마지막 복구 결과 메시지 — 토스트 표시 + 자동 dismiss.
    @Published public private(set) var lastRecoveryResult: String?

    /// 복구 결과 유형 — 토스트 색 결정.
    public enum RecoveryOutcome: Equatable, Sendable {
        case success
        case failure
        case notConnected
    }

    @Published public private(set) var lastRecoveryOutcome: RecoveryOutcome?

    /// 복구 경로 진행 중 플래그 — applyPoseSmoothly 의 SafeMotion.verify /
    /// lastSafetyEvent 쓰기를 우회하기 위한 가드. 다른 UI 코드는 이 플래그를 안 봐도 됨.
    private var isInRecoveryPath: Bool = false

    /// E-stop 후 액추에이터 복구 — 사이드바 "로봇 복구" 버튼이 호출.
    ///
    /// 시퀀스 (Apple-style 안전 우선):
    ///   1. 버스 연결 확인 — 미연결 시 즉시 안내.
    ///   2. CRITIC P1-D: cradle 거치 확인 — `cradleConfirmed = false` 시 거부.
    ///      단발 다리 균형 변화로 fall 위험이라 정비 스탠드 거치가 필수.
    ///   3. CM dxl_power = 1 (E-stop 이 전원 차단까지 안 가지만 방어적 ON).
    ///   4. 모든 20개 관절 torque ON — SYNC_WRITE 1 회.
    ///   5. 내부 상태 리셋 (isMovingPoseCancelled / consecutiveBusFailures / lastSafetyEvent).
    ///   6. **`walkReady` 자세 (ROBOTIS deep squat) 로 매우 천천히 이동** — SafeMotion.verify 우회.
    ///      CRITIC P1-C: 종전엔 `.idle` (T-pose 직립) 으로 갔으나 이는 Sprint 16 hotfix v2 에서
    ///      "뒤로 넘어짐" 보고된 자세. v3 부터 walkReady = ROBOTIS deep squat 으로 변경됐고
    ///      복구 target 도 동일하게 deep squat 으로 통일 — 검증된 균형 자세.
    ///   7. 결과 토스트 + outcome 발행.
    ///
    /// 작업 진행 중에는 isRecovering = true → 버튼이 자동 disabled + spinner.
    /// 복구 경로 동안 lastSafetyEvent 는 절대 작성되지 않음 ("관절 안전 가이드" 미노출).
    ///
    /// `cradleConfirmed`: 호출자 (RootView / WalkLab) 가 정비 스탠드 거치를 사용자에게
    /// 명시 확인받았다는 신호. 기본값 false — 사용자가 명시적으로 cradle 확인하지 않은
    /// 호출은 자동 거부 (P1-D).
    ///
    /// **W2.9 분해 (2026-05-23)**: 154 줄 god method 를 facade + 6 helper + `RecoverContext` 로 분할.
    /// 동작 100% 보존 — refactor only. 단계 순서, 정착 시간, 안전 가드 모두 동일.
    /// W2.8 `ApsContext` 와 패턴 일관성 유지 (reference-type context, `re` prefix).
    ///
    /// helpers:
    ///   - `reGuardEntry` — 중복 호출 / bus nil / cradleConfirmed 3 게이트 + RecoverContext 생성
    ///   - `reSetupRecoveryFlags` — `isRecovering` / `isInRecoveryPath` ON + lastSafetyEvent clear
    ///   - `rePowerOnDxl` — CM dxl_power 3x 재시도 + 150ms 백오프 + 200ms 정착
    ///   - `reTorqueOnAllJoints` — 모든 관절 torque ON SYNC_WRITE 2x 재시도
    ///   - `reRestorePGains` — P_GAIN=32 복원 + 200ms 정착 + state reset + 400ms 정착
    ///   - `reFinalizeAndReport` — applyPoseSlowly + finalize + 결과 토스트
    public func recoverFromEStop(cradleConfirmed: Bool = false) async {
        guard let ctx = reGuardEntry(cradleConfirmed: cradleConfirmed) else { return }

        await reSetupRecoveryFlags()
        // 에러 경로용 fallback — 정상 경로에서는 finalizeRecoveryState 가 동기 정리.
        defer {
            Task { @MainActor in
                if self.isRecovering {
                    self.isRecovering = false
                    self.isInRecoveryPath = false
                }
            }
        }

        guard await rePowerOnDxl(ctx: ctx) else { return }
        guard await reTorqueOnAllJoints(ctx: ctx) else { return }
        await reRestorePGains(ctx: ctx)
        await reFinalizeAndReport(ctx: ctx)
    }

    // MARK: - recoverFromEStop helpers (W2.9)

    /// `recoverFromEStop` per-call 가변 상태. W2.8 `ApsContext` 와 동일한 reference-type
    /// 패턴 — async helper 간 누적 카운터를 inout 없이 공유.
    ///
    /// 동시성: `@MainActor` 인 ConnectionStore 안에서만 만들어지고 사용 — main actor 안에서만 접근.
    /// `Sendable` 표기 없음 — actor boundary 를 넘지 않는다.
    private final class RecoverContext {
        let bus: any BusInterface
        /// [2.5] P_GAIN 복원 실패 관절 수. `reRestorePGains` 가 write, `reFinalizeAndReport` 가 read.
        var pGainFailures: Int = 0
        /// [4] `applyPoseSlowlyForRecovery` 결과. `reFinalizeAndReport` 가 write & read.
        var diag: RecoveryDiagnostics? = nil

        init(bus: any BusInterface) {
            self.bus = bus
        }
    }

    /// 게이트 0/1/2 — 중복 호출 / bus nil / cradleConfirmed 검증 + 통과 시 `RecoverContext` 생성.
    ///
    /// 반환:
    ///   - `nil` — 게이트 실패. 호출자는 즉시 return (published state + scheduleResultDismiss 처리 완료).
    ///   - `RecoverContext` — 게이트 통과. 후속 helper 에 전달.
    ///
    /// 동작 보존:
    ///   - `isRecovering == true` → 조용히 nil (lastRecoveryResult 변경 없음).
    ///   - `bus == nil` → `.notConnected` 토스트 + dismiss.
    ///   - `cradleConfirmed == false` → P1-D 거부 토스트 + dismiss.
    private func reGuardEntry(cradleConfirmed: Bool) -> RecoverContext? {
        guard !isRecovering else { return nil }  // 중복 호출 차단.

        guard let bus = bus else {
            self.lastRecoveryOutcome = .notConnected
            self.lastRecoveryResult = "연결 안 됨 — 연결 마법사를 먼저 사용하세요"
            scheduleResultDismiss()
            return nil
        }

        // CRITIC P1-D: cradle 거치 확인 게이트. 다리 자세 변화로 fall 위험이므로 거치 필수.
        guard cradleConfirmed else {
            self.lastRecoveryOutcome = .failure
            self.lastRecoveryResult = "정비 스탠드 거치 확인이 필요합니다 — 복구 중 다리 자세가 변경됩니다"
            scheduleResultDismiss()
            return nil
        }

        return RecoverContext(bus: bus)
    }

    /// 복구 모드 진입 — `isRecovering` / `isInRecoveryPath` ON + E-stop 잔존 안전 이벤트 clear.
    ///
    /// 동작 보존: 원본은 `await MainActor.run { ... }` 로 감쌌지만 ConnectionStore 가 이미
    /// `@MainActor` 라 직접 set 과 동일. `await` 보존하면 suspension point 가 동일하게 유지.
    private func reSetupRecoveryFlags() async {
        await MainActor.run {
            self.isRecovering = true
            self.isInRecoveryPath = true
            // E-stop 직후 남아 있던 안전 이벤트 표시를 먼저 깨끗하게.
            self.lastSafetyEvent = nil
        }
    }

    /// [1] CM dxl_power ON — E-stop 후 일관성 보장. 3x 재시도 + 150ms 백오프 + 200ms 정착.
    ///
    /// 2026-05-17 사용자 보고 fix: 단일 시도 timeout 으로 recovery 실패.
    /// CM-740 의 dxl_power register 가 가끔 첫 write 응답 지연 → ForgeError.timeout.
    /// 3회 재시도 + 각 시도 사이 150ms 백오프 — robust.
    ///
    /// 반환: 성공 시 true (호출자가 다음 단계 진행). 실패 시 false (published state + dismiss 처리 완료).
    private func rePowerOnDxl(ctx: RecoverContext) async -> Bool {
        var dxlErr: Error?
        for attempt in 0..<3 {
            do {
                try ctx.bus.setDxlPower(true)
                dxlErr = nil
                break
            } catch {
                dxlErr = error
                if attempt < 2 { try? await Task.sleep(nanoseconds: 150_000_000) }
            }
        }
        if let err = dxlErr {
            self.lastRecoveryOutcome = .failure
            self.lastRecoveryResult = "모터 전원 ON 실패 (3회 재시도) — \(err.localizedDescription)"
            scheduleResultDismiss()
            return false
        }

        // 짧은 정착 — CM 보드 power-up.
        try? await Task.sleep(nanoseconds: 200_000_000)
        return true
    }

    /// [2] 모든 관절 torque ON — **per-joint write loop**. 2x 재시도 + 150ms 백오프.
    ///
    /// **사이클 252 (deployment readiness audit) — docstring 정정**:
    /// 종전 주석은 "SYNC_WRITE 한 패킷 형태" 였으나 실제로는 `JointID.allCases` 순회하며
    /// `bus.setTorque(j, true)` 를 개별 호출 — `fc_joint_set_torque_many` C-binding 이
    /// `forge_core.h` 에 미노출 (Rust 측 `control::set_torque_many` 는 존재).
    /// 1Mbps bus 기준 ~1ms/joint × 20 joint = ~20ms typical, 재시도 시 최대 ~40ms.
    /// 응급 복구 경로에서는 안전 수치이나, 향후 FFI 노출 시 ~1ms 로 단축 가능.
    ///
    /// 반환: 성공 시 true. 실패 시 false (published state + dismiss 처리 완료).
    private func reTorqueOnAllJoints(ctx: RecoverContext) async -> Bool {
        var torqueErr: Error?
        for attempt in 0..<2 {
            do {
                for j in JointID.allCases {
                    try ctx.bus.setTorque(j, enable: true)
                }
                torqueErr = nil
                break
            } catch {
                torqueErr = error
                if attempt < 1 { try? await Task.sleep(nanoseconds: 150_000_000) }
            }
        }
        if let err = torqueErr {
            self.lastRecoveryOutcome = .failure
            self.lastRecoveryResult = "관절 토크 ON 실패 — \(err.localizedDescription)"
            scheduleResultDismiss()
            return false
        }
        return true
    }

    /// [2.5] **2026-05-17 CRITICAL FIX**: P_GAIN 복원 (MX-28T default = 32).
    ///
    /// 사용자 보고 버그: emergencyStop 후 recovery 해도 "약한 토크 + 메뉴 동작
    /// 무반응". 원인: `Bus.emergencyStop()` → Rust `emergency_stop()` 가 torque OFF
    /// 와 동시에 **P_GAIN = 0** 으로 설정 (forge-core/control/mod.rs:214).
    /// 종전 recovery 는 torque 만 ON 하고 P_GAIN 복원 안 함 → 위치 제어 불능.
    ///
    /// 결과: 모터가 위치 명령 받아도 토크 못 만들음 → 자세 변경 무응답 → 모든
    /// 메뉴 (Walk/Pilot/MotionStudio) 의 setPosition 호출이 silently 무시되는
    /// 것처럼 보임. "약한 hold" 는 마찰 + 기어비 잔류만.
    ///
    /// Fix: 모든 관절 P_GAIN 을 default 32 로 ramp. 실패는 카운트만 (한 관절
    /// 실패해도 다른 관절은 정상 동작 — 부분 복구라도 사용자 가치).
    ///
    /// 추가로 [3] state reset 과 두 개의 정착 대기(200 ms + 400 ms) 를 동봉 — 동작 보존.
    /// `ctx.pGainFailures` 에 실패 카운트 누적.
    private func reRestorePGains(ctx: RecoverContext) async {
        for j in JointID.allCases {
            do { try ctx.bus.setPGain(j, value: 32) }
            catch {
                ctx.pGainFailures += 1
                // P0 (2026-05-23): silent failure → 진단 trail 없음. DFLog 추가.
                // recovery P-gain restore 가 실패하면 해당 관절은 위치 제어 불능 → root cause 추적 필수.
                DFLog.connection.warning("setPGain 실패 joint=\(j.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        // P_GAIN 정착 — 짧은 대기 (모터 내부 register write 후 효과 적용).
        try? await Task.sleep(nanoseconds: 200_000_000)

        // [3] 내부 상태 리셋 — 사용자가 다시 동작을 보낼 수 있도록.
        await MainActor.run {
            self.isMovingPoseCancelled = false
            self.consecutiveBusFailures = 0
            self.lastSafetyEvent = nil
        }

        // 토크 안정화 — 명령된 위치(현재 위치)로 모터 정착.
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    /// [4] + [5] + 결과 토스트.
    ///
    /// [4] walkReady (ROBOTIS deep squat) 로 매우 천천히 이동 — verify 우회 + 단일-shot + 5 초 정착.
    ///     CRITIC P1-C: 종전엔 `.idle` 이었으나 hotfix v2 "뒤로 넘어짐" 자세와 동일했음.
    ///     walkReady 는 hip ±36° / knee ±53° / ankle ±30° 의 검증된 균형 자세.
    /// [5] 후속 메뉴들이 정상 동작하도록 모든 상태 + 하드웨어 레지스터 리셋 (`finalizeRecoveryState`).
    ///
    /// 결과 분기:
    ///   - `diag.reached + pGainFailures == 0` → `.success`
    ///   - `diag.reached + pGainFailures > 0` → `.failure` (부분 성공이지만 P_GAIN 경고)
    ///   - `diag.cancelledByUser` → `.failure` ("복구 취소됨")
    ///   - `diag.summary.isEmpty == false` → `.failure` (통신 진단)
    ///   - else → `.failure` ("부분 완료")
    private func reFinalizeAndReport(ctx: RecoverContext) async {
        let diag = await applyPoseSlowlyForRecovery(.walkReady)
        ctx.diag = diag
        await finalizeRecoveryState()

        await MainActor.run {
            self.lastSafetyEvent = nil
            let pGainSuffix = ctx.pGainFailures > 0
                ? " (P_GAIN 복원 \(ctx.pGainFailures)개 실패 — 해당 관절 응답 약할 수 있음)"
                : ""
            if diag.reached {
                self.lastRecoveryOutcome = ctx.pGainFailures > 0 ? .failure : .success
                self.lastRecoveryResult = "복구 완료 — 기본 자세 + 토크 ON + 모든 메뉴 동작 가능\(pGainSuffix)"
            } else if diag.cancelledByUser {
                self.lastRecoveryOutcome = .failure
                self.lastRecoveryResult = "복구 취소됨 — 다시 시도하세요"
            } else if !diag.summary.isEmpty {
                // 통신 실패 진단 표시 — 사용자가 USB / 전원 점검 가능.
                self.lastRecoveryOutcome = .failure
                self.lastRecoveryResult = "복구 실패 — \(diag.summary). USB / 전원 / 모터 ID 확인\(pGainSuffix)"
            } else {
                self.lastRecoveryOutcome = .failure
                self.lastRecoveryResult = "복구 부분 완료 — 토크 ON 됐지만 일부 모터 응답 없음\(pGainSuffix)"
            }
        }
        scheduleResultDismiss()
    }

    /// 복구 완료 후 호출 — 후속 메뉴 모두가 정상 동작하도록 상태 + 하드웨어 리셋.
    ///
    /// **리셋 항목**:
    ///   1. (하드웨어) 모든 관절 `moving_speed = 0` — Dynamixel 공장 default. JointControl /
    ///      MotionStudio / Teach 등 setMovingSpeed 안 부르는 callers 의 동작 속도 정상화.
    ///   2. (Swift state) `isMovingPose`, `isMovingPoseCancelled`, `lastSafetyEvent`,
    ///      `consecutiveBusFailures`, `isRecovering`, `isInRecoveryPath` 모두 깨끗하게.
    ///   3. (텔레메트리) 한 번 fresh poll — applyPoseSmoothly 의 load watchdog 이 stale 값으로
    ///      false-positive trip 하지 않도록 갱신.
    ///   4. (정착) 400 ms 대기 — Dynamixel 의 present_load 노이즈 안정화.
    private func finalizeRecoveryState() async {
        guard let bus = bus else { return }

        // [a] moving_speed = 0 (factory default) — Dynamixel 내부 throttle 해제.
        //     이후 callers 가 setMovingSpeed 명시적으로 호출 안 해도 정상 속도로 동작.
        for j in JointID.allCases {
            try? bus.setMovingSpeed(j, speed: 0)
        }

        // [b] Swift state 동기 리셋 — defer 의 비동기 Task 보다 먼저 확정.
        await MainActor.run {
            self.isMovingPose = false
            self.isMovingPoseCancelled = false
            self.lastSafetyEvent = nil
            self.consecutiveBusFailures = 0
            self.isRecovering = false
            self.isInRecoveryPath = false
        }

        // [c] 정착 대기 — 모터 load 측정 노이즈 안정화. 이후 applyPoseSmoothly 의
        //     SafeMotion.verify 가 stale load 로 false-positive 거부 안 하도록.
        try? await Task.sleep(nanoseconds: 400_000_000)

        // [d] 텔레메트리 1 회 fresh refresh — UI 와 verify 가 최신 load / voltage 사용.
        await MainActor.run {
            for j in JointID.allCases {
                self.refreshJointState(j)
            }
        }
    }

    /// 복구 결과 (자세 변경 성공/실패 + 진단 문자열).
    public struct RecoveryDiagnostics: Equatable, Sendable {
        public let reached: Bool
        public let speedWriteFailures: Int
        public let positionWriteFailures: Int
        public let cancelledByUser: Bool
        public var summary: String {
            var bits: [String] = []
            if speedWriteFailures > 0 {
                bits.append("목표 속도 전송 실패 \(speedWriteFailures)/\(JointID.allCases.count)")
            }
            if positionWriteFailures > 0 {
                bits.append("목표 위치 전송 실패 \(positionWriteFailures)/\(JointID.allCases.count)")
            }
            if cancelledByUser { bits.append("사용자 취소") }
            return bits.joined(separator: " · ")
        }
    }

    /// 복구 전용 매우 느린 자세 적용 — SafeMotion.verify **우회**.
    ///
    /// **단순화된 단일-shot 방식** (이전 16-step interpolation 은 moving_speed 와
    /// 충돌해 모터가 따라잡지 못함):
    ///   1. 모든 관절 `moving_speed = 80` (~9 s per 360° — 안전하지만 시각적으로 명확).
    ///   2. 모든 관절에 `goal_position = target` **한 번만** 송출. Dynamixel 의 내부
    ///      trapezoidal motion controller 가 자체적으로 부드럽게 가속/감속.
    ///   3. 5 초 정착 대기 (250 ms × 20). 그 동안 isMovingPoseCancelled 가 true 되면 즉시 종료.
    ///   4. 모든 setMovingSpeed / setPosition 호출 결과를 **카운트** — 실패 수 진단 토스트 표시.
    ///   5. lastSafetyEvent 는 **절대 작성하지 않음**.
    private func applyPoseSlowlyForRecovery(_ target: RobotPose) async -> RecoveryDiagnostics {
        guard let bus = bus else {
            return RecoveryDiagnostics(
                reached: false,
                speedWriteFailures: 0,
                positionWriteFailures: 0,
                cancelledByUser: false
            )
        }

        await MainActor.run {
            self.isMovingPose = true
            self.isMovingPoseCancelled = false
        }
        defer {
            Task { @MainActor in self.isMovingPose = false }
        }

        var speedFailures = 0
        var posFailures = 0

        // [1] moving_speed = 80 — ~9 s per 360°. 충분히 느려서 안전, 충분히 빨라서 시각적으로
        //     자세 변화가 명확히 보임. 40 은 너무 느려 사용자가 "동작 안 한다" 고 느꼈음.
        let recoverySpeed: UInt16 = 80
        for j in JointID.allCases {
            do { try bus.setMovingSpeed(j, speed: recoverySpeed) }
            catch { speedFailures += 1 }
        }

        // 모터가 새 speed 를 적용할 짧은 시간.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // [2] 목표 위치 한 번에 송출 — Dynamixel 의 내부 controller 가 부드럽게 이동.
        for j in JointID.allCases {
            let raw = UInt16(clamping: target.positions[j] ?? 2048)
            do { _ = try bus.setPosition(j, raw: raw) }
            catch { posFailures += 1 }
        }

        // 모든 쓰기가 실패하면 즉시 보고 — 버스 다운.
        if speedFailures == JointID.allCases.count || posFailures == JointID.allCases.count {
            return RecoveryDiagnostics(
                reached: false,
                speedWriteFailures: speedFailures,
                positionWriteFailures: posFailures,
                cancelledByUser: false
            )
        }

        // [3] 5 초 동안 모터 물리 도달 대기 — 250 ms × 20 = 5 s.
        //     중간에 사용자가 E-stop 다시 누르거나 disconnect 하면 즉시 종료.
        for _ in 0..<20 {
            if isMovingPoseCancelled {
                return RecoveryDiagnostics(
                    reached: false,
                    speedWriteFailures: speedFailures,
                    positionWriteFailures: posFailures,
                    cancelledByUser: true
                )
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return RecoveryDiagnostics(
            reached: speedFailures == 0 && posFailures == 0,
            speedWriteFailures: speedFailures,
            positionWriteFailures: posFailures,
            cancelledByUser: false
        )
    }

    /// 4 초 후 토스트 자동 해제.
    private func scheduleResultDismiss() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.lastRecoveryResult = nil
            self?.lastRecoveryOutcome = nil
        }
    }

    // MARK: - Per-joint helpers (sync)

    /// 한 관절 상태 갱신 (sync, 메인 스레드).
    public func refreshJointState(_ joint: JointID) {
        guard let bus else { return }
        do {
            jointStates[joint] = try bus.readState(joint)
        } catch {
            // v1.11.23: print → OSLog. Console.app 에서 subsystem
            // "com.darwinforge" / category "connection" 으로 필터.
            // Codex HIGH fix: privacy=.public — joint.name + error 모두 공개 (개인 정보 X).
            DFLog.connection.error("readState(\(joint.name, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
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
        // **v1.10 (2026-05-17 debugger 분석)**: IMU 전용 50ms 별도 Task.
        // 종전: IMU read 가 runTelemetryLoop 의 joint/board read 와 같은 iteration
        //       → bus contention + 200ms duty → WalkLab tick (50ms) 에서 89.8% duplicate.
        // 신규: IMU 전용 50ms Task → WalkLab 과 1:1 sync. Bus 는 internal mutex 보호
        //       (Dynamixel SDK 패턴) 가정 — packet collision 없음.
        // **v1.14.8 (2026-05-21) perf #1**: 20Hz → 5Hz.
        // 종전: 50ms = 20Hz IMU polling. 매 iteration 마다 Task.detached
        //       + actor hop + @Published mutate → main actor 부하 + bus contention.
        // 신규: 200ms = 5Hz. WalkLab 의 SwiftUI redraw 와 fall detection (1Hz) 에
        //       충분. IMU sensor 자체는 200-500Hz 출력이지만 SwiftUI 표시는
        //       5Hz 면 사람 눈으로 부드러움. fall risk 는 별도 board IMU 직접
        //       read 로 보완 (telemetryLoop 안에서).
        //
        // **사이클 159 (P0-1 gyro closed-loop review fix)**: walk 활성 시 imuFastPollActive
        // = true 면 50ms (20Hz) 로 동적 증속 — applyBalanceCorrection 의 freshness gate
        // (250ms) 와 4 step 마진. idle 시 200ms (5Hz) 유지 → perf 영향 최소.
        // runImuLoop 안에서 flag 매 iter 확인. 시작 period 는 slow default.
        imuPollTask = Task { [weak self] in
            await self?.runImuLoop()
        }
    }

    public func stopTelemetry() {
        pollTask?.cancel()
        pollTask = nil
        imuPollTask?.cancel()
        imuPollTask = nil
        cadence = .off
    }

    /// v1.10 — IMU 전용 polling task. WalkLab 의 50ms tick 과 같은 rate 로 IMU update.
    private var imuPollTask: Task<Void, Never>?

    /// IMU 전용 polling loop. joint/board read 와 분리되어 bus contention 회피.
    /// 사이클 159 (P0-1 fix): period 는 imuFastPollActive flag 에 따라 동적 — fast 시 50ms,
    /// slow 시 200ms. WalkLabSession 가 walk start/stop 시 flag toggle.
    private func runImuLoop() async {
        // **v1.14.2 (2026-05-21) — IMU 상태 전환 트래킹**.
        // 매 iter 진입 전 직전 상태를 보고, 전환 발생 시 telemetry 발화.
        var prevImuUnavailable: Bool = false
        var prevImuStale: Bool = false
        var prevScaleSuspicion: ImuScaleSuspicion = .unknown
        // 사이클 159: 모드 전환 telemetry — fast↔slow 첫 전환에 .imuPollRateChanged 발화.
        var prevFastMode: Bool = self.imuFastPollActive
        while !Task.isCancelled, let bus = self.bus {
            let imuResult: Result<ImuRaw, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try bus.readImu()) }
                catch { return .failure(error) }
            }.value
            switch imuResult {
            case .success(let value):
                // **v1.14.2** — 회복 검출: 직전 unavailable 또는 stale 이었으면 telemetry.
                let wasUnavailable = prevImuUnavailable
                let wasStale = prevImuStale
                let priorFailures = self.imuConsecutiveFailures
                self.health.recordImuSuccess(raw: value)
                self.diagnoseImuScale(value)
                if let snap = self.lastTelemetry {
                    self.lastTelemetry = TelemetrySnapshot(board: snap.board, joints: snap.joints, imu: value)
                }
                // 회복 telemetry — 직전이 unavailable/stale 이었으면.
                if wasUnavailable {
                    harness.record(
                        .imuRecovered, level: .notice, actor: .robot,
                        data: ["from_state": AnyCodable("unavailable"),
                               "prior_failures": AnyCodable(priorFailures)],
                        context: harnessContext()
                    )
                } else if wasStale {
                    harness.record(
                        .imuRecovered, level: .notice, actor: .robot,
                        data: ["from_state": AnyCodable("stale"),
                               "prior_failures": AnyCodable(priorFailures)],
                        context: harnessContext()
                    )
                }
                // Scale suspicion 전환.
                if imuScaleSuspicion != prevScaleSuspicion, prevScaleSuspicion != .unknown {
                    harness.record(
                        .imuScaleChanged, level: .notice, actor: .robot,
                        data: ["from": AnyCodable(prevScaleSuspicion.rawValue),
                               "to": AnyCodable(imuScaleSuspicion.rawValue),
                               "accelz_mag_avg": AnyCodable(imuAccelZMagnitudeAvg)],
                        context: harnessContext()
                    )
                }
                prevScaleSuspicion = imuScaleSuspicion
                prevImuUnavailable = false
                prevImuStale = false

            case .failure(let error):
                self.health.recordImuFailure(error: error)
                // **v1.14.2** — 상태 전환 검출 (failure 누적이 임계 넘는 첫 순간).
                let nowUnavailable = isImuUnavailable
                let nowStale = isImuStale && !nowUnavailable
                if nowUnavailable, !prevImuUnavailable {
                    let errMsg = error.localizedDescription
                    harness.record(
                        .imuUnavailable, level: .warn, actor: .robot,
                        data: ["consecutive_failures": AnyCodable(imuConsecutiveFailures),
                               "error_len": AnyCodable(errMsg.count),
                               "error_hash": AnyCodable(Harness.shortHash(errMsg))],
                        context: harnessContext()
                    )
                    prevImuUnavailable = true
                } else if nowStale, !prevImuStale, !nowUnavailable {
                    harness.record(
                        .imuStale, level: .warn, actor: .robot,
                        data: ["consecutive_failures": AnyCodable(imuConsecutiveFailures),
                               "stale_for_s": AnyCodable(
                                   lastImuSuccessAt.map { Date().timeIntervalSince($0) } ?? 0)],
                        context: harnessContext()
                    )
                    prevImuStale = true
                }
            }
            // 사이클 159 (P0-1 fix): 동적 polling period — walk 활성 시 50ms, idle 시 200ms.
            // flag 변경 telemetry — 전환 시 한 번.
            let fastNow = self.imuFastPollActive
            if fastNow != prevFastMode {
                harness.record(
                    .imuPollRateChanged, level: .info, actor: .robot,
                    data: ["fast_mode": AnyCodable(fastNow),
                           "period_ms": AnyCodable(fastNow ? 50 : 200)],
                    context: harnessContext()
                )
                prevFastMode = fastNow
            }
            let periodNs: UInt64 = fastNow ? 50_000_000 : 200_000_000
            try? await Task.sleep(nanoseconds: periodNs)
        }
    }

    private static let lightSampleJoints: [JointID] =
        [.headPan, .headTilt, .rShoulderPitch, .rKnee]

    private func runTelemetryLoop(periodNs: UInt64) async {
        var tick = 0
        while !Task.isCancelled, let bus = self.bus {
            // 2026-05-17 perf audit T3.2 fix: bus I/O 를 background thread 에서 수행.
            // 종전: boardSnapshot (~200ms timeout) / readImu / readState 가 MainActor
            //       에서 동기 실행 → main thread 200-400ms stall → UI freeze.
            // 신규: Task.detached 로 background hop. Bus 가 `@unchecked Sendable` 이고
            //       BusActor 의 cross-thread access 안전성 보장됨 (Dynamixel SDK 가 mutex).
            //       결과만 MainActor 에서 publish — UI freeze 해소.

            // P0-D: 보드 read는 매 5 tick (1 Hz). throw 감지 시 watchdog 카운터 +1.
            // **사이클 141 (Swift 6 warning fix)**: imu 는 재할당 없음 → let.
            var didFail = false
            var board: BoardSnapshot? = lastTelemetry?.board
            let imu: ImuRaw? = lastTelemetry?.imu
            if tick % 5 == 0 {
                let t0 = Date()
                // background bus I/O.
                let result: Result<BoardSnapshot, Error> = await Task.detached(priority: .userInitiated) {
                    do { return .success(try bus.boardSnapshot()) }
                    catch { return .failure(error) }
                }.value
                switch result {
                case .success(let snap):
                    board = snap
                    let rtt = Date().timeIntervalSince(t0) * 1000
                    self.health.recordSuccess(rttMs: rtt)
                case .failure(let error):
                    didFail = true
                    self.health.recordFailure()
                    handleBusError(error)
                }

                // v1.11.25 audit P0 robot-D — FSR polling (board read 와 같은 1Hz cadence).
                // board 미장착 robot 일부에서는 timeout fail — 3회 연속 실패 시 자동 disable
                // 하여 polling spam 차단. 한 번 disable 되면 다음 connect 까지 재시도 안 함.
                if !self.fsrPollingDisabled {
                    let fsrResult: (Result<FsrReading, Error>, Result<FsrReading, Error>) =
                        await Task.detached(priority: .userInitiated) {
                            let l: Result<FsrReading, Error> = {
                                do { return .success(try bus.readFsrLeft()) }
                                catch { return .failure(error) }
                            }()
                            let r: Result<FsrReading, Error> = {
                                do { return .success(try bus.readFsrRight()) }
                                catch { return .failure(error) }
                            }()
                            return (l, r)
                        }.value
                    let leftOpt: FsrReading? = {
                        if case .success(let l) = fsrResult.0 { return l } else { return nil }
                    }()
                    let rightOpt: FsrReading? = {
                        if case .success(let r) = fsrResult.1 { return r } else { return nil }
                    }()
                    let fsrOk = (leftOpt != nil) || (rightOpt != nil)
                    if fsrOk {
                        self.health.updateFsr(left: leftOpt, right: rightOpt)
                    } else {
                        self.health.bumpFsrFailure()
                        if self.health.fsrConsecutiveFailures >= 3 {
                            self.health.disableFsrPolling()
                            // event tee — Harness 가 trace.
                            harness.record(
                                .telemetrySkip, level: .info, actor: .system,
                                data: ["reason": AnyCodable("fsr_board_missing"),
                                       "consecutive_failures": AnyCodable(self.health.fsrConsecutiveFailures)]
                            )
                        }
                    }
                }
            }

            // v1.10: IMU read 는 runImuLoop (50ms 전용 Task) 가 담당.
            // 여기서는 lastTelemetry.imu 만 reuse (이전 update 결과).
            // runImuLoop 가 자체적으로 lastTelemetry 의 imu 필드 갱신.

            // 카운터 임계 도달 시 self.bus가 nil이 되어 다음 iteration의 while 조건에서 종료.
            if self.bus == nil { return }

            // Joint reads — background. readJoints 자체는 MainActor (per-joint
            // counter 업데이트 때문) 이지만 read 호출만 background로 위임.
            let joints: [JointID: JointState]
            switch cadence {
            case .full:
                joints = await readJointsDetached(bus: bus, list: JointID.allCases, didFail: &didFail)
            case .light:
                joints = await readJointsDetached(bus: bus, list: Self.lightSampleJoints, didFail: &didFail)
            case .off:
                return
            }

            // 이 사이에 watchdog가 trigger됐으면 종료.
            if self.bus == nil { return }

            // 한 사이클 내 모든 호출이 성공하면 카운터 reset.
            if !didFail { resetBusFailureCounter() }

            let snap = TelemetrySnapshot(board: board, joints: joints, imu: imu)
            self.lastTelemetry = snap
            // 주요 관절 캐시 업데이트.
            for (j, s) in joints { self.jointStates[j] = s }

            // 1초당 1회 sparkline에 추가.
            if tick % 5 == 0 {
                if let v = board?.voltageVolts {
                    health.appendVoltage(v)
                }
                if let t = snap.avgTemperature {
                    health.appendAvgTemp(t)
                }
            }

            tick += 1
            try? await Task.sleep(nanoseconds: periodNs)
        }
    }

    /// 관절 상태 일괄 read. 실패가 1회라도 발생하면 didFail=true로 표시.
    ///
    /// 2026-05-17 chaos audit #3 fix: 개별 모터 timeout / deviceNotFound 격리.
    /// - `.timeout` / `.deviceNotFound`: per-joint counter — bus 전체는 살아있다
    ///   (e.g. HeadPan ID 19 만 응답 없음, headTilt/rShoulderPitch 정상).
    /// - 그 외 (`.io`, `.codec`, `.generic`): bus-level 실패 — global watchdog 트리거.
    ///   (PosixSerial 자체 read() throw = port closed = 전체 bus dead)
    /// 종전엔 모든 에러가 handleBusError 로 → 단일 모터 고장이 전체 disconnect 유발.
    private func readJoints(bus: any BusInterface, list: [JointID], didFail: inout Bool) -> [JointID: JointState] {
        var out: [JointID: JointState] = [:]
        for j in list {
            do {
                out[j] = try bus.readState(j)
                // 성공 — per-joint counter reset.
                if jointConsecutiveFailures[j] != nil {
                    jointConsecutiveFailures[j] = nil
                }
            } catch {
                didFail = true
                if isJointLevelError(error) {
                    // Per-joint timeout — global watchdog 미트리거.
                    jointConsecutiveFailures[j, default: 0] += 1
                } else {
                    // Bus-level (port closed / IO error) — global watchdog.
                    handleBusError(error)
                    if self.bus == nil { return out }
                }
            }
        }
        return out
    }

    /// 개별 모터 응답 없음 vs bus 전체 죽음 구분.
    private func isJointLevelError(_ error: Error) -> Bool {
        guard let fe = error as? ForgeError else { return false }
        switch fe {
        case .timeout, .deviceNotFound: return true
        case .io, .codec, .generic, .invalid, .panic: return false
        }
    }

    /// 2026-05-17 T3.2 perf: readJoints 의 bus.readState 호출만 background 위임.
    /// per-joint counter 업데이트 + watchdog 호출은 MainActor 격리 유지.
    /// MainActor 동기 readJoints 대비: ~20 joint × ~5ms = 100ms freeze 해소.
    private func readJointsDetached(bus: any BusInterface, list: [JointID], didFail: inout Bool) async -> [JointID: JointState] {
        // Background: 모든 joint read 를 한 번에 위임 (per-joint Task.detached 의 overhead 회피).
        let results: [(JointID, Result<JointState, Error>)] = await Task.detached(priority: .userInitiated) {
            var out: [(JointID, Result<JointState, Error>)] = []
            out.reserveCapacity(list.count)
            for j in list {
                do { out.append((j, .success(try bus.readState(j)))) }
                catch { out.append((j, .failure(error))) }
            }
            return out
        }.value

        // MainActor: 결과를 jointStates / per-joint counter / watchdog 에 반영.
        var out: [JointID: JointState] = [:]
        for (j, result) in results {
            switch result {
            case .success(let state):
                out[j] = state
                if jointConsecutiveFailures[j] != nil {
                    jointConsecutiveFailures[j] = nil
                }
            case .failure(let error):
                didFail = true
                if isJointLevelError(error) {
                    jointConsecutiveFailures[j, default: 0] += 1
                } else {
                    handleBusError(error)
                    if self.bus == nil { return out }
                }
            }
        }
        return out
    }
}
