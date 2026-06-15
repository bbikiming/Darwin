import XCTest
@testable import DarwinForgeUI

/// `ActivatorState.updated(pressed:nowMs:type:)` 의 상태 전이 검증.
///
/// 시간을 외부 주입(nowMs)해 하드웨어 없이 결정론적 테스트.
final class ControllerActivatorTests: XCTestCase {

    // MARK: - hold

    func test_hold_active_while_pressed() {
        let state0 = ActivatorState.idle
        let (s1, active1, fired1) = state0.updated(pressed: true, nowMs: 0, type: .hold)
        XCTAssertTrue(active1)
        XCTAssertFalse(fired1)

        let (s2, active2, fired2) = s1.updated(pressed: true, nowMs: 100, type: .hold)
        _ = s2
        XCTAssertTrue(active2)
        XCTAssertFalse(fired2)
    }

    func test_hold_inactive_when_released() {
        let (s1, _, _) = ActivatorState.idle.updated(pressed: true, nowMs: 0, type: .hold)
        let (_, active, fired) = s1.updated(pressed: false, nowMs: 100, type: .hold)
        XCTAssertFalse(active)
        XCTAssertFalse(fired)
    }

    // MARK: - start

    func test_start_fires_on_press_edge_only() {
        let s0 = ActivatorState.idle
        // 누름 edge
        let (s1, active1, fired1) = s0.updated(pressed: true, nowMs: 0, type: .start)
        XCTAssertTrue(fired1, "누름 순간 fired")
        XCTAssertTrue(active1)

        // 계속 누름 (edge 아님)
        let (s2, active2, fired2) = s1.updated(pressed: true, nowMs: 50, type: .start)
        _ = s2
        XCTAssertFalse(fired2, "연속 누름 중에는 fired 없음")
        XCTAssertFalse(active2)
    }

    func test_start_does_not_fire_when_already_pressed() {
        let (s1, _, _) = ActivatorState.idle.updated(pressed: true, nowMs: 0, type: .start)
        let (_, _, fired) = s1.updated(pressed: true, nowMs: 100, type: .start)
        XCTAssertFalse(fired)
    }

    // MARK: - release

    func test_release_fires_on_release_edge_only() {
        let (s1, _, _) = ActivatorState.idle.updated(pressed: true, nowMs: 0, type: .release)
        // 뗌 edge
        let (_, active, fired) = s1.updated(pressed: false, nowMs: 100, type: .release)
        XCTAssertTrue(fired, "뗌 순간 fired")
        XCTAssertTrue(active)
    }

    func test_release_does_not_fire_while_pressed() {
        let (s1, _, _) = ActivatorState.idle.updated(pressed: true, nowMs: 0, type: .release)
        let (_, _, fired) = s1.updated(pressed: true, nowMs: 50, type: .release)
        XCTAssertFalse(fired)
    }

    // MARK: - longPress

    func test_longPress_fires_after_threshold() {
        let threshold = 500
        var state = ActivatorState.idle

        // 누름 시작 (t=0)
        var fired = false
        (state, _, fired) = state.updated(pressed: true, nowMs: 0, type: .longPress(thresholdMs: threshold))
        XCTAssertFalse(fired, "임계 전 fired 없음")

        // 임계 미달 (t=400)
        (state, _, fired) = state.updated(pressed: true, nowMs: 400, type: .longPress(thresholdMs: threshold))
        XCTAssertFalse(fired, "t=400 < 500ms → fired 없음")

        // 임계 초과 (t=500)
        var active = false
        (state, active, fired) = state.updated(pressed: true, nowMs: 500, type: .longPress(thresholdMs: threshold))
        XCTAssertTrue(fired, "t=500 >= 500ms → fired")
        XCTAssertTrue(active)
    }

    func test_longPress_does_not_fire_twice() {
        let threshold = 100
        var state = ActivatorState.idle
        (state, _, _) = state.updated(pressed: true, nowMs: 0, type: .longPress(thresholdMs: threshold))
        (state, _, _) = state.updated(pressed: true, nowMs: 100, type: .longPress(thresholdMs: threshold))
        // 이미 발화됨 → 같은 누름 중 두 번째 호출 fired=false
        var fired = false
        (state, _, fired) = state.updated(pressed: true, nowMs: 200, type: .longPress(thresholdMs: threshold))
        _ = state
        XCTAssertFalse(fired, "longPress 는 동일 누름 중 1회만 fired")
    }

    func test_longPress_resets_on_release() {
        let threshold = 100
        var state = ActivatorState.idle
        (state, _, _) = state.updated(pressed: true, nowMs: 0, type: .longPress(thresholdMs: threshold))
        (state, _, _) = state.updated(pressed: true, nowMs: 100, type: .longPress(thresholdMs: threshold)) // 발화
        // 뗌
        (state, _, _) = state.updated(pressed: false, nowMs: 150, type: .longPress(thresholdMs: threshold))
        // 다시 누름 → 새로 타이머 시작
        var fired = false
        (state, _, _) = state.updated(pressed: true, nowMs: 200, type: .longPress(thresholdMs: threshold))
        (state, _, fired) = state.updated(pressed: true, nowMs: 300, type: .longPress(thresholdMs: threshold))
        _ = state
        XCTAssertTrue(fired, "뗀 후 재누름으로 longPress 다시 발화")
    }

    // MARK: - toggle

    func test_toggle_flips_on_press_edge() {
        var state = ActivatorState.idle
        XCTAssertFalse(state.isActive)

        var active = false
        (state, active, _) = state.updated(pressed: true, nowMs: 0, type: .toggle)
        XCTAssertTrue(active, "첫 누름 → active=true")

        // 계속 누름 (edge 아님)
        (state, active, _) = state.updated(pressed: true, nowMs: 100, type: .toggle)
        XCTAssertTrue(active, "edge 아닐 때 상태 유지")

        // 뗌 + 재누름 → 반전
        (state, _, _) = state.updated(pressed: false, nowMs: 200, type: .toggle)
        (state, active, _) = state.updated(pressed: true, nowMs: 300, type: .toggle)
        XCTAssertFalse(active, "두 번째 누름 → active=false")
    }

    func test_toggle_does_not_change_on_hold() {
        var state = ActivatorState.idle
        (state, _, _) = state.updated(pressed: true, nowMs: 0, type: .toggle)   // ON
        let stateBefore = state
        (state, _, _) = state.updated(pressed: true, nowMs: 50, type: .toggle)  // 유지
        XCTAssertEqual(state.isActive, stateBefore.isActive, "edge 아닌 누름 유지 중 toggle 변화 없음")
    }

    // MARK: - double

    func test_double_fires_within_window() {
        let window = 300
        var state = ActivatorState.idle

        // 첫 번째 누름 (t=0)
        var fired = false
        (state, _, fired) = state.updated(pressed: true, nowMs: 0, type: .double(windowMs: window))
        XCTAssertFalse(fired)

        // 뗌
        (state, _, _) = state.updated(pressed: false, nowMs: 50, type: .double(windowMs: window))

        // 두 번째 누름 (t=200, window=300 이내)
        (state, _, fired) = state.updated(pressed: true, nowMs: 200, type: .double(windowMs: window))
        XCTAssertTrue(fired, "window 내 2회 → fired")
    }

    func test_double_does_not_fire_outside_window() {
        let window = 200
        var state = ActivatorState.idle

        var fired = false
        (state, _, fired) = state.updated(pressed: true, nowMs: 0, type: .double(windowMs: window))
        XCTAssertFalse(fired)

        (state, _, _) = state.updated(pressed: false, nowMs: 50, type: .double(windowMs: window))

        // 두 번째 누름이 window 초과 (t=300 > 200)
        (state, _, fired) = state.updated(pressed: true, nowMs: 300, type: .double(windowMs: window))
        _ = state
        XCTAssertFalse(fired, "window(200ms) 초과 후 두 번째 누름 → fired 없음 (새 첫 번째로 리셋)")
    }
}
