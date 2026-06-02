import XCTest
@testable import DarwinForgeUI

/// Unit tests for the Mac virtual joystick mapper. These pin down the same
/// direction semantics as the iOS `WalkFreeformCommandTests` so the user
/// gets identical behaviour whether they grab the on-screen joystick on iPhone
/// or drag the Mac panel with the mouse.
///
/// # Convention under test
///
/// `VirtualJoystickMapper.map(x:y:turn:speedScale:)`
///   - `x = +1` → 우 측 → `sideMm > 0`
///   - `y = -1` → 위 (전진) → `strideMm > 0`
///   - `turn = +1` → 좌회전 → `turnDeg > 0` (matches `WalkLabPreset.turnLeft`)
///   - `speedScale` is clamped to [0.5, 1.5] and multiplies every axis once.
@MainActor
final class VirtualJoystickMapperTests: XCTestCase {

    // MARK: - Direction semantics

    func test_stick_up_maps_to_positive_stride_forward() {
        let cmd = VirtualJoystickMapper.map(x: 0, y: -1, turn: 0, speedScale: 1.0)
        XCTAssertEqual(cmd.strideMm, 25, accuracy: 0.001,
                       "stick up (y=-1) → forward (strideMm > 0)")
        XCTAssertEqual(cmd.sideMm, 0, accuracy: 0.001)
        XCTAssertEqual(cmd.turnDeg, 0, accuracy: 0.001)
    }

    func test_stick_down_maps_to_negative_stride_backward() {
        let cmd = VirtualJoystickMapper.map(x: 0, y: 1, turn: 0, speedScale: 1.0)
        XCTAssertEqual(cmd.strideMm, -25, accuracy: 0.001,
                       "stick down (y=+1) → backward (strideMm < 0)")
    }

    func test_stick_right_maps_to_positive_side() {
        let cmd = VirtualJoystickMapper.map(x: 1, y: 0, turn: 0, speedScale: 1.0)
        XCTAssertEqual(cmd.sideMm, 15, accuracy: 0.001,
                       "stick right (x=+1) → lateral right (sideMm > 0)")
        XCTAssertEqual(cmd.strideMm, 0, accuracy: 0.001)
    }

    func test_stick_left_maps_to_negative_side() {
        let cmd = VirtualJoystickMapper.map(x: -1, y: 0, turn: 0, speedScale: 1.0)
        XCTAssertEqual(cmd.sideMm, -15, accuracy: 0.001)
    }

    func test_turn_positive_maps_to_positive_turnDeg() {
        let cmd = VirtualJoystickMapper.map(x: 0, y: 0, turn: 1, speedScale: 1.0)
        XCTAssertEqual(cmd.turnDeg, 10, accuracy: 0.001,
                       "turn=+1 → +10° (matches WalkLabPreset.turnLeft sign)")
    }

    func test_turn_negative_maps_to_negative_turnDeg() {
        let cmd = VirtualJoystickMapper.map(x: 0, y: 0, turn: -1, speedScale: 1.0)
        XCTAssertEqual(cmd.turnDeg, -10, accuracy: 0.001)
    }

    // MARK: - Deadzone

    func test_under_deadzone_is_treated_as_centre() {
        let cmd = VirtualJoystickMapper.map(x: 0.03, y: -0.04, turn: 0.04, speedScale: 1.0)
        XCTAssertEqual(cmd.strideMm, 0)
        XCTAssertEqual(cmd.sideMm, 0)
        XCTAssertEqual(cmd.turnDeg, 0)
        XCTAssertTrue(cmd.isStop)
    }

    func test_just_past_deadzone_passes_through() {
        let cmd = VirtualJoystickMapper.map(x: 0.10, y: 0, turn: 0, speedScale: 1.0)
        XCTAssertEqual(cmd.sideMm, 1.5, accuracy: 0.001,
                       "0.10 stick × 15 mm = 1.5 mm — passes through")
        XCTAssertFalse(cmd.isStop)
    }

    // MARK: - speedScale

    func test_speedScale_multiplies_all_axes_once() {
        let cmd = VirtualJoystickMapper.map(x: 1, y: -1, turn: 1, speedScale: 1.5)
        XCTAssertEqual(cmd.strideMm, 37.5, accuracy: 0.001,
                       "1.5 × 25 = 37.5 mm forward stride")
        XCTAssertEqual(cmd.sideMm, 22.5, accuracy: 0.001,
                       "1.5 × 15 = 22.5 mm lateral")
        XCTAssertEqual(cmd.turnDeg, 15, accuracy: 0.001,
                       "1.5 × 10 = 15° turn")
    }

    func test_speedScale_clamps_above_15() {
        let cmd = VirtualJoystickMapper.map(x: 0, y: -1, turn: 0, speedScale: 5.0)
        XCTAssertEqual(cmd.strideMm, 37.5, accuracy: 0.001,
                       "speedScale clamped to 1.5 — 25 × 1.5 = 37.5, not 25 × 5")
    }

    func test_speedScale_clamps_below_05() {
        let cmd = VirtualJoystickMapper.map(x: 0, y: -1, turn: 0, speedScale: 0.1)
        XCTAssertEqual(cmd.strideMm, 12.5, accuracy: 0.001,
                       "speedScale clamped to 0.5 — 25 × 0.5 = 12.5")
    }

    // MARK: - Walking command safety range

    func test_mapper_clamps_into_walking_module_range() {
        // Even with absurd inputs, the result must stay within the safe
        // Walking-module amplitude bounds (-40..40 mm, -25..25 mm, -20..20 deg).
        let cmd = VirtualJoystickMapper.map(x: 100, y: -100, turn: 100, speedScale: 1.5)
        XCTAssertLessThanOrEqual(cmd.strideMm, 40)
        XCTAssertLessThanOrEqual(cmd.sideMm, 25)
        XCTAssertLessThanOrEqual(cmd.turnDeg, 20)
    }

    // MARK: - Diagonal combination

    func test_diagonal_forward_right_combines_correctly() {
        let cmd = VirtualJoystickMapper.map(x: 0.5, y: -0.5, turn: 0, speedScale: 1.0)
        XCTAssertEqual(cmd.strideMm, 12.5, accuracy: 0.001,
                       "0.5 × 25 = 12.5 mm forward")
        XCTAssertEqual(cmd.sideMm, 7.5, accuracy: 0.001,
                       "0.5 × 15 = 7.5 mm lateral")
        XCTAssertEqual(cmd.turnDeg, 0, accuracy: 0.001)
    }

    // MARK: - Consistency with iOS WalkFreeformCommandTests

    /// The user-facing motion is the same magnitude on both platforms when
    /// the user pushes the stick fully forward. The exact mm/deg numbers
    /// (25 mm forward, 15 mm lateral, 10 deg turn) mirror the iOS baseline.
    func test_max_amplitudes_match_iOS_freeform_baseline() {
        let full = VirtualJoystickMapper.map(x: 1, y: -1, turn: 1, speedScale: 1.0)
        XCTAssertEqual(full.strideMm, 25)
        XCTAssertEqual(full.sideMm, 15)
        XCTAssertEqual(full.turnDeg, 10)
    }
}
