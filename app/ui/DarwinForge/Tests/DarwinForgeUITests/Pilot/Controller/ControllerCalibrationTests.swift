import XCTest
@testable import DarwinForgeUI

/// `AxisCalibration.normalize(_:)` 와 `CalibrationCapture` 누적 검증.
final class ControllerCalibrationTests: XCTestCase {

    // MARK: - AxisCalibration.normalize 경계값

    func test_normalize_min_returns_minus1() {
        // min=0, max=1000, center=500, deadband=0
        let cal = AxisCalibration(min: 0, max: 1000, center: 500, deadband: 0)
        XCTAssertEqual(cal.normalize(0), -1.0, accuracy: 1e-9,
                       "raw=min → -1.0")
    }

    func test_normalize_max_returns_plus1() {
        let cal = AxisCalibration(min: 0, max: 1000, center: 500, deadband: 0)
        XCTAssertEqual(cal.normalize(1000), 1.0, accuracy: 1e-9,
                       "raw=max → +1.0")
    }

    func test_normalize_center_returns_zero() {
        let cal = AxisCalibration(min: 0, max: 1000, center: 500, deadband: 0)
        XCTAssertEqual(cal.normalize(500), 0.0, accuracy: 1e-9,
                       "raw=center → 0.0")
    }

    func test_normalize_midpoint_above_center() {
        // center=500, max=1000 → raw=750 → (750-500)/(1000-500) = 0.5
        let cal = AxisCalibration(min: 0, max: 1000, center: 500, deadband: 0)
        XCTAssertEqual(cal.normalize(750), 0.5, accuracy: 1e-9)
    }

    func test_normalize_midpoint_below_center() {
        // center=500, min=0 → raw=250 → (250-500)/(500-0) = -0.5
        let cal = AxisCalibration(min: 0, max: 1000, center: 500, deadband: 0)
        XCTAssertEqual(cal.normalize(250), -0.5, accuracy: 1e-9)
    }

    // MARK: - deadband

    func test_normalize_within_deadband_returns_zero() {
        // center=500, deadband=10 → raw in [490, 510] → 0
        let cal = AxisCalibration(min: 0, max: 1000, center: 500, deadband: 10)
        XCTAssertEqual(cal.normalize(505), 0.0, accuracy: 1e-9,
                       "deadband 내부 → 0")
        XCTAssertEqual(cal.normalize(495), 0.0, accuracy: 1e-9)
        XCTAssertEqual(cal.normalize(510), 0.0, accuracy: 1e-9,
                       "deadband 경계값 510 = center+deadband → 0")
    }

    func test_normalize_outside_deadband_nonzero() {
        let cal = AxisCalibration(min: 0, max: 1000, center: 500, deadband: 10)
        // raw=511 → deadband 초과 → 0 이 아님
        let out = cal.normalize(511)
        XCTAssertGreaterThan(out, 0.0, "deadband 직후 → 양수")
    }

    // MARK: - clamp

    func test_normalize_beyond_max_clamped_to_plus1() {
        let cal = AxisCalibration(min: 0, max: 1000, center: 500, deadband: 0)
        XCTAssertEqual(cal.normalize(1200), 1.0, accuracy: 1e-9,
                       "raw > max → clamp 1.0")
    }

    func test_normalize_beyond_min_clamped_to_minus1() {
        let cal = AxisCalibration(min: 0, max: 1000, center: 500, deadband: 0)
        XCTAssertEqual(cal.normalize(-200), -1.0, accuracy: 1e-9,
                       "raw < min → clamp -1.0")
    }

    // MARK: - 비대칭 하드웨어 보정

    func test_normalize_asymmetric_hardware() {
        // 저가 패드: center=512, min=100, max=900 (비대칭)
        let cal = AxisCalibration(min: 100, max: 900, center: 512, deadband: 0)
        // raw=900 → +1.0
        XCTAssertEqual(cal.normalize(900), 1.0, accuracy: 1e-9)
        // raw=100 → -1.0
        XCTAssertEqual(cal.normalize(100), -1.0, accuracy: 1e-9)
    }

    // MARK: - CalibrationCapture 누적

    func test_capture_initial_state() {
        let c = CalibrationCapture.initial
        XCTAssertTrue(c.recordedMin.isInfinite && c.recordedMin > 0,
                      "초기 recordedMin = +∞")
        XCTAssertTrue(c.recordedMax.isInfinite && c.recordedMax < 0,
                      "초기 recordedMax = -∞")
    }

    func test_capture_recording_updates_min_max() {
        var c = CalibrationCapture.initial
        c = c.recording(sample: 0.5)
        c = c.recording(sample: -0.8)
        c = c.recording(sample: 0.3)

        XCTAssertEqual(c.recordedMin, -0.8, accuracy: 1e-9, "가장 작은 샘플 -0.8")
        XCTAssertEqual(c.recordedMax,  0.5, accuracy: 1e-9, "가장 큰 샘플 0.5")
    }

    func test_capture_immutability() {
        let c0 = CalibrationCapture.initial
        let c1 = c0.recording(sample: 0.9)
        // c0 는 변경되지 않아야 함
        XCTAssertTrue(c0.recordedMin.isInfinite, "c0 는 mutation 없음")
        XCTAssertEqual(c1.recordedMax, 0.9, accuracy: 1e-9)
    }

    func test_capture_finished_produces_correct_calibration() {
        var c = CalibrationCapture.initial
        c = c.recording(sample: 50)
        c = c.recording(sample: 950)
        let cal = c.finished(center: 500, deadband: 5)

        XCTAssertEqual(cal.min,      50,  accuracy: 1e-9)
        XCTAssertEqual(cal.max,      950, accuracy: 1e-9)
        XCTAssertEqual(cal.center,   500, accuracy: 1e-9)
        XCTAssertEqual(cal.deadband, 5,   accuracy: 1e-9)
    }

    func test_capture_finished_without_samples_uses_fallback() {
        // 샘플 없이 완료 → min=-1, max=1 폴백
        let c = CalibrationCapture.initial
        let cal = c.finished(center: 0.0, deadband: 0.0)
        XCTAssertEqual(cal.min, -1.0, accuracy: 1e-9, "샘플 없음 → min=-1 폴백")
        XCTAssertEqual(cal.max,  1.0, accuracy: 1e-9, "샘플 없음 → max=+1 폴백")
    }
}
