import XCTest
@testable import DarwinForgeUI

/// `ControllerSnapshot` 안전 접근자·중립 스냅샷 검증.
final class ControllerSnapshotTests: XCTestCase {

    func test_neutral_is_all_zero_and_unpressed() {
        let s = ControllerSnapshot.neutral
        XCTAssertEqual(s.axes.count, ControllerSnapshot.standardAxisCount)
        XCTAssertEqual(s.buttons.count, ControllerSnapshot.standardButtonCount)
        XCTAssertTrue(s.axes.allSatisfy { $0 == 0 })
        XCTAssertTrue(s.buttons.allSatisfy { $0 == false })
    }

    func test_axis_in_range_returns_value() {
        let s = ControllerSnapshot(axes: [0.1, -0.2, 0.3], buttons: [])
        XCTAssertEqual(s.axis(0), 0.1, accuracy: 1e-9)
        XCTAssertEqual(s.axis(1), -0.2, accuracy: 1e-9)
        XCTAssertEqual(s.axis(2), 0.3, accuracy: 1e-9)
    }

    func test_axis_out_of_range_returns_zero() {
        let s = ControllerSnapshot(axes: [0.5], buttons: [])
        XCTAssertEqual(s.axis(5), 0.0, "범위 밖 축 → 0 (방어적)")
        XCTAssertEqual(s.axis(-1), 0.0)
    }

    func test_button_in_range_returns_state() {
        let s = ControllerSnapshot(axes: [], buttons: [false, true, false])
        XCTAssertFalse(s.button(0))
        XCTAssertTrue(s.button(1))
    }

    func test_button_out_of_range_returns_false() {
        let s = ControllerSnapshot(axes: [], buttons: [true])
        XCTAssertFalse(s.button(10), "범위 밖 버튼 → false (방어적)")
        XCTAssertFalse(s.button(-1))
    }
}
