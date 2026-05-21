import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.17.0 (2026-05-21) Phase 4 — Tello → DARwIn 매핑 unit test**.
///
/// 순수 함수 (TelloRCMapper.map) 의 결정 logic 검증:
/// - default scale + deadzone + clamp
/// - extreme stick → walking 한도 내
/// - stop 명령 (모든 stick = 0)
final class TelloRCMapperTests: XCTestCase {

    // MARK: - Deadzone

    func testDeadzoneSilencesSmallStick() {
        let cmd = TelloRCMapper.map(lr: 3, fb: -4, ud: 0, yaw: 2)
        XCTAssertEqual(cmd, .stop, "stick < 5 → all zero (deadzone)")
    }

    func testNoDeadzoneAtThreshold() {
        let cmd = TelloRCMapper.map(lr: 0, fb: 5, ud: 0, yaw: 0)
        XCTAssertEqual(cmd.strideMm, 5 * 0.4, accuracy: 1e-9,
                       "stick = 5 (threshold) → 0 인지 ≥인지 — 현재 |x|<5 만 deadzone 이라 5 는 통과")
    }

    // MARK: - Default scale

    func testFullForwardStickMapsToMaxStride() {
        let cmd = TelloRCMapper.map(lr: 0, fb: 100, ud: 0, yaw: 0)
        // 100 * 0.4 = 40 (clamp 한도)
        XCTAssertEqual(cmd.strideMm, 40, accuracy: 1e-9)
        XCTAssertEqual(cmd.sideMm, 0, accuracy: 1e-9)
        XCTAssertEqual(cmd.turnDeg, 0, accuracy: 1e-9)
    }

    func testFullSideStickMapsToMaxSide() {
        let cmd = TelloRCMapper.map(lr: 100, fb: 0, ud: 0, yaw: 0)
        // 100 * 0.3 = 30, clamp 25 → 25.
        XCTAssertEqual(cmd.sideMm, 25, accuracy: 1e-9)
    }

    func testFullYawStickMapsToMaxTurn() {
        let cmd = TelloRCMapper.map(lr: 0, fb: 0, ud: 0, yaw: 100)
        // 100 * 0.2 = 20.
        XCTAssertEqual(cmd.turnDeg, 20, accuracy: 1e-9)
    }

    // MARK: - Clamp

    func testNegativeOverloadClampedToNegativeLimit() {
        let cmd = TelloRCMapper.map(lr: -100, fb: -100, ud: 0, yaw: -100)
        // fb: -100 * 0.4 = -40 (clamp -40..40 → -40)
        // lr: -100 * 0.3 = -30 → -25 (clamp -25..25)
        // yaw: -100 * 0.2 = -20.
        XCTAssertEqual(cmd.strideMm, -40, accuracy: 1e-9)
        XCTAssertEqual(cmd.sideMm, -25, accuracy: 1e-9)
        XCTAssertEqual(cmd.turnDeg, -20, accuracy: 1e-9)
    }

    // MARK: - UD ignored

    func testUDStickIsIgnored() {
        let cmd1 = TelloRCMapper.map(lr: 0, fb: 0, ud: 100, yaw: 0)
        let cmd2 = TelloRCMapper.map(lr: 0, fb: 0, ud: -100, yaw: 0)
        XCTAssertEqual(cmd1, .stop, "ud 채널은 DARwIn 무관 — robot 정지")
        XCTAssertEqual(cmd2, .stop)
    }

    // MARK: - Custom scale

    func testCustomScaleApplied() {
        let custom = TelloRCMapper.Scale(fb: 0.5, lr: 0.5, yaw: 0.5)
        let cmd = TelloRCMapper.map(lr: 20, fb: 20, ud: 0, yaw: 20, scale: custom)
        // 20 * 0.5 = 10. clamp 한도 내.
        XCTAssertEqual(cmd.strideMm, 10, accuracy: 1e-9)
        XCTAssertEqual(cmd.sideMm, 10, accuracy: 1e-9)
        XCTAssertEqual(cmd.turnDeg, 10, accuracy: 1e-9)
    }

    // MARK: - Stop helper

    func testStopHelper() {
        XCTAssertEqual(WalkingCommand.stop.strideMm, 0)
        XCTAssertTrue(WalkingCommand.stop.isStop)
    }
}

/// **v1.17.0 Phase 4 — Mock TelloLink 동작 검증**.
@MainActor
final class MockTelloLinkTests: XCTestCase {

    func testStartRecordsCommand() async throws {
        let mock = MockTelloLink()
        try await mock.start()
        XCTAssertEqual(mock.startCount, 1)
        XCTAssertEqual(mock.sentCommands, ["command"], "SDK 진입 명령")
    }

    func testSendRCRecordsClamped() async {
        let mock = MockTelloLink()
        await mock.sendRC(lr: 150, fb: -200, ud: 50, yaw: 80)
        XCTAssertEqual(mock.lastRC?.lr, 100, "150 → 100 clamp")
        XCTAssertEqual(mock.lastRC?.fb, -100, "-200 → -100 clamp")
        XCTAssertEqual(mock.lastRC?.ud, 50)
        XCTAssertEqual(mock.lastRC?.yaw, 80)
        XCTAssertEqual(mock.sentCommands.last, "rc 100 -100 50 80")
    }

    func testEmergencyRecorded() async {
        let mock = MockTelloLink()
        await mock.emergency()
        XCTAssertEqual(mock.emergencyCount, 1)
        XCTAssertTrue(mock.sentCommands.contains("emergency"))
    }

    func testResetClearsState() async {
        let mock = MockTelloLink()
        try? await mock.start()
        await mock.sendRC(lr: 10, fb: 20, ud: 0, yaw: 5)
        mock.reset()
        XCTAssertEqual(mock.sentCommands, [])
        XCTAssertNil(mock.lastRC)
        XCTAssertEqual(mock.startCount, 0)
    }
}
