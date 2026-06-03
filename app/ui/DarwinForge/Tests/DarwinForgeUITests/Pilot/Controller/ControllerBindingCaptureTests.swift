import XCTest
@testable import DarwinForgeUI

/// `ControllerBindingCapture.detect` — press-to-bind 캡처.
final class ControllerBindingCaptureTests: XCTestCase {

    private func snapshot(axes: [(Int, Double)] = [], buttons: [Int] = []) -> ControllerSnapshot {
        var a = Array(repeating: 0.0, count: ControllerSnapshot.standardAxisCount)
        for (i, v) in axes { a[i] = v }
        var b = Array(repeating: false, count: ControllerSnapshot.standardButtonCount)
        for i in buttons { b[i] = true }
        return ControllerSnapshot(axes: a, buttons: b)
    }

    func test_neutral_returns_nil() {
        XCTAssertNil(ControllerBindingCapture.detect(.neutral))
    }

    func test_button_takes_priority() {
        let s = snapshot(axes: [(0, 0.9)], buttons: [2])
        XCTAssertEqual(ControllerBindingCapture.detect(s), .button(index: 2))
    }

    func test_strongest_axis_with_polarity() {
        let s = snapshot(axes: [(0, 0.6), (1, -0.9)])
        XCTAssertEqual(ControllerBindingCapture.detect(s), .axis(index: 1, polarity: .negative))
    }

    func test_positive_polarity() {
        let s = snapshot(axes: [(2, 0.8)])
        XCTAssertEqual(ControllerBindingCapture.detect(s), .axis(index: 2, polarity: .positive))
    }

    func test_below_threshold_ignored() {
        let s = snapshot(axes: [(0, 0.3)]) // < 0.5
        XCTAssertNil(ControllerBindingCapture.detect(s))
    }
}
