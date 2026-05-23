import Foundation
import XCTest
@testable import DarwinForgeUI

/// HarnessLiveAlerts unit tests — 5 alert rules, windowing, reset, multi-alert.
///
/// All tests are `@MainActor` because `HarnessLiveAlerts` is `@MainActor`-isolated.
/// Each test calls `sut.reset()` first to guarantee isolation.
final class HarnessLiveAlertsTests: XCTestCase {

    // MARK: - Helpers

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Build a TelemetryEvent with wall-clock relative to *now*.
    ///
    /// `secondsFromNow` is negative for the past (e.g., -5 = 5 seconds ago).
    /// This matches `evaluate()` which filters by `Date() - windowSeconds`.
    private func ev(
        _ kind: TelemetryKind,
        level: TelemetryLevel = .info,
        actor: TelemetryActor = .system,
        seq: UInt64 = 1,
        secondsFromNow: Double = 0,
        payload: [String: AnyCodable] = [:],
        context: TelemetryContext? = nil
    ) -> TelemetryEvent {
        let wall = isoFormatter.string(from: Date().addingTimeInterval(secondsFromNow))
        return TelemetryEvent(
            session: "TEST", seq: seq,
            wall: wall, mono: 0,
            kind: kind, level: level, actor: actor,
            data: TelemetryPayload(payload),
            context: context
        )
    }

    /// Heartbeat event with RTT context.
    private func heartbeat(
        rttMs: Double,
        imuStale: Bool = false,
        seq: UInt64 = 1,
        secondsFromNow: Double = 0
    ) -> TelemetryEvent {
        let ctx = TelemetryContext(rttMs: rttMs, imuStale: imuStale)
        return ev(.heartbeat, seq: seq, secondsFromNow: secondsFromNow, context: ctx)
    }

    /// Heartbeat event with only imuStale context (no RTT).
    private func heartbeatImu(
        imuStale: Bool,
        seq: UInt64 = 1,
        secondsFromNow: Double = 0
    ) -> TelemetryEvent {
        let ctx = TelemetryContext(imuStale: imuStale)
        return ev(.heartbeat, seq: seq, secondsFromNow: secondsFromNow, context: ctx)
    }

    // MARK: - 1. Empty events

    @MainActor
    func testEmptyEventsProducesNoAlerts() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        sut.evaluate(events: [])

        XCTAssertTrue(sut.active.isEmpty, "Empty input must produce zero alerts")
    }

    // MARK: - 2. RTT alert fires

    @MainActor
    func testRttAlertFiresWhenMeanExceedsThreshold() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // 3 heartbeats with RTT > 80ms (default threshold)
        let events = [
            heartbeat(rttMs: 90, seq: 1, secondsFromNow: -3),
            heartbeat(rttMs: 95, seq: 2, secondsFromNow: -2),
            heartbeat(rttMs: 100, seq: 3, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let rttAlert = sut.active.first { $0.id == "rtt.window_mean" }
        XCTAssertNotNil(rttAlert, "RTT alert must fire when mean > 80ms")
    }

    // MARK: - 3. RTT severity levels

    @MainActor
    func testRttAlertSeverityCriticalAbove120ms() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // mean = 130ms → > 80 * 1.5 = 120 → critical
        let events = [
            heartbeat(rttMs: 130, seq: 1, secondsFromNow: -2),
            heartbeat(rttMs: 130, seq: 2, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let rttAlert = sut.active.first { $0.id == "rtt.window_mean" }
        XCTAssertEqual(rttAlert?.severity, .critical,
                       "RTT mean > 120ms must be critical severity")
    }

    @MainActor
    func testRttAlertSeverityWarnBetween80And120ms() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // mean = 100ms → > 80 but <= 120 → warn
        let events = [
            heartbeat(rttMs: 100, seq: 1, secondsFromNow: -2),
            heartbeat(rttMs: 100, seq: 2, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let rttAlert = sut.active.first { $0.id == "rtt.window_mean" }
        XCTAssertEqual(rttAlert?.severity, .warn,
                       "RTT mean 80-120ms must be warn severity")
    }

    // MARK: - 4. RTT alert does NOT fire below threshold

    @MainActor
    func testRttAlertDoesNotFireBelowThreshold() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // mean = 50ms → below 80ms threshold
        let events = [
            heartbeat(rttMs: 50, seq: 1, secondsFromNow: -2),
            heartbeat(rttMs: 50, seq: 2, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let rttAlert = sut.active.first { $0.id == "rtt.window_mean" }
        XCTAssertNil(rttAlert, "RTT alert must NOT fire when mean < 80ms")
    }

    // MARK: - 5. IMU stale alert fires

    @MainActor
    func testImuStaleAlertFiresWhenRatioMet() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // 6 heartbeats: 4 stale, 2 not → ratio = 0.667 >= 0.5, count >= 5
        let events = [
            heartbeatImu(imuStale: true, seq: 1, secondsFromNow: -6),
            heartbeatImu(imuStale: true, seq: 2, secondsFromNow: -5),
            heartbeatImu(imuStale: true, seq: 3, secondsFromNow: -4),
            heartbeatImu(imuStale: true, seq: 4, secondsFromNow: -3),
            heartbeatImu(imuStale: false, seq: 5, secondsFromNow: -2),
            heartbeatImu(imuStale: false, seq: 6, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let imuAlert = sut.active.first { $0.id == "imu.window_stale" }
        XCTAssertNotNil(imuAlert, "IMU stale alert must fire when ratio >= 0.5 and count >= 5")
        XCTAssertEqual(imuAlert?.severity, .warn)
    }

    // MARK: - 6. IMU stale does NOT fire below ratio

    @MainActor
    func testImuStaleAlertDoesNotFireBelowRatio() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // 6 heartbeats: 2 stale, 4 not → ratio = 0.333 < 0.5
        let events = [
            heartbeatImu(imuStale: true, seq: 1, secondsFromNow: -6),
            heartbeatImu(imuStale: true, seq: 2, secondsFromNow: -5),
            heartbeatImu(imuStale: false, seq: 3, secondsFromNow: -4),
            heartbeatImu(imuStale: false, seq: 4, secondsFromNow: -3),
            heartbeatImu(imuStale: false, seq: 5, secondsFromNow: -2),
            heartbeatImu(imuStale: false, seq: 6, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let imuAlert = sut.active.first { $0.id == "imu.window_stale" }
        XCTAssertNil(imuAlert, "IMU stale alert must NOT fire when ratio < 0.5")
    }

    // MARK: - 7. IMU stale does NOT fire with few heartbeats

    @MainActor
    func testImuStaleAlertDoesNotFireWithFewHeartbeats() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // 4 heartbeats (all stale) — below minimum 5
        let events = [
            heartbeatImu(imuStale: true, seq: 1, secondsFromNow: -4),
            heartbeatImu(imuStale: true, seq: 2, secondsFromNow: -3),
            heartbeatImu(imuStale: true, seq: 3, secondsFromNow: -2),
            heartbeatImu(imuStale: true, seq: 4, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let imuAlert = sut.active.first { $0.id == "imu.window_stale" }
        XCTAssertNil(imuAlert, "IMU stale alert must NOT fire when heartbeat count < 5")
    }

    // MARK: - 8. Connection failure alert fires

    @MainActor
    func testConnectionFailureAlertFiresAtThreshold() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // 2 connection.failure events (threshold = 2)
        let events = [
            ev(.connectFailure, level: .error, seq: 1, secondsFromNow: -3),
            ev(.connectFailure, level: .error, seq: 2, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let connAlert = sut.active.first { $0.id == "connection.window_failures" }
        XCTAssertNotNil(connAlert, "Connection failure alert must fire at >= 2 failures")
        XCTAssertEqual(connAlert?.severity, .warn)
    }

    // MARK: - 9. Connection failure does NOT fire below threshold

    @MainActor
    func testConnectionFailureAlertDoesNotFireBelowThreshold() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // Only 1 failure — below threshold of 2
        let events = [
            ev(.connectFailure, level: .error, seq: 1, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let connAlert = sut.active.first { $0.id == "connection.window_failures" }
        XCTAssertNil(connAlert, "Connection failure alert must NOT fire with < 2 failures")
    }

    // MARK: - 10. Bus write fail alert fires

    @MainActor
    func testBusWriteFailAlertFiresAtThreshold() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // 3 bus.write_fail events (threshold = 3)
        let events = [
            ev(.busWriteFail, level: .warn, seq: 1, secondsFromNow: -4),
            ev(.busWriteFail, level: .warn, seq: 2, secondsFromNow: -3),
            ev(.busWriteFail, level: .warn, seq: 3, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let busAlert = sut.active.first { $0.id == "bus.window_write_fail" }
        XCTAssertNotNil(busAlert, "Bus write fail alert must fire at >= 3 events")
        XCTAssertEqual(busAlert?.severity, .warn)
    }

    // MARK: - 11. Bus write fail does NOT fire below threshold

    @MainActor
    func testBusWriteFailAlertDoesNotFireBelowThreshold() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // 2 events — below threshold of 3
        let events = [
            ev(.busWriteFail, level: .warn, seq: 1, secondsFromNow: -3),
            ev(.busWriteFail, level: .warn, seq: 2, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let busAlert = sut.active.first { $0.id == "bus.window_write_fail" }
        XCTAssertNil(busAlert, "Bus write fail alert must NOT fire with < 3 events")
    }

    // MARK: - 12. E-stop alert fires (bus.e_stop)

    @MainActor
    func testEStopAlertFiresForBusEStop() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        let events = [
            ev(.busEStop, level: .error, seq: 1, secondsFromNow: -2),
        ]
        sut.evaluate(events: events)

        let estopAlert = sut.active.first { $0.id == "estop.window" }
        XCTAssertNotNil(estopAlert, "E-stop alert must fire for bus.e_stop event")
        XCTAssertEqual(estopAlert?.severity, .critical,
                       "E-stop must always be critical severity")
    }

    // MARK: - 13. E-stop alert fires (walklab.emergency_stop)

    @MainActor
    func testEStopAlertFiresForWalkLabEmergencyStop() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        let events = [
            ev(.walkLabEmergencyStop, level: .error, seq: 1, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let estopAlert = sut.active.first { $0.id == "estop.window" }
        XCTAssertNotNil(estopAlert, "E-stop alert must fire for walklab.emergency_stop")
        XCTAssertEqual(estopAlert?.severity, .critical)
    }

    // MARK: - 14. Reset clears all alerts

    @MainActor
    func testResetClearsAllAlerts() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // First trigger an alert
        let events = [
            ev(.busEStop, level: .error, seq: 1, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)
        XCTAssertFalse(sut.active.isEmpty, "Pre-condition: alert must be active")

        // Now reset
        sut.reset()

        XCTAssertTrue(sut.active.isEmpty, "reset() must clear all active alerts")
    }

    // MARK: - 15. Events outside window are ignored

    @MainActor
    func testEventsOutsideWindowAreIgnored() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // Events 120s ago — outside default 60s window
        let events = [
            ev(.busEStop, level: .error, seq: 1, secondsFromNow: -120),
            ev(.connectFailure, level: .error, seq: 2, secondsFromNow: -90),
            ev(.connectFailure, level: .error, seq: 3, secondsFromNow: -91),
        ]
        sut.evaluate(events: events)

        XCTAssertTrue(sut.active.isEmpty,
                      "Events older than windowSeconds must not trigger alerts")
    }

    // MARK: - 16. Multiple alerts simultaneously

    @MainActor
    func testMultipleAlertsFireSimultaneously() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // RTT high + E-stop — both should fire
        let events = [
            heartbeat(rttMs: 150, seq: 1, secondsFromNow: -4),
            heartbeat(rttMs: 150, seq: 2, secondsFromNow: -3),
            ev(.busEStop, level: .error, seq: 3, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let rttAlert = sut.active.first { $0.id == "rtt.window_mean" }
        let estopAlert = sut.active.first { $0.id == "estop.window" }
        XCTAssertNotNil(rttAlert, "RTT alert must fire alongside other alerts")
        XCTAssertNotNil(estopAlert, "E-stop alert must fire alongside other alerts")
        XCTAssertEqual(sut.active.count, 2, "Exactly 2 alerts expected")
    }

    // MARK: - 17. All windowed events empty after filtering

    @MainActor
    func testNonEmptyInputButAllOutsideWindowProducesNoAlerts() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // Events exist but all outside the window
        let events = [
            heartbeat(rttMs: 200, seq: 1, secondsFromNow: -120),
        ]
        sut.evaluate(events: events)

        XCTAssertTrue(sut.active.isEmpty,
                      "Non-empty input with all events outside window must yield no alerts")
    }

    // MARK: - 18. firstObservedAt persists across evaluations

    @MainActor
    func testFirstObservedAtPersistsAcrossEvaluations() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        let events = [
            ev(.busEStop, level: .error, seq: 1, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)
        let firstAlert = try? XCTUnwrap(sut.active.first { $0.id == "estop.window" })
        let firstObserved = firstAlert?.firstObservedAt

        // Second evaluation with same alert
        sut.evaluate(events: events)
        let secondAlert = sut.active.first { $0.id == "estop.window" }

        XCTAssertEqual(firstObserved, secondAlert?.firstObservedAt,
                       "firstObservedAt must persist across consecutive evaluations")
    }

    // MARK: - 19. RTT at exact threshold boundary

    @MainActor
    func testRttAlertDoesNotFireAtExactThreshold() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // mean = 80ms exactly → NOT > 80, so should NOT fire
        let events = [
            heartbeat(rttMs: 80, seq: 1, secondsFromNow: -2),
            heartbeat(rttMs: 80, seq: 2, secondsFromNow: -1),
        ]
        sut.evaluate(events: events)

        let rttAlert = sut.active.first { $0.id == "rtt.window_mean" }
        XCTAssertNil(rttAlert, "RTT alert must NOT fire at exactly the threshold (> not >=)")
    }

    // MARK: - 20. Custom window seconds

    @MainActor
    func testCustomWindowSecondsFiltersProperly() {
        let sut = HarnessLiveAlerts.shared
        sut.reset()

        // Event 15s ago, with a 10s window → outside window → no alert
        let events = [
            ev(.busEStop, level: .error, seq: 1, secondsFromNow: -15),
        ]
        sut.evaluate(events: events, windowSeconds: 10)

        XCTAssertTrue(sut.active.isEmpty,
                      "Custom windowSeconds=10 must exclude events older than 10s")
    }
}
