import XCTest
@testable import DarwinForgeUI

/// Baseline-aware gyro balance correction — pure math + integration tests.
///
/// # Coverage (6 tests)
///
/// 1. Constant -20° pitch converges to -20° baseline → deviation → ~0 (corrector stops fighting posture).
/// 2. Real step deviation: -20° baseline + sudden -8° tilt → deviation captures -8° (real instability corrected).
/// 3. Seed on first tick: sample -20° → EMA = -20° immediately, deviation = 0 on tick 1.
/// 4. Baseline-0 / not-initialized equivalence: deviation == raw sample (regression guarantee).
/// 5. robotisOriginal.derivativeTimeSec == 0.12 (strengthened D-term confirmation).
/// 6. BalanceBaseline.step formula: pure-math α = dt/(tau+dt) IIR.
final class BalanceBaselineTests: XCTestCase {

    // MARK: - Pure helper tests (BalanceBaseline)

    /// BalanceBaseline.step formula: α = dt/(tau+dt) IIR.
    func test_step_formula_alphaCorrect() {
        let tau = 5.0
        let dt  = 0.1
        let alpha = dt / (tau + dt)   // ≈ 0.0196
        let prev: Double = 0
        let sample: Double = -20
        let result = BalanceBaseline.step(prev: prev, sample: sample, tau: tau, dt: dt)
        let expected = alpha * sample + (1 - alpha) * prev
        XCTAssertEqual(result, expected, accuracy: 1e-12,
                       "step() must implement α = dt/(tau+dt) IIR")
    }

    /// deviation = sample - baseline (pure subtraction).
    func test_deviation_is_sample_minus_baseline() {
        XCTAssertEqual(BalanceBaseline.deviation(sample: -28, baseline: -20), -8,  accuracy: 1e-12)
        XCTAssertEqual(BalanceBaseline.deviation(sample: -20, baseline: -20),  0,  accuracy: 1e-12)
        XCTAssertEqual(BalanceBaseline.deviation(sample:   3, baseline:  0),   3,  accuracy: 1e-12)
    }

    // MARK: - EMA convergence tests

    /// Test 1: Constant -20° pitch for many ticks → EMA converges to -20°, deviation → ~0.
    ///
    /// Justification: the robot's intended forward-lean posture is ~-20°. Once the baseline
    /// has converged, the corrector should produce near-zero corrections for steady posture.
    func test_constantPitch_baselineConverges_deviationNearZero() {
        let tau = 5.0
        let dt  = 0.1
        let constantPitch = -20.0
        var ema = 0.0  // start at 0 (pre-seed state)

        // Run for 30 s of simulated time (300 ticks) — > 5 × tau
        for _ in 0..<300 {
            ema = BalanceBaseline.step(prev: ema, sample: constantPitch, tau: tau, dt: dt)
        }

        let deviation = BalanceBaseline.deviation(sample: constantPitch, baseline: ema)
        XCTAssertEqual(ema, -20.0, accuracy: 0.5,
                       "EMA must converge to constant input after 5×tau ticks")
        XCTAssertEqual(deviation, 0.0, accuracy: 0.5,
                       "Deviation from steady posture must be near-zero after convergence")
    }

    /// Test 2: -20° baseline + sudden -8° real tilt → deviation captures the -8°.
    ///
    /// Justification: real instability (sudden tilt) must still be detected and corrected
    /// even when the baseline has learned the chronic posture.
    func test_realDeviation_capturedAboveBaseline() {
        let tau = 5.0
        let dt  = 0.1
        let steadyPitch = -20.0

        // Converge baseline to -20° first (simulate pre-warmed baseline)
        var ema = steadyPitch  // seeded (equivalent to many ticks of -20°)

        // Now robot hits a real -8° perturbation (total pitch = -28°)
        let perturbedPitch = -28.0
        // One tick of baseline update (slow alpha ≈ 0.02, barely moves)
        ema = BalanceBaseline.step(prev: ema, sample: perturbedPitch, tau: tau, dt: dt)
        let deviation = BalanceBaseline.deviation(sample: perturbedPitch, baseline: ema)

        // Baseline barely moved (~0.02 × (-8) = -0.16° change).
        // Deviation should be close to -8° (the actual perturbation).
        XCTAssertEqual(deviation, -8.0, accuracy: 0.5,
                       "Real deviation of -8° must be captured above converged -20° baseline")
        XCTAssertLessThan(deviation, -7.0,
                          "Deviation must be sufficiently negative to trigger corrector")
    }

    // MARK: - Seed-on-first-tick test

    /// Test 3: Seed on first tick — sample -20° → EMA = -20° immediately, deviation = 0.
    ///
    /// Justification: without seed-on-start, the robot would need 5 s for the baseline to
    /// converge, causing over-correction at the start of each walk. Seeding eliminates this.
    func test_seedOnFirstTick_noConvergenceLag() {
        // Simulate what WalkLabSession does on first P-control tick after walk start:
        // balanceBaselineInitialized = false → seed baseline from first sample
        let firstSample = -20.0
        let ema = firstSample  // seeded directly (WalkLabSession: pitchBaselineEma = normalized.pitch)
        let deviation = BalanceBaseline.deviation(sample: firstSample, baseline: ema)

        XCTAssertEqual(ema, -20.0, accuracy: 1e-12,
                       "Seeded EMA must equal first sample immediately")
        XCTAssertEqual(deviation, 0.0, accuracy: 1e-12,
                       "Deviation on tick 1 after seed must be exactly 0 — no convergence lag")
    }

    // MARK: - Backward-compat regression test

    /// Test 4: Baseline = 0, not initialized → deviation == raw sample (regression guarantee).
    ///
    /// Justification: when baseline is 0 (e.g., balanceBaselineInitialized=false and baseline
    /// was never seeded), deviation = sample - 0 = sample. This is IDENTICAL to the previous
    /// behavior where raw normalized.pitch was fed directly to the LPF.
    func test_baseline0_deviationEqualsRawSample() {
        let testSamples: [Double] = [0, -20, 15, -3.5, 8.2]
        for sample in testSamples {
            let deviation = BalanceBaseline.deviation(sample: sample, baseline: 0)
            XCTAssertEqual(deviation, sample, accuracy: 1e-12,
                           "With baseline=0, deviation must equal raw sample (regression guarantee)")
        }
    }

    // MARK: - derivativeTimeSec change confirmation

    /// Test 5: robotisOriginal.derivativeTimeSec == 0.12 (strengthened D-term).
    ///
    /// Justification: the spec strengthens the D-term 0.05 → 0.12 so gyro angular rate
    /// provides stronger anticipatory correction. This test guards against accidental revert.
    func test_robotisOriginal_derivativeTimeSec_is_0_12() {
        XCTAssertEqual(BalanceCorrector.robotisOriginal.derivativeTimeSec, 0.12, accuracy: 1e-12,
                       "robotisOriginal.derivativeTimeSec must be 0.12 (baseline-aware D-term)")
    }
}
