import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// V291-12 — EStopVerifier 단위 테스트.
///
/// # 비유
///
/// 정지 버튼을 눌렀는데 차가 진짜 멈췄는지 직접 확인하는 검사원 역할.
/// MockBus 를 차량 시뮬레이터로 사용 — 각 시나리오(정지 성공/실패/연결 오류)를
/// 안전하게 반복 검증.
///
/// # 테스트 시나리오
///
///   1. 모든 joint speed=0  → .verified
///   2. 일부 joint speed 초과 → .failed(unstoppedJoints)
///   3. bus throw           → .unreachable
///   4. bus nil             → .unreachable
///   5. speed threshold 경계 → verified/failed 분기 정확성
@MainActor
final class EStopVerifierTests: XCTestCase {

    // MARK: - 1. 모든 joint speed=0 → .verified

    func testVerifyTorqueOff_AllSpeedZero_ReturnsVerified() async {
        let bus = MockBus()
        // MockBus.readState 는 기본값으로 속도=0 인 JointState 반환.
        let result = await EStopVerifier.verifyTorqueOff(bus: bus, delay: 0)
        XCTAssertEqual(result, .verified,
                       "모든 joint speed=0 이면 .verified 반환")
    }

    // MARK: - 2. 일부 joint speed 초과 → .failed(unstoppedJoints)

    func testVerifyTorqueOff_OneJointMoving_ReturnsFailed() async {
        // SpeedStubBus 로 특정 joint 의 presentSpeed 를 threshold 초과로 주입.
        let bus = SpeedStubBus(speedByJoint: [.rHipPitch: 10])  // speed=10 > threshold(5)
        let result = await EStopVerifier.verifyTorqueOff(bus: bus, delay: 0)
        guard case .failed(let joints) = result else {
            XCTFail("speed > threshold 인 관절이 있으면 .failed 반환해야 함, 실제: \(result)")
            return
        }
        XCTAssertTrue(joints.contains(.rHipPitch),
                      "speed 초과한 rHipPitch 가 unstoppedJoints 에 포함되어야 함")
    }

    func testVerifyTorqueOff_MultipleJointsMoving_ReturnsAllFailed() async {
        let bus = SpeedStubBus(speedByJoint: [.lHipPitch: 20, .rKnee: 15])
        let result = await EStopVerifier.verifyTorqueOff(bus: bus, delay: 0)
        guard case .failed(let joints) = result else {
            XCTFail("복수 관절 speed 초과 → .failed 반환 필요")
            return
        }
        XCTAssertEqual(joints.count, 2,
                       "속도 초과 관절 2개 모두 포함되어야 함")
        XCTAssertTrue(joints.contains(.lHipPitch))
        XCTAssertTrue(joints.contains(.rKnee))
    }

    // MARK: - 3. bus readState throw → .unreachable

    func testVerifyTorqueOff_BusThrows_ReturnsUnreachable() async {
        let bus = MockBus()
        bus.failNextReadState = true  // 첫 joint read 에서 throw
        let result = await EStopVerifier.verifyTorqueOff(bus: bus, delay: 0)
        guard case .unreachable = result else {
            XCTFail("bus throw → .unreachable 반환 필요, 실제: \(result)")
            return
        }
    }

    // MARK: - 4. bus nil → .unreachable

    func testVerifyTorqueOff_NilBus_ReturnsUnreachable() async {
        let result = await EStopVerifier.verifyTorqueOff(bus: nil, delay: 0)
        guard case .unreachable = result else {
            XCTFail("bus nil → .unreachable 반환 필요")
            return
        }
    }

    // MARK: - 5. threshold 경계 정확성

    func testVerifyTorqueOff_SpeedAtThreshold_ReturnsFailed() async {
        // speed == threshold(5) → 조건: speed >= threshold → failed
        let bus = SpeedStubBus(speedByJoint: [.headTilt: EStopVerifier.defaultSpeedThreshold])
        let result = await EStopVerifier.verifyTorqueOff(bus: bus, delay: 0)
        guard case .failed = result else {
            XCTFail("speed == threshold 이면 .failed (>= 판정)")
            return
        }
    }

    func testVerifyTorqueOff_SpeedBelowThreshold_ReturnsVerified() async {
        // speed == threshold - 1 → verified
        let belowThreshold = EStopVerifier.defaultSpeedThreshold - 1
        let bus = SpeedStubBus(speedByJoint: [.headTilt: belowThreshold])
        let result = await EStopVerifier.verifyTorqueOff(bus: bus, delay: 0)
        XCTAssertEqual(result, .verified,
                       "speed < threshold 이면 .verified")
    }
}

// MARK: - EStopVerifier Integration: fireEmergencyStop → verification → alert

/// IntentDispatcher.fireEmergencyStop 에서 EStopVerifier 가 호출되는지 검증.
@MainActor
final class EStopVerifierIntegrationTests: XCTestCase {

    private func makeDispatcher(
        bus: (any BusInterface)?,
        harness: RecordingHarness
    ) -> (dispatcher: IntentDispatcher, store: ConnectionStore) {
        let store = ConnectionStore(harness: harness)
        if let bus { store.bus = bus }
        let dispatcher = IntentDispatcher(harness: harness)
        dispatcher.connectionStore = store
        return (dispatcher, store)
    }

    /// fireEmergencyStop → bus=nil → unreachable → safetyAlert 설정.
    func testFireEmergencyStop_NilBus_SetsUnreachableAlert() async throws {
        let harness = RecordingHarness()
        let (dispatcher, store) = makeDispatcher(bus: nil, harness: harness)
        _ = await dispatcher.fireEmergencyStop()
        // Task.detached 완료 대기 (delay=0 아님, 실제 1초 대기 포함 — 테스트에서 1.5초 대기)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        // bus nil → unreachable alert 설정.
        XCTAssertNotNil(store.lastSafetyAlert,
                        "bus nil 시 unreachable 알림이 표시되어야 함")
    }

    /// fireEmergencyStop → 모든 joint speed=0 → safetyAlert nil (verified).
    func testFireEmergencyStop_AllStopped_ClearsAlert() async throws {
        let harness = RecordingHarness()
        let bus = MockBus()
        let (dispatcher, store) = makeDispatcher(bus: bus, harness: harness)
        // 사전에 alert 설정 후 fireEmergencyStop → verified 시 nil 로 해제.
        store.publishSafetyAlert("기존 알림")
        _ = await dispatcher.fireEmergencyStop()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(store.lastSafetyAlert,
                     "모든 관절 정지 확인 → alert nil (해제)")
    }

    /// fireEmergencyStop → verified → safetyEStopVerified telemetry 기록.
    func testFireEmergencyStop_Verified_RecordsTelemetry() async throws {
        let harness = RecordingHarness()
        let bus = MockBus()
        let (dispatcher, _) = makeDispatcher(bus: bus, harness: harness)
        _ = await dispatcher.fireEmergencyStop()
        // Task.detached 내부에서 1초 대기 후 record → 넉넉하게 2초 대기.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let verifiedEvents = harness.events.filter { $0.kind == .safetyEStopVerified }
        XCTAssertGreaterThanOrEqual(verifiedEvents.count, 1,
                                    "검증 성공 시 safetyEStopVerified telemetry 기록 필요")
    }

    /// fireEmergencyStop → bus throw → safetyEStopVerificationFailed telemetry.
    func testFireEmergencyStop_BusThrows_RecordsFailedTelemetry() async throws {
        let harness = RecordingHarness()
        let bus = MockBus()
        bus.failNextReadState = true
        let (dispatcher, _) = makeDispatcher(bus: bus, harness: harness)
        harness.reset()
        _ = await dispatcher.fireEmergencyStop()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let failedEvents = harness.events.filter { $0.kind == .safetyEStopVerificationFailed }
        XCTAssertGreaterThanOrEqual(failedEvents.count, 1,
                                    "검증 실패 시 safetyEStopVerificationFailed telemetry 기록 필요")
    }
}

// MARK: - SpeedStubBus

/// 특정 joint 의 presentSpeed 를 지정값으로 반환하는 test stub.
/// EStopVerifier 의 속도 threshold 분기 테스트 전용.
private final class SpeedStubBus: BusInterface, @unchecked Sendable {

    private let speedByJoint: [JointID: UInt16]
    private let defaultSpeed: UInt16

    init(speedByJoint: [JointID: UInt16] = [:], defaultSpeed: UInt16 = 0) {
        self.speedByJoint = speedByJoint
        self.defaultSpeed = defaultSpeed
    }

    func ping(id: UInt8) throws {}
    func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] { [] }
    func boardSnapshot() throws -> BoardSnapshot { throw ForgeError.io }
    func readImu() throws -> ImuRaw { throw ForgeError.io }
    func readFsrLeft() throws -> FsrReading { throw ForgeError.io }
    func readFsrRight() throws -> FsrReading { throw ForgeError.io }
    func setDxlPower(_ on: Bool) throws {}
    func setTorque(_ joint: JointID, enable: Bool) throws {}
    func emergencyStop() throws {}
    @discardableResult
    func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 { position }
    func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {}
    func setPGain(_ joint: JointID, value: UInt8) throws {}

    func readState(_ joint: JointID) throws -> JointState {
        let speed = speedByJoint[joint] ?? defaultSpeed
        return JointState(
            id: joint,
            torqueEnabled: false,
            goalPosition: 2048,
            presentPosition: 2048,
            presentSpeed: speed,
            presentLoad: 0,
            presentVoltageRaw: 130,
            presentTemperature: 30
        )
    }

    func motionPlaySlot(slot: UInt8, binPath: String?, dryRun: Bool, confirmRisk: Bool,
                        singleFootOk: Bool, followChain: Bool, maxChainDepth: Int) throws {}
    func motionPlayCancel() throws {}
    var isMotionPlaying: Bool { false }
}
