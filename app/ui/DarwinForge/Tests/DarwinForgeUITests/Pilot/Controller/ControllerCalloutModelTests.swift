import XCTest
@testable import DarwinForgeUI

/// `ControllerCalloutModel` — 다이어그램 콜아웃 라벨 데이터 (reWASD 패턴, 순수 함수).
final class ControllerCalloutModelTests: XCTestCase {

    // MARK: - 컬럼 구성 (xbox 프리셋)

    func test_xbox_left_column_order() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        XCTAssertEqual(columns.left.map(\.id), ["LT", "LB", "LS", "DPAD"])
    }

    func test_xbox_right_column_order() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        XCTAssertEqual(columns.right.map(\.id), ["RT", "RB", "Y", "X", "B", "A", "RS"])
    }

    // MARK: - 개별 컨트롤 라벨/카테고리

    func test_trigger_shows_bound_action() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        let lt = columns.left.first { $0.id == "LT" }!
        XCTAssertEqual(lt.actionLabel, "머리 좌")
        XCTAssertEqual(lt.category, .head)
        XCTAssertFalse(lt.locked)
    }

    func test_safety_button_is_locked() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        let b = columns.right.first { $0.id == "B" }!
        XCTAssertEqual(b.actionLabel, "긴급 정지")
        XCTAssertEqual(b.category, .safety)
        XCTAssertTrue(b.locked)
    }

    func test_unbound_button_shows_unset() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        let a = columns.right.first { $0.id == "A" }!
        XCTAssertEqual(a.actionLabel, "미설정")
        XCTAssertEqual(a.category, .unbound)
        XCTAssertFalse(a.locked)
    }

    func test_deadman_and_turbo_assist_labels() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        let lb = columns.left.first { $0.id == "LB" }!
        let rb = columns.right.first { $0.id == "RB" }!
        XCTAssertEqual(lb.actionLabel, "데드맨 홀드")
        XCTAssertEqual(lb.category, .assist)
        XCTAssertEqual(rb.actionLabel, "터보")
        XCTAssertEqual(rb.category, .assist)
    }

    func test_bound_action_wins_over_assist_label() {
        let (profile, _) = ControllerBindingProfile.xbox
            .setting(.button(index: 4), for: .ballTracking)
        let columns = ControllerCalloutModel.columns(for: profile)
        let lb = columns.left.first { $0.id == "LB" }!
        XCTAssertEqual(lb.actionLabel, "볼 트래킹")
        XCTAssertEqual(lb.category, .head)
    }

    // MARK: - 집계 컨트롤 (스틱/D패드)

    func test_left_stick_aggregates_single_group() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        let ls = columns.left.first { $0.id == "LS" }!
        XCTAssertEqual(ls.actionLabel, "이동")
        XCTAssertEqual(ls.category, .movement)
    }

    func test_right_stick_aggregates_multiple_groups() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        let rs = columns.right.first { $0.id == "RS" }!
        XCTAssertEqual(rs.actionLabel, "회전·머리")
        XCTAssertEqual(rs.category, .movement)
    }

    func test_dpad_unbound_in_xbox() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        let dpad = columns.left.first { $0.id == "DPAD" }!
        XCTAssertEqual(dpad.actionLabel, "미설정")
        XCTAssertEqual(dpad.category, .unbound)
    }

    func test_stick_selection_binding_prefers_bound_sub_binding() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        let ls = columns.left.first { $0.id == "LS" }!
        XCTAssertFalse(ControllerBindingProfile.xbox.actions(boundTo: ls.selectionBinding).isEmpty)
    }

    // MARK: - 조건부 컨트롤 (센터 버튼)

    func test_center_buttons_hidden_when_unbound() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        XCTAssertFalse(columns.left.contains { $0.id == "VIEW" })
        XCTAssertFalse(columns.right.contains { $0.id == "MENU" })
    }

    func test_center_button_appears_when_bound() {
        let (profile, _) = ControllerBindingProfile.xbox
            .setting(.button(index: 6), for: .ballTracking)
        let columns = ControllerCalloutModel.columns(for: profile)
        let view = columns.left.first { $0.id == "VIEW" }
        XCTAssertEqual(view?.actionLabel, "볼 트래킹")
    }

    // MARK: - empty 프로파일

    func test_empty_profile_safety_not_locked() {
        let columns = ControllerCalloutModel.columns(for: .empty)
        let b = columns.right.first { $0.id == "B" }!
        XCTAssertEqual(b.actionLabel, "미설정")
        XCTAssertFalse(b.locked)
    }

    // MARK: - Activator 글리프

    func test_toggle_activator_glyph() {
        var profile = ControllerBindingProfile.xbox
        profile.activators[.ballTracking] = .toggle
        let columns = ControllerCalloutModel.columns(for: profile)
        let x = columns.right.first { $0.id == "X" }!
        XCTAssertEqual(x.modeGlyph, "⇄")
    }

    func test_hold_activator_has_no_glyph() {
        let columns = ControllerCalloutModel.columns(for: .xbox)
        let x = columns.right.first { $0.id == "X" }!
        XCTAssertNil(x.modeGlyph)
    }

    // MARK: - rgg01Label (사람 친화 입력명)

    func test_rgg01_labels_for_buttons() {
        XCTAssertEqual(ControllerBinding.button(index: 1).rgg01Label, "B")
        XCTAssertEqual(ControllerBinding.button(index: 4).rgg01Label, "LB")
        XCTAssertEqual(ControllerBinding.button(index: 10).rgg01Label, "D패드 ↑")
    }

    func test_rgg01_labels_for_axes() {
        XCTAssertEqual(ControllerBinding.axis(index: 1, polarity: .negative).rgg01Label, "L스틱 ↑")
        XCTAssertEqual(ControllerBinding.axis(index: 2, polarity: .positive).rgg01Label, "R스틱 →")
        XCTAssertEqual(ControllerBinding.axis(index: 4, polarity: .positive).rgg01Label, "LT")
    }

    func test_rgg01_label_fallback() {
        XCTAssertEqual(ControllerBinding.unbound.rgg01Label, "—")
        XCTAssertEqual(ControllerBinding.button(index: 99).rgg01Label, "Button 99")
    }
}
