import XCTest
@testable import DarwinForgeUI

/// `CockpitControllerDriver` 주입 검증 — **M2 수용 기준**:
/// 가상/Mock 컨트롤러 snapshot → CockpitState 주입.
@MainActor
final class CockpitControllerDriverTests: XCTestCase {

    private func makeAxes(_ pairs: [(Int, Double)]) -> [Double] {
        var axes = Array(repeating: 0.0, count: ControllerSnapshot.standardAxisCount)
        for (i, v) in pairs { axes[i] = v }
        return axes
    }

    private func makeButtons(_ pressed: [Int]) -> [Bool] {
        var b = Array(repeating: false, count: ControllerSnapshot.standardButtonCount)
        for i in pressed { b[i] = true }
        return b
    }

    // MARK: - 이동 주입

    func test_inject_forward_sets_cockpit_leftStick_and_source() {
        let state = CockpitState()
        let src = MockControllerSource()
        let driver = CockpitControllerDriver(state: state, source: src, profile: .xbox)

        // LS Y 위(−0.8) = 전진
        driver.inject(ControllerSnapshot(axes: makeAxes([(1, -0.8)]), buttons: makeButtons([])))

        XCTAssertLessThan(state.leftStick.y, 0.0, "전진 → leftStick.y 음수")
        XCTAssertEqual(state.leftStick.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(state.lastSource, .gamepad)
    }

    func test_inject_turn_sets_rightStick() {
        let state = CockpitState()
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: .xbox)
        // RS X(axis2) +0.7 → turnRight → rightStick.x +
        driver.inject(ControllerSnapshot(axes: makeAxes([(2, 0.7)]), buttons: makeButtons([])))
        XCTAssertGreaterThan(state.rightStick.x, 0.0)
    }

    // MARK: - tick (소스 경유)

    func test_tick_pulls_from_source() {
        let state = CockpitState()
        let src = MockControllerSource()
        src.snapshot = ControllerSnapshot(axes: makeAxes([(1, -0.8)]), buttons: makeButtons([]))
        let driver = CockpitControllerDriver(state: state, source: src, profile: .xbox)
        driver.tick()
        XCTAssertLessThan(state.leftStick.y, 0.0)
    }

    func test_tick_noop_when_disconnected() {
        let state = CockpitState()
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(isConnected: false), profile: .xbox)
        driver.tick()
        XCTAssertEqual(state.leftStick, .zero, "미연결 → 주입 없음")
    }

    // MARK: - 버튼 edge-trigger

    func test_emergency_fires_on_rising_edge_only() {
        let state = CockpitState()
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: .xbox)

        let bPressed = ControllerSnapshot(axes: makeAxes([]), buttons: makeButtons([1])) // B
        let bReleased = ControllerSnapshot.neutral

        // 1) press → 발화
        driver.inject(bPressed)
        XCTAssertNotNil(state.emergencyAt, "rising edge → 발화")

        // 2) hold → 재발화 금지 (reset 후 유지)
        state.emergencyAt = nil
        driver.inject(bPressed)
        XCTAssertNil(state.emergencyAt, "hold 중 재발화 없음")

        // 3) release
        driver.inject(bReleased)
        XCTAssertNil(state.emergencyAt)

        // 4) re-press → 재발화
        driver.inject(bPressed)
        XCTAssertNotNil(state.emergencyAt, "release 후 재press → 재발화")
    }

    func test_recover_and_ballTracking_edge_fire() {
        let state = CockpitState()
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: .xbox)
        // Y(3)=recover, X(2)=ballTracking
        driver.inject(ControllerSnapshot(axes: makeAxes([]), buttons: makeButtons([3, 2])))
        XCTAssertNotNil(state.recoveryAt)
        XCTAssertNotNil(state.ballTrackingToggleAt)
    }

    // MARK: - 연결 표시

    func test_start_sets_controller_name() {
        let state = CockpitState()
        let src = MockControllerSource(displayName: "Mock Pad")
        let driver = CockpitControllerDriver(state: state, source: src, profile: .xbox)
        driver.start(pollInterval: 999) // 타이머 거의 안 돎; start 부수효과만 검증
        XCTAssertEqual(state.connectedController, "Mock Pad")
        driver.stop()
    }
}
