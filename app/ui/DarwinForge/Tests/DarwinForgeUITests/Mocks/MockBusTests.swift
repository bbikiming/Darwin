import XCTest
@testable import ForgeCore

/// 사이클 255 — `MockBus` 회귀 가드 + 기본 사용 데모.
///
/// 본 테스트는 mock 자체의 invariant 만 검증 — recovery/preflight 등 caller 의 unit test
/// 는 별도 cycle 에서 추가. write 누적 / failure injection / readState fallback 의
/// 3 가지 핵심 시나리오 확인.
final class MockBusTests: XCTestCase {

    // MARK: - Write 누적

    func testPositionWritesRecorded() throws {
        let bus = MockBus()

        _ = try bus.setPosition(.headPan, raw: 2048)
        _ = try bus.setPosition(.headTilt, raw: 1900)
        _ = try bus.setPosition(.rShoulderPitch, raw: 1500)

        XCTAssertEqual(bus.positionWrites.count, 3, "3 write 모두 기록")
        XCTAssertEqual(bus.positionWrites[0].joint, .headPan)
        XCTAssertEqual(bus.positionWrites[0].raw, 2048)
        XCTAssertEqual(bus.positionWrites[1].joint, .headTilt)
        XCTAssertEqual(bus.positionWrites[2].joint, .rShoulderPitch)
    }

    func testTorqueAndSpeedWritesRecorded() throws {
        let bus = MockBus()

        try bus.setTorque(.lKnee, enable: true)
        try bus.setMovingSpeed(.lKnee, speed: 80)
        try bus.setPGain(.lKnee, value: 32)
        try bus.setDxlPower(true)

        XCTAssertEqual(bus.torqueWrites.count, 1)
        XCTAssertEqual(bus.torqueWrites[0].joint, .lKnee)
        XCTAssertTrue(bus.torqueWrites[0].enable)

        XCTAssertEqual(bus.speedWrites.count, 1)
        XCTAssertEqual(bus.speedWrites[0].speed, 80)

        XCTAssertEqual(bus.pGainWrites.count, 1)
        XCTAssertEqual(bus.pGainWrites[0].value, 32)

        XCTAssertEqual(bus.dxlPowerWrites, [true])
    }

    // MARK: - Failure injection (single-shot auto-reset)

    func testFailureInjectionAutoResetsAfterOneFailure() {
        let bus = MockBus()
        bus.failNextSetPosition = true

        XCTAssertThrowsError(try bus.setPosition(.headPan, raw: 2048),
                             "첫 호출은 inject failure → throw")
        XCTAssertFalse(bus.failNextSetPosition,
                       "single-shot: 첫 throw 후 flag auto-reset")

        // 다음 호출은 정상 통과.
        XCTAssertNoThrow(try bus.setPosition(.headPan, raw: 2048),
                         "auto-reset 후 다음 호출은 성공")
        XCTAssertEqual(bus.positionWrites.count, 1,
                       "throw 발생한 호출은 누적되지 않음, 성공한 1회만 기록")
    }

    func testEmergencyStopClearsAllTorque() throws {
        let bus = MockBus()
        try bus.setTorque(.headPan, enable: true)
        try bus.setTorque(.headTilt, enable: true)

        try bus.emergencyStop()

        XCTAssertEqual(bus.emergencyStopCount, 1)

        // emergency stop 후 readState 는 torqueEnabled=false 반환.
        let state = try bus.readState(.headPan)
        XCTAssertFalse(state.torqueEnabled, "emergencyStop 후 torque OFF")
    }

    // MARK: - readState fallback (seeded position 반환)

    func testReadStateReturnsLastSetPosition() throws {
        let bus = MockBus()
        _ = try bus.setPosition(.headPan, raw: 1500)
        try bus.setTorque(.headPan, enable: true)

        let state = try bus.readState(.headPan)
        XCTAssertEqual(state.presentPosition, 1500,
                       "마지막 setPosition 값을 readState 가 반환")
        XCTAssertEqual(state.goalPosition, 1500)
        XCTAssertTrue(state.torqueEnabled)
        XCTAssertEqual(state.presentSpeed, 0, "idle motor — speed 0")
    }

    func testSeededPositionReturnedByReadState() throws {
        let bus = MockBus()
        bus.seedPosition(.lAnklePitch, raw: 2200)

        let state = try bus.readState(.lAnklePitch)
        XCTAssertEqual(state.presentPosition, 2200,
                       "직접 seed 한 position 도 readState 가 반환")
    }

    // MARK: - BusInterface conformance — 실 Bus 대신 사용 가능

    func testMockBusUsableAsBusInterface() throws {
        // 함수가 `any BusInterface` 받을 수 있는지 검증 — recovery / preflight 가
        // 본 protocol 로 추상화될 때 MockBus 가 적합한 stand-in.
        let bus: any BusInterface = MockBus()

        try bus.setTorque(.headPan, enable: true)
        _ = try bus.setPosition(.headPan, raw: 2048)
        let state = try bus.readState(.headPan)

        XCTAssertEqual(state.presentPosition, 2048,
                       "protocol existential 로도 동작 동일")
    }
}
