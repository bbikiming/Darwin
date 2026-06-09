import XCTest
@testable import DarwinForgeUI

/// `PressToSelectTracker` — 실패드 입력으로 다이어그램 컨트롤을 선택 (Steam Input 패턴).
/// 바인딩하지 않고 선택만 한다. 엣지 기반 — 누르고 있는 동안 재선택하지 않는다.
final class PressToSelectTrackerTests: XCTestCase {

    private func snapshot(axes: [(Int, Double)] = [], buttons: [Int] = []) -> ControllerSnapshot {
        var a = Array(repeating: 0.0, count: ControllerSnapshot.standardAxisCount)
        for (i, v) in axes { a[i] = v }
        var b = Array(repeating: false, count: ControllerSnapshot.standardButtonCount)
        for i in buttons { b[i] = true }
        return ControllerSnapshot(axes: a, buttons: b)
    }

    func test_press_selects_control() {
        let (_, selection) = PressToSelectTracker().updated(with: snapshot(buttons: [2]))
        XCTAssertEqual(selection, .button(index: 2))
    }

    func test_holding_does_not_reselect() {
        let s = snapshot(buttons: [2])
        let (tracker, _) = PressToSelectTracker().updated(with: s)
        let (_, selection) = tracker.updated(with: s)
        XCTAssertNil(selection)
    }

    func test_release_then_new_press_selects_again() {
        var tracker = PressToSelectTracker()
        (tracker, _) = tracker.updated(with: snapshot(buttons: [2]))
        (tracker, _) = tracker.updated(with: .neutral)
        let (_, selection) = tracker.updated(with: snapshot(buttons: [0]))
        XCTAssertEqual(selection, .button(index: 0))
    }

    func test_axis_push_selects_with_polarity() {
        let (_, selection) = PressToSelectTracker().updated(with: snapshot(axes: [(1, -0.9)]))
        XCTAssertEqual(selection, .axis(index: 1, polarity: .negative))
    }

    func test_neutral_yields_no_selection() {
        let (_, selection) = PressToSelectTracker().updated(with: .neutral)
        XCTAssertNil(selection)
    }
}
