import Foundation
import XCTest
@testable import DarwinForgeUI

/// **WalkLabRCBridge emergency/recovery 사이클 단위 테스트**.
///
/// 범위: emergency 발화, recovery flag clear, 입력 차단 invariant, 사이클 58 보안 회귀 가드.
@MainActor
final class WalkLabRCBridgeEmergencyTests: XCTestCase {

    private var mock: MockTelloLink!
    private var session: WalkLabSession!
    private var bridge: WalkLabRCBridge!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockTelloLink()
        session = WalkLabSession()
        bridge = WalkLabRCBridge(tello: mock)
        bridge.session = session
    }

    override func tearDown() async throws {
        bridge = nil
        session = nil
        mock = nil
        try await super.tearDown()
    }

    // MARK: - Emergency 발화

    func testEmergencyTriggersSessionEmergencyAndTelloEmergency() async {
        session.start(.march)
        XCTAssertEqual(bridge.emergencyCount, 0)

        bridge.handleEmergency(from: .ui)

        XCTAssertEqual(bridge.emergencyCount, 1)
        XCTAssertEqual(session.current, .idle, "emergencyStop 후 current idle")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mock.emergencyCount, 1, "MockTello 의 emergency() 호출됨")
    }

    func testEmergencyAllowedEvenWhenDisabled() {
        session.start(.march)
        bridge.enabled = false
        bridge.handleEmergency(from: .ui)
        XCTAssertEqual(bridge.emergencyCount, 1, "disabled 라도 emergency 허용")
        XCTAssertEqual(session.current, .idle)
    }

    func testEmergencyCountAccumulates() {
        XCTAssertEqual(bridge.emergencyCount, 0)
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertEqual(bridge.emergencyCount, 1)
        bridge.handleRecovery(from: .ui)
        session.start(.march)
        bridge.handleEmergency(from: .keyboard)
        XCTAssertEqual(bridge.emergencyCount, 2, "두 번째 emergency 카운트")
    }

    func testEmergencyStopZerosAmplitudeFields() {
        bridge.smoothingFactor = 0.5
        session.start(.march)
        for _ in 0..<5 {
            bridge.handleTelloStick(lr: 25, fb: 100, ud: 0, yaw: 50)
        }
        XCTAssertGreaterThan(session.strideMm, 10, "사전: amplitude 잔재")

        bridge.handleEmergency(from: .ui)

        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "emergency 후 stride 0")
        XCTAssertEqual(session.sideMm, 0, accuracy: 1e-9, "emergency 후 side 0")
        XCTAssertEqual(session.turnDeg, 0, accuracy: 1e-9, "emergency 후 turn 0")
    }

    // MARK: - Recovery

    func testHandleRecoveryClearsEmergencyFlag() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive)
        XCTAssertEqual(session.current, .idle, "emergency 후 current idle")

        bridge.handleRecovery(from: .ui)

        XCTAssertFalse(session.emergencyStopActive, "recovery → flag clear")
        XCTAssertEqual(session.current, .idle, "walking 자동 시작 안 함")
        XCTAssertNil(bridge.safetyMessage, "safety 메시지 clear")
    }

    func testRecoveryUnblocksPresetShortcuts() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive)

        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(session.current, .idle, "recovery 전 차단")

        bridge.handleRecovery(from: .ui)

        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(session.current, .march, "recovery 후 unblock")
    }

    func testHandleRecoveryNoOpWhenNotInEmergency() {
        XCTAssertFalse(session.emergencyStopActive)
        bridge.handleRecovery(from: .ui)
        XCTAssertNil(bridge.safetyMessage, "silent no-op — message 미변경")
        XCTAssertFalse(session.emergencyStopActive)
    }

    func testHandleRecoveryClearsLastIntent() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertNotNil(bridge.lastIntent, "사전: emergency intent 기록")

        bridge.handleRecovery(from: .ui)

        XCTAssertNil(bridge.lastIntent, "recovery 후 lastIntent clear")
    }

    func testRepeatedEmergencyAndRecovery() {
        for cycle in 1...3 {
            session.start(.march)
            XCTAssertEqual(session.current, .march, "cycle \(cycle): march 시작")

            bridge.handleEmergency(from: .ui)
            XCTAssertTrue(session.emergencyStopActive, "cycle \(cycle): emergency 활성")
            XCTAssertEqual(session.current, .idle)

            bridge.handleRecovery(from: .ui)
            XCTAssertFalse(session.emergencyStopActive, "cycle \(cycle): recovery 후 flag clear")
        }
    }

    // MARK: - Cycle 58 security-auditor 회귀 가드

    /// **CRITICAL fix 회귀 가드** — emergency 도중 handleTelloStick auto-start 차단.
    /// 종전 bug: Space → W → autostart .march 로 robot 재작동.
    func testEmergencyBlocksHandleTelloStickAutoStart() {
        session.pilotBridge = bridge
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive)
        XCTAssertEqual(session.current, .idle)

        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)

        XCTAssertEqual(session.current, .idle, "emergency 중 autostart 차단")
        XCTAssertTrue(bridge.safetyMessage?.contains("긴급 정지") ?? false,
                      "사용자에게 recovery 안내")
    }

    /// **CRITICAL fix 회귀 가드** — emergency 후 syncCommandToEngine 은 enabled=false만 송출.
    func testEmergencyBlocksSyncCommandToEngine() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive)

        session.strideMm = 40
        session.syncCommandToEngine()

        XCTAssertTrue(session.emergencyStopActive, "syncCommand 이 emergency state 영향 없음")
    }

    /// **HIGH 2 fix 회귀 가드** — emergency 시 applyAmplitude 즉시 return.
    func testEmergencyBlocksApplyAmplitudeViaHandleMotion() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "emergency 후 stride 0")

        let result = bridge.handleMotion(id: "preset.march", from: .ui)
        if case .rejectedSafety = result { /* OK */ } else {
            XCTFail("emergency → handleMotion rejected 기대")
        }
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "stride 변화 없음")
    }

    func testHandlePresetBlockedDuringEmergency() {
        session.start(.march)
        bridge.handleEmergency(from: .keyboard)
        XCTAssertTrue(session.emergencyStopActive, "emergency 후 active flag")

        bridge.handlePreset(.march, from: .keyboard)

        XCTAssertEqual(session.current, .idle, "emergency 동안 preset 재시작 차단")
        XCTAssertTrue(bridge.safetyMessage?.contains("긴급 정지") ?? false,
                      "emergency 안전 메시지")
    }
}
