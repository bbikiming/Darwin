import Foundation
import XCTest
@testable import DarwinForgeUI

/// Comprehensive tests for the CORE insight rules in HarnessInsights.
/// Covers: connectionRules, connection.flapping, reconnectRule, rttRules,
/// imuRules, imuFlappingRule, busRules (read_storm), busFlappingRule,
/// harnessRules, idleRules, busWriteFailStorm.
final class HarnessInsightsCoreTests: XCTestCase {

    // MARK: - Helpers

    private let base = Date(timeIntervalSince1970: 1_716_000_000)

    private func ev(
        _ kind: TelemetryKind,
        level: TelemetryLevel = .info,
        actor: TelemetryActor = .system,
        seq: UInt64 = 1,
        secondsFromBase: Double = 0,
        payload: [String: AnyCodable] = [:],
        context: TelemetryContext? = nil
    ) -> TelemetryEvent {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wall = f.string(from: base.addingTimeInterval(secondsFromBase))
        let monoNs = UInt64(max(0, secondsFromBase * 1e9))
        return TelemetryEvent(
            session: "TEST", seq: seq,
            wall: wall, mono: monoNs,
            kind: kind, level: level, actor: actor,
            data: TelemetryPayload(payload),
            context: context
        )
    }

    private func heartbeat(
        rttMs: Double? = nil,
        imuStale: Bool? = nil,
        seq: UInt64 = 1,
        secondsFromBase: Double = 0
    ) -> TelemetryEvent {
        let ctx = TelemetryContext(rttMs: rttMs, imuStale: imuStale)
        return ev(
            .heartbeat, level: .trace, seq: seq,
            secondsFromBase: secondsFromBase, context: ctx
        )
    }

    private func run(_ events: [TelemetryEvent]) -> [Insight] {
        let analysis = SessionAnalyzer.analyze(events: events)
        return HarnessInsights.compute(analysis: analysis, events: events)
    }

    // MARK: - connectionRules (high_failure_rate)

    func testConnectionHighFailureRateFiresAtThreshold() {
        // 3 attempts, 2 failures = 66% >= 40%
        let events = [
            ev(.connectAttempt, seq: 1, secondsFromBase: 0),
            ev(.connectFailure, level: .error, seq: 2, secondsFromBase: 1),
            ev(.connectAttempt, seq: 3, secondsFromBase: 2),
            ev(.connectFailure, level: .error, seq: 4, secondsFromBase: 3),
            ev(.connectAttempt, seq: 5, secondsFromBase: 4),
            ev(.connectSuccess, seq: 6, secondsFromBase: 5),
        ]
        let insights = run(events)
        XCTAssertTrue(insights.contains { $0.ruleID == "connection.high_failure_rate" })
    }

    func testConnectionHighFailureRateSeverityIsWarn() {
        let events = [
            ev(.connectAttempt, seq: 1, secondsFromBase: 0),
            ev(.connectFailure, level: .error, seq: 2, secondsFromBase: 1),
            ev(.connectAttempt, seq: 3, secondsFromBase: 2),
            ev(.connectFailure, level: .error, seq: 4, secondsFromBase: 3),
            ev(.connectAttempt, seq: 5, secondsFromBase: 4),
            ev(.connectFailure, level: .error, seq: 6, secondsFromBase: 5),
        ]
        let insights = run(events)
        let found = insights.first { $0.ruleID == "connection.high_failure_rate" }
        XCTAssertEqual(found?.severity, .warn)
        XCTAssertEqual(found?.kind, .connection)
    }

    func testConnectionHighFailureRateDoesNotFireBelowThreshold() {
        // 2 attempts (below 3) with 100% failure -- count too low
        let events = [
            ev(.connectAttempt, seq: 1, secondsFromBase: 0),
            ev(.connectFailure, level: .error, seq: 2, secondsFromBase: 1),
            ev(.connectAttempt, seq: 3, secondsFromBase: 2),
            ev(.connectFailure, level: .error, seq: 4, secondsFromBase: 3),
        ]
        let insights = run(events)
        XCTAssertFalse(insights.contains { $0.ruleID == "connection.high_failure_rate" })
    }

    func testConnectionHighFailureRateDoesNotFireWithLowRate() {
        // 5 attempts, 1 failure = 20% < 40%
        let events = [
            ev(.connectAttempt, seq: 1, secondsFromBase: 0),
            ev(.connectFailure, level: .error, seq: 2, secondsFromBase: 1),
            ev(.connectAttempt, seq: 3, secondsFromBase: 2),
            ev(.connectSuccess, seq: 4, secondsFromBase: 3),
            ev(.connectAttempt, seq: 5, secondsFromBase: 4),
            ev(.connectSuccess, seq: 6, secondsFromBase: 5),
            ev(.connectAttempt, seq: 7, secondsFromBase: 6),
            ev(.connectSuccess, seq: 8, secondsFromBase: 7),
            ev(.connectAttempt, seq: 9, secondsFromBase: 8),
            ev(.connectSuccess, seq: 10, secondsFromBase: 9),
        ]
        let insights = run(events)
        XCTAssertFalse(insights.contains { $0.ruleID == "connection.high_failure_rate" })
    }

    // MARK: - connection.flapping

    func testConnectionFlappingFiresAt3Cycles() {
        // 3 success->disconnect pairs within 60s
        let events = [
            ev(.connectSuccess, seq: 1, secondsFromBase: 0),
            ev(.connectDisconnect, seq: 2, secondsFromBase: 5),
            ev(.connectSuccess, seq: 3, secondsFromBase: 10),
            ev(.connectDisconnect, seq: 4, secondsFromBase: 15),
            ev(.connectSuccess, seq: 5, secondsFromBase: 20),
            ev(.connectDisconnect, seq: 6, secondsFromBase: 25),
        ]
        let insights = run(events)
        XCTAssertTrue(insights.contains { $0.ruleID == "connection.flapping" })
    }

    func testConnectionFlappingDoesNotFireAt2Cycles() {
        let events = [
            ev(.connectSuccess, seq: 1, secondsFromBase: 0),
            ev(.connectDisconnect, seq: 2, secondsFromBase: 5),
            ev(.connectSuccess, seq: 3, secondsFromBase: 10),
            ev(.connectDisconnect, seq: 4, secondsFromBase: 15),
        ]
        let insights = run(events)
        XCTAssertFalse(insights.contains { $0.ruleID == "connection.flapping" })
    }

    func testConnectionFlappingSeverityIsWarn() {
        let events = [
            ev(.connectSuccess, seq: 1, secondsFromBase: 0),
            ev(.connectDisconnect, seq: 2, secondsFromBase: 5),
            ev(.connectSuccess, seq: 3, secondsFromBase: 10),
            ev(.connectDisconnect, seq: 4, secondsFromBase: 15),
            ev(.connectSuccess, seq: 5, secondsFromBase: 20),
            ev(.connectDisconnect, seq: 6, secondsFromBase: 25),
        ]
        let insights = run(events)
        let found = insights.first { $0.ruleID == "connection.flapping" }
        XCTAssertEqual(found?.severity, .warn)
        XCTAssertEqual(found?.kind, .connection)
    }

    // MARK: - reconnectRule

    func testReconnectFrequentFiresAt5() {
        let events = (0..<5).map { i in
            ev(.connectReconnectAttempt, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let insights = run(events)
        XCTAssertTrue(
            insights.contains { $0.ruleID == "connection.reconnect_frequent" }
        )
    }

    func testReconnectFrequentDoesNotFireAt4() {
        let events = (0..<4).map { i in
            ev(.connectReconnectAttempt, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let insights = run(events)
        XCTAssertFalse(
            insights.contains { $0.ruleID == "connection.reconnect_frequent" }
        )
    }

    func testReconnectFrequentSeverityAndKind() {
        let events = (0..<6).map { i in
            ev(.connectReconnectAttempt, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let insights = run(events)
        let found = insights.first { $0.ruleID == "connection.reconnect_frequent" }
        XCTAssertEqual(found?.severity, .warn)
        XCTAssertEqual(found?.kind, .connection)
    }

    // MARK: - rttRules (severe)

    func testRttSevereFiresAbove100ms() {
        // 20 heartbeats all at 120ms => p95 = 120ms > 100
        let events = (0..<20).map { i in
            heartbeat(rttMs: 120, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let insights = run(events)
        XCTAssertTrue(insights.contains { $0.ruleID == "rtt.severe" })
    }

    func testRttSevereSeverityIsWarn() {
        let events = (0..<20).map { i in
            heartbeat(rttMs: 150, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let insights = run(events)
        let found = insights.first { $0.ruleID == "rtt.severe" }
        XCTAssertEqual(found?.severity, .warn)
        XCTAssertEqual(found?.kind, .connection)
    }

    // MARK: - rttRules (regression)

    func testRttRegressionFiresBetween50And100ms() {
        // 20 heartbeats at 70ms => p95 = 70ms, in (50, 100]
        let events = (0..<20).map { i in
            heartbeat(rttMs: 70, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let insights = run(events)
        XCTAssertTrue(insights.contains { $0.ruleID == "rtt.regression" })
        XCTAssertFalse(insights.contains { $0.ruleID == "rtt.severe" })
    }

    func testRttRegressionSeverityIsNotice() {
        let events = (0..<20).map { i in
            heartbeat(rttMs: 60, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let insights = run(events)
        let found = insights.first { $0.ruleID == "rtt.regression" }
        XCTAssertEqual(found?.severity, .notice)
    }

    func testRttDoesNotFireBelow50ms() {
        let events = (0..<20).map { i in
            heartbeat(rttMs: 30, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let insights = run(events)
        XCTAssertFalse(insights.contains { $0.ruleID == "rtt.severe" })
        XCTAssertFalse(insights.contains { $0.ruleID == "rtt.regression" })
    }

    // MARK: - imuRules (stale_persistent)

    func testImuStalePersistentFiresAtHighRatio() {
        // 10 heartbeats: 5 stale + 5 fresh = 50% >= 25%
        let stale = (0..<5).map { i in
            heartbeat(imuStale: true, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let fresh = (5..<10).map { i in
            heartbeat(imuStale: false, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let insights = run(stale + fresh)
        XCTAssertTrue(
            insights.contains { $0.ruleID == "imu.stale_persistent" }
        )
    }

    func testImuStalePersistentSeverityWarnAt50Percent() {
        // ratio = 0.5 => severity .warn
        let stale = (0..<5).map { i in
            heartbeat(imuStale: true, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let fresh = (5..<10).map { i in
            heartbeat(imuStale: false, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let insights = run(stale + fresh)
        let found = insights.first { $0.ruleID == "imu.stale_persistent" }
        XCTAssertEqual(found?.severity, .warn)
        XCTAssertEqual(found?.kind, .imu)
    }

    func testImuStalePersistentSeverityNoticeBelow50Percent() {
        // 3 stale / 10 total = 30% — above 25% but below 50%
        let stale = (0..<3).map { i in
            heartbeat(imuStale: true, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let fresh = (3..<10).map { i in
            heartbeat(imuStale: false, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let insights = run(stale + fresh)
        let found = insights.first { $0.ruleID == "imu.stale_persistent" }
        XCTAssertEqual(found?.severity, .notice)
    }

    func testImuStalePersistentDoesNotFireAtLowRatio() {
        // 1 stale / 10 total = 10% < 25%
        let stale = [heartbeat(imuStale: true, seq: 1, secondsFromBase: 0)]
        let fresh = (1..<10).map { i in
            heartbeat(imuStale: false, seq: UInt64(i + 1),
                      secondsFromBase: Double(i))
        }
        let insights = run(stale + fresh)
        XCTAssertFalse(
            insights.contains { $0.ruleID == "imu.stale_persistent" }
        )
    }

    // MARK: - imuFlappingRule

    func testImuFlappingFiresAt3Recoveries() {
        let events = (0..<3).map { i in
            ev(.imuRecovered, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let insights = run(events)
        XCTAssertTrue(insights.contains { $0.ruleID == "imu.flapping" })
    }

    func testImuFlappingDoesNotFireAt2Recoveries() {
        let events = (0..<2).map { i in
            ev(.imuRecovered, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let insights = run(events)
        XCTAssertFalse(insights.contains { $0.ruleID == "imu.flapping" })
    }

    func testImuFlappingSeverityAndKind() {
        let events = (0..<4).map { i in
            ev(.imuRecovered, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let insights = run(events)
        let found = insights.first { $0.ruleID == "imu.flapping" }
        XCTAssertEqual(found?.severity, .warn)
        XCTAssertEqual(found?.kind, .imu)
    }

    // MARK: - busRules (read_storm)

    func testBusReadStormFiresAtThreshold() {
        // 10 read fails in 30s = 20/min >= 10/min, count >= 10
        let events = (0..<10).map { i in
            ev(.busReadFail, level: .error, actor: .robot,
               seq: UInt64(i + 1), secondsFromBase: Double(i) * 3)
        }
        let insights = run(events)
        XCTAssertTrue(insights.contains { $0.ruleID == "bus.read_storm" })
    }

    func testBusReadStormDoesNotFireBelowCount() {
        // 9 read fails -- below count threshold of 10
        let events = (0..<9).map { i in
            ev(.busReadFail, level: .error, actor: .robot,
               seq: UInt64(i + 1), secondsFromBase: Double(i))
        }
        let insights = run(events)
        XCTAssertFalse(insights.contains { $0.ruleID == "bus.read_storm" })
    }

    func testBusReadStormDoesNotFireAtLowRate() {
        // 10 read fails spread over 600s (10 min) = 1/min < 10/min
        let events = (0..<10).map { i in
            ev(.busReadFail, level: .error, actor: .robot,
               seq: UInt64(i + 1), secondsFromBase: Double(i) * 60)
        }
        let insights = run(events)
        XCTAssertFalse(
            insights.contains { $0.ruleID == "bus.read_storm" },
            "count >= 10 but rate < 10/min should not fire"
        )
    }

    func testBusReadStormSeverityAndKind() {
        let events = (0..<12).map { i in
            ev(.busReadFail, level: .error, actor: .robot,
               seq: UInt64(i + 1), secondsFromBase: Double(i) * 2)
        }
        let insights = run(events)
        let found = insights.first { $0.ruleID == "bus.read_storm" }
        XCTAssertEqual(found?.severity, .warn)
        XCTAssertEqual(found?.kind, .bus)
    }

    // MARK: - busFlappingRule

    func testBusFlappingFiresAt5Recoveries() {
        let events = (0..<5).map { i in
            ev(.busRecovered, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let insights = run(events)
        XCTAssertTrue(insights.contains { $0.ruleID == "bus.flapping" })
    }

    func testBusFlappingDoesNotFireAt4Recoveries() {
        let events = (0..<4).map { i in
            ev(.busRecovered, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let insights = run(events)
        XCTAssertFalse(insights.contains { $0.ruleID == "bus.flapping" })
    }

    func testBusFlappingSeverityAndKind() {
        let events = (0..<6).map { i in
            ev(.busRecovered, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let insights = run(events)
        let found = insights.first { $0.ruleID == "bus.flapping" }
        XCTAssertEqual(found?.severity, .warn)
        XCTAssertEqual(found?.kind, .bus)
    }

    // MARK: - harnessRules (dropped_present)

    func testHarnessDroppedFiresWhenDroppedPresent() {
        let events = [
            ev(.heartbeat, level: .trace, seq: 1, secondsFromBase: 0),
            ev(.harnessDropped, level: .warn, seq: 2,
               secondsFromBase: 1,
               payload: ["count": AnyCodable(5)]),
            ev(.heartbeat, level: .trace, seq: 3, secondsFromBase: 2),
        ]
        let insights = run(events)
        XCTAssertTrue(
            insights.contains { $0.ruleID == "harness.dropped_present" }
        )
    }

    func testHarnessDroppedSeverityIsNotice() {
        let events = [
            ev(.harnessDropped, level: .warn, seq: 1,
               secondsFromBase: 0,
               payload: ["count": AnyCodable(3)]),
            ev(.heartbeat, level: .trace, seq: 2, secondsFromBase: 1),
        ]
        let insights = run(events)
        let found = insights.first { $0.ruleID == "harness.dropped_present" }
        XCTAssertEqual(found?.severity, .notice)
        XCTAssertEqual(found?.kind, .harness)
    }

    func testHarnessDroppedDoesNotFireAtZero() {
        // No harness.dropped events -> dropped = 0
        let events = [
            ev(.heartbeat, level: .trace, seq: 1, secondsFromBase: 0),
            ev(.heartbeat, level: .trace, seq: 2, secondsFromBase: 1),
        ]
        let insights = run(events)
        XCTAssertFalse(
            insights.contains { $0.ruleID == "harness.dropped_present" }
        )
    }

    // MARK: - idleRules

    func testIdleSessionFiresOnLongIdleSession() {
        // duration > 1800s with < 10 user events
        // 2 heartbeats spanning 2000s, 0 user actor events
        let events = [
            heartbeat(seq: 1, secondsFromBase: 0),
            heartbeat(seq: 2, secondsFromBase: 2000),
        ]
        let insights = run(events)
        XCTAssertTrue(
            insights.contains { $0.ruleID == "idle_session" }
        )
    }

    func testIdleSessionSeverityAndKind() {
        let events = [
            heartbeat(seq: 1, secondsFromBase: 0),
            heartbeat(seq: 2, secondsFromBase: 3600),
        ]
        let insights = run(events)
        let found = insights.first { $0.ruleID == "idle_session" }
        XCTAssertEqual(found?.severity, .info)
        XCTAssertEqual(found?.kind, .idle)
    }

    func testIdleSessionDoesNotFireOnShortSession() {
        // duration = 600s < 1800s
        let events = [
            heartbeat(seq: 1, secondsFromBase: 0),
            heartbeat(seq: 2, secondsFromBase: 600),
        ]
        let insights = run(events)
        XCTAssertFalse(
            insights.contains { $0.ruleID == "idle_session" }
        )
    }

    func testIdleSessionDoesNotFireWithManyUserEvents() {
        // duration = 2000s but 12 user events
        let userEvents = (0..<12).map { i in
            ev(.uiButtonTapped, actor: .user, seq: UInt64(i + 1),
               secondsFromBase: Double(i) * 150)
        }
        let bookend = [
            heartbeat(seq: 100, secondsFromBase: 2000),
        ]
        let insights = run(userEvents + bookend)
        XCTAssertFalse(
            insights.contains { $0.ruleID == "idle_session" }
        )
    }

    // MARK: - busWriteFailStorm (duplicate coverage from cycle226, kept for core suite)

    func testBusWriteStormFiresAboveThreshold() {
        // 6 write fails in 30s = 12/min >= 5/min, count >= 5
        let events = (0..<6).map { i in
            ev(.busWriteFail, level: .error, actor: .robot,
               seq: UInt64(i + 1), secondsFromBase: Double(i) * 5)
        }
        let insights = run(events)
        XCTAssertTrue(insights.contains { $0.ruleID == "bus.write_storm" })
    }

    func testBusWriteStormDoesNotFireBelowCount() {
        // 4 write fails -- below threshold of 5
        let events = (0..<4).map { i in
            ev(.busWriteFail, level: .error, actor: .robot,
               seq: UInt64(i + 1), secondsFromBase: Double(i))
        }
        let insights = run(events)
        XCTAssertFalse(
            insights.contains { $0.ruleID == "bus.write_storm" }
        )
    }

    func testBusWriteStormSeverityIsCritical() {
        let events = (0..<8).map { i in
            ev(.busWriteFail, level: .error, actor: .robot,
               seq: UInt64(i + 1), secondsFromBase: Double(i) * 3)
        }
        let insights = run(events)
        let found = insights.first { $0.ruleID == "bus.write_storm" }
        XCTAssertEqual(found?.severity, .critical)
        XCTAssertEqual(found?.kind, .bus)
    }
}
