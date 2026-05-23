import Foundation
import XCTest
@testable import DarwinForgeUI

/// Comprehensive tests for `HarnessBaseline.compare(baseline:current:)`.
///
/// Covers: MetricDelta computation, CountDelta computation, verdict logic
/// (improvement / regression / similar), hardRegressionMarker boost,
/// lowerIsBetter flags, and structural invariants (array sizes, IDs).
final class HarnessBaselineTests: XCTestCase {

    // MARK: - Helpers

    private let base = Date(timeIntervalSince1970: 1_716_000_000)

    /// Convenience event factory with optional TelemetryContext for RTT / battery / IMU.
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

    /// Build a heartbeat event with RTT context attached.
    private func heartbeat(
        rttMs: Double?,
        batteryV: Double? = nil,
        imuStale: Bool? = nil,
        seq: UInt64 = 1,
        secondsFromBase: Double = 0
    ) -> TelemetryEvent {
        let ctx = TelemetryContext(
            batteryV: batteryV,
            rttMs: rttMs,
            imuStale: imuStale
        )
        return ev(
            .heartbeat, level: .trace, actor: .system,
            seq: seq, secondsFromBase: secondsFromBase,
            context: ctx
        )
    }

    /// Analyze events via SessionAnalyzer and return a (id, analysis) tuple.
    private func analyzed(
        id: String,
        events: [TelemetryEvent]
    ) -> (id: String, analysis: SessionAnalysis) {
        let analysis = SessionAnalyzer.analyze(events: events)
        return (id: id, analysis: analysis)
    }

    /// Build a minimal session with N error events spread over time.
    private func errorSession(count: Int) -> [TelemetryEvent] {
        (0..<count).map { i in
            ev(.errorException, level: .error, seq: UInt64(i),
               secondsFromBase: Double(i))
        }
    }

    /// Build a minimal session with N e-stop events spread over time.
    private func eStopSession(count: Int) -> [TelemetryEvent] {
        (0..<count).map { i in
            ev(.busEStop, level: .error, actor: .robot,
               seq: UInt64(i), secondsFromBase: Double(i))
        }
    }

    /// Build a minimal session with N walkLab emergency stop events.
    private func walkEmergencyStopSession(count: Int) -> [TelemetryEvent] {
        (0..<count).map { i in
            ev(.walkLabEmergencyStop, level: .error, actor: .system,
               seq: UInt64(i), secondsFromBase: Double(i))
        }
    }

    /// Build a minimal session with N walkLab start-blocked events.
    private func walkBlockedSession(count: Int) -> [TelemetryEvent] {
        (0..<count).map { i in
            ev(.walkLabStartBlocked, level: .warn, actor: .system,
               seq: UInt64(i), secondsFromBase: Double(i))
        }
    }

    /// Build a set of heartbeats with a specific RTT value to produce a known p95.
    /// For a single repeated value, mean == p95 == that value.
    private func rttSession(rttMs: Double, count: Int = 20) -> [TelemetryEvent] {
        (0..<count).map { i in
            heartbeat(rttMs: rttMs, seq: UInt64(i),
                      secondsFromBase: Double(i))
        }
    }

    /// Build a minimal empty session (single heartbeat, no errors).
    private func emptySession() -> [TelemetryEvent] {
        [ev(.heartbeat, level: .trace, seq: 0, secondsFromBase: 0)]
    }

    // MARK: - 1. Identical sessions -> .similar

    func testIdenticalSessionsProduceSimilarVerdict() {
        let events = errorSession(count: 3) + rttSession(rttMs: 50.0)
        let baselineTuple = analyzed(id: "baseline-1", events: events)
        let currentTuple = analyzed(id: "current-1", events: events)

        let diff = HarnessBaseline.compare(baseline: baselineTuple, current: currentTuple)

        switch diff.verdict {
        case .similar:
            break // expected
        default:
            XCTFail("Expected .similar but got \(diff.verdict)")
        }
        XCTAssertEqual(diff.weightedScorePercent, 0, accuracy: 0.01,
                       "Identical sessions should yield ~0% weighted score")
    }

    // MARK: - 2. Improved RTT -> check metric deltas

    func testImprovedRttShowsNegativeDelta() {
        let baselineEvents = rttSession(rttMs: 100.0)
        let currentEvents = rttSession(rttMs: 50.0)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let rttP95 = diff.metrics.first { $0.label == "RTT p95 (ms)" }
        XCTAssertNotNil(rttP95)
        XCTAssertNotNil(rttP95?.deltaAbsolute)
        XCTAssertNotNil(rttP95?.deltaPercent)
        XCTAssertEqual(rttP95!.deltaAbsolute!, -50.0, accuracy: 1.0,
                       "RTT p95 should decrease by ~50ms")
        XCTAssertEqual(rttP95!.deltaPercent!, -50.0, accuracy: 1.0,
                       "RTT p95 should decrease by ~50%")
    }

    func testImprovedRttMeanShowsNegativeDelta() {
        let baselineEvents = rttSession(rttMs: 100.0)
        let currentEvents = rttSession(rttMs: 50.0)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let rttMean = diff.metrics.first { $0.label == "RTT mean (ms)" }
        XCTAssertNotNil(rttMean)
        XCTAssertEqual(rttMean!.deltaAbsolute!, -50.0, accuracy: 1.0)
        XCTAssertEqual(rttMean!.deltaPercent!, -50.0, accuracy: 1.0)
    }

    // MARK: - 3. Error count regression (0 -> N)

    func testErrorCountZeroToNForcesRegression() {
        let baselineEvents = emptySession()
        let currentEvents = errorSession(count: 5)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        switch diff.verdict {
        case .regression:
            break // expected
        default:
            XCTFail("Expected .regression for 0->5 errors but got \(diff.verdict)")
        }
    }

    // MARK: - 4. E-stop from 0 -> N forces regression

    func testEStopZeroToNForcesRegression() {
        let baselineEvents = emptySession()
        let currentEvents = eStopSession(count: 2)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        switch diff.verdict {
        case .regression:
            break // expected -- hardRegressionMarker + weight 3
        default:
            XCTFail("Expected .regression for 0->2 e-stops but got \(diff.verdict)")
        }
    }

    func testEStopRegressionReasonContainsEStop() {
        let baselineEvents = emptySession()
        let currentEvents = eStopSession(count: 2)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        if case .regression(let reason) = diff.verdict {
            XCTAssertTrue(reason.contains("E-stop"),
                          "Regression reason should mention E-stop, got: \(reason)")
        } else {
            XCTFail("Expected .regression verdict")
        }
    }

    // MARK: - 5. Error count improvement

    func testErrorCountImprovementShowsNegativeDelta() {
        let baselineEvents = errorSession(count: 10)
        let currentEvents = errorSession(count: 2)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let errorCount = diff.counts.first { $0.label == "에러" }
        XCTAssertNotNil(errorCount)
        XCTAssertEqual(errorCount!.delta, -8,
                       "10 errors -> 2 errors = delta -8")
        XCTAssertEqual(errorCount!.baseline, 10)
        XCTAssertEqual(errorCount!.current, 2)
    }

    // MARK: - 6. Both nil metrics -> deltas are nil

    func testBothNilMetricsProduceNilDeltas() {
        // Sessions with no heartbeats containing RTT context -> rttMs will be nil
        let events = [ev(.appLaunch, level: .notice, seq: 0, secondsFromBase: 0)]

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        let rttP95 = diff.metrics.first { $0.label == "RTT p95 (ms)" }
        XCTAssertNotNil(rttP95, "RTT p95 metric should always be present in array")
        XCTAssertNil(rttP95!.baseline, "No heartbeats -> baseline RTT nil")
        XCTAssertNil(rttP95!.current, "No heartbeats -> current RTT nil")
        XCTAssertNil(rttP95!.deltaAbsolute, "Both nil -> deltaAbsolute nil")
        XCTAssertNil(rttP95!.deltaPercent, "Both nil -> deltaPercent nil")

        let rttMean = diff.metrics.first { $0.label == "RTT mean (ms)" }
        XCTAssertNil(rttMean!.deltaAbsolute)
        XCTAssertNil(rttMean!.deltaPercent)
    }

    // MARK: - 7. Baseline zero, current zero -> no regression

    func testBothZeroCountsProduceSimilar() {
        // Both sessions have 0 errors, 0 e-stops -- just benign events
        let events = emptySession()

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        switch diff.verdict {
        case .similar:
            break // expected
        default:
            XCTFail("Expected .similar when both have zero counts, got \(diff.verdict)")
        }
    }

    func testBothZeroErrorsDeltaIsZero() {
        let events = emptySession()

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        let errorCount = diff.counts.first { $0.label == "에러" }
        XCTAssertNotNil(errorCount)
        XCTAssertEqual(errorCount!.delta, 0)
        XCTAssertEqual(errorCount!.baseline, 0)
        XCTAssertEqual(errorCount!.current, 0)
    }

    func testBothZeroEStopsDeltaIsZero() {
        let events = emptySession()

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        let eStop = diff.counts.first { $0.label == "E-stop" }
        XCTAssertNotNil(eStop)
        XCTAssertEqual(eStop!.delta, 0)
    }

    // MARK: - 8. MetricDelta count is 5

    func testMetricDeltaCountIsFive() {
        let events = emptySession()

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        XCTAssertEqual(diff.metrics.count, 5,
                       "Should produce exactly 5 MetricDelta entries")
    }

    func testMetricDeltaLabelsAreCorrect() {
        let events = emptySession()

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        let labels = diff.metrics.map(\.label)
        XCTAssertTrue(labels.contains("RTT p95 (ms)"))
        XCTAssertTrue(labels.contains("RTT mean (ms)"))
        XCTAssertTrue(labels.contains("배터리 min (V)"))
        XCTAssertTrue(labels.contains("IMU stale ratio"))
        XCTAssertTrue(labels.contains("연결 성공률"))
    }

    // MARK: - 9. CountDelta count is 8

    func testCountDeltaCountIsEight() {
        let events = emptySession()

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        XCTAssertEqual(diff.counts.count, 8,
                       "Should produce exactly 8 CountDelta entries")
    }

    func testCountDeltaLabelsAreCorrect() {
        let events = emptySession()

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        let labels = diff.counts.map(\.label)
        let expected = [
            "에러", "경고", "Bus 읽기 실패", "Bus 쓰기 실패",
            "E-stop", "보행 시작", "보행 비상 정지", "보행 차단"
        ]
        for label in expected {
            XCTAssertTrue(labels.contains(label),
                          "Missing CountDelta label: \(label)")
        }
    }

    // MARK: - 10. MetricDelta lowerIsBetter flags

    func testRttMetricsHaveLowerIsBetterTrue() {
        let events = emptySession()
        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        let rttP95 = diff.metrics.first { $0.label == "RTT p95 (ms)" }
        XCTAssertTrue(rttP95!.lowerIsBetter, "RTT p95 should be lowerIsBetter=true")

        let rttMean = diff.metrics.first { $0.label == "RTT mean (ms)" }
        XCTAssertTrue(rttMean!.lowerIsBetter, "RTT mean should be lowerIsBetter=true")
    }

    func testImuStaleRatioHasLowerIsBetterTrue() {
        let events = emptySession()
        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        let imu = diff.metrics.first { $0.label == "IMU stale ratio" }
        XCTAssertTrue(imu!.lowerIsBetter, "IMU stale ratio should be lowerIsBetter=true")
    }

    func testBatteryMinHasLowerIsBetterFalse() {
        let events = emptySession()
        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        let battery = diff.metrics.first { $0.label == "배터리 min (V)" }
        XCTAssertFalse(battery!.lowerIsBetter,
                       "Battery min should be lowerIsBetter=false (higher voltage is better)")
    }

    func testConnectionSuccessRateHasLowerIsBetterFalse() {
        let events = emptySession()
        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        let conn = diff.metrics.first { $0.label == "연결 성공률" }
        XCTAssertFalse(conn!.lowerIsBetter,
                       "Connection success rate should be lowerIsBetter=false")
    }

    // MARK: - 11. hardRegressionMarker boost

    func testHardRegressionMarkerBoostsScoreToAtLeast21() {
        // Baseline: 0 e-stops. Current: 1 e-stop.
        // Even if RTT strongly improves, score should be >= 21% due to marker.
        let baselineEvents = rttSession(rttMs: 200.0, count: 20) + emptySession()
        let currentEvents = rttSession(rttMs: 10.0, count: 20) + eStopSession(count: 1)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        XCTAssertGreaterThanOrEqual(diff.weightedScorePercent, 21.0,
            "hardRegressionMarker should boost score to at least 21%")

        switch diff.verdict {
        case .regression:
            break // expected
        default:
            XCTFail("Expected .regression due to hardRegressionMarker, got \(diff.verdict)")
        }
    }

    func testHardRegressionMarkerTriggersForWalkEmergencyStop() {
        // 보행 비상 정지 is also safety-critical (weight 3).
        let baselineEvents = emptySession()
        let currentEvents = walkEmergencyStopSession(count: 1)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        XCTAssertGreaterThanOrEqual(diff.weightedScorePercent, 21.0)
        switch diff.verdict {
        case .regression:
            break
        default:
            XCTFail("Expected .regression for 0->1 walk emergency stop")
        }
    }

    func testHardRegressionMarkerTriggersForWalkBlocked() {
        // 보행 차단 is also covered by hardRegressionMarker.
        let baselineEvents = emptySession()
        let currentEvents = walkBlockedSession(count: 1)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        XCTAssertGreaterThanOrEqual(diff.weightedScorePercent, 21.0)
        switch diff.verdict {
        case .regression:
            break
        default:
            XCTFail("Expected .regression for 0->1 walk blocked")
        }
    }

    // MARK: - 12. Baseline/current IDs preserved

    func testBaselineAndCurrentIdsPreserved() {
        let events = emptySession()

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "session-alpha", events: events),
            current: analyzed(id: "session-beta", events: events)
        )

        XCTAssertEqual(diff.baselineId, "session-alpha")
        XCTAssertEqual(diff.currentId, "session-beta")
    }

    // MARK: - CRITICAL: Verdict ±20% exact boundary (critic CRITICAL-1)
    //
    // computeVerdict 는 `effectiveScore > 20` (strictly greater) 로 regression 판정.
    // 정확히 20.0 이면 .similar 여야 한다. 이 경계를 명시적으로 검증.

    func testVerdictExactlyPlus20PercentIsSimilar() {
        // All 4 verdict-counted categories at exactly +20%:
        //   error: 15→18 (20%), e-stop: 5→6 (20%), walkEmergency: 5→6 (20%), walkBlocked: 5→6 (20%)
        // weighted = 20*1 + 20*3 + 20*3 + 20*1 = 160, totalWeight = 1+3+3+1 = 8
        // score = 160/8 = 20.0. `20.0 > 20` is false → .similar.
        let baselineEvents = errorSession(count: 5) + eStopSession(count: 5)
            + walkEmergencyStopSession(count: 5) + walkBlockedSession(count: 5)
        let currentEvents = errorSession(count: 6) + eStopSession(count: 6)
            + walkEmergencyStopSession(count: 6) + walkBlockedSession(count: 6)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        switch diff.verdict {
        case .similar:
            break // expected — strictly greater means 20.0 is still similar
        default:
            XCTFail("Exactly +20% should be .similar (> 20, not >=), got \(diff.verdict)")
        }
        XCTAssertEqual(diff.weightedScorePercent, 20.0, accuracy: 0.01,
                       "Score should be exactly 20.0%")
    }

    func testVerdictExactlyMinus20PercentIsSimilar() {
        // All 4 categories at exactly -20%:
        //   error: 15→12 (-20%), e-stop: 5→4 (-20%), walkEmergency: 5→4 (-20%), walkBlocked: 5→4 (-20%)
        // score = -160/8 = -20.0. `-20.0 < -20` is false → .similar.
        let baselineEvents = errorSession(count: 5) + eStopSession(count: 5)
            + walkEmergencyStopSession(count: 5) + walkBlockedSession(count: 5)
        let currentEvents = errorSession(count: 4) + eStopSession(count: 4)
            + walkEmergencyStopSession(count: 4) + walkBlockedSession(count: 4)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        switch diff.verdict {
        case .similar:
            break // expected — strictly less means -20.0 is still similar
        default:
            XCTFail("Exactly -20% should be .similar (< -20, not <=), got \(diff.verdict)")
        }
        XCTAssertEqual(diff.weightedScorePercent, -20.0, accuracy: 0.01,
                       "Score should be exactly -20.0%")
    }

    func testVerdictJustAbovePlus20IsRegression() {
        // All 4 categories at +25%:
        //   error: 12→15 (25%), e-stop: 4→5 (25%), walkEmergency: 4→5 (25%), walkBlocked: 4→5 (25%)
        // score = 200/8 = 25.0 > 20 → .regression.
        let baselineEvents = errorSession(count: 4) + eStopSession(count: 4)
            + walkEmergencyStopSession(count: 4) + walkBlockedSession(count: 4)
        let currentEvents = errorSession(count: 5) + eStopSession(count: 5)
            + walkEmergencyStopSession(count: 5) + walkBlockedSession(count: 5)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        switch diff.verdict {
        case .regression:
            break // expected
        default:
            XCTFail("+25% across all counts should be .regression, got \(diff.verdict)")
        }
        XCTAssertGreaterThan(diff.weightedScorePercent, 20.0)
    }

    func testVerdictJustBelowMinus20IsImprovement() {
        // All 4 categories at -25%:
        //   error: 12→9 (-25%), e-stop: 4→3 (-25%), walkEmergency: 4→3 (-25%), walkBlocked: 4→3 (-25%)
        // score = -200/8 = -25.0 < -20 → .improvement.
        let baselineEvents = errorSession(count: 4) + eStopSession(count: 4)
            + walkEmergencyStopSession(count: 4) + walkBlockedSession(count: 4)
        let currentEvents = errorSession(count: 3) + eStopSession(count: 3)
            + walkEmergencyStopSession(count: 3) + walkBlockedSession(count: 3)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        switch diff.verdict {
        case .improvement:
            break // expected
        default:
            XCTFail("-25% across all counts should be .improvement, got \(diff.verdict)")
        }
        XCTAssertLessThan(diff.weightedScorePercent, -20.0)
    }

    // MARK: - Verdict regression/improvement extremes

    func testStrongImprovementVerdict() {
        // Baseline: 20 errors, 5 e-stops. Current: 2 errors, 0 e-stops.
        let baselineEvents = errorSession(count: 20) + eStopSession(count: 5)
        let currentEvents = errorSession(count: 2)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        switch diff.verdict {
        case .improvement:
            break // expected
        default:
            XCTFail("Expected .improvement for strong count reduction, got \(diff.verdict)")
        }
        XCTAssertLessThan(diff.weightedScorePercent, -20.0,
                          "Weighted score should be strongly negative for improvement")
    }

    func testMultipleHardRegressionMarkersStillForceRegression() {
        // 0->N for errors AND e-stops AND walk emergency stops simultaneously.
        let currentEvents = errorSession(count: 3)
            + eStopSession(count: 2)
            + walkEmergencyStopSession(count: 1)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: emptySession()),
            current: analyzed(id: "c", events: currentEvents)
        )

        switch diff.verdict {
        case .regression:
            break
        default:
            XCTFail("Expected .regression when multiple safety-critical counts go 0->N")
        }
        XCTAssertGreaterThan(diff.weightedScorePercent, 21.0,
                             "Score should exceed 21% with multiple hard regression markers")
    }
}
