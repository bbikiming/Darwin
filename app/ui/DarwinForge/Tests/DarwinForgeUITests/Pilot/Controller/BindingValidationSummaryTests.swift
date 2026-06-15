import XCTest
@testable import DarwinForgeUI

/// `BindingValidationSummary` — 하단 검증 레일 상태 (설계 §D, 순수 함수).
final class BindingValidationSummaryTests: XCTestCase {

    func test_xbox_profile_is_valid() {
        let summary = BindingValidationSummary.from(.xbox)
        XCTAssertTrue(summary.isValid)
        XCTAssertEqual(summary.headline, "충돌 0 · 안전 OK")
        XCTAssertNil(summary.focusBinding)
    }

    func test_duplicate_input_names_binding_and_actions() {
        let profile = ControllerBindingProfile(
            name: "dup", deviceKey: "test",
            bindings: [
                .emergencyStop: .button(index: 1),
                .ballTracking:  .button(index: 1),
                .recover:       .button(index: 3),
            ])
        let summary = BindingValidationSummary.from(profile)
        XCTAssertFalse(summary.isValid)
        XCTAssertEqual(summary.headline, "중복: B — 볼 트래킹, 긴급 정지")
        XCTAssertEqual(summary.focusBinding, .button(index: 1))
    }

    func test_safety_unbound_with_overflow_count() {
        let summary = BindingValidationSummary.from(.empty)
        XCTAssertFalse(summary.isValid)
        XCTAssertEqual(summary.headline, "안전 미할당: 긴급 정지 외 1건")
        XCTAssertNil(summary.focusBinding)
    }
}
