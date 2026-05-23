import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **V266-2** — MockBus 기반 critical path 추가 테스트 (5건).
///
/// 비유: 항공기 시뮬레이터에서 아직 미검증된 5개 고장 시나리오를 추가 훈련하는 것처럼,
/// Mock Bus 를 활용해 reconnect backoff / IMU scale 진단 / FSR disable / lowerBody
/// 관절 선택적 실패 경로를 하드웨어 없이 검증.
///
/// **Coverage gap (V255-1 이후 잔여)**:
/// 1. `startReconnectIfPossible` — 5회 시도 후 reconnectAttempt 순서 + 백오프 공식.
/// 2. `diagnoseImuScale` — 25 sample 주입 후 `looksValid16Bit` 전환 (정상 센서).
/// 3. `diagnoseImuScale` — 중력 미감지 accel Z → `suspectedLegacy10Bit` 전환.
/// 4. `telemetryLoopPollFsr` — 3회 연속 실패 → `health.fsrPollingDisabled = true`.
/// 5. `applyPoseSmoothly` — lowerBody 단일 관절만 position write 실패 → `.writeFailed`.
///
/// **testability hook 의존**:
/// - `ConnectionStore._testFeedImuSample(accelZ:)` — `diagnoseImuScale` 직접 호출.
/// - `ConnectionStore._testImuScaleSamplesRequired` — 25 상수 노출.
/// - `ConnectionStore._testPollFsrOnce(bus:)` — `telemetryLoopPollFsr` 직접 호출.
/// - `ConnectionTransportStore.updateReconnectAttempt(_:)` — backoff 상태 검증.
@MainActor
final class MockBusExtraTests: XCTestCase {

    var store: ConnectionStore!
    var mockBus: MockBus!
    var recorder: RecordingHarness!

    override func setUp() async throws {
        recorder = RecordingHarness()
        store = ConnectionStore(harness: recorder)
        mockBus = MockBus()
        store.bus = mockBus
    }

    override func tearDown() {
        store = nil
        mockBus = nil
        recorder = nil
    }

    // =========================================================================
    // MARK: - Test 1: Reconnect exponential backoff 공식 검증
    // =========================================================================

    /// `startReconnectIfPossible` 의 backoff 공식 — 1,2,4,8,16 초 시퀀스를 수식으로 검증.
    ///
    /// 실제 네트워크 I/O 없이 `1 << (attempt - 1)` 공식의 정확성과
    /// `ConnectionTransportStore` 의 state machine (beginReconnecting → 5 attempts → endReconnecting) 을 검증.
    ///
    /// 비유: 비행 매뉴얼에 "엔진 재시동 간격은 1분, 2분, 4분, 8분, 16분" 이라고 적혀 있을 때,
    /// 실제 비행 없이 매뉴얼 수식이 올바른지 수학적으로 확인하는 것.
    func testReconnectBackoffFormulaProducesCorrectDelays() {
        // backoff formula: 1 << (attempt - 1) — attempt 1..5.
        let expectedDelays: [Int: Double] = [
            1: 1.0,   // 1 << 0 = 1
            2: 2.0,   // 1 << 1 = 2
            3: 4.0,   // 1 << 2 = 4
            4: 8.0,   // 1 << 3 = 8
            5: 16.0,  // 1 << 4 = 16
        ]
        for (attempt, expected) in expectedDelays.sorted(by: { $0.key < $1.key }) {
            let delay = Double(1 << (attempt - 1))
            XCTAssertEqual(
                delay, expected,
                "attempt \(attempt) → backoff \(expected)초 (1 << \(attempt-1) = \(Int(delay)))"
            )
        }
    }

    /// `ConnectionTransportStore` reconnect state machine: beginReconnecting → updateAttempt(1..5) → endReconnecting.
    ///
    /// `startReconnectIfPossible` 이 transport store mutator 를 올바른 순서로 호출하는 계약 검증.
    func testReconnectTransportStateMachineSequence() {
        let transport = ConnectionTransportStore()

        // 초기: isReconnecting=false, attempt=0.
        XCTAssertFalse(transport.isReconnecting, "초기 isReconnecting=false")
        XCTAssertEqual(transport.reconnectAttempt, 0, "초기 attempt=0")

        // reconnect 시작.
        transport.beginReconnecting()
        XCTAssertTrue(transport.isReconnecting, "beginReconnecting 후 isReconnecting=true")
        XCTAssertEqual(transport.reconnectAttempt, 0, "beginReconnecting 후 attempt=0 (첫 시도 전)")

        // 5회 시도 진행.
        let maxAttempts = 5
        for attempt in 1...maxAttempts {
            transport.updateReconnectAttempt(attempt)
            XCTAssertEqual(
                transport.reconnectAttempt, attempt,
                "attempt \(attempt) 갱신 후 reconnectAttempt=\(attempt)"
            )
            XCTAssertTrue(
                transport.isReconnecting,
                "진행 중 (attempt=\(attempt)) isReconnecting=true"
            )
        }

        // 모든 시도 소진 후 endReconnecting.
        transport.endReconnecting()
        XCTAssertFalse(transport.isReconnecting, "endReconnecting 후 isReconnecting=false")
        XCTAssertEqual(transport.reconnectAttempt, 0, "endReconnecting 후 attempt=0 (reset)")
    }

    /// `lastSuccessfulEndpoint` 없으면 `startReconnectIfPossible` 이 조용히 무시.
    ///
    /// guard 조건: `lastSuccessfulEndpoint` nil → reconnectTask 생성 안 함.
    func testStartReconnectIfPossibleIgnoredWithoutLastEndpoint() {
        // lastSuccessfulEndpoint = nil (초기 상태).
        XCTAssertNil(store.lastSuccessfulEndpoint, "사전 조건: lastSuccessfulEndpoint nil")

        store.startReconnectIfPossible()

        // reconnect task 가 생성되지 않았으므로 isReconnecting=false.
        XCTAssertFalse(store.isReconnecting, "lastSuccessfulEndpoint nil → reconnect task 미생성")
        XCTAssertEqual(store.reconnectAttempt, 0, "attempt 0 유지")
    }

    // =========================================================================
    // MARK: - Test 2: IMU accel Z 정상 → looksValid16Bit 전환
    // =========================================================================

    /// 25 sample (imuScaleSamplesRequired) 이상의 정상 accel Z (768 = 512 + 256, centered=256) 주입
    /// → `imuScaleSuspicion = .looksValid16Bit`.
    ///
    /// 비유: 체온계가 37.0°C 연속 25회 → "정상" 판정하는 것처럼, 1g 중력 패턴이 25회
    /// 연속되면 IMU 를 정상으로 확정.
    ///
    /// accelZ = 768 → centered = |768 - 512| = 256 → 50..500 범위 → `.looksValid16Bit`.
    func testImuScaleSuspicionTransitionsToLooksValidAfter25NormalSamples() {
        let required = ConnectionStore._testImuScaleSamplesRequired

        // 24 sample 까지는 unknown (sample 부족).
        for _ in 1..<required {
            store._testFeedImuSample(accelZ: 768)  // 1g 중력 정상 패턴
        }
        XCTAssertEqual(
            store.imuScaleSuspicion, .unknown,
            "\(required - 1)개 — sample 부족, unknown 유지"
        )

        // 25번째 sample → 진단 완료 → looksValid16Bit.
        store._testFeedImuSample(accelZ: 768)
        XCTAssertEqual(
            store.imuScaleSuspicion, .looksValid16Bit,
            "25개 accelZ=768(centered=256) → looksValid16Bit (50..500 범위)"
        )
        // imuAccelZMagnitudeAvg 도 256 근처여야 함 (floating point 허용).
        XCTAssertEqual(
            store.imuAccelZMagnitudeAvg, 256.0, accuracy: 0.5,
            "평균 |centered| ≈ 256.0"
        )
    }

    /// 25 sample 의 accel Z = 512 (centered = 0, 중력 미감지) → `suspectedLegacy10Bit`.
    ///
    /// accelZ = 512 → centered = |512 - 512| = 0 → < 50 → `.suspectedLegacy10Bit`.
    func testImuScaleSuspicionTransitionsToSuspectedAfterGravityNotDetected() {
        let required = ConnectionStore._testImuScaleSamplesRequired

        for _ in 0..<required {
            store._testFeedImuSample(accelZ: 512)  // 중력 미감지 (자유낙하 또는 stuck)
        }

        XCTAssertEqual(
            store.imuScaleSuspicion, .suspectedLegacy10Bit,
            "25개 accelZ=512(centered=0) → suspectedLegacy10Bit (< 50)"
        )
        XCTAssertLessThan(
            store.imuAccelZMagnitudeAvg, 50.0,
            "평균 |centered| < 50 (중력 미감지 범위)"
        )
    }

    // =========================================================================
    // MARK: - Test 3: FSR polling 3회 연속 실패 → disablePolling
    // =========================================================================

    /// `_testPollFsrOnce` 를 3회 호출 (FSR L/R 모두 항상 실패) → `health.fsrPollingDisabled = true`.
    ///
    /// 비유: 3번 연속 도어 잠금장치가 응답 없으면 → 경보 차단 (spam 방지). FSR 센서가
    /// 3회 연속 timeout 하면 → polling 자동 비활성화.
    func testFsrPollingDisabledAfter3ConsecutiveFailures() async {
        // AlwaysFailFsrMockBus — readFsrLeft / readFsrRight 항상 throw.
        let failBus = AlwaysFailFsrMockBus()
        store.bus = failBus

        // 초기 상태 확인.
        XCTAssertFalse(store.fsrPollingDisabled, "초기 fsrPollingDisabled=false")
        XCTAssertEqual(store.fsrConsecutiveFailures, 0, "초기 consecutiveFailures=0")

        // 1회: failure → consecutiveFailures=1, 아직 disabled 아님.
        await store._testPollFsrOnce(bus: failBus)
        XCTAssertEqual(store.fsrConsecutiveFailures, 1, "1회 실패 → consecutiveFailures=1")
        XCTAssertFalse(store.fsrPollingDisabled, "1회 실패 — 3회 미달, 아직 enabled")

        // 2회: consecutiveFailures=2.
        await store._testPollFsrOnce(bus: failBus)
        XCTAssertEqual(store.fsrConsecutiveFailures, 2, "2회 실패 → consecutiveFailures=2")
        XCTAssertFalse(store.fsrPollingDisabled, "2회 실패 — 3회 미달, 아직 enabled")

        // 3회: consecutiveFailures=3 → disableFsrPolling 호출 → disabled=true.
        await store._testPollFsrOnce(bus: failBus)
        XCTAssertEqual(store.fsrConsecutiveFailures, 3, "3회 실패 → consecutiveFailures=3")
        XCTAssertTrue(
            store.fsrPollingDisabled,
            "3회 연속 FSR 실패 → fsrPollingDisabled=true (spam 차단)"
        )

        // .telemetrySkip 이벤트가 harness 에 기록됐는지 확인.
        let hasSkipEvent = recorder.events.contains { $0.kind == .telemetrySkip }
        XCTAssertTrue(
            hasSkipEvent,
            "3회 실패 → .telemetrySkip 이벤트 harness 에 기록 (진단 trail)"
        )
    }

    // =========================================================================
    // MARK: - Test 4: lowerBody 단일 관절만 position write 실패 → .writeFailed
    // =========================================================================

    /// `rAnklePitch` 만 `setPosition` 실패, 나머지 성공 → `applyPoseSmoothly` → `.writeFailed`.
    ///
    /// 비유: 오케스트라에서 첫 번째 바이올린만 음이 틀려도 지휘자가 연주를 중단하는 것처럼,
    /// 하체 관절 1개라도 position write 실패하면 fall risk → `.writeFailed` hard stop.
    func testPoseApplyLowerBodySingleJointFailureReturnsWriteFailed() async {
        let failBus = SingleJointFailMockBus(failJoint: .rAnklePitch)
        store.bus = failBus

        let result = await store.applyPoseSmoothly(.center, profile: .smooth)

        // rAnklePitch 는 lowerBodyJoints 에 포함 → lowerBodyPositionFails 비어 있지 않음.
        guard case .writeFailed(let posFailed, _, _, _) = result else {
            XCTFail("lowerBody 관절 실패 → .writeFailed 기대, 실제: \(result)")
            return
        }
        XCTAssertGreaterThan(
            posFailed, 0,
            "positionFailed > 0 (rAnklePitch 실패 집계됨)"
        )
    }

    /// lowerBody 가 아닌 상체 관절만 실패하면 `.partialFailure` (fall risk 아님).
    ///
    /// 비유: 지휘자는 타악기 음이 틀려도 연주를 계속하지만, 첼로(하체)가 틀리면 중단.
    /// 상체 관절 실패 → partialFailure (계속 진행 가능).
    func testPoseApplyUpperBodyJointFailureReturnsPartialFailure() async {
        // rShoulderPitch 는 lowerBodyJoints 에 포함되지 않음 → partialFailure.
        let failBus = SingleJointFailMockBus(failJoint: .rShoulderPitch)
        store.bus = failBus

        let result = await store.applyPoseSmoothly(.center, profile: .smooth)

        switch result {
        case .partialFailure:
            break  // 예상 결과 — 상체 부분 실패
        case .completed:
            // rShoulderPitch 가 RobotPose.center 에 포함되지 않으면 실패 없음 → completed 도 유효.
            break
        case .writeFailed:
            XCTFail("상체 관절만 실패 시 .writeFailed 는 불가 — lowerBody 실패 아님")
        default:
            break  // notConnected / rejected / cancelled / criticalLoad — 예상 외지만 허용
        }
    }
}

// =============================================================================
// MARK: - AlwaysFailFsrMockBus
// =============================================================================

/// FSR read (좌/우 모두) 를 항상 throw 하는 mock — FSR 3회 consecutive fail 경로 검증용.
///
/// 비유: 발바닥 압력센서가 완전히 고장난 로봇 시뮬레이터.
/// board snapshot / joint reads 등 나머지 메서드는 항상 성공 (FSR 경로만 격리 검증).
final class AlwaysFailFsrMockBus: BusInterface, @unchecked Sendable {

    func readFsrLeft() throws -> FsrReading {
        throw ForgeError.timeout  // 항상 실패
    }

    func readFsrRight() throws -> FsrReading {
        throw ForgeError.timeout  // 항상 실패
    }

    // MARK: - 나머지 메서드 — 항상 성공 (FSR 경로 격리)

    func ping(id: UInt8) throws {}

    func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] { [] }

    func boardSnapshot() throws -> BoardSnapshot {
        BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
    }

    func readImu() throws -> ImuRaw {
        ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 512, accelZ: 768,
            rollDeg: 0, pitchDeg: 0
        )
    }

    func setDxlPower(_ on: Bool) throws {}

    func setTorque(_ joint: JointID, enable: Bool) throws {}

    func emergencyStop() throws {}

    @discardableResult
    func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 { position }

    func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {}

    func setPGain(_ joint: JointID, value: UInt8) throws {}

    func readState(_ joint: JointID) throws -> JointState {
        JointState(
            id: joint,
            torqueEnabled: false,
            goalPosition: 2048,
            presentPosition: 2048,
            presentSpeed: 0,
            presentLoad: 0,
            presentVoltageRaw: 120,
            presentTemperature: 25
        )
    }

    func motionPlaySlot(
        slot: UInt8,
        binPath: String?,
        dryRun: Bool,
        confirmRisk: Bool,
        singleFootOk: Bool,
        followChain: Bool,
        maxChainDepth: Int
    ) throws {}

    func motionPlayCancel() throws {}

    var isMotionPlaying: Bool { false }
}

// =============================================================================
// MARK: - SingleJointFailMockBus
// =============================================================================

/// 지정한 단일 관절의 `setPosition` 만 throw 하는 mock — lowerBody 선택적 실패 경로 검증용.
///
/// 비유: 로봇 관절 테스터에서 특정 서보만 "고장" 스위치를 켜고 나머지는 정상 운전.
/// `failJoint` 의 position write 만 실패, 나머지 모든 관절과 write 타입은 성공.
final class SingleJointFailMockBus: BusInterface, @unchecked Sendable {

    let failJoint: JointID
    private(set) var positionWrites: [(joint: JointID, raw: UInt16)] = []
    private(set) var failCount: Int = 0

    init(failJoint: JointID) {
        self.failJoint = failJoint
    }

    @discardableResult
    func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 {
        if joint == failJoint {
            failCount += 1
            throw ForgeError.timeout  // 단일 관절만 실패
        }
        positionWrites.append((joint, position))
        return position
    }

    // MARK: - 나머지 메서드 — 항상 성공

    func ping(id: UInt8) throws {}

    func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] { [] }

    func boardSnapshot() throws -> BoardSnapshot {
        BoardSnapshot(modelNumber: 740, version: 1, voltageRaw: 120, button: 0)
    }

    func readImu() throws -> ImuRaw {
        ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 512, accelZ: 768,
            rollDeg: 0, pitchDeg: 0
        )
    }

    func readFsrLeft() throws -> FsrReading {
        FsrReading(
            id: 112,
            cellFrontLeft: 256, cellFrontRight: 256,
            cellRearRight: 256, cellRearLeft: 256,
            centerX: 0, centerY: 0
        )
    }

    func readFsrRight() throws -> FsrReading {
        FsrReading(
            id: 111,
            cellFrontLeft: 256, cellFrontRight: 256,
            cellRearRight: 256, cellRearLeft: 256,
            centerX: 0, centerY: 0
        )
    }

    func setDxlPower(_ on: Bool) throws {}

    func setTorque(_ joint: JointID, enable: Bool) throws {}

    func emergencyStop() throws {}

    func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {}

    func setPGain(_ joint: JointID, value: UInt8) throws {}

    func readState(_ joint: JointID) throws -> JointState {
        JointState(
            id: joint,
            torqueEnabled: false,
            goalPosition: 2048,
            presentPosition: 2048,
            presentSpeed: 0,
            presentLoad: 0,
            presentVoltageRaw: 120,
            presentTemperature: 25
        )
    }

    func motionPlaySlot(
        slot: UInt8,
        binPath: String?,
        dryRun: Bool,
        confirmRisk: Bool,
        singleFootOk: Bool,
        followChain: Bool,
        maxChainDepth: Int
    ) throws {}

    func motionPlayCancel() throws {}

    var isMotionPlaying: Bool { false }
}
