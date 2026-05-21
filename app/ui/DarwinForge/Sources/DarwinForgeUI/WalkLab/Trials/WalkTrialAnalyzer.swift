import Foundation

/// **v1.15.0 (2026-05-21) — Phase 1 분석 엔진**.
///
/// `WalkTrialAnalyzer` 는 trial 의 `outcome` 을 계산하는 **순수 함수** 컬렉션입니다.
/// 입력: trial 의 시계열 source (`WalkSessionSample` 배열 + start/end metadata).
/// 출력: `TrialOutcome` (정량 metric).
///
/// # 설계 원칙
///
/// 1. **순수 함수**: 모든 메서드 `static`, 입력 → 출력만. 부작용 / 외부 상태 X.
/// 2. **테스트 친화**: 각 metric 을 개별 함수로 노출, edge case (빈 배열, sample 1개 등) 명시.
/// 3. **0..1 정규화**: 3 핵심 metric (stability/smoothness/energy) 모두 0..1.
/// 4. **가중 평균**: overallScore = 0.5 × stability + 0.3 × smoothness + 0.2 × energy.
///
/// # 비유
///
/// 운동 선수의 한 경기 분석가 — 점수 (안정성/부드러움/체력) 를 매기지만 채점만 하고 선수는
/// 안 만들고 추천도 안 함. 추천은 `MotionRecommender` (Phase 2) 가 N trial 의 분석 결과를
/// 모아서 판단.
public enum WalkTrialAnalyzer {

    // MARK: - Public entry — 모든 metric 한 번에

    /// trial 의 시계열에서 `TrialOutcome` 계산. 메인 API.
    ///
    /// - Parameters:
    ///   - samples: `WalkSessionSample` 배열 (시계열, 시작 → 종료).
    ///   - endReason: trial 종료 사유 — stability 계산에 반영.
    ///   - durationSec: trial 지속 시간.
    ///   - stepsExecuted: motor write step count (footer 기반).
    /// - Returns: TrialOutcome (모든 metric).
    public static func analyze(
        samples: [WalkSessionSample],
        endReason: EndReason,
        durationSec: Double,
        stepsExecuted: Int,
        busWriteFailures: Int
    ) -> TrialOutcome {
        let stateDistribution = balanceStateDistribution(samples: samples)
        let fallEventCount = countFallEvents(samples: samples)
        let meanTimeBetweenFalls = computeMeanTimeBetweenFalls(samples: samples, fallEventCount: fallEventCount, durationSec: durationSec)
        let (peakRoll, peakPitch, meanRoll, meanPitch) = imuStats(samples: samples)
        let peakTemp = peakMotorTemp(samples: samples)

        let stability = stabilityScore(
            stateDistribution: stateDistribution,
            fallEventCount: fallEventCount,
            endReason: endReason
        )
        let smoothness = smoothnessScore(samples: samples)
        let energy = energyScore(
            peakMotorTempC: peakTemp,
            stepsExecuted: stepsExecuted,
            durationSec: durationSec
        )
        let overall = weightedOverall(stability: stability, smoothness: smoothness, energy: energy)

        return TrialOutcome(
            stabilityScore: stability,
            smoothnessScore: smoothness,
            energyScore: energy,
            overallScore: overall,
            stateDistribution: stateDistribution,
            fallEventCount: fallEventCount,
            meanTimeBetweenFallsSec: meanTimeBetweenFalls,
            peakAbsRollDeg: peakRoll,
            peakAbsPitchDeg: peakPitch,
            meanAbsRollDeg: meanRoll,
            meanAbsPitchDeg: meanPitch,
            peakMotorTempC: peakTemp,
            busWriteFailures: busWriteFailures,
            stepsExecuted: stepsExecuted,
            sampleCount: samples.count
        )
    }

    // MARK: - 개별 metric 함수 (테스트 단위)

    /// BalanceState 분포 — 5 state 각 비율 (합=1.0). 빈 배열 → 모두 0 (sum=0 invariant 깨짐 명시).
    public static func balanceStateDistribution(samples: [WalkSessionSample]) -> [String: Double] {
        guard !samples.isEmpty else {
            return ["normal": 0, "caution": 0, "warning": 0, "danger": 0, "emergency": 0]
        }
        var counts: [String: Int] = [:]
        for s in samples {
            counts[s.balanceState, default: 0] += 1
        }
        let total = Double(samples.count)
        var dist: [String: Double] = [:]
        for state in ["normal", "caution", "warning", "danger", "emergency"] {
            dist[state] = Double(counts[state] ?? 0) / total
        }
        return dist
    }

    /// fall event 수 — fallRecommendEmergency=true 인 sample 의 group count.
    /// 연속된 true 는 1건으로 묶음 (false → true transition 만 count).
    public static func countFallEvents(samples: [WalkSessionSample]) -> Int {
        var count = 0
        var lastWasFall = false
        for s in samples {
            let isFall = s.fallRecommendEmergency ?? false
            if isFall && !lastWasFall {
                count += 1
            }
            lastWasFall = isFall
        }
        return count
    }

    /// fall event 사이 평균 시간 (초). fall 0 또는 1건이면 nil (의미 없음).
    public static func computeMeanTimeBetweenFalls(
        samples: [WalkSessionSample],
        fallEventCount: Int,
        durationSec: Double
    ) -> Double? {
        guard fallEventCount >= 2, durationSec > 0 else { return nil }
        return durationSec / Double(fallEventCount - 1)
    }

    /// IMU statistics — peak/mean abs roll & pitch (deg).
    public static func imuStats(samples: [WalkSessionSample]) -> (peakRoll: Double, peakPitch: Double, meanRoll: Double, meanPitch: Double) {
        guard !samples.isEmpty else { return (0, 0, 0, 0) }
        var peakRoll = 0.0, peakPitch = 0.0
        var sumRoll = 0.0, sumPitch = 0.0
        for s in samples {
            let r = abs(s.imuRollDeg), p = abs(s.imuPitchDeg)
            if r > peakRoll { peakRoll = r }
            if p > peakPitch { peakPitch = p }
            sumRoll += r
            sumPitch += p
        }
        let n = Double(samples.count)
        return (peakRoll, peakPitch, sumRoll / n, sumPitch / n)
    }

    /// peak motor temp (°C). nil sample 은 skip. 빈 배열 또는 모두 nil → 0.
    public static func peakMotorTemp(samples: [WalkSessionSample]) -> Double {
        var peak = 0.0
        for s in samples {
            if let t = s.motorAvgTemp, t > peak {
                peak = t
            }
        }
        return peak
    }

    // MARK: - 3 핵심 score (0..1)

    /// **Stability score** — BalanceState 분포 + fall 보정 + endReason 페널티.
    ///
    /// 계산:
    ///   1. weighted distribution: normal × 1.0 + caution × 0.7 + warning × 0.4 + danger × 0.1 + emergency × 0.0
    ///   2. fall penalty: each fall × -0.1 (max -0.5)
    ///   3. endReason penalty: !isSuccess → -0.2
    ///   4. clamp 0..1.
    public static func stabilityScore(
        stateDistribution: [String: Double],
        fallEventCount: Int,
        endReason: EndReason
    ) -> Double {
        let weighted =
            (stateDistribution["normal"] ?? 0) * 1.0 +
            (stateDistribution["caution"] ?? 0) * 0.7 +
            (stateDistribution["warning"] ?? 0) * 0.4 +
            (stateDistribution["danger"] ?? 0) * 0.1 +
            (stateDistribution["emergency"] ?? 0) * 0.0
        let fallPenalty = min(0.5, Double(fallEventCount) * 0.1)
        let reasonPenalty: Double = endReason.isSuccess ? 0 : 0.2
        let raw = weighted - fallPenalty - reasonPenalty
        return max(0, min(1, raw))
    }

    /// **Smoothness score** — IMU 가속도 std-dev 의 역 정규화.
    ///
    /// 작은 std-dev = 부드러움 (좋음). 큰 std-dev = jerky (나쁨).
    /// std-dev 0 → score 1.0, std-dev ≥ 0.5g → score 0.
    /// Linear mapping: score = max(0, 1 - stdDev / 0.5).
    public static func smoothnessScore(samples: [WalkSessionSample]) -> Double {
        // rawAccel{X,Y,Z}G 가 nil 인 sample 은 skip. 모두 nil → score 0.5 (중립).
        let accels = samples.compactMap { s -> Double? in
            guard let x = s.rawAccelXG, let y = s.rawAccelYG, let z = s.rawAccelZG else { return nil }
            // 중력 보정 후 magnitude — z ≈ 1 (중력) → (x, y, z-1) 의 magnitude.
            return sqrt(x * x + y * y + (z - 1) * (z - 1))
        }
        guard accels.count >= 5 else { return 0.5 }  // sample 부족 시 중립.
        let mean = accels.reduce(0, +) / Double(accels.count)
        let variance = accels.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(accels.count)
        let stdDev = sqrt(variance)
        let normalized = 1.0 - (stdDev / 0.5)
        return max(0, min(1, normalized))
    }

    /// **Energy score** — motor temp rise vs step 수.
    ///
    /// 같은 step 수 대비 온도 상승 작을수록 효율 좋음.
    /// rise = peakMotorTempC - 35 (idle baseline).
    /// score = 1 - rise/30. rise ≥ 30°C → 0, rise = 0 → 1.
    /// step 0 인 경우 (실 motor 미작동 sim) → 1.0 (energy 측정 불가, 중립 max).
    public static func energyScore(
        peakMotorTempC: Double,
        stepsExecuted: Int,
        durationSec: Double
    ) -> Double {
        guard stepsExecuted > 0 else { return 1.0 }
        let rise = max(0, peakMotorTempC - 35)
        let normalized = 1.0 - (rise / 30.0)
        return max(0, min(1, normalized))
    }

    /// 3 metric 의 가중 평균. 사용자 ranking 의 기본 key.
    public static func weightedOverall(
        stability: Double,
        smoothness: Double,
        energy: Double
    ) -> Double {
        let raw = stability * 0.5 + smoothness * 0.3 + energy * 0.2
        return max(0, min(1, raw))
    }
}
