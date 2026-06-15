import XCTest
@testable import DarwinForgeUI

/// `CockpitControllerDriver` 주입 검증 — **M2 수용 기준**:
/// 가상/Mock 컨트롤러 snapshot → CockpitState 주입.
///
/// M3 추가: 데드맨 게이트 / 터보 스케일 / activator 모드 소비.
/// `.xbox` 프리셋은 deadmanEnabled=true(버튼4=LB) — 이동 테스트는 데드맨 홀드를 명시.
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

    /// 데드맨 게이트 없는 프로파일 — 이동 주입 자체를 검증할 때 사용.
    private var xboxNoDeadman: ControllerBindingProfile {
        var p = ControllerBindingProfile.xbox
        p.deadmanEnabled = false
        return p
    }

    // MARK: - 이동 주입

    func test_inject_forward_sets_cockpit_leftStick_and_source() {
        let state = CockpitState()
        let src = MockControllerSource()
        let driver = CockpitControllerDriver(state: state, source: src, profile: xboxNoDeadman)

        // LS Y 위(−0.8) = 전진
        driver.inject(ControllerSnapshot(axes: makeAxes([(1, -0.8)]), buttons: makeButtons([])))

        XCTAssertLessThan(state.leftStick.y, 0.0, "전진 → leftStick.y 음수")
        XCTAssertEqual(state.leftStick.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(state.lastSource, .gamepad)
    }

    func test_inject_turn_sets_rightStick() {
        let state = CockpitState()
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: xboxNoDeadman)
        // RS X(axis2) +0.7 → turnRight → rightStick.x +
        driver.inject(ControllerSnapshot(axes: makeAxes([(2, 0.7)]), buttons: makeButtons([])))
        XCTAssertGreaterThan(state.rightStick.x, 0.0)
    }

    // MARK: - tick (소스 경유)

    func test_tick_pulls_from_source() {
        let state = CockpitState()
        let src = MockControllerSource()
        src.snapshot = ControllerSnapshot(axes: makeAxes([(1, -0.8)]), buttons: makeButtons([]))
        let driver = CockpitControllerDriver(state: state, source: src, profile: xboxNoDeadman)
        driver.tick()
        XCTAssertLessThan(state.leftStick.y, 0.0)
    }

    func test_tick_noop_when_disconnected() {
        let state = CockpitState()
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(isConnected: false), profile: .xbox)
        driver.tick()
        XCTAssertEqual(state.leftStick, .zero, "미연결 → 주입 없음")
    }

    // MARK: - 버튼 edge-trigger (기본 activator = .start)

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

    // MARK: - 데드맨 게이트 (M3)

    func test_deadman_not_held_zeroes_movement() {
        let state = CockpitState()
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: .xbox)
        // 전진 + 회전 입력, 데드맨(버튼4) 비홀드 → 주입 0
        driver.inject(ControllerSnapshot(axes: makeAxes([(1, -0.8), (2, 0.7)]), buttons: makeButtons([])))
        XCTAssertEqual(state.leftStick, .zero, "데드맨 비홀드 → 이동 0")
        XCTAssertEqual(state.rightStick.x, 0.0, accuracy: 1e-9, "데드맨 비홀드 → 회전 0")
    }

    func test_deadman_held_allows_movement() {
        let state = CockpitState()
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: .xbox)
        driver.inject(ControllerSnapshot(axes: makeAxes([(1, -0.8)]), buttons: makeButtons([4])))
        XCTAssertLessThan(state.leftStick.y, 0.0, "데드맨 홀드 → 이동 주입")
    }

    func test_estop_fires_even_without_deadman() {
        let state = CockpitState()
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: .xbox)
        // 데드맨 비홀드 + B(E-STOP)만 — 안전 액션은 항상 동작
        driver.inject(ControllerSnapshot(axes: makeAxes([]), buttons: makeButtons([1])))
        XCTAssertNotNil(state.emergencyAt, "E-STOP 은 데드맨과 무관")
    }

    func test_recover_fires_even_without_deadman() {
        let state = CockpitState()
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: .xbox)
        driver.inject(ControllerSnapshot(axes: makeAxes([]), buttons: makeButtons([3])))
        XCTAssertNotNil(state.recoveryAt, "복구는 데드맨과 무관")
    }

    // MARK: - 터보 (M3)

    func test_turbo_scales_movement() {
        // 같은 축 입력(−0.5, 데드존 정형 통과 후 값)을 터보 유무로 비교 — 비율 = turboScale.
        let plainState = CockpitState()
        let plainDriver = CockpitControllerDriver(state: plainState, source: MockControllerSource(), profile: xboxNoDeadman)
        plainDriver.inject(ControllerSnapshot(axes: makeAxes([(1, -0.5)]), buttons: makeButtons([])))

        let turboState = CockpitState()
        let turboDriver = CockpitControllerDriver(state: turboState, source: MockControllerSource(), profile: xboxNoDeadman)
        turboDriver.inject(ControllerSnapshot(axes: makeAxes([(1, -0.5)]), buttons: makeButtons([5])))

        XCTAssertLessThan(plainState.leftStick.y, 0.0, "전제: 터보 없이도 전진 주입")
        XCTAssertEqual(turboState.leftStick.y / plainState.leftStick.y,
                       ControllerDriveModifiers.turboScale, accuracy: 1e-6,
                       "터보 홀드 → 이동 × turboScale")
    }

    func test_turbo_clamps_to_unit_range() {
        let state = CockpitState()
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: xboxNoDeadman)
        driver.inject(ControllerSnapshot(axes: makeAxes([(1, -1.0)]), buttons: makeButtons([5])))
        XCTAssertEqual(state.leftStick.y, -1.0, accuracy: 1e-6, "터보 스케일 후 ±1 클램프")
    }

    // MARK: - Activator 모드 소비 (M3)

    func test_recover_toggle_activator_fires_on_every_press() {
        let state = CockpitState()
        var p = xboxNoDeadman
        p.activators[.recover] = .toggle
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: p)

        let pressed = ControllerSnapshot(axes: makeAxes([]), buttons: makeButtons([3]))

        driver.inject(pressed, nowMs: 0)
        XCTAssertNotNil(state.recoveryAt, "토글 ON → 발화")

        state.recoveryAt = nil
        driver.inject(ControllerSnapshot.neutral, nowMs: 33)
        XCTAssertNil(state.recoveryAt, "release 자체는 발화 없음")

        driver.inject(pressed, nowMs: 66)
        XCTAssertNotNil(state.recoveryAt, "토글 OFF 플립 → 재발화")
    }

    func test_recover_longPress_activator_fires_after_threshold() {
        let state = CockpitState()
        var p = xboxNoDeadman
        p.activators[.recover] = .longPress(thresholdMs: 100)
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: p)

        let pressed = ControllerSnapshot(axes: makeAxes([]), buttons: makeButtons([3]))

        driver.inject(pressed, nowMs: 0)
        XCTAssertNil(state.recoveryAt, "임계 미달 → 발화 없음")

        driver.inject(pressed, nowMs: 50)
        XCTAssertNil(state.recoveryAt)

        driver.inject(pressed, nowMs: 150)
        XCTAssertNotNil(state.recoveryAt, "100ms 초과 홀드 → 발화")
    }

    func test_estop_ignores_longPress_activator_for_safety() {
        let state = CockpitState()
        var p = xboxNoDeadman
        p.activators[.emergencyStop] = .longPress(thresholdMs: 500)
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: p)

        driver.inject(ControllerSnapshot(axes: makeAxes([]), buttons: makeButtons([1])), nowMs: 0)
        XCTAssertNotNil(state.emergencyAt, "E-STOP 은 activator 무시 — 누름 즉시 발화")
    }

    func test_profile_swap_resets_activator_state() {
        let state = CockpitState()
        var p = xboxNoDeadman
        p.activators[.recover] = .toggle
        let driver = CockpitControllerDriver(state: state, source: MockControllerSource(), profile: p)

        driver.inject(ControllerSnapshot(axes: makeAxes([]), buttons: makeButtons([3])), nowMs: 0)
        XCTAssertNotNil(state.recoveryAt)

        // 프로파일 교체 → activator 상태 초기화 (잔존 토글 상태 방지)
        state.recoveryAt = nil
        driver.profile = p
        driver.inject(ControllerSnapshot.neutral, nowMs: 33)
        driver.inject(ControllerSnapshot(axes: makeAxes([]), buttons: makeButtons([3])), nowMs: 66)
        XCTAssertNotNil(state.recoveryAt, "리셋 후 첫 press → 발화")
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
