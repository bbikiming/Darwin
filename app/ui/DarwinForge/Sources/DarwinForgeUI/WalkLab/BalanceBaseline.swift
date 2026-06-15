import Foundation

/// Pure, stateless helpers for the P-control baseline EMA.
///
/// Extracted for testability — tests can exercise the math directly
/// without instantiating a WalkLabSession.
///
/// # 비유 (Analogy)
///
/// Like a ship's horizon line: the horizon is the baseline, waves are deviations.
/// The corrector only needs to fight the waves (real instability), not the horizon
/// (intended forward-lean posture). This helper computes both.
///
/// # Formula
///
/// ```
/// alpha      = dt / (tau + dt)          // first-order IIR decay
/// new_ema    = alpha * sample + (1 - alpha) * prev
/// deviation  = sample - new_ema         // real deviation above chronic posture
/// ```
///
/// With dt=0.1 s and tau=5.0 s → alpha ≈ 0.0196 per tick.
/// A -20° constant baseline converges to -20° in ~3×tau = 15 s;
/// seed-on-start (see WalkLabSession) removes this lag entirely.
public enum BalanceBaseline {

    /// Advance the slow EMA by one tick.
    ///
    /// - Parameters:
    ///   - prev: Previous EMA value.
    ///   - sample: Current IMU reading (degrees, convention-normalized).
    ///   - tau: Time constant in seconds (default 5.0 s).
    ///   - dt: Tick interval in seconds (default 0.1 s = 10 Hz).
    /// - Returns: New EMA value.
    public static func step(
        prev: Double,
        sample: Double,
        tau: Double,
        dt: Double
    ) -> Double {
        let alpha = dt / (tau + dt)
        return alpha * sample + (1 - alpha) * prev
    }

    /// Compute the real deviation: how much the current sample differs from the baseline.
    ///
    /// - Parameters:
    ///   - sample: Current IMU reading.
    ///   - baseline: The slow EMA (chronic posture).
    /// - Returns: `sample - baseline` — the part the corrector should act on.
    public static func deviation(sample: Double, baseline: Double) -> Double {
        sample - baseline
    }
}
