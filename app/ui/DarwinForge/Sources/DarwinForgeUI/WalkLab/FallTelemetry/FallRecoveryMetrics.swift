import Foundation

/// Pure aggregator over a list of fall-recovery outcomes.
///
/// # Analogy
/// Like a sports statistician's summary card after a season — counts falls, computes
/// averages, and gives a single "success rate" number without touching any storage.
///
/// # Design
/// - Pure struct + static factory — no I/O, no MainActor dependency.
/// - Fully unit-testable: construct outcomes, call `aggregate`, assert.
/// - Phase 2 will wire this to the UI and Trial recommender; Phase 1 just provides
///   the pure computation layer.
public struct FallRecoveryMetrics: Sendable, Equatable {

    // MARK: - Aggregate counters

    /// Total number of fall events in the set.
    public let fallCount: Int
    /// Number of forward falls (face-down, pitch > 0).
    public let forwardCount: Int
    /// Number of backward falls (face-up, pitch < 0).
    public let backwardCount: Int

    // MARK: - Time metrics (ms)

    /// Mean time from fall detection to gyro settling (ms). nil if no data.
    public let meanSettleMs: Double?
    /// Mean total time from fall detection to .done/.failed (ms). nil if no data.
    public let meanRecoveryMs: Double?
    /// Mean time between consecutive fall events (seconds). nil if fewer than 2 falls.
    public let meanTimeBetweenFallsSec: Double?

    // MARK: - Quality metrics

    /// Fraction of falls that ended with success == true. 0…1. nil if no falls.
    public let recoverySuccessRate: Double?
    /// Maximum leg-joint load observed across all recovery outcomes. nil if no data.
    public let peakLegLoad: Double?

    // MARK: - Factory

    /// Build metrics from a list of recorded outcomes.
    ///
    /// - Parameters:
    ///   - outcomes: List of `FallTelemetryOutcome` objects (order: chronological).
    ///   - fallTimestamps: Optional list of fall-detected wall-clock timestamps (same order
    ///     as outcomes) used to compute `meanTimeBetweenFallsSec`. If nil/empty,
    ///     `meanTimeBetweenFallsSec` will be nil.
    /// - Returns: Aggregated metrics.
    public static func aggregate(
        outcomes: [FallTelemetryOutcome],
        fallTimestamps: [Date]? = nil
    ) -> FallRecoveryMetrics {
        let count = outcomes.count
        guard count > 0 else {
            return FallRecoveryMetrics(
                fallCount: 0, forwardCount: 0, backwardCount: 0,
                meanSettleMs: nil, meanRecoveryMs: nil,
                meanTimeBetweenFallsSec: nil,
                recoverySuccessRate: nil, peakLegLoad: nil
            )
        }

        let fwd = outcomes.filter { $0.direction == "forward" }.count
        let bwd = outcomes.filter { $0.direction == "backward" }.count

        let meanSettle = outcomes.map { $0.settleMs }.reduce(0, +) / Double(count)
        let meanRecovery = outcomes.map { $0.recoveryTotalMs }.reduce(0, +) / Double(count)
        let successRate = Double(outcomes.filter { $0.success }.count) / Double(count)

        let peakLoad: Double? = outcomes.compactMap { $0.peakLegLoad }.max()

        var meanTimeBetween: Double? = nil
        if let ts = fallTimestamps, ts.count >= 2 {
            let sorted = ts.sorted()
            var gaps: [Double] = []
            for i in 1..<sorted.count {
                gaps.append(sorted[i].timeIntervalSince(sorted[i - 1]))
            }
            meanTimeBetween = gaps.reduce(0, +) / Double(gaps.count)
        }

        return FallRecoveryMetrics(
            fallCount: count,
            forwardCount: fwd,
            backwardCount: bwd,
            meanSettleMs: meanSettle,
            meanRecoveryMs: meanRecovery,
            meanTimeBetweenFallsSec: meanTimeBetween,
            recoverySuccessRate: successRate,
            peakLegLoad: peakLoad
        )
    }

    // MARK: - Init (public for test construction)

    public init(
        fallCount: Int,
        forwardCount: Int,
        backwardCount: Int,
        meanSettleMs: Double?,
        meanRecoveryMs: Double?,
        meanTimeBetweenFallsSec: Double?,
        recoverySuccessRate: Double?,
        peakLegLoad: Double?
    ) {
        self.fallCount = fallCount
        self.forwardCount = forwardCount
        self.backwardCount = backwardCount
        self.meanSettleMs = meanSettleMs
        self.meanRecoveryMs = meanRecoveryMs
        self.meanTimeBetweenFallsSec = meanTimeBetweenFallsSec
        self.recoverySuccessRate = recoverySuccessRate
        self.peakLegLoad = peakLegLoad
    }
}
