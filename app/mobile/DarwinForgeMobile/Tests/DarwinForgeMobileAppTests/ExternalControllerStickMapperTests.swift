import XCTest
import MobilePilotKit
@testable import DarwinForgeMobileApp

/// Tests for the pure stick → WalkFreeformInput mapping.
///
/// `ExternalControllerStickMapper` is the one piece of the external-controller
/// path that the user can't see — there's no UI for it — so it needs explicit
/// unit coverage to prove that a real DJI RC / DualSense / Xbox stick produces
/// the same robot motion as the on-screen joystick.
@MainActor
final class ExternalControllerStickMapperTests: XCTestCase {

    private func snapshot(leftX: Float = 0, leftY: Float = 0,
                          rightX: Float = 0, rightY: Float = 0) -> ExternalControllerSnapshot {
        ExternalControllerSnapshot(
            controllerName: "Test",
            sticks: ExternalControllerStickState(
                leftX: leftX, leftY: leftY,
                rightX: rightX, rightY: rightY),
            buttons: .init())
    }

    // MARK: - Sign convention bridging

    /// GameController.framework reports `+1` when the stick is pushed up.
    /// The mapper inverts so the rest of the system sees DSJoystick convention
    /// (`y = -1` = up = forward).
    func test_gameController_up_translates_to_DSJoystick_forward() {
        let snap = snapshot(leftY: +1) // stick pushed up
        let input = ExternalControllerStickMapper.map(snap)
        XCTAssertEqual(input.y, -1, accuracy: 0.001,
                       "GameController +1 (up) must become DSJoystick -1 (forward)")
    }

    func test_gameController_down_translates_to_DSJoystick_backward() {
        let snap = snapshot(leftY: -1)
        let input = ExternalControllerStickMapper.map(snap)
        XCTAssertEqual(input.y, +1, accuracy: 0.001,
                       "GameController -1 (down) must become DSJoystick +1 (back)")
    }

    func test_left_stick_right_is_lateral_right() {
        let snap = snapshot(leftX: +1)
        let input = ExternalControllerStickMapper.map(snap)
        XCTAssertEqual(input.x, +1, accuracy: 0.001)
        XCTAssertEqual(input.y, 0,  accuracy: 0.001)
    }

    func test_right_stick_drives_turn() {
        let snap = snapshot(rightX: +1)
        let input = ExternalControllerStickMapper.map(snap)
        XCTAssertEqual(input.turn, +1, accuracy: 0.001)
    }

    // MARK: - Deadzone

    func test_under_deadzone_is_treated_as_centre() {
        let snap = snapshot(leftX: 0.04, leftY: -0.03, rightX: 0.02)
        let input = ExternalControllerStickMapper.map(snap)
        XCTAssertEqual(input.x, 0)
        XCTAssertEqual(input.y, 0)
        XCTAssertEqual(input.turn, 0)
        XCTAssertFalse(input.isMoving)
    }

    func test_just_past_deadzone_passes_through() {
        let snap = snapshot(leftX: 0.10)
        let input = ExternalControllerStickMapper.map(snap)
        XCTAssertEqual(input.x, 0.10, accuracy: 0.001)
        XCTAssertTrue(input.isMoving)
    }

    // MARK: - speedScale carry-through

    func test_speedScale_flows_through_unchanged() {
        let snap = snapshot(leftY: +1)
        let input = ExternalControllerStickMapper.map(snap, speedScale: 1.3)
        XCTAssertEqual(input.speedScale, 1.3)
    }

    // MARK: - End-to-end through CommandBuilder

    /// Prove that a physical "stick up" — the most common motion — produces a
    /// forward stride on the wire, identical to the on-screen joystick path.
    func test_full_pipeline_physical_up_drives_forward_stride() {
        let snap = snapshot(leftY: +1) // GameController: stick up
        let input = ExternalControllerStickMapper.map(snap)
        let builder = CommandBuilder(ids: MonotonicCommandIDGenerator(prefix: "t"),
                                     clock: LiveClock())
        let env = builder.walkFreeform(input)
        XCTAssertEqual(env.payload.xMm, 25, "forward stride after full pipeline")
        XCTAssertTrue(env.payload.enabled)
    }
}
