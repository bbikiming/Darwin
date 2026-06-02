import XCTest
@testable import DarwinForgeUI

/// Binding profile + capture + mapper(profile) 의 round-trip 검증.
///
/// 매핑 sheet 의 모든 사용자 시나리오가 일관 동작함을 보장:
///   - Profile JSON encode/decode round-trip
///   - Default profile (DJI Mode 2) 의 정확한 stick → cockpit 매핑
///   - Conflict detection (1:1 binding invariant)
///   - Listen-mode capture 의 가장 큰 axis / button 우선순위
final class CockpitDJIBindingTests: XCTestCase {

    // MARK: - Profile model

    func test_djiMode2_default_has_all_actions_bound() {
        let p = DJIBindingProfile.djiMode2
        for action in CockpitAction.allCases {
            let binding = p.bindings[action]
            XCTAssertNotNil(binding, "\(action.label) 가 default profile 에 미정의")
            XCTAssertFalse(binding?.isUnbound ?? true,
                           "\(action.label) 가 unbound 면 DJI Mode 2 default 결함")
        }
    }

    func test_empty_profile_has_all_unbound() {
        let p = DJIBindingProfile.empty
        for action in CockpitAction.allCases {
            XCTAssertEqual(p.bindings[action], .unbound)
        }
    }

    func test_json_roundtrip_preserves_bindings() throws {
        let p = DJIBindingProfile.djiMode2
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(DJIBindingProfile.self, from: data)
        XCTAssertEqual(decoded, p)
    }

    func test_setBinding_swaps_existing_action_to_unbound() {
        var p = DJIBindingProfile.djiMode2
        // Mode 2: moveForward = .axis(.ry, +)
        // 새 action (turnLeft) 에 동일 binding 적용 — 기존 moveForward 는 unbound.
        p.setBinding(.axis(.ry, polarity: .positive), for: .turnLeft)
        XCTAssertEqual(p.bindings[.turnLeft], .axis(.ry, polarity: .positive))
        XCTAssertEqual(p.bindings[.moveForward], .unbound,
                       "single-binding invariant 미준수")
    }

    func test_setBinding_unbound_does_not_clear_others() {
        var p = DJIBindingProfile.djiMode2
        p.setBinding(.unbound, for: .moveForward)
        XCTAssertEqual(p.bindings[.moveForward], .unbound)
        XCTAssertEqual(p.bindings[.moveBackward],
                       .axis(.ry, polarity: .negative),
                       "다른 action 의 binding 이 unbound 적용으로 영향받으면 안 됨")
    }

    // MARK: - Mapper with profile

    private func report(axisX: Double = 0, axisY: Double = 0, axisZ: Double = 0,
                        axisRx: Double = 0, axisRy: Double = 0,
                        buttons: [Bool] = Array(repeating: false, count: 24)) -> DJIVirtualJoystickReport {
        DJIVirtualJoystickReport(axisX: axisX, axisY: axisY, axisZ: axisZ,
                                 axisRx: axisRx, axisRy: axisRy,
                                 buttons: buttons)
    }

    func test_profile_mapping_default_forward() {
        // DJI Mode 2: Ry +1 = forward
        let r = report(axisRy: 1.0)
        let s = DJIVirtualJoystickMapper.map(r, profile: .djiMode2)
        // DSJoystick: forward = leftY -1.
        XCTAssertEqual(s.leftY, -1.0, accuracy: 0.001)
        XCTAssertEqual(s.leftX, 0, accuracy: 0.001)
        XCTAssertEqual(s.turn, 0, accuracy: 0.001)
    }

    func test_profile_mapping_default_strafe_right() {
        let r = report(axisRx: 1.0)
        let s = DJIVirtualJoystickMapper.map(r, profile: .djiMode2)
        XCTAssertEqual(s.leftX, 1.0, accuracy: 0.001)
    }

    func test_profile_mapping_default_turn_left() {
        let r = report(axisX: -1.0)  // Mode 2: X- = turnLeft
        let s = DJIVirtualJoystickMapper.map(r, profile: .djiMode2)
        // turn convention: leftTurn = +turn.
        XCTAssertEqual(s.turn, 1.0, accuracy: 0.001)
    }

    func test_profile_mapping_button_emergency() {
        var buttons = Array(repeating: false, count: 24)
        buttons[0] = true
        let r = report(buttons: buttons)
        let actions = DJIVirtualJoystickMapper.buttonActions(report: r,
                                                              profile: .djiMode2)
        XCTAssertTrue(actions.emergencyStop)
        XCTAssertFalse(actions.recover)
    }

    func test_profile_mapping_under_deadzone_is_zero() {
        let r = report(axisRy: 0.03)  // deadzone 0.10 미만
        let s = DJIVirtualJoystickMapper.map(r, profile: .djiMode2)
        XCTAssertEqual(s.leftY, 0, accuracy: 0.001)
    }

    // MARK: - Capture

    func test_capture_button_takes_priority_over_axis() {
        var buttons = Array(repeating: false, count: 24)
        buttons[5] = true
        let r = report(axisRy: 0.9, buttons: buttons)  // axis 도 active
        let binding = DJIBindingCapture.detect(r)
        XCTAssertEqual(binding, .button(5))
    }

    func test_capture_returns_largest_axis() {
        let r = report(axisX: 0.4, axisRx: 0.9, axisRy: 0.6)
        let binding = DJIBindingCapture.detect(r)
        XCTAssertEqual(binding, .axis(.rx, polarity: .positive))
    }

    func test_capture_respects_listen_deadzone() {
        let r = report(axisRy: 0.10)  // listen deadzone 0.30 미만
        XCTAssertNil(DJIBindingCapture.detect(r))
    }

    func test_capture_polarity_negative() {
        let r = report(axisRy: -0.85)
        XCTAssertEqual(DJIBindingCapture.detect(r),
                       .axis(.ry, polarity: .negative))
    }

    // MARK: - Persistence

    func test_persistence_roundtrip_via_userdefaults() throws {
        let defaults = UserDefaults(suiteName: "test.cockpit.dji.bindings")!
        defaults.removePersistentDomain(forName: "test.cockpit.dji.bindings")
        var p = DJIBindingProfile.djiMode2
        p.name = "사용자 테스트"
        p.setBinding(.button(5), for: .recover)
        DJIBindingProfileStore.save(p, into: defaults)
        let loaded = DJIBindingProfileStore.load(defaults)
        XCTAssertEqual(loaded.name, "사용자 테스트")
        XCTAssertEqual(loaded.bindings[.recover], .button(5))
    }

    // MARK: - Truth-gap fixes (TG-3/TG-4)

    func test_setBinding_returns_swapped_actions_for_user_notice() {
        var p = DJIBindingProfile.djiMode2
        // Mode 2: moveForward = .axis(.ry, +). 이제 turnLeft 에 같은 binding 적용.
        let result = p.setBinding(.axis(.ry, polarity: .positive), for: .turnLeft)
        XCTAssertEqual(result, .appliedWithSwap([.moveForward]),
                       "TG-3: setBinding 가 swap 발생 시 unbound 된 action 보고해야 함")
        XCTAssertEqual(p.bindings[.moveForward], .unbound)
    }

    func test_setBinding_returns_applied_when_no_swap() {
        var p = DJIBindingProfile.empty
        let result = p.setBinding(.axis(.ry, polarity: .positive), for: .moveForward)
        XCTAssertEqual(result, .applied)
    }

    func test_safety_action_cannot_be_unbound() {
        var p = DJIBindingProfile.djiMode2
        let originalEstop = p.bindings[.emergencyStop]
        // TG-4: 안전 action 의 unbound 시도는 거부.
        let result = p.setBinding(.unbound, for: .emergencyStop)
        XCTAssertEqual(result, .rejectedSafetyUnbound(.emergencyStop))
        XCTAssertEqual(p.bindings[.emergencyStop], originalEstop,
                       "TG-4: 안전 action 의 binding 은 변경되지 않아야 함")
    }

    func test_safety_action_can_be_remapped_to_different_button() {
        var p = DJIBindingProfile.djiMode2
        // 다른 button 으로 변경은 허용 (unbound 만 차단).
        let result = p.setBinding(.button(5), for: .emergencyStop)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(p.bindings[.emergencyStop], .button(5))
    }

    func test_other_action_cannot_steal_safety_binding() {
        var p = DJIBindingProfile.djiMode2
        // 사용자가 moveForward 에 button 0 (= 현재 emergency) 매핑 시도.
        // emergencyStop 이 unbound 되면 안 되므로 swap 거부.
        let result = p.setBinding(.button(0), for: .moveForward)
        XCTAssertEqual(result, .rejectedSafetyStolen(.emergencyStop),
                       "안전 action 의 binding 을 빼앗는 시도는 거부 사유 보고")
        XCTAssertEqual(p.bindings[.emergencyStop], .button(0),
                       "safety action 의 binding 보존")
    }

    func test_isSafetyCritical_only_true_for_estop_and_recover() {
        XCTAssertTrue(CockpitAction.emergencyStop.isSafetyCritical)
        XCTAssertTrue(CockpitAction.recover.isSafetyCritical)
        for a in [CockpitAction.moveForward, .moveBackward, .strafeLeft,
                  .strafeRight, .turnLeft, .turnRight] {
            XCTAssertFalse(a.isSafetyCritical)
        }
    }

    func test_load_returns_default_when_no_saved_profile() {
        let defaults = UserDefaults(suiteName: "test.cockpit.dji.bindings.empty")!
        defaults.removePersistentDomain(forName: "test.cockpit.dji.bindings.empty")
        let loaded = DJIBindingProfileStore.load(defaults)
        XCTAssertEqual(loaded, .djiMode2)
    }
}
