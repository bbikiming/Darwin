import XCTest
@testable import DarwinForgeUI

/// `BindingChangeFeedback` — 바인딩 변경 토스트 문구 + undo 가능 여부 (순수 함수).
final class BindingChangeFeedbackTests: XCTestCase {

    func test_applied_message_uses_human_label() {
        let msg = BindingChangeFeedback.message(
            action: .emergencyStop, binding: .button(index: 1), result: .applied)
        XCTAssertEqual(msg, "B ← 긴급 정지")
    }

    func test_swap_message_names_displaced_action() {
        let msg = BindingChangeFeedback.message(
            action: .emergencyStop, binding: .button(index: 2),
            result: .appliedWithSwap([.ballTracking]))
        XCTAssertEqual(msg, "X ← 긴급 정지 (볼 트래킹은 미설정됨)")
    }

    func test_unbind_message() {
        let msg = BindingChangeFeedback.message(
            action: .moveForward, binding: .unbound, result: .applied)
        XCTAssertEqual(msg, "‘전진’ 매핑 해제됨")
    }

    func test_rejected_safety_unbound_message() {
        let msg = BindingChangeFeedback.message(
            action: .emergencyStop, binding: .unbound,
            result: .rejectedSafetyUnbound(.emergencyStop))
        XCTAssertTrue(msg.contains("긴급 정지"))
        XCTAssertTrue(msg.contains("해제할 수 없"))
    }

    func test_rejected_safety_stolen_message() {
        let msg = BindingChangeFeedback.message(
            action: .ballTracking, binding: .button(index: 1),
            result: .rejectedSafetyStolen(.emergencyStop))
        XCTAssertTrue(msg.contains("긴급 정지"))
        XCTAssertTrue(msg.contains("가져올 수 없"))
    }

    func test_undoable_only_for_applied_results() {
        XCTAssertTrue(BindingChangeFeedback.isUndoable(.applied))
        XCTAssertTrue(BindingChangeFeedback.isUndoable(.appliedWithSwap([.recover])))
        XCTAssertFalse(BindingChangeFeedback.isUndoable(.rejectedSafetyUnbound(.recover)))
        XCTAssertFalse(BindingChangeFeedback.isUndoable(.rejectedSafetyStolen(.recover)))
    }
}
