import XCTest
@testable import DarwinForgeUI

/// `ControllerBindingProfile` 불변성·안전 보호·충돌 감지·Codable 검증.
final class ControllerBindingProfileTests: XCTestCase {

    // MARK: - setting(_:for:) 기본 적용

    func test_setting_applies_binding_to_action() {
        let profile = ControllerBindingProfile.empty
        let binding: ControllerBinding = .button(index: 0)
        // emergencyStop 은 안전 액션이므로 button 바인딩 허용 (unbound 만 거부)
        let (updated, result) = profile.setting(binding, for: .emergencyStop)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(updated.bindings[.emergencyStop], binding)
    }

    func test_setting_non_safety_action_applied() {
        let profile = ControllerBindingProfile.empty
        let (updated, result) = profile.setting(.button(index: 2), for: .moveForward)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(updated.bindings[.moveForward], .button(index: 2))
    }

    // MARK: - 1:1 swap invariant

    func test_setting_same_binding_swaps_previous_action() {
        let binding: ControllerBinding = .button(index: 0)
        // xbox 프리셋에서 button(1)=emergencyStop, button(2)=ballTracking
        // button(2) 를 moveForward 에 설정하면 ballTracking → unbound
        let (updated, result) = ControllerBindingProfile.xbox
            .setting(.button(index: 2), for: .moveForward)

        switch result {
        case .appliedWithSwap(let swapped):
            XCTAssertTrue(swapped.contains(.ballTracking),
                          "button(2) 가 ballTracking 에서 이동됐으므로 swap 목록에 포함")
        case .applied:
            // button(2) 가 이미 비어 있을 경우도 허용 (xbox 프리셋이 이미 ballTracking 에 할당)
            break
        default:
            XCTFail("예상치 않은 결과: \(result)")
        }
        XCTAssertNotEqual(updated.bindings[.ballTracking], .button(index: 2),
                          "swap 후 ballTracking 은 button(2) 를 잃어야 한다")
    }

    // MARK: - 안전 액션 unbound 거부

    func test_setting_safety_action_to_unbound_is_rejected() {
        let (updated, result) = ControllerBindingProfile.xbox
            .setting(.unbound, for: .emergencyStop)

        XCTAssertEqual(result, .rejectedSafetyUnbound(.emergencyStop))
        // 프로파일은 변경 없이 원본 그대로
        XCTAssertEqual(updated.bindings[.emergencyStop],
                       ControllerBindingProfile.xbox.bindings[.emergencyStop])
    }

    func test_setting_recover_to_unbound_is_rejected() {
        let (_, result) = ControllerBindingProfile.xbox
            .setting(.unbound, for: .recover)
        XCTAssertEqual(result, .rejectedSafetyUnbound(.recover))
    }

    // MARK: - 안전 액션 강탈 거부

    func test_stealing_safety_action_binding_is_rejected() {
        // xbox 에서 emergencyStop = button(1)
        // button(1) 을 moveForward 에 설정하면 → emergencyStop 강탈 시도 → 거부
        let (updated, result) = ControllerBindingProfile.xbox
            .setting(.button(index: 1), for: .moveForward)

        switch result {
        case .rejectedSafetyStolen(let action):
            XCTAssertEqual(action, .emergencyStop)
        default:
            XCTFail("안전 액션 강탈은 rejectedSafetyStolen 이어야 함, 실제: \(result)")
        }
        // 프로파일 불변
        XCTAssertEqual(updated.bindings[.emergencyStop], .button(index: 1))
    }

    // MARK: - xbox 프리셋 완전성

    func test_xbox_preset_binds_all_movement_actions() {
        let profile = ControllerBindingProfile.xbox
        let movementActions: [CockpitAction] = [
            .moveForward, .moveBackward, .strafeLeft, .strafeRight,
            .turnLeft, .turnRight
        ]
        for action in movementActions {
            let bound = profile.bindings[action]
            XCTAssertNotNil(bound, "\(action) 가 바인딩 돼 있어야 한다")
            XCTAssertFalse(bound!.isUnbound, "\(action) 는 unbound 면 안 된다")
        }
    }

    func test_xbox_preset_binds_safety_actions() {
        let profile = ControllerBindingProfile.xbox
        let safetyActions: [CockpitAction] = [.emergencyStop, .recover]
        for action in safetyActions {
            let bound = profile.bindings[action]
            XCTAssertNotNil(bound)
            XCTAssertFalse(bound!.isUnbound, "안전 액션 \(action) 은 unbound 면 안 된다")
        }
    }

    func test_xbox_preset_deadman_enabled_by_default() {
        XCTAssertTrue(ControllerBindingProfile.xbox.deadmanEnabled,
                      "데드맨은 기본 ON — PRD §13 결정")
    }

    func test_xbox_preset_failsafe_is_freeze() {
        XCTAssertEqual(ControllerBindingProfile.xbox.failsafe, .freeze,
                       "failsafe 기본 .freeze — PRD §13 결정")
    }

    // MARK: - conflicts() 감지

    func test_conflicts_detects_duplicate_input() {
        // moveForward 와 moveBackward 를 같은 button 에 설정 → 중복 충돌
        var profile = ControllerBindingProfile.empty
        // 안전 액션은 unbound 불가이므로 먼저 button 바인딩 부여
        (profile, _) = profile.setting(.button(index: 0), for: .emergencyStop)
        (profile, _) = profile.setting(.button(index: 1), for: .recover)
        (profile, _) = profile.setting(.button(index: 2), for: .moveForward)
        // moveBackward 에도 button(2) 설정 → 중복 (swap 에 의해 moveForward 가 unbound 됨)
        var bindings2 = profile.bindings
        bindings2[.moveBackward] = .button(index: 2)
        bindings2[.moveForward]  = .button(index: 2)   // 강제 중복
        let dupProfile = ControllerBindingProfile(
            name: "dup", deviceKey: "test", bindings: bindings2
        )
        let conflicts = dupProfile.conflicts()
        let hasDup = conflicts.contains { c in
            if case .duplicateInput(let b, _) = c { return b == .button(index: 2) }
            return false
        }
        XCTAssertTrue(hasDup, "동일 button(2) 중복 할당 → duplicateInput 충돌이어야 함")
    }

    func test_conflicts_detects_safety_critical_unbound() {
        // empty 프로파일은 안전 액션 모두 unbound
        let profile = ControllerBindingProfile.empty
        let conflicts = profile.conflicts()
        let hasEmergencyUnbound = conflicts.contains { c in
            if case .safetyCriticalUnbound(let a) = c { return a == .emergencyStop }
            return false
        }
        XCTAssertTrue(hasEmergencyUnbound, "empty 프로파일의 emergencyStop unbound 는 충돌이어야 함")
    }

    func test_xbox_preset_has_no_conflicts() {
        let conflicts = ControllerBindingProfile.xbox.conflicts()
        XCTAssertTrue(conflicts.isEmpty, "xbox 프리셋은 충돌 없어야 함, 실제: \(conflicts)")
    }

    // MARK: - Codable round-trip

    func test_codable_round_trip_equality() {
        let original = ControllerBindingProfile.xbox
        guard let data = try? JSONEncoder().encode(original),
              let decoded = try? JSONDecoder().decode(ControllerBindingProfile.self, from: data) else {
            XCTFail("Codable 인코딩/디코딩 실패")
            return
        }
        XCTAssertEqual(original, decoded, "JSON round-trip 후 동등해야 한다")
    }

    func test_codable_round_trip_empty_profile() {
        let original = ControllerBindingProfile.empty
        guard let data = try? JSONEncoder().encode(original),
              let decoded = try? JSONDecoder().decode(ControllerBindingProfile.self, from: data) else {
            XCTFail("empty 프로파일 Codable 실패")
            return
        }
        XCTAssertEqual(original, decoded)
    }

    // MARK: - actions(boundTo:)

    func test_actions_bound_to_returns_correct_action() {
        let profile = ControllerBindingProfile.xbox
        let actions = profile.actions(boundTo: .button(index: 1))
        XCTAssertTrue(actions.contains(.emergencyStop),
                      "button(1) 은 emergencyStop 에 할당돼 있어야 함")
    }

    func test_actions_bound_to_unbound_is_empty() {
        let profile = ControllerBindingProfile.empty
        let actions = profile.actions(boundTo: .button(index: 99))
        XCTAssertTrue(actions.isEmpty)
    }
}
