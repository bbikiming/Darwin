import XCTest
@testable import DarwinForgeUI

/// Unit tests for FallRecoveryMetrics — direction split, success rate, mean times.
final class FallRecoveryMetricsTests: XCTestCase {

    // MARK: - Helpers

    private func makeOutcome(
        direction: String,
        success: Bool,
        settleMs: Double = 500,
        recoveryTotalMs: Double = 3000,
        peakLegLoad: Double? = nil
    ) -> FallTelemetryOutcome {
        FallTelemetryOutcome(
            direction: direction,
            getUpPage: direction == "forward" ? 10 : 11,
            settleMs: settleMs,
            attempts: 1,
            success: success,
            recoveryTotalMs: recoveryTotalMs,
            peakLegLoad: peakLegLoad
        )
    }

    // MARK: - Empty input

    func testAggregate_emptyOutcomes() {
        let metrics = FallRecoveryMetrics.aggregate(outcomes: [])
        XCTAssertEqual(metrics.fallCount, 0)
        XCTAssertNil(metrics.recoverySuccessRate)
        XCTAssertNil(metrics.meanSettleMs)
        XCTAssertNil(metrics.meanRecoveryMs)
        XCTAssertNil(metrics.meanTimeBetweenFallsSec)
        XCTAssertNil(metrics.peakLegLoad)
    }

    // MARK: - Direction split

    func testDirectionSplit_forwardOnly() {
        let outcomes = [
            makeOutcome(direction: "forward", success: true),
            makeOutcome(direction: "forward", success: true)
        ]
        let m = FallRecoveryMetrics.aggregate(outcomes: outcomes)
        XCTAssertEqual(m.fallCount, 2)
        XCTAssertEqual(m.forwardCount, 2)
        XCTAssertEqual(m.backwardCount, 0)
    }

    func testDirectionSplit_backwardOnly() {
        let outcomes = [makeOutcome(direction: "backward", success: false)]
        let m = FallRecoveryMetrics.aggregate(outcomes: outcomes)
        XCTAssertEqual(m.forwardCount, 0)
        XCTAssertEqual(m.backwardCount, 1)
    }

    func testDirectionSplit_mixed() {
        let outcomes = [
            makeOutcome(direction: "forward", success: true),
            makeOutcome(direction: "backward", success: true),
            makeOutcome(direction: "forward", success: false)
        ]
        let m = FallRecoveryMetrics.aggregate(outcomes: outcomes)
        XCTAssertEqual(m.fallCount, 3)
        XCTAssertEqual(m.forwardCount, 2)
        XCTAssertEqual(m.backwardCount, 1)
    }

    // MARK: - Success rate

    func testSuccessRate_allSuccess() {
        let outcomes = [
            makeOutcome(direction: "forward", success: true),
            makeOutcome(direction: "forward", success: true)
        ]
        let m = FallRecoveryMetrics.aggregate(outcomes: outcomes)
        XCTAssertEqual(m.recoverySuccessRate!, 1.0, accuracy: 1e-9)
    }

    func testSuccessRate_noSuccess() {
        let outcomes = [
            makeOutcome(direction: "forward", success: false),
            makeOutcome(direction: "backward", success: false)
        ]
        let m = FallRecoveryMetrics.aggregate(outcomes: outcomes)
        XCTAssertEqual(m.recoverySuccessRate!, 0.0, accuracy: 1e-9)
    }

    func testSuccessRate_partial() {
        let outcomes = [
            makeOutcome(direction: "forward", success: true),
            makeOutcome(direction: "backward", success: false),
            makeOutcome(direction: "forward", success: false)
        ]
        let m = FallRecoveryMetrics.aggregate(outcomes: outcomes)
        XCTAssertEqual(m.recoverySuccessRate!, 1.0/3.0, accuracy: 1e-9)
    }

    // MARK: - Mean settle ms

    func testMeanSettleMs() {
        let outcomes = [
            makeOutcome(direction: "forward", success: true, settleMs: 400),
            makeOutcome(direction: "backward", success: true, settleMs: 600)
        ]
        let m = FallRecoveryMetrics.aggregate(outcomes: outcomes)
        XCTAssertEqual(m.meanSettleMs!, 500.0, accuracy: 1e-9)
    }

    // MARK: - Mean recovery ms

    func testMeanRecoveryMs() {
        let outcomes = [
            makeOutcome(direction: "forward", success: true, recoveryTotalMs: 2000),
            makeOutcome(direction: "forward", success: false, recoveryTotalMs: 4000)
        ]
        let m = FallRecoveryMetrics.aggregate(outcomes: outcomes)
        XCTAssertEqual(m.meanRecoveryMs!, 3000.0, accuracy: 1e-9)
    }

    // MARK: - Mean time between falls

    func testMeanTimeBetweenFalls_singleFall() {
        let outcomes = [makeOutcome(direction: "forward", success: true)]
        let m = FallRecoveryMetrics.aggregate(
            outcomes: outcomes,
            fallTimestamps: [Date()]
        )
        // Only 1 fall → nil (need ≥ 2 for a gap).
        XCTAssertNil(m.meanTimeBetweenFallsSec)
    }

    func testMeanTimeBetweenFalls_twoFalls() {
        let t1 = Date()
        let t2 = t1.addingTimeInterval(60.0)  // 60s gap
        let outcomes = [
            makeOutcome(direction: "forward", success: true),
            makeOutcome(direction: "backward", success: false)
        ]
        let m = FallRecoveryMetrics.aggregate(
            outcomes: outcomes,
            fallTimestamps: [t1, t2]
        )
        XCTAssertNotNil(m.meanTimeBetweenFallsSec)
        XCTAssertEqual(m.meanTimeBetweenFallsSec!, 60.0, accuracy: 0.01)
    }

    func testMeanTimeBetweenFalls_noTimestamps() {
        let outcomes = [
            makeOutcome(direction: "forward", success: true),
            makeOutcome(direction: "forward", success: true)
        ]
        let m = FallRecoveryMetrics.aggregate(outcomes: outcomes)
        XCTAssertNil(m.meanTimeBetweenFallsSec, "nil timestamps → nil meanTimeBetweenFalls")
    }

    // MARK: - Peak leg load

    func testPeakLegLoad_returnsMax() {
        let outcomes = [
            makeOutcome(direction: "forward", success: true, peakLegLoad: 1500),
            makeOutcome(direction: "backward", success: false, peakLegLoad: 2100),
            makeOutcome(direction: "forward", success: true, peakLegLoad: 800)
        ]
        let m = FallRecoveryMetrics.aggregate(outcomes: outcomes)
        XCTAssertEqual(m.peakLegLoad!, 2100.0, accuracy: 1e-9)
    }

    func testPeakLegLoad_nilWhenNoData() {
        let outcomes = [makeOutcome(direction: "forward", success: true, peakLegLoad: nil)]
        let m = FallRecoveryMetrics.aggregate(outcomes: outcomes)
        XCTAssertNil(m.peakLegLoad)
    }
}
