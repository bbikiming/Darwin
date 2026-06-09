import XCTest
@testable import DarwinForgeUI

/// `AxisResponseCurveModel` — 응답 곡선 샘플링 (설계 §C, 순수 함수).
/// 좌표는 입력 크기 x ∈ [0,1] → 출력 크기 y ∈ [0,1] (둘 다 magnitude).
final class AxisResponseCurveModelTests: XCTestCase {

    func test_linear_default_endpoints() {
        let points = AxisResponseCurveModel.points(tuning: ControllerAxisTuning(), sampleCount: 41)
        XCTAssertEqual(points.count, 41)
        XCTAssertEqual(points.first?.x, 0)
        XCTAssertEqual(points.first?.y, 0)
        XCTAssertEqual(points.last!.x, 1, accuracy: 0.0001)
        XCTAssertEqual(points.last!.y, 1, accuracy: 0.0001)
    }

    func test_curve_is_monotonic_non_decreasing() {
        let tuning = ControllerAxisTuning(innerDeadzone: 0.12, expo: 0.85, sensitivity: 1.4)
        let points = AxisResponseCurveModel.points(tuning: tuning, sampleCount: 64)
        for pair in zip(points, points.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.y, pair.0.y - 0.0001)
        }
    }

    func test_live_point_below_deadzone_outputs_zero() {
        let live = AxisResponseCurveModel.livePoint(tuning: ControllerAxisTuning(), raw: 0.05)
        XCTAssertEqual(live.x, 0.05, accuracy: 0.0001)
        XCTAssertEqual(live.y, 0, accuracy: 0.0001)
    }

    func test_live_point_uses_magnitude_even_when_inverted() {
        let tuning = ControllerAxisTuning(invert: true)
        let live = AxisResponseCurveModel.livePoint(tuning: tuning, raw: -0.8)
        XCTAssertEqual(live.x, 0.8, accuracy: 0.0001)
        XCTAssertEqual(live.y, abs(tuning.shaped(-0.8)), accuracy: 0.0001)
    }
}
