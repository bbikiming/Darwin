import XCTest
@testable import DarwinForgeUI

/// `ControllerAxisTuning.shaped(_:)` 의 수학적 정확성 검증.
///
/// 검증 항목:
/// - 데드존 내부는 0
/// - 데드존 경계 직후 anti-deadzone 최소 출력 보장
/// - expo f(0)=0, f(1)=1 보존 + 중앙 둔감 + 단조증가
/// - invert 부호 반전
/// - 출력 [-1, 1] clamp
final class ControllerAxisTuningTests: XCTestCase {

    // MARK: - 데드존

    func test_innerDeadzone_exact_threshold_returns_zero() {
        // deadzone=0.10, raw=0.10 → m=0.10 < 0.10 은 false, 경계는 통과
        // raw=0.09 → m=0.09 < 0.10 → 0
        let tuning = ControllerAxisTuning(innerDeadzone: 0.10)
        XCTAssertEqual(tuning.shaped(0.09), 0.0, accuracy: 1e-9,
                       "데드존 내부(0.09 < 0.10) → 0")
    }

    func test_innerDeadzone_just_inside_returns_zero() {
        let tuning = ControllerAxisTuning(innerDeadzone: 0.10)
        XCTAssertEqual(tuning.shaped(0.05), 0.0, accuracy: 1e-9)
        XCTAssertEqual(tuning.shaped(-0.05), 0.0, accuracy: 1e-9)
        XCTAssertEqual(tuning.shaped(0.0), 0.0, accuracy: 1e-9)
    }

    func test_innerDeadzone_zero_passes_any_nonzero_input() {
        let tuning = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0, expo: 0.0, sensitivity: 1.0)
        // innerDeadzone=0, 아무 입력이든 통과 (감도 1.0, expo 0 → 선형)
        let out = tuning.shaped(0.5)
        XCTAssertGreaterThan(out, 0.0, "deadzone=0 이면 0.5 입력도 통과")
    }

    // MARK: - Anti-deadzone 최소 출력

    func test_antiDeadzone_provides_minimum_output_just_past_deadzone() {
        // innerDeadzone=0.10, antiDeadzone=0.20, expo=0, sensitivity=1.0
        // raw=0.10 → m=0.10 == innerDeadzone → guard 통과
        // t = (0.10 - 0.10) / (1.0 - 0.10) = 0
        // e = 0 → antiOut = 0 (e>0 일 때만 anti-deadzone 적용)
        // raw=0.101 → m=0.101 > 0.10, t 아주 작음, e 아주 작음 > 0
        // antiOut = 0.20 + (1-0.20)*e ≈ 0.20
        let tuning = ControllerAxisTuning(
            innerDeadzone: 0.10,
            antiDeadzone:  0.20,
            maxZone:       1.0,
            expo:          0.0,
            sensitivity:   1.0,
            invert:        false
        )
        let out = tuning.shaped(0.11)
        // 데드존 직후: antiOut ≈ antiDeadzone + (1-antiDeadzone)*작은값 > 0.20
        XCTAssertGreaterThanOrEqual(out, 0.20 - 1e-2,
                                    "데드존 직후 출력은 antiDeadzone(\(0.20)) 이상이어야 한다")
    }

    func test_antiDeadzone_zero_means_no_minimum_output() {
        let tuning = ControllerAxisTuning(
            innerDeadzone: 0.10,
            antiDeadzone:  0.0,
            expo:          0.0,
            sensitivity:   1.0
        )
        // raw=0.10 정확히 → guard 통과, t=(0.10-0.10)/(0.9)=0, e=0 → 0
        XCTAssertEqual(tuning.shaped(0.10), 0.0, accuracy: 1e-9,
                       "antiDeadzone=0, raw=deadzone → 0")
    }

    // MARK: - Expo 수학적 특성

    func test_expo_zero_is_linear() {
        let tuning = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0,
                                          maxZone: 1.0, expo: 0.0, sensitivity: 1.0)
        // expo=0: e=t (선형)
        XCTAssertEqual(tuning.shaped(0.0),  0.0, accuracy: 1e-9, "f(0)=0")
        XCTAssertEqual(tuning.shaped(0.5),  0.5, accuracy: 1e-9, "선형 0.5→0.5")
        XCTAssertEqual(tuning.shaped(1.0),  1.0, accuracy: 1e-9, "f(1)=1")
        XCTAssertEqual(tuning.shaped(-0.5), -0.5, accuracy: 1e-9, "음수 선형")
    }

    func test_expo_one_preserves_f0_and_f1() {
        let tuning = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0,
                                          maxZone: 1.0, expo: 1.0, sensitivity: 1.0)
        // expo=1: e = t^3, f(0)=0, f(1)=1
        XCTAssertEqual(tuning.shaped(0.0), 0.0, accuracy: 1e-9, "expo=1, f(0)=0")
        XCTAssertEqual(tuning.shaped(1.0), 1.0, accuracy: 1e-9, "expo=1, f(1)=1")
    }

    func test_expo_makes_center_less_sensitive_than_linear() {
        // expo=1 의 중앙(t=0.5) 출력 = 0.5^3 = 0.125
        // expo=0 의 중앙(t=0.5) 출력 = 0.5
        let linear = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0,
                                           expo: 0.0, sensitivity: 1.0)
        let cubic  = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0,
                                          expo: 1.0, sensitivity: 1.0)
        let midLinear = linear.shaped(0.5)
        let midCubic  = cubic.shaped(0.5)
        XCTAssertGreaterThan(midLinear, midCubic,
                             "expo=1 은 중앙에서 expo=0 보다 출력이 작아야 한다 (중앙 둔감)")
    }

    func test_expo_is_monotonically_increasing() {
        // expo=0.5 에서 입력 증가 시 출력도 증가하는지 확인
        let tuning = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0,
                                          expo: 0.5, sensitivity: 1.0)
        let steps: [Double] = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
        var prev = tuning.shaped(steps[0])
        for step in steps.dropFirst() {
            let curr = tuning.shaped(step)
            XCTAssertGreaterThanOrEqual(curr, prev - 1e-9,
                                        "expo=0.5 단조증가 위반: shaped(\(step))=\(curr) < \(prev)")
            prev = curr
        }
    }

    // MARK: - Invert

    func test_invert_false_positive_input_positive_output() {
        let tuning = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0,
                                          expo: 0.0, sensitivity: 1.0, invert: false)
        XCTAssertGreaterThan(tuning.shaped(0.5), 0.0)
    }

    func test_invert_true_flips_sign() {
        let normal   = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0,
                                            expo: 0.0, sensitivity: 1.0, invert: false)
        let inverted = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0,
                                            expo: 0.0, sensitivity: 1.0, invert: true)
        let raw = 0.7
        XCTAssertEqual(normal.shaped(raw), -inverted.shaped(raw), accuracy: 1e-9,
                       "invert=true 는 부호를 반전해야 한다")
    }

    func test_invert_on_negative_input() {
        let inverted = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0,
                                            expo: 0.0, sensitivity: 1.0, invert: true)
        // raw=-0.5, invert=true → 출력 양수
        XCTAssertGreaterThan(inverted.shaped(-0.5), 0.0)
    }

    // MARK: - 출력 범위 clamp [-1, 1]

    func test_output_is_clamped_to_minus1_plus1() {
        // sensitivity=3.0 으로도 1.0 초과 안 함
        let tuning = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0,
                                          expo: 0.0, sensitivity: 3.0)
        XCTAssertLessThanOrEqual(tuning.shaped(1.0), 1.0)
        XCTAssertGreaterThanOrEqual(tuning.shaped(-1.0), -1.0)
    }

    func test_raw_beyond_range_is_clamped_before_processing() {
        let tuning = ControllerAxisTuning(innerDeadzone: 0.0, antiDeadzone: 0.0,
                                          expo: 0.0, sensitivity: 1.0)
        // raw=5.0 → 먼저 [-1,1]로 clamp → 1.0 처리
        XCTAssertEqual(tuning.shaped(5.0),  1.0, accuracy: 1e-9)
        XCTAssertEqual(tuning.shaped(-5.0), -1.0, accuracy: 1e-9)
    }
}
