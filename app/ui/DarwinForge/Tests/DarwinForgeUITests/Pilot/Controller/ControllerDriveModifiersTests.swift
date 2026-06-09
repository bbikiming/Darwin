import XCTest
@testable import DarwinForgeUI

/// `ControllerDriveModifiers` 순수 로직 검증 — 데드맨 게이트 + 터보 스케일.
final class ControllerDriveModifiersTests: XCTestCase {

    private func snapshot(buttons pressed: [Int]) -> ControllerSnapshot {
        var b = Array(repeating: false, count: ControllerSnapshot.standardButtonCount)
        for i in pressed { b[i] = true }
        return ControllerSnapshot(
            axes: Array(repeating: 0.0, count: ControllerSnapshot.standardAxisCount),
            buttons: b
        )
    }

    // MARK: - deadmanSatisfied

    func test_deadman_disabled_always_satisfied() {
        var p = ControllerBindingProfile.xbox
        p.deadmanEnabled = false
        XCTAssertTrue(ControllerDriveModifiers.deadmanSatisfied(
            profile: p, snapshot: snapshot(buttons: [])))
    }

    func test_deadman_enabled_without_index_satisfied() {
        // 버튼이 지정되지 않으면 게이트 불가 — 주행을 막지 않는다.
        var p = ControllerBindingProfile.xbox
        p.deadmanEnabled = true
        p.deadmanButtonIndex = nil
        XCTAssertTrue(ControllerDriveModifiers.deadmanSatisfied(
            profile: p, snapshot: snapshot(buttons: [])))
    }

    func test_deadman_enabled_held_satisfied() {
        let p = ControllerBindingProfile.xbox // deadmanButtonIndex = 4
        XCTAssertTrue(ControllerDriveModifiers.deadmanSatisfied(
            profile: p, snapshot: snapshot(buttons: [4])))
    }

    func test_deadman_enabled_not_held_not_satisfied() {
        let p = ControllerBindingProfile.xbox
        XCTAssertFalse(ControllerDriveModifiers.deadmanSatisfied(
            profile: p, snapshot: snapshot(buttons: [])))
    }

    // MARK: - isTurboHeld

    func test_turbo_nil_index_never_held() {
        var p = ControllerBindingProfile.xbox
        p.turboButtonIndex = nil
        XCTAssertFalse(ControllerDriveModifiers.isTurboHeld(
            profile: p, snapshot: snapshot(buttons: [5])))
    }

    func test_turbo_held_when_button_pressed() {
        let p = ControllerBindingProfile.xbox // turboButtonIndex = 5
        XCTAssertTrue(ControllerDriveModifiers.isTurboHeld(
            profile: p, snapshot: snapshot(buttons: [5])))
        XCTAssertFalse(ControllerDriveModifiers.isTurboHeld(
            profile: p, snapshot: snapshot(buttons: [])))
    }

    // MARK: - modifiedDrive

    func test_drive_zeroed_when_deadman_not_satisfied() {
        let out = ControllerDriveModifiers.modifiedDrive(
            leftX: 0.5, leftY: -0.8, turn: 0.3,
            deadmanSatisfied: false, turboHeld: true)
        XCTAssertEqual(out.leftX, 0.0)
        XCTAssertEqual(out.leftY, 0.0)
        XCTAssertEqual(out.turn, 0.0)
    }

    func test_drive_passthrough_without_turbo() {
        let out = ControllerDriveModifiers.modifiedDrive(
            leftX: 0.5, leftY: -0.8, turn: 0.3,
            deadmanSatisfied: true, turboHeld: false)
        XCTAssertEqual(out.leftX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(out.leftY, -0.8, accuracy: 1e-9)
        XCTAssertEqual(out.turn, 0.3, accuracy: 1e-9)
    }

    func test_drive_turbo_scales_and_clamps() {
        let out = ControllerDriveModifiers.modifiedDrive(
            leftX: 0.5, leftY: -0.8, turn: 1.0,
            deadmanSatisfied: true, turboHeld: true)
        XCTAssertEqual(out.leftX, 0.5 * ControllerDriveModifiers.turboScale, accuracy: 1e-9)
        // −0.8 × 1.3 = −1.04 → −1.0 클램프
        XCTAssertEqual(out.leftY, -1.0, accuracy: 1e-9)
        XCTAssertEqual(out.turn, 1.0, accuracy: 1e-9)
    }
}
