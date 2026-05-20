import Foundation

/// 세션 sample 시계열로부터 평균 / std / lagged effectiveness / phase residual 등을
/// 계산. quality analyzer 와 분리 — quality 는 데이터가 쓸 만한지 판단, metrics 는
/// 실제 값.
public enum WalkSessionMetricsAnalyzer {

    public struct Metrics: Sendable, Equatable {
        public let meanRollDeg: Double
        public let meanPitchDeg: Double
        public let meanAbsRollDeg: Double
        public let meanAbsPitchDeg: Double
        public let peakAbsRollDeg: Double
        public let peakAbsPitchDeg: Double
        public let rollStdevDeg: Double
        public let pitchStdevDeg: Double

        public let pitchBiasDeg: Double
        public let rollBiasDeg: Double

        public let oscillationPitchHz: Double
        public let oscillationRollHz: Double

        public let laggedPitchEffectiveness: Double?
        public let laggedRollEffectiveness: Double?
        public let bestLagMs: Double?

        public let phaseResidualPitchRms: Double?
        public let phaseResidualRollRms: Double?
    }

    /// stale / duplicate 가 아닌 sample 만 골라 metric 계산.
    public static func analyze(session: DecodedWalkSession,
                               lagCandidatesMs: [Double] = [100, 150, 200, 250, 300, 400, 500]) -> Metrics {
        // 유효 sample — IMU 값이 있는 것만.
        let valid = session.samples.filter {
            $0.imuRollDeg != nil && $0.imuPitchDeg != nil
        }

        let rolls = valid.compactMap { $0.imuRollDeg }
        let pitches = valid.compactMap { $0.imuPitchDeg }

        let meanRoll = mean(rolls)
        let meanPitch = mean(pitches)
        let meanAbsRoll = mean(rolls.map(abs))
        let meanAbsPitch = mean(pitches.map(abs))
        let peakAbsRoll = rolls.map(abs).max() ?? 0
        let peakAbsPitch = pitches.map(abs).max() ?? 0
        let rollStdev = stdev(rolls, mean: meanRoll)
        let pitchStdev = stdev(pitches, mean: meanPitch)

        // bias 추정 — 단순 평균. 향후 EMA 또는 robust median 으로 교체 가능.
        let pitchBias = meanPitch
        let rollBias = meanRoll

        // oscillation 빈도 — zero-cross rate 기반.
        let duration = WalkSessionQualityAnalyzer.computeDuration(valid)
        let oscPitch = duration > 0 ? Double(zeroCrossings(pitches.map { $0 - meanPitch })) / (2 * duration) : 0
        let oscRoll = duration > 0 ? Double(zeroCrossings(rolls.map { $0 - meanRoll })) / (2 * duration) : 0

        // lagged effectiveness — 보정 delta 의 절댓값 합을 입력, tilt 변화량을 출력으로 본다.
        let (laggedPitch, laggedRoll, bestLagMs) = computeLagged(samples: valid,
                                                                  lagCandidatesMs: lagCandidatesMs)

        // phase residual — walkPhase01 이 있는 v2 sample 에 한해 의미 있음.
        let (phasePitch, phaseRoll) = computePhaseResidual(samples: valid)

        return Metrics(
            meanRollDeg: meanRoll,
            meanPitchDeg: meanPitch,
            meanAbsRollDeg: meanAbsRoll,
            meanAbsPitchDeg: meanAbsPitch,
            peakAbsRollDeg: peakAbsRoll,
            peakAbsPitchDeg: peakAbsPitch,
            rollStdevDeg: rollStdev,
            pitchStdevDeg: pitchStdev,
            pitchBiasDeg: pitchBias,
            rollBiasDeg: rollBias,
            oscillationPitchHz: oscPitch,
            oscillationRollHz: oscRoll,
            laggedPitchEffectiveness: laggedPitch,
            laggedRollEffectiveness: laggedRoll,
            bestLagMs: bestLagMs,
            phaseResidualPitchRms: phasePitch,
            phaseResidualRollRms: phaseRoll
        )
    }

    // MARK: - lagged effectiveness

    /// correction(t) 와 -ΔTilt(t+lag) 의 correlation. 양수면 보정이 회복 방향으로 작용.
    /// stale / duplicate sample 은 제외.
    static func computeLagged(samples: [WalkSessionSampleResolved],
                              lagCandidatesMs: [Double]) -> (Double?, Double?, Double?) {
        // 유효 sample — duplicate / stale 제외.
        let clean = samples.filter { !$0.imuDuplicate && !$0.imuStale }
        guard clean.count >= 8 else { return (nil, nil, nil) }

        let ts = clean.map { $0.tMs }
        let pitches = clean.compactMap { $0.imuPitchDeg }
        let rolls = clean.compactMap { $0.imuRollDeg }
        guard pitches.count == clean.count, rolls.count == clean.count else { return (nil, nil, nil) }

        // correction signal — appliedDeltas (없으면 correctorDeltas) 의 절댓값 합.
        let corrSeries: [Double] = clean.map { s in
            let arr = s.appliedDeltas ?? s.correctorDeltas ?? []
            return arr.map(abs).reduce(0, +)
        }
        guard corrSeries.contains(where: { $0 != 0 }) else { return (nil, nil, nil) }

        // tilt delta — IMU 변화량 = -회복 방향. 입력 = correction signal,
        // 출력 = -(pitch[t+lag] - pitch[t]) → positive 면 회복 방향으로 줄었다는 의미.
        func bestCorrelation(_ tilt: [Double]) -> (bestRho: Double, bestLag: Double)? {
            var bestRho = -2.0
            var bestLag: Double = 0
            for lag in lagCandidatesMs {
                let pairs = lagPairs(times: ts, signal: corrSeries, tilt: tilt, lagMs: lag)
                guard pairs.count >= 8 else { continue }
                let x = pairs.map { $0.0 }
                let y = pairs.map { -1.0 * $0.1 } // negative: correction → tilt 감소가 양수가 되도록
                if let rho = pearson(x: x, y: y), rho > bestRho {
                    bestRho = rho
                    bestLag = lag
                }
            }
            return bestRho > -2.0 ? (bestRho, bestLag) : nil
        }

        // tilt 변화량 자체 (delta)
        let pitchDelta = differences(pitches)
        let rollDelta = differences(rolls)
        // delta sequence length = pitches.count - 1; pair times = ts[0..<n-1].
        var pairedSamples = clean
        if pairedSamples.count > pitchDelta.count {
            pairedSamples.removeLast(pairedSamples.count - pitchDelta.count)
        }
        let pairedTs = pairedSamples.map { $0.tMs }
        let pairedCorr = Array(corrSeries.prefix(pitchDelta.count))

        func bestCorrelationWith(_ tilt: [Double]) -> (Double, Double)? {
            var bestRho = -2.0
            var bestLag: Double = 0
            for lag in lagCandidatesMs {
                let pairs = lagPairs(times: pairedTs, signal: pairedCorr, tilt: tilt, lagMs: lag)
                guard pairs.count >= 8 else { continue }
                let x = pairs.map { $0.0 }
                let y = pairs.map { -1.0 * $0.1 }
                if let rho = pearson(x: x, y: y), rho > bestRho {
                    bestRho = rho
                    bestLag = lag
                }
            }
            return bestRho > -2.0 ? (bestRho, bestLag) : nil
        }

        let pitchResult = bestCorrelationWith(pitchDelta)
        let rollResult = bestCorrelationWith(rollDelta)

        _ = bestCorrelation // satisfy unused — kept for symmetry / future use

        let bestLag = pitchResult?.1 ?? rollResult?.1
        return (pitchResult?.0, rollResult?.0, bestLag)
    }

    /// times (ms) 와 signal/tilt 두 시계열에서 lag 만큼 떨어진 (sig[t], tilt[t+lag]) 쌍을 만든다.
    /// sample 간격이 균일하지 않을 수 있으므로 nearest-time lookup.
    static func lagPairs(times: [Double], signal: [Double], tilt: [Double], lagMs: Double) -> [(Double, Double)] {
        guard times.count == signal.count, times.count == tilt.count, !times.isEmpty else { return [] }
        var pairs: [(Double, Double)] = []
        var j = 0
        for i in 0..<times.count {
            let target = times[i] + lagMs
            while j < times.count - 1 && times[j] < target {
                j += 1
            }
            if abs(times[j] - target) <= 100 { // 100ms tolerance — sample rate 14-25Hz 가정.
                pairs.append((signal[i], tilt[j]))
            }
        }
        return pairs
    }

    static func differences(_ xs: [Double]) -> [Double] {
        guard xs.count > 1 else { return [] }
        return (1..<xs.count).map { xs[$0] - xs[$0 - 1] }
    }

    // MARK: - phase residual

    /// expectedPitch = swayAmp * sin(2π * phase + offset). v2 sample 에 expectedPitchDeg 가
    /// 있으면 그걸 쓰고, 없으면 walkPhase01 을 기반으로 추정. v1 로그는 phase 정보가 없어
    /// nil 반환.
    static func computePhaseResidual(samples: [WalkSessionSampleResolved]) -> (Double?, Double?) {
        let candidates = samples.filter {
            $0.walkPhase01 != nil && $0.imuPitchDeg != nil && $0.imuRollDeg != nil
        }
        guard candidates.count >= 8 else { return (nil, nil) }

        var pitchResiduals: [Double] = []
        var rollResiduals: [Double] = []
        for s in candidates {
            // expectedPitch 가 명시되어 있으면 사용, 없으면 단순 sin model.
            let expectedPitch = s.expectedPitchDeg ?? simpleExpected(phase: s.walkPhase01 ?? 0,
                                                                      amp: 2.0,
                                                                      offsetPhase: 0)
            let expectedRoll = s.expectedRollDeg ?? simpleExpected(phase: s.walkPhase01 ?? 0,
                                                                    amp: 4.0,
                                                                    offsetPhase: .pi / 2)
            let emaP = s.emaPitchDeg ?? 0
            let emaR = s.emaRollDeg ?? 0
            let residP = (s.imuPitchDeg ?? 0) - emaP - expectedPitch
            let residR = (s.imuRollDeg ?? 0) - emaR - expectedRoll
            pitchResiduals.append(residP)
            rollResiduals.append(residR)
        }
        return (rms(pitchResiduals), rms(rollResiduals))
    }

    static func simpleExpected(phase phase01: Double, amp: Double, offsetPhase: Double) -> Double {
        amp * sin(2 * .pi * phase01 + offsetPhase)
    }

    // MARK: - statistical helpers

    static func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return xs.reduce(0, +) / Double(xs.count)
    }

    static func stdev(_ xs: [Double], mean m: Double) -> Double {
        guard xs.count > 1 else { return 0 }
        let s = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (s / Double(xs.count - 1)).squareRoot()
    }

    static func rms(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.reduce(0) { $0 + $1 * $1 }
        return (s / Double(xs.count)).squareRoot()
    }

    static func zeroCrossings(_ xs: [Double]) -> Int {
        guard xs.count >= 2 else { return 0 }
        var count = 0
        for i in 1..<xs.count {
            if (xs[i-1] >= 0 && xs[i] < 0) || (xs[i-1] < 0 && xs[i] >= 0) { count += 1 }
        }
        return count
    }

    /// pearson — std == 0 면 nil 반환.
    static func pearson(x: [Double], y: [Double]) -> Double? {
        guard x.count == y.count, x.count > 1 else { return nil }
        let n = Double(x.count)
        let mx = mean(x)
        let my = mean(y)
        var num: Double = 0
        var dx: Double = 0
        var dy: Double = 0
        for i in 0..<x.count {
            let a = x[i] - mx
            let b = y[i] - my
            num += a * b
            dx += a * a
            dy += b * b
        }
        let denom = (dx * dy).squareRoot()
        guard denom > 0 else { return nil }
        return num / denom
        // n 미사용 경고 회피
        // (n 은 표본수 — 정보 보존 차원에서 남겨둠)
    }
}
