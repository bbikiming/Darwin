import XCTest
@testable import DarwinForgeUI

/// Mac-side counterpart to iOS `WalkFreeformCommandTests`. Confirms that the
/// joystick payload semantics defined on the mobile side
/// (`xMm = forward`, `yMm = lateral`, `aDeg = turn`) survive the Mac mapper
/// unchanged and apply the `speedScale` exactly once.
///
/// Together with the iOS tests this brackets the full wire format:
/// iOS `CommandBuilder.walkFreeform` ⇄ JSON ⇄ Mac `MobileFreeformWalkMapper`
/// ⇄ `WalkLabSession.startOrUpdateMobileFreeform`.
@MainActor
final class MobileFreeformWalkMapperTests: XCTestCase {

    private func makePayload(xMm: Double = 0, yMm: Double = 0, aDeg: Double = 0,
                             speedScale: Double? = 1.0,
                             enabled: Bool = true) -> WalkPayload {
        WalkPayload(preset: .freeform,
                    enabled: enabled,
                    xMm: xMm, yMm: yMm, aDeg: aDeg,
                    periodMs: 700, footMm: 35, hipPitchDeg: 13,
                    speedScale: speedScale)
    }

    // MARK: - Direction semantics — proves payload field → tuning field mapping

    func test_forward_payload_maps_to_positive_stride() {
        let tuning = MobileFreeformWalkMapper.tuning(
            from: makePayload(xMm: 25), speedScale: 1.0)
        XCTAssertEqual(tuning.strideMm, 25, accuracy: 0.001,
                       "iOS xMm > 0 (전진) must produce strideMm > 0")
    }

    func test_backward_payload_maps_to_negative_stride() {
        let tuning = MobileFreeformWalkMapper.tuning(
            from: makePayload(xMm: -25), speedScale: 1.0)
        XCTAssertEqual(tuning.strideMm, -25, accuracy: 0.001,
                       "iOS xMm < 0 (후진) must produce strideMm < 0")
    }

    func test_lateral_right_payload_maps_to_positive_side() {
        let tuning = MobileFreeformWalkMapper.tuning(
            from: makePayload(yMm: 15), speedScale: 1.0)
        XCTAssertEqual(tuning.sideMm, 15, accuracy: 0.001,
                       "iOS yMm > 0 (우측) must produce sideMm > 0")
    }

    func test_lateral_left_payload_maps_to_negative_side() {
        let tuning = MobileFreeformWalkMapper.tuning(
            from: makePayload(yMm: -15), speedScale: 1.0)
        XCTAssertEqual(tuning.sideMm, -15, accuracy: 0.001,
                       "iOS yMm < 0 (좌측) must produce sideMm < 0")
    }

    func test_turn_left_payload_maps_to_positive_turnDeg() {
        let tuning = MobileFreeformWalkMapper.tuning(
            from: makePayload(aDeg: 10), speedScale: 1.0)
        XCTAssertEqual(tuning.turnDeg, 10, accuracy: 0.001,
                       "iOS aDeg > 0 (좌회전) must produce turnDeg > 0")
    }

    func test_turn_right_payload_maps_to_negative_turnDeg() {
        let tuning = MobileFreeformWalkMapper.tuning(
            from: makePayload(aDeg: -10), speedScale: 1.0)
        XCTAssertEqual(tuning.turnDeg, -10, accuracy: 0.001,
                       "iOS aDeg < 0 (우회전) must produce turnDeg < 0")
    }

    // MARK: - speedScale — single source of truth for scale

    func test_speedScale_multiplies_amplitude_once() {
        let tuning = MobileFreeformWalkMapper.tuning(
            from: makePayload(xMm: 20, yMm: 10, aDeg: 5),
            speedScale: 1.5)
        XCTAssertEqual(tuning.strideMm, 30, accuracy: 0.001,
                       "speedScale 1.5 × xMm 20 = 30")
        XCTAssertEqual(tuning.sideMm, 15, accuracy: 0.001)
        XCTAssertEqual(tuning.turnDeg, 7.5, accuracy: 0.001)
    }

    func test_speedScale_clamps_above_15() {
        let tuning = MobileFreeformWalkMapper.tuning(
            from: makePayload(xMm: 20), speedScale: 5.0)
        XCTAssertEqual(tuning.strideMm, 30, accuracy: 0.001,
                       "speedScale clamped to 1.5 — 20 × 1.5 = 30, not 20 × 5")
    }

    func test_speedScale_clamps_below_05() {
        let tuning = MobileFreeformWalkMapper.tuning(
            from: makePayload(xMm: 20), speedScale: 0.1)
        XCTAssertEqual(tuning.strideMm, 10, accuracy: 0.001,
                       "speedScale clamped to 0.5 — 20 × 0.5 = 10, not 20 × 0.1")
    }

    // MARK: - Safety clamp — robot never sees out-of-range amplitudes

    func test_mapper_clamps_into_safe_range() {
        let tuning = MobileFreeformWalkMapper.tuning(
            from: makePayload(xMm: 100, yMm: 100, aDeg: 100),
            speedScale: 1.5)
        XCTAssertLessThanOrEqual(tuning.strideMm, 38)
        XCTAssertLessThanOrEqual(tuning.sideMm,   22)
        XCTAssertLessThanOrEqual(tuning.turnDeg,  12)   // 18 → 12 보수화
    }

    func test_mapper_clamps_negative_range_too() {
        let tuning = MobileFreeformWalkMapper.tuning(
            from: makePayload(xMm: -100, yMm: -100, aDeg: -100),
            speedScale: 1.5)
        XCTAssertGreaterThanOrEqual(tuning.strideMm, -30)
        XCTAssertGreaterThanOrEqual(tuning.sideMm,   -22)
        XCTAssertGreaterThanOrEqual(tuning.turnDeg,  -12)   // -18 → -12 보수화
    }

    // MARK: - JSON wire format

    /// Real iOS clients encode payloads with `JSONEncoder.sortedKeys` and
    /// fractional ISO-8601 timestamps. Decoding a raw JSON envelope on Mac
    /// must reach the same tuning a hand-built `WalkPayload` would.
    func test_decoded_json_payload_maps_identically() throws {
        let json = """
        {
          "preset": "freeform",
          "enabled": true,
          "xMm": 25,
          "yMm": 0,
          "aDeg": 0,
          "periodMs": 700,
          "footMm": 35,
          "hipPitchDeg": 13,
          "speedScale": 1.0
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(WalkPayload.self, from: json)
        let tuning = MobileFreeformWalkMapper.tuning(
            from: payload, speedScale: payload.speedScale ?? 1.0)
        XCTAssertEqual(tuning.strideMm, 25, accuracy: 0.001,
                       "joystick-up payload → JSON → Mac tuning must yield strideMm > 0")
        XCTAssertEqual(tuning.sideMm, 0, accuracy: 0.001)
        XCTAssertEqual(tuning.turnDeg, 0, accuracy: 0.001)
    }

    func test_decoded_json_payload_with_lateral_right_yields_positive_side() throws {
        let json = """
        {
          "preset": "freeform",
          "enabled": true,
          "xMm": 0,
          "yMm": 15,
          "aDeg": 0,
          "periodMs": 700,
          "footMm": 35,
          "hipPitchDeg": 13,
          "speedScale": 1.0
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(WalkPayload.self, from: json)
        let tuning = MobileFreeformWalkMapper.tuning(
            from: payload, speedScale: payload.speedScale ?? 1.0)
        XCTAssertGreaterThan(tuning.sideMm, 0,
                             "joystick right → JSON → lateral right → sideMm > 0")
        XCTAssertEqual(tuning.strideMm, 0, accuracy: 0.001)
    }

    func test_decoded_json_payload_without_speedScale_defaults_to_10() throws {
        // Older iOS clients omitted speedScale entirely. Server treats it as 1.0.
        let json = """
        {
          "preset": "freeform",
          "enabled": true,
          "xMm": 20,
          "yMm": 0,
          "aDeg": 0,
          "periodMs": 700,
          "footMm": 35,
          "hipPitchDeg": 13
        }
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(WalkPayload.self, from: json)
        XCTAssertNil(payload.speedScale)
        let tuning = MobileFreeformWalkMapper.tuning(
            from: payload, speedScale: payload.speedScale ?? 1.0)
        XCTAssertEqual(tuning.strideMm, 20, accuracy: 0.001,
                       "missing speedScale → 1.0 → strideMm = xMm")
    }
}
