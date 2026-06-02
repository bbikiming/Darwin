import XCTest
@testable import MobilePilotKit

/// Unit tests that pin down the freeform walk command semantics so a regression
/// in either the joystick UI or the command builder is caught at compile of CI
/// rather than during a real-robot demo.
///
/// # Convention under test
///
/// `WalkFreeformInput`:
///   - `x ∈ [-1, +1]` — +1 = stick right
///   - `y ∈ [-1, +1]` — -1 = stick up = forward (DSJoystick convention)
///   - `turn ∈ [-1, +1]` — caller-defined sign (see CommandBuilder for how it
///     maps onto WalkPayload.aDeg)
///   - `speedScale` — multiplier, sent on the payload (Mac clamps to 0.5~1.5)
///
/// `WalkPayload` (freeform):
///   - `xMm` = forward stride per step (positive = forward, negative = back)
///   - `yMm` = lateral side step (positive = right, negative = left)
///   - `aDeg` = turn per step (sign matches `input.turn * 10`)
///   - `speedScale` = forwarded payload field
final class WalkFreeformCommandTests: XCTestCase {

    private func builder() -> CommandBuilder {
        CommandBuilder(ids: MonotonicCommandIDGenerator(prefix: "test"),
                       clock: LiveClock())
    }

    // MARK: - Forward / backward

    func test_joystick_up_maps_to_forward_stride() {
        let input = WalkFreeformInput(x: 0, y: -1, turn: 0, speedScale: 1.0)
        let env = builder().walkFreeform(input)
        XCTAssertEqual(env.type, "pilot.walk")
        XCTAssertEqual(env.payload.preset, .freeform)
        XCTAssertEqual(env.payload.xMm, 25, "joystick up (y=-1) must drive forward stride > 0")
        XCTAssertEqual(env.payload.yMm, 0)
        XCTAssertEqual(env.payload.aDeg, 0)
        XCTAssertTrue(env.payload.enabled, "non-centred stick must enable walk")
    }

    func test_joystick_down_maps_to_backward_stride() {
        let input = WalkFreeformInput(x: 0, y: 1, turn: 0, speedScale: 1.0)
        let env = builder().walkFreeform(input)
        XCTAssertEqual(env.payload.xMm, -25, "joystick down (y=+1) must drive backward stride < 0")
        XCTAssertTrue(env.payload.enabled)
    }

    // MARK: - Lateral

    func test_joystick_right_maps_to_positive_lateral() {
        let input = WalkFreeformInput(x: 1, y: 0, turn: 0, speedScale: 1.0)
        let env = builder().walkFreeform(input)
        XCTAssertEqual(env.payload.xMm, 0)
        XCTAssertEqual(env.payload.yMm, 15, "joystick right (x=+1) must drive lateral right > 0")
    }

    func test_joystick_left_maps_to_negative_lateral() {
        let input = WalkFreeformInput(x: -1, y: 0, turn: 0, speedScale: 1.0)
        let env = builder().walkFreeform(input)
        XCTAssertEqual(env.payload.yMm, -15, "joystick left (x=-1) must drive lateral left < 0")
    }

    // MARK: - Turn

    func test_turn_positive_maps_to_positive_aDeg() {
        let input = WalkFreeformInput(x: 0, y: 0, turn: 1, speedScale: 1.0)
        let env = builder().walkFreeform(input)
        XCTAssertEqual(env.payload.aDeg, 10,
                       "turn=+1 → +10° (matches WalkPreset.turnLeft.aDeg=+8 sign)")
    }

    func test_turn_negative_maps_to_negative_aDeg() {
        let input = WalkFreeformInput(x: 0, y: 0, turn: -1, speedScale: 1.0)
        let env = builder().walkFreeform(input)
        XCTAssertEqual(env.payload.aDeg, -10,
                       "turn=-1 → -10° (matches WalkPreset.turnRight.aDeg=-8 sign)")
    }

    // MARK: - speedScale

    func test_speedScale_is_carried_separately_and_does_not_double_apply() {
        let input = WalkFreeformInput(x: 0, y: -1, turn: 0, speedScale: 1.5)
        let env = builder().walkFreeform(input)
        // Baseline amplitude * stick magnitude — NOT multiplied by speedScale.
        // The Mac side clamps and applies speedScale separately to keep one
        // single source of truth for clamping (see MobileFreeformWalkMapper).
        XCTAssertEqual(env.payload.xMm, 25,
                       "baseline forward at stick max is 25 mm regardless of scale field")
        XCTAssertEqual(env.payload.speedScale, 1.5,
                       "speedScale flows through as a separate payload field")
    }

    func test_proportional_speed_within_baseline_amplitude() {
        // Half stick → half baseline amplitude.
        let input = WalkFreeformInput(x: 0, y: -0.5, turn: 0, speedScale: 1.0)
        let env = builder().walkFreeform(input)
        XCTAssertEqual(env.payload.xMm, 13,
                       "half-stick forward = round(0.5 * 25) = 13 mm")
    }

    // MARK: - Combined inputs

    func test_diagonal_forward_right_combines_correctly() {
        // Stick "northeast" — half forward + half right.
        let input = WalkFreeformInput(x: 0.5, y: -0.5, turn: 0, speedScale: 1.0)
        let env = builder().walkFreeform(input)
        XCTAssertEqual(env.payload.xMm, 13, "forward component")
        XCTAssertEqual(env.payload.yMm, 8,  "lateral component (round(0.5 * 15))")
        XCTAssertEqual(env.payload.aDeg, 0)
    }

    // MARK: - Idle

    func test_centred_input_disables_walk() {
        let input = WalkFreeformInput(x: 0, y: 0, turn: 0, speedScale: 1.0)
        let env = builder().walkFreeform(input)
        XCTAssertFalse(env.payload.enabled,
                       "centred stick (below isMoving threshold) must clear enabled")
    }

    func test_isMoving_threshold_05_pct() {
        let almostCentre = WalkFreeformInput(x: 0.03, y: 0.03, turn: 0.03, speedScale: 1.0)
        XCTAssertFalse(almostCentre.isMoving, "0.03 must be under the deadzone")
        XCTAssertFalse(builder().walkFreeform(almostCentre).payload.enabled)

        let pastDeadzone = WalkFreeformInput(x: 0.10, y: 0, turn: 0, speedScale: 1.0)
        XCTAssertTrue(pastDeadzone.isMoving, "0.10 must be past the deadzone")
        XCTAssertTrue(builder().walkFreeform(pastDeadzone).payload.enabled)
    }

    // MARK: - JSON round-trip — proves the wire format survives encode/decode

    func test_walkFreeform_envelope_survives_json_roundtrip() throws {
        let input = WalkFreeformInput(x: 0.5, y: -0.7, turn: 0.3, speedScale: 1.2)
        let env = builder().walkFreeform(input)
        let data = try RelayCodec.encode(env)
        let decoded: RelayEnvelope<WalkPayload> = try RelayCodec.decode(data, as: WalkPayload.self)

        XCTAssertEqual(decoded.payload.preset, .freeform)
        XCTAssertEqual(decoded.payload.xMm, env.payload.xMm)
        XCTAssertEqual(decoded.payload.yMm, env.payload.yMm)
        XCTAssertEqual(decoded.payload.aDeg, env.payload.aDeg)
        XCTAssertEqual(decoded.payload.speedScale, 1.2)
        XCTAssertEqual(decoded.payload.enabled, env.payload.enabled)
    }
}
