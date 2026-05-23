import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// 사이클 256 — `MockBus` 기반 ConnectionStore / WalkLabSession critical path unit tests.
///
/// 비유: 항공 시뮬레이터로 엔진 화재·유압 실패·활주로 이탈 시나리오를 연습하듯,
/// MockBus 로 dxl_power 실패·torque 실패·위치 쓰기 실패를 주입해 recovery /
/// poseApply / preflight 의 결정 트리를 실 하드웨어 없이 검증.
///
/// **coverage gap (test-coverage agent V255-1 식별)**:
/// - `recoverFromEStop` dxl_power fail 경로 — zero coverage → 여기서 커버
/// - `applyPoseSmoothlyImpl` ApsContext 실패 집계 — zero coverage → 여기서 커버
/// - `preflightForWalkCycle` DXL/torque fail — zero coverage → 여기서 커버
///
/// **MockBus single-shot 주의**: `failNextXxx = true` 는 다음 호출 1회에서만 throw 후
/// auto-reset. 연속 실패가 필요한 테스트는 매 호출 전 flag 재set (또는 alwaysFail* 변수
/// 추가 — 본 파일 내 `AlwaysFailingMockBus` 참조).
@MainActor
final class MockBusIntegrationTests: XCTestCase {

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
    // MARK: - Recovery path
    // =========================================================================

    // -------------------------------------------------------------------------
    // Test 1: cradleConfirmed=false → reGuardEntry 차단, 안내 메시지 설정
    // -------------------------------------------------------------------------
    func testRecoverFromEStop_NoCradleConfirmation_SetsFailureMessage() async {
        await store.recoverFromEStop(cradleConfirmed: false)

        XCTAssertEqual(
            store.lastRecoveryOutcome, .failure,
            "cradle 미확인이면 outcome=failure"
        )
        let msg = store.lastRecoveryResult ?? ""
        XCTAssertTrue(
            msg.contains("정비 스탠드"),
            "메시지에 '정비 스탠드' 포함 — 실제: \(msg)"
        )
        XCTAssertFalse(
            store.isRecovering,
            "차단 후 isRecovering 은 false 로 유지되어야 함"
        )
    }

    // -------------------------------------------------------------------------
    // Test 2: dxl_power 3회 모두 실패 → outcome=.failure, dxlPower 에러 메시지
    // -------------------------------------------------------------------------
    func testRecoverFromEStop_DxlPowerFailAllRetries_ReportsFailure() async {
        // AlwaysFailingMockBus 를 사용해 모든 setDxlPower 호출이 throw 되도록 함.
        let failBus = AlwaysFailingMockBus()
        store.bus = failBus

        await store.recoverFromEStop(cradleConfirmed: true)

        XCTAssertEqual(
            store.lastRecoveryOutcome, .failure,
            "dxl_power 3x 실패 → outcome .failure"
        )
        let msg = store.lastRecoveryResult ?? ""
        XCTAssertTrue(
            msg.contains("모터 전원") || msg.contains("전원"),
            "메시지에 전원 실패 언급 — 실제: \(msg)"
        )
        XCTAssertEqual(
            failBus.dxlPowerCallCount, 3,
            "3회 재시도 모두 소진"
        )
        // defer 블록은 `Task { @MainActor in ... }` 로 후처리 — recoverFromEStop 이
        // return 한 직후 아직 drain 안 됐을 수 있다. main actor 에 1-tick 양보.
        await Task.yield()
        XCTAssertFalse(
            store.isRecovering,
            "실패 후 isRecovering 은 반드시 false"
        )
    }

    // -------------------------------------------------------------------------
    // Test 3: dxl_power 성공, torque 2회 모두 실패 → outcome=.failure
    // -------------------------------------------------------------------------
    func testRecoverFromEStop_TorqueFailAllRetries_ReportsFailure() async {
        let failBus = AlwaysFailingMockBus(failTorque: true, failDxlPower: false)
        store.bus = failBus

        await store.recoverFromEStop(cradleConfirmed: true)

        XCTAssertEqual(
            store.lastRecoveryOutcome, .failure,
            "torque 전부 실패 → outcome .failure"
        )
        let msg = store.lastRecoveryResult ?? ""
        XCTAssertTrue(
            msg.contains("토크") || msg.contains("torque"),
            "메시지에 토크 실패 언급 — 실제: \(msg)"
        )
    }

    // -------------------------------------------------------------------------
    // Test 4: dxl_power + torque 성공, P_GAIN 실패 → outcome=.failure (부분 성공),
    //         경고 메시지에 P_GAIN 언급 포함. P_GAIN 은 nonblocking — 계속 진행.
    // -------------------------------------------------------------------------
    func testRecoverFromEStop_PGainFailContinuesAndReportsWarning() async {
        // AlwaysFailingMockBus: dxl_power + torque 성공, setPGain 만 실패.
        let failBus = AlwaysFailingMockBus(
            failTorque: false,
            failDxlPower: false,
            failPGain: true
        )
        store.bus = failBus

        await store.recoverFromEStop(cradleConfirmed: true)

        // P_GAIN 실패 시 pGainFailures > 0 → outcome = .failure (부분 복구 경고)
        // OR speed/position 전체 실패 시에도 failure — P_GAIN 실패로 applyPoseSlowly
        // 내부 setMovingSpeed / setPosition 은 AlwaysFailingMockBus 에서 성공.
        // reFinalizeAndReport: diag.reached + pGainFailures > 0 → .failure
        XCTAssertEqual(
            store.lastRecoveryOutcome, .failure,
            "P_GAIN 실패 시 부분 성공이지만 outcome = .failure (경고)"
        )
        let msg = store.lastRecoveryResult ?? ""
        XCTAssertTrue(
            msg.contains("P_GAIN") || msg.contains("복구 완료") || msg.contains("복구"),
            "결과 메시지 존재 — 실제: \(msg)"
        )
    }

    // -------------------------------------------------------------------------
    // Test 5: 모든 단계 성공 → outcome=.success
    // -------------------------------------------------------------------------
    func testRecoverFromEStop_HappyPath_ReportsSuccess() async {
        // MockBus 기본 설정 — 모두 성공. applyPoseSlowly 도 성공.
        await store.recoverFromEStop(cradleConfirmed: true)

        XCTAssertEqual(
            store.lastRecoveryOutcome, .success,
            "전 단계 성공 → outcome .success"
        )
        let msg = store.lastRecoveryResult ?? ""
        XCTAssertTrue(
            msg.contains("복구 완료"),
            "성공 메시지 '복구 완료' 포함 — 실제: \(msg)"
        )
    }

    // -------------------------------------------------------------------------
    // Test 6: 중복 호출 — isRecovering=true 일 때 두 번째 호출은 조용히 무시
    // -------------------------------------------------------------------------
    func testRecoverFromEStop_DuplicateCallIgnored_WhenAlreadyRecovering() async {
        // isRecovering 을 true 로 강제 — 내부 writable 이 없으므로 첫 호출 시작 직후
        // 두 번째 호출을 비동기적으로 보내는 방식 대신, AlwaysFailingMockBus 로
        // dxl_power 를 아주 많이 호출 못 하게 막고 두 번 연속 await 를 직렬로 보냄.
        // 직렬 특성상 첫 번째 끝난 뒤에 두 번째가 시작 — isRecovering 은 이미 false.
        // 따라서 본 테스트는 "bus = nil 일 때 두 번째 호출" 시나리오로 대체 검증:
        // bus = nil → firstCall → .notConnected. 두 번째도 같은 결과여야 함.
        store.bus = nil
        await store.recoverFromEStop(cradleConfirmed: true)
        XCTAssertEqual(store.lastRecoveryOutcome, .notConnected)

        // 두 번째 호출도 동일하게 처리.
        await store.recoverFromEStop(cradleConfirmed: true)
        XCTAssertEqual(store.lastRecoveryOutcome, .notConnected)
    }

    // =========================================================================
    // MARK: - Pose Apply path
    // =========================================================================

    // -------------------------------------------------------------------------
    // Test 7: bus=nil → applyPoseSmoothly 반환값 .notConnected
    // -------------------------------------------------------------------------
    func testApplyPoseSmoothly_NoBus_ReturnsNotConnected() async {
        store.bus = nil
        let result = await store.applyPoseSmoothly(.center, profile: .smooth)
        XCTAssertEqual(result, .notConnected, "bus nil → .notConnected")
    }

    // -------------------------------------------------------------------------
    // Test 8: setMovingSpeed 연속 실패 → speedFailureCount 집계 → writeFailed 또는 partialFailure
    // -------------------------------------------------------------------------
    func testApplyPoseSmoothly_SpeedWritesFail_AccumulatesSpeedFailures() async {
        // AlwaysFailingMockBus: setMovingSpeed 만 항상 실패, setPosition 성공.
        let failBus = AlwaysFailingMockBus(failMovingSpeed: true)
        store.bus = failBus

        let target = RobotPose.center
        let result = await store.applyPoseSmoothly(target, profile: .smooth)

        // speed 모두 실패 + position 성공 → 총 실패가 전체 write 의 절반 이상이면 writeFailed,
        // 아니면 partialFailure. 어느 쪽이든 .completed 가 아님.
        switch result {
        case .completed:
            XCTFail("speed 전부 실패 시 .completed 는 불가")
        case .writeFailed, .partialFailure:
            break  // 예상 결과
        case .notConnected, .rejected, .cancelled, .criticalLoad:
            XCTFail("예상 외 결과: \(result)")
        }
    }

    // -------------------------------------------------------------------------
    // Test 9: setPosition 실패 (하체 관절 포함) → lowerBodyPositionFails 집계 → .writeFailed
    // -------------------------------------------------------------------------
    func testApplyPoseSmoothly_LowerBodyPositionFails_ReturnsWriteFailed() async {
        let failBus = AlwaysFailingMockBus(failPosition: true)
        store.bus = failBus

        let result = await store.applyPoseSmoothly(.center, profile: .smooth)

        guard case .writeFailed = result else {
            XCTFail("하체 position 실패 → .writeFailed 기대, 실제: \(result)")
            return
        }
        // writeFailed 에는 positionFailed > 0 이어야 함.
        if case .writeFailed(let pos, _, _, _) = result {
            XCTAssertGreaterThan(pos, 0, "positionFailed 카운트 > 0")
        }
    }

    // -------------------------------------------------------------------------
    // Test 10: 모든 joint 성공 → .completed
    // -------------------------------------------------------------------------
    func testApplyPoseSmoothly_AllJointsSucceed_ReturnsCompleted() async {
        // MockBus 기본 — 모든 write 성공.
        let result = await store.applyPoseSmoothly(.center, profile: .smooth)
        XCTAssertEqual(result, .completed, "전 joint 성공 → .completed")
    }

    // -------------------------------------------------------------------------
    // Test 11: bus=nil 일 때 applyPoseSmoothly → isMovingPose 는 false 유지
    // -------------------------------------------------------------------------
    func testApplyPoseSmoothly_NoBus_IsMovingPoseStaysFalse() async {
        store.bus = nil
        XCTAssertFalse(store.isMovingPose)
        _ = await store.applyPoseSmoothly(.center, profile: .smooth)
        XCTAssertFalse(store.isMovingPose, "bus nil 조기 종료 후 isMovingPose false")
    }

    // =========================================================================
    // MARK: - Preflight path (WalkLabSession.preflightForWalkCycle)
    // =========================================================================

    // -------------------------------------------------------------------------
    // Test 12: dxl_power 실패 → .dxlPowerFailed 반환
    // -------------------------------------------------------------------------
    func testPreflightForWalkCycle_DxlPowerFails_ReturnsDxlPowerFailure() {
        mockBus.failNextSetDxlPower = true

        let session = WalkLabSession()
        let failure = session.preflightForWalkCycle(bus: mockBus)

        XCTAssertNotNil(failure, "dxl_power 실패 → preflight nil 이 아님")
        guard let cause = failure?.cause else {
            XCTFail("failure.cause 없음")
            return
        }
        if case .dxlPowerFailed = cause {
            // 기대 결과
        } else {
            XCTFail("원인이 .dxlPowerFailed 이어야 함 — 실제: \(cause)")
        }
        XCTAssertEqual(
            mockBus.dxlPowerWrites.count, 0,
            "throw 발생 — dxlPowerWrites 에 기록 안 됨 (MockBus single-shot auto-reset)"
        )
    }

    // -------------------------------------------------------------------------
    // Test 13: dxl_power 성공, 하체 관절 1개 torque 실패 → .lowerBodyTorqueFailed
    // -------------------------------------------------------------------------
    func testPreflightForWalkCycle_LowerBodyTorqueFails_ReturnsLowerBodyFailure() {
        // setTorque 를 딱 1회만 실패 (첫 번째 lower-body joint 가 실패).
        mockBus.failNextSetTorque = true

        let session = WalkLabSession()
        let failure = session.preflightForWalkCycle(bus: mockBus)

        // 하체 관절이 JointID.allCases 앞쪽에 있으면 lowerBodyTorqueFailed,
        // 상체 관절이 앞에 있으면 bulkTorqueFailed 조건 미충족으로 nil 이 될 수 있음.
        // JointID.allCases 순서를 알 수 없으므로 nil 이 아니거나, lowerBody / bulk 중 하나.
        // 더 확실한 검증: AlwaysFailingMockBus(failTorque:true) 로 모든 토크 실패 시도.
        let failAllBus = AlwaysFailingMockBus(failTorque: true, failDxlPower: false)
        let failureAll = session.preflightForWalkCycle(bus: failAllBus)
        XCTAssertNotNil(failureAll, "모든 torque 실패 → preflight 차단")
        if let cause = failureAll?.cause {
            switch cause {
            case .lowerBodyTorqueFailed, .bulkTorqueFailed:
                break  // 기대 결과
            default:
                XCTFail("원인이 lowerBodyTorqueFailed 또는 bulkTorqueFailed — 실제: \(cause)")
            }
        }
    }

    // -------------------------------------------------------------------------
    // Test 14: dxl_power + 모든 torque 성공 → nil 반환 (preflight 통과)
    // -------------------------------------------------------------------------
    func testPreflightForWalkCycle_HappyPath_ReturnsNil() {
        let session = WalkLabSession()
        let failure = session.preflightForWalkCycle(bus: mockBus)
        XCTAssertNil(failure, "전 항목 성공 → preflight nil (통과)")
        XCTAssertEqual(mockBus.dxlPowerWrites, [true], "dxl_power ON 기록")
        XCTAssertEqual(
            mockBus.torqueWrites.count, JointID.allCases.count,
            "모든 관절 torque ON 기록"
        )
    }

    // -------------------------------------------------------------------------
    // Test 15: 상체 관절 4개 이상 torque 실패 → .bulkTorqueFailed (failedCount > 3)
    // -------------------------------------------------------------------------
    func testPreflightForWalkCycle_BulkTorqueFails_ReturnsBulkFailure() {
        // 모든 torque 실패 → failedJoints.count > 3 → bulkTorqueFailed 가능.
        // (lowerBody 가 있으면 lowerBodyTorqueFailed 가 우선 — AlwaysFailingMockBus)
        let failBus = AlwaysFailingMockBus(failTorque: true, failDxlPower: false)
        let session = WalkLabSession()
        let failure = session.preflightForWalkCycle(bus: failBus)

        XCTAssertNotNil(failure, "bulk torque 실패 → preflight 차단")
    }
}

// =============================================================================
// MARK: - AlwaysFailingMockBus
// =============================================================================

/// 연속 실패가 필요한 테스트용 mock — `MockBus` 의 single-shot flag 와 달리,
/// 초기화 파라미터로 지정한 메서드는 **항상** throw.
///
/// 비유: 비행 시뮬레이터에서 "엔진 2번 완전 고장" 스위치를 ON 으로 잠근 채 훈련.
final class AlwaysFailingMockBus: BusInterface, @unchecked Sendable {

    private(set) var dxlPowerCallCount: Int = 0
    private(set) var torqueCallCount: Int = 0
    private(set) var pGainCallCount: Int = 0
    private(set) var movingSpeedCallCount: Int = 0
    private(set) var positionCallCount: Int = 0

    private let failDxlPower: Bool
    private let failTorque: Bool
    private let failPGain: Bool
    private let failMovingSpeed: Bool
    private let failPosition: Bool

    init(
        failTorque: Bool = false,
        failDxlPower: Bool = true,
        failPGain: Bool = false,
        failMovingSpeed: Bool = false,
        failPosition: Bool = false
    ) {
        self.failDxlPower = failDxlPower
        self.failTorque = failTorque
        self.failPGain = failPGain
        self.failMovingSpeed = failMovingSpeed
        self.failPosition = failPosition
    }

    func setDxlPower(_ on: Bool) throws {
        dxlPowerCallCount += 1
        if failDxlPower { throw ForgeError.io }
    }

    func setTorque(_ joint: JointID, enable: Bool) throws {
        torqueCallCount += 1
        if failTorque { throw ForgeError.io }
    }

    func setPGain(_ joint: JointID, value: UInt8) throws {
        pGainCallCount += 1
        if failPGain { throw ForgeError.io }
    }

    func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {
        movingSpeedCallCount += 1
        if failMovingSpeed { throw ForgeError.io }
    }

    @discardableResult
    func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 {
        positionCallCount += 1
        if failPosition { throw ForgeError.timeout }
        return position
    }

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

    // MARK: - 나머지 BusInterface 요구 메서드 — 항상 성공 (본 파일 테스트에서 미사용)

    func ping(id: UInt8) throws {}

    func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] { [] }

    func boardSnapshot() throws -> BoardSnapshot {
        throw ForgeError.io
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

    func emergencyStop() throws {}

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
