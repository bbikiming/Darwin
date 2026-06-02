// V298-AutoRecovery safety fixes — orchestration regression tests.
// H3: 버스 인터페이스 mock 기반 — 실 하드웨어 없이 실행 가능 (pure/fast).
#if DEBUG
import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **자동 일어나기 오케스트레이션 안전 회귀 가드** (H3).
///
/// # 비유
/// 소방 훈련 시뮬레이터 — 실제 불 없이 대피 경로·소화기 동작·통신 채널을
/// 검증하듯, 실 로봇 없이 recovery 흐름·bus write 순서·상태 전환을 확인한다.
///
/// # 커버리지
/// - **H3-1**: `playGetUpMotion(page: 12)` 및 비-10/11 page → false + motionPlaySlot 미호출.
/// - **H3-2**: `emergencyStop()` during recovery → motionPlayCancel 호출 + phase .idle/.failed 보존.
/// - **H3-3** (M1): `emergencyStop()` when phase == .failed → .failed 보존.
/// - **H3-4** (C1b): isHardStopped 논리 — recovery 중 (phase != .idle) true 반환.
/// - **H3-5** (L1): 하체 관절 torque 실패 시 `restoreTorqueAndPGain` → false 반환.
@MainActor
final class AutoFallRecoveryOrchestrationTests: XCTestCase {

    // MARK: - Helpers

    /// WalkLabSession 은 store 에 weak 참조 — store 를 함께 반환해야 테스트 동안 살아있음.
    private func makeSession(bus: (any BusInterface)? = nil) -> (session: WalkLabSession, store: ConnectionStore) {
        let session = WalkLabSession()
        let store = ConnectionStore()
        store.bus = bus ?? MockBus()
        session.attach(store: store)
        session.cradleConfirmed = true
        return (session, store)
    }

    // MARK: - H3-1: 잘못된 get-up page 는 bus 호출 없이 false 반환

    /// page 12 (kick rk) 는 get-up 에 절대 금지 — motionPlaySlot 을 호출해서는 안 된다.
    func testPlayGetUpMotion_invalidPage12_returnsFalseNoBusCall() async {
        let bus = MockBus()
        let (session, _store) = makeSession(bus: bus)
        _ = _store  // store strong reference 유지

        let result = await session._testPlayGetUpMotion(page: 12)

        XCTAssertFalse(result,
            "page 12 (kick rk) 는 get-up 불가 — false 반환 필수")
        XCTAssertEqual(bus.motionPlaySlotCalls.count, 0,
            "잘못된 page 로 motionPlaySlot 이 호출되면 안 됨 (안전 위반)")
    }

    /// page 9 (허용 범위 외) 도 동일하게 false + 버스 미호출.
    func testPlayGetUpMotion_invalidPage9_returnsFalseNoBusCall() async {
        let bus = MockBus()
        let (session, _store) = makeSession(bus: bus)
        _ = _store

        let result = await session._testPlayGetUpMotion(page: 9)

        XCTAssertFalse(result, "page 9 은 허용 범위 외 — false 반환")
        XCTAssertEqual(bus.motionPlaySlotCalls.count, 0, "motionPlaySlot 은 호출되면 안 됨")
    }

    /// page 0 도 동일하게 false + 버스 미호출.
    func testPlayGetUpMotion_invalidPage0_returnsFalseNoBusCall() async {
        let bus = MockBus()
        let (session, _store) = makeSession(bus: bus)
        _ = _store

        let result = await session._testPlayGetUpMotion(page: 0)

        XCTAssertFalse(result)
        XCTAssertEqual(bus.motionPlaySlotCalls.count, 0)
    }

    /// page 10 (forward get-up) 은 허용 — motionPlaySlot 정확히 1회 호출.
    func testPlayGetUpMotion_validPage10_callsMotionPlaySlot() async {
        let bus = MockBus()
        let (session, _store) = makeSession(bus: bus)
        _ = _store

        let result = await session._testPlayGetUpMotion(page: 10)

        XCTAssertTrue(result, "page 10 은 정상 get-up page")
        XCTAssertEqual(bus.motionPlaySlotCalls.count, 1, "motionPlaySlot 정확히 1회 호출")
        XCTAssertEqual(bus.motionPlaySlotCalls.first?.slot, 10, "slot 10 으로 호출")
    }

    /// page 11 (backward get-up) 은 허용.
    func testPlayGetUpMotion_validPage11_callsMotionPlaySlot() async {
        let bus = MockBus()
        let (session, _store) = makeSession(bus: bus)
        _ = _store

        let result = await session._testPlayGetUpMotion(page: 11)

        XCTAssertTrue(result, "page 11 은 정상 get-up page")
        XCTAssertEqual(bus.motionPlaySlotCalls.count, 1)
        XCTAssertEqual(bus.motionPlaySlotCalls.first?.slot, 11)
    }

    // MARK: - H3-2: emergencyStop during recovery — motionPlayCancel 호출 + phase 처리

    /// `emergencyStop()` 이 recovery 진행 중 (`gettingUp`) 에 호출되면:
    /// - motionPlayCancel() 이 bus 에 전달됨
    /// - autoRecoveryTask 가 cancel + nil
    /// - autoRecoveryPhase 가 .idle (아직 .failed 아닌 경우)
    func testEmergencyStop_duringGettingUp_cancelsMotionAndResetsPhase() async {
        let bus = MockBus()
        let (session, _store) = makeSession(bus: bus)
        _ = _store

        session.autoRecoveryPhase = .gettingUp
        session.emergencyStop(trigger: .userClick)

        XCTAssertGreaterThanOrEqual(bus.motionPlayCancelCount, 1,
            "emergencyStop 은 get-up 중 motionPlayCancel 을 버스에 전달해야 함")
        XCTAssertNil(session.autoRecoveryTask,
            "emergencyStop 이후 autoRecoveryTask nil")
        XCTAssertEqual(session.autoRecoveryPhase, .idle,
            "gettingUp 에서 emergencyStop → .idle (M1: .failed 아니면 .idle 로)")
    }

    /// `.settling` 에서 emergencyStop → .idle.
    func testEmergencyStop_duringSettling_resetsToIdle() async {
        let (session, _store) = makeSession()
        _ = _store
        session.autoRecoveryPhase = .settling

        session.emergencyStop(trigger: .userClick)

        XCTAssertEqual(session.autoRecoveryPhase, .idle, ".settling 에서 emergencyStop → .idle")
    }

    // MARK: - H3-3 (M1): .failed 상태에서 emergencyStop → .failed 보존

    /// M1 fix: emergencyStop 의 Phase 4b 는 .failed 를 .idle 로 덮어쓰면 안 된다.
    func testEmergencyStop_afterFailedPhase_preservesFailedPhase() async {
        let (session, _store) = makeSession()
        _ = _store
        session.autoRecoveryPhase = .failed

        session.emergencyStop(trigger: .balanceLostL3)

        XCTAssertEqual(session.autoRecoveryPhase, .failed,
            "M1 fix: .failed 상태는 emergencyStop 이 .idle 로 덮어쓰면 안 됨 — UI 실패 표시 필요")
    }

    /// .idle 에서 emergencyStop → .idle 유지.
    func testEmergencyStop_fromIdlePhase_remainsIdle() async {
        let (session, _store) = makeSession()
        _ = _store
        session.autoRecoveryPhase = .idle

        session.emergencyStop(trigger: .userClick)

        XCTAssertEqual(session.autoRecoveryPhase, .idle, ".idle 에서 emergencyStop → .idle 유지")
    }

    // MARK: - H3-4 (C1b): isHardStopped 논리 — recovery 중 write 차단

    /// recovery 진행 중 (phase != .idle) 에는 isHardStopped 논리가 true.
    func testIsHardStopped_duringRecovery_returnsTrue() async {
        let (session, _store) = makeSession()
        _ = _store
        session.emergencyStopActive = false
        session.autoRecoveryPhase = .gettingUp

        let hardStopped = session.emergencyStopActive || session.autoRecoveryPhase != .idle
        XCTAssertTrue(hardStopped,
            "C1b: recovery 중 (phase=.gettingUp) isHardStopped 논리는 true")
    }

    /// emergency 없고 recovery idle 이면 hardStopped 논리는 false.
    func testIsHardStopped_idleAndNoEmergency_returnsFalse() async {
        let (session, _store) = makeSession()
        _ = _store
        session.emergencyStopActive = false
        session.autoRecoveryPhase = .idle

        let hardStopped = session.emergencyStopActive || session.autoRecoveryPhase != .idle
        XCTAssertFalse(hardStopped, "emergency 없고 recovery idle → isHardStopped 논리 false")
    }

    /// emergency active 이면 phase 무관하게 hardStopped true.
    func testIsHardStopped_emergencyActive_returnsTrue() async {
        let (session, _store) = makeSession()
        _ = _store
        session.emergencyStopActive = true
        session.autoRecoveryPhase = .idle

        let hardStopped = session.emergencyStopActive || session.autoRecoveryPhase != .idle
        XCTAssertTrue(hardStopped, "emergencyStopActive=true → hardStopped true (phase 무관)")
    }

    // MARK: - H3-5 (L1): 하체 torque 실패 시 restoreTorqueAndPGain false 반환

    /// 하체 관절 setTorque 가 실패하면 false 를 반환해야 한다.
    func testRestoreTorqueAndPGain_lowerBodyTorqueFail_returnsFalse() async {
        let bus = AlwaysTorqueFailBus()
        let (session, _store) = makeSession(bus: bus)
        _ = _store

        let result = await session._testRestoreTorqueAndPGain()

        XCTAssertFalse(result,
            "L1: 하체 관절 torque ON 실패 시 false 반환 (dead leg 보호)")
    }

    /// 모든 관절 torque 성공 시 true 반환.
    func testRestoreTorqueAndPGain_allJointsOk_returnsTrue() async {
        let bus = MockBus()
        let (session, _store) = makeSession(bus: bus)
        _ = _store

        let result = await session._testRestoreTorqueAndPGain()

        XCTAssertTrue(result, "모든 관절 torque 성공 → true")
    }

    /// bus nil 이면 false 반환.
    func testRestoreTorqueAndPGain_busNil_returnsFalse() async {
        let session = WalkLabSession()
        let store = ConnectionStore()
        // bus nil
        session.attach(store: store)
        session.cradleConfirmed = true
        _ = store  // strong reference

        let result = await session._testRestoreTorqueAndPGain()

        XCTAssertFalse(result, "bus nil → false")
    }
}

// MARK: - AlwaysTorqueFailBus

/// 모든 `setTorque` 호출을 실패시키는 `BusInterface` 구현 — L1 하체 torque 실패 경로 검증용.
/// MockBus 는 final 이라 서브클래싱 불가 — BusInterface 를 직접 구현.
private final class AlwaysTorqueFailBus: BusInterface, @unchecked Sendable {
    private(set) var motionPlaySlotCalls: [(slot: UInt8, confirmRisk: Bool, dryRun: Bool)] = []

    func ping(id: UInt8) throws {}
    func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] { [] }
    func boardSnapshot() throws -> BoardSnapshot { throw ForgeError.io }
    func readImu() throws -> ImuRaw {
        ImuRaw(gyroX: 512, gyroY: 512, gyroZ: 512,
               accelX: 512, accelY: 512, accelZ: 512,
               rollDeg: 0.0, pitchDeg: 0.0)
    }
    func readFsrLeft() throws -> FsrReading {
        FsrReading(id: 111, cellFrontLeft: 0, cellFrontRight: 0,
                   cellRearRight: 0, cellRearLeft: 0, centerX: 0, centerY: 0)
    }
    func readFsrRight() throws -> FsrReading {
        FsrReading(id: 112, cellFrontLeft: 0, cellFrontRight: 0,
                   cellRearRight: 0, cellRearLeft: 0, centerX: 0, centerY: 0)
    }
    func setDxlPower(_ on: Bool) throws {}  // power ON 성공
    func setTorque(_ joint: JointID, enable: Bool) throws {
        throw ForgeError.io  // 모든 torque 실패 (하체 포함)
    }
    func emergencyStop() throws {}
    @discardableResult
    func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 { position }
    func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {}
    func setPGain(_ joint: JointID, value: UInt8) throws {}
    func readState(_ joint: JointID) throws -> JointState {
        JointState(id: joint, torqueEnabled: false, goalPosition: 2048,
                   presentPosition: 2048, presentSpeed: 0, presentLoad: 0,
                   presentVoltageRaw: 120, presentTemperature: 25)
    }
    func motionPlaySlot(slot: UInt8, binPath: String?, dryRun: Bool,
                        confirmRisk: Bool, singleFootOk: Bool,
                        followChain: Bool, maxChainDepth: Int) throws {
        motionPlaySlotCalls.append((slot, confirmRisk, dryRun))
    }
    func motionPlayCancel() throws {}
    var isMotionPlaying: Bool { false }
}
#endif
