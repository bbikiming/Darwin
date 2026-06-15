import Foundation

/// **v1.9 (2026-05-17)**: 종료된 보행 session 의 sample 배열을 분석하여
/// 안정성 metric + 자동 튜닝 권고를 산출.
///
/// **알고리즘** (NN/g + control theory inspired):
///
/// 1. **평균 |tilt|** — 작을수록 안정. 회복 능력 평가.
/// 2. **Oscillation score** — corrector delta 의 zero-crossing rate (Hz).
///    높으면 corrector 가 진동 — gain 과잉 또는 phase 오류 의심.
/// 3. **Corrector 효과 score (correlation)** — corrector delta vs IMU tilt 의 음의 상관계수.
///    +1 = 완벽 회복 (corrector 가 tilt 정 반대), 0 = 무관, -1 = fall 가속 (같은 부호).
/// 4. **권고 logic**:
///    - oscillation 높음 + |tilt| 낮음 → intensity 한 단계 낮춤 (over-correction)
///    - oscillation 낮음 + |tilt| 큼 → intensity 한 단계 올림 (under-correction)
///    - correlation 음수 → 부호 / phase 문제, level 자동 0 권고 (사용자 점검)
///    - 둘 다 적절 → 유지
public enum WalkSessionAnalyzer {

    /// 분석 임계 — config 화 가능.
    public static let oscillationHighHz: Double = 4.0   // 4Hz 이상 = over-correction.
    public static let tiltHighDeg: Double = 12.0        // |mean tilt| 가 12° 이상 = under-correction.
    public static let tiltLowDeg: Double = 4.0          // 4° 이하 = 안정.
    public static let correlationNegativeThreshold: Double = -0.3  // 명백한 fall 가속.
    public static let minSampleCountForRecommendation: Int = 60   // 3초 @ 20Hz.

    // **데이터 기반 자동 튜닝 (2026-05-30)**: 안정성 파라미터 권고 임계.
    /// corrector pitch 오차 평균이 이 값 초과 + 동적 변동보다 크면 baseline 미추종 → tau 하향.
    public static let correctorErrHighDeg: Double = 8.0
    /// caution 이상 상태 비율이 이 값 초과면 불안정 corroboration (D항 상향 게이트).
    public static let cautionElevatedRatio: Double = 0.10

    /// **v1.11.10 (2026-05-19)** — header 받아서 V2 metric 모두 산출.
    /// header 없으면 backward-compat path (V1).
    public static func analyze(_ samples: [WalkSessionSample],
                                preset: String,
                                startTime: Date,
                                durationSec: Double,
                                intensityLevelUsed: Int,
                                header: WalkSessionHeader? = nil,
                                // **데이터 기반 자동 튜닝 (2026-05-30)**: 권고 방향 산출 기준.
                                // 기본값 = 현행 default (legacy caller 무영향).
                                derivativeTimeSecUsed: Double = 0.12,
                                baselineTauSecUsed: Double = 5.0) -> WalkSessionSummary {
        guard !samples.isEmpty else {
            return emptySummary(preset: preset,
                                startTime: startTime,
                                durationSec: durationSec,
                                intensityLevelUsed: intensityLevelUsed)
        }

        // 1. tilt statistics.
        let rolls = samples.map { abs($0.imuRollDeg) }
        let pitches = samples.map { abs($0.imuPitchDeg) }
        let meanAbsRoll = rolls.reduce(0, +) / Double(rolls.count)
        let meanAbsPitch = pitches.reduce(0, +) / Double(pitches.count)
        let peakAbsRoll = rolls.max() ?? 0
        let peakAbsPitch = pitches.max() ?? 0
        let rollStdev = stdev(samples.map { $0.imuRollDeg })
        let pitchStdev = stdev(samples.map { $0.imuPitchDeg })

        // 2. oscillation score — corrector delta zero-crossing rate.
        // R hipRoll (index 0) 기준 — lateral 보정의 진동 직접 측정.
        let hipRollDeltas = samples.compactMap { $0.correctorDeltas.first }
        let zeroCrossings = countZeroCrossings(hipRollDeltas)
        let oscillationScore: Double = durationSec > 0 ? Double(zeroCrossings) / durationSec : 0

        // 3. corrector effectiveness — correlation(-imu_roll, hip_roll_delta).
        // 회복 작동 시: tilt + 이면 delta - → 둘이 음의 관계 → -correlation > 0.
        let effectiveness = correlation(
            samples.map { $0.imuRollDeg },
            samples.map { -($0.correctorDeltas.first ?? 0) }
        )

        // 4. 권고 logic.
        let (recommended, reason, confidence) = recommend(
            current: intensityLevelUsed,
            meanTilt: max(meanAbsRoll, meanAbsPitch),
            oscillation: oscillationScore,
            correlation: effectiveness,
            sampleCount: samples.count
        )

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // **v1.11.10**: V2 metric 산출.
        // header 없으면 quality / sagittal / candidateApplied 모두 nil (legacy compat).
        let quality: DataQualityReport? = header.map { h in
            DataQualityReport.compute(samples: samples, header: h, durationSec: durationSec)
        }
        let sagittal = SagittalMetric.compute(samples: samples, durationSec: durationSec)
        let candidateApplied = CandidateAppliedSplit.compute(samples: samples)

        // **데이터 기반 자동 튜닝 (2026-05-30)**: 균형 안정성 파라미터(tau/D항) 권고.
        // corrector pitch 오차(baseline 차감 후)·caution 비율은 별도 신호.
        let meanAbsCorrectorPitchErr = samples.map { abs($0.correctorPitchErrDeg) }
            .reduce(0, +) / Double(samples.count)
        let cautionCount = samples.filter { $0.balanceState != "normal" }.count
        let cautionRatio = Double(cautionCount) / Double(samples.count)
        let dTermRec = recommendDerivativeTimeSec(
            current: derivativeTimeSecUsed,
            meanTilt: max(meanAbsRoll, meanAbsPitch),
            oscillation: oscillationScore,
            correlation: effectiveness,
            cautionRatio: cautionRatio,
            sampleCount: samples.count
        )
        let tauRec = recommendBaselineTauSec(
            current: baselineTauSecUsed,
            meanAbsCorrectorPitchErr: meanAbsCorrectorPitchErr,
            pitchStdev: pitchStdev,
            sampleCount: samples.count
        )
        let dChanged = abs(dTermRec.value - derivativeTimeSecUsed) > 1e-9
        let tauChanged = abs(tauRec.value - baselineTauSecUsed) > 1e-9
        var stabilityConfidence: Double = (dChanged || tauChanged)
            ? max(dChanged ? dTermRec.confidence : 0, tauChanged ? tauRec.confidence : 0)
            : min(dTermRec.confidence, tauRec.confidence)
        let stabilityReason = "D항: \(dTermRec.reason) │ tau: \(tauRec.reason) │ caution \(Int((cautionRatio * 100).rounded()))%"

        // **v1.11.10**: quality.fail 이면 권고 confidence 강제 0 (재수집 안내).
        var finalReason = reason
        var finalConfidence = confidence
        if let q = quality, q.verdict == .fail {
            finalReason = "데이터 품질 fail — 재수집 권고. 이유: \(q.reasons.prefix(2).joined(separator: ", "))"
            finalConfidence = 0
            stabilityConfidence = 0   // 안정성 권고도 fail 시 차단.
        } else if let q = quality, q.verdict == .weak {
            // weak 면 confidence cap.
            finalConfidence = min(confidence, 0.5)
            stabilityConfidence = min(stabilityConfidence, 0.5)
        }

        return WalkSessionSummary(
            id: isoFormatter.string(from: startTime).replacingOccurrences(of: ":", with: "-"),
            preset: preset,
            startTimeIso: isoFormatter.string(from: startTime),
            durationSec: durationSec,
            sampleCount: samples.count,
            intensityLevelUsed: intensityLevelUsed,
            meanAbsRoll: meanAbsRoll,
            meanAbsPitch: meanAbsPitch,
            rollStdev: rollStdev,
            pitchStdev: pitchStdev,
            peakAbsRoll: peakAbsRoll,
            peakAbsPitch: peakAbsPitch,
            oscillationScore: oscillationScore,
            correctorEffectivenessScore: effectiveness,
            recommendedIntensityLevel: recommended,
            recommendationReason: finalReason,
            confidence: finalConfidence,
            dataQuality: quality,
            sagittal: sagittal,
            candidateApplied: candidateApplied,
            derivativeTimeSecUsed: derivativeTimeSecUsed,
            recommendedDerivativeTimeSec: dTermRec.value,
            baselineTauSecUsed: baselineTauSecUsed,
            recommendedBaselineTauSec: tauRec.value,
            stabilityRecommendationReason: stabilityReason,
            stabilityConfidence: stabilityConfidence,
            cautionRatio: cautionRatio
        )
    }

    // MARK: - 데이터 기반 자동 튜닝 (2026-05-30) — 안정성 파라미터 권고 (pure)

    /// 자이로 D항(lookahead) 권고. 단일 step 보수적 조정.
    /// - 진동 높음 + tilt 낮음 → over-correction → 하향.
    /// - tilt 높음 + 진동 낮음 + 회복 정상(correlation≥0) + caution 상승 → under-correction → 상향.
    /// - correlation 음수(fall 가속) → 상향 금지 (보수적 유지).
    static func recommendDerivativeTimeSec(
        current: Double, meanTilt: Double, oscillation: Double,
        correlation: Double, cautionRatio: Double, sampleCount: Int
    ) -> (value: Double, reason: String, confidence: Double) {
        let step = 0.03, minD = 0.0, maxD = 0.25
        if sampleCount < minSampleCountForRecommendation {
            return (current, "데이터 부족 — D항 유지", 0.0)
        }
        if oscillation > oscillationHighHz && meanTilt < tiltLowDeg && current > minD {
            let v = max(minD, current - step)
            return (v, String(format: "진동 %.1fHz·tilt %.1f° 안정 → D항 %.2f→%.2f 하향(선제 보정 과함)",
                              oscillation, meanTilt, current, v), 0.70)
        }
        if meanTilt > tiltHighDeg && oscillation < oscillationHighHz
            && correlation >= 0 && cautionRatio > cautionElevatedRatio && current < maxD {
            let v = min(maxD, current + step)
            return (v, String(format: "tilt %.1f°(높음)·진동 낮음·caution↑ → D항 %.2f→%.2f 상향(선제 보정 강화)",
                              meanTilt, current, v), 0.65)
        }
        return (current, String(format: "안정(tilt %.1f°, 진동 %.1fHz) → D항 %.2f 유지",
                                meanTilt, oscillation, current), 0.80)
    }

    /// baseline EMA tau 권고. corrector pitch 오차(baseline 차감 후) 평균이 동적 변동보다
    /// 크게 높으면 → 만성 자세 미추종 → tau 하향(학습 가속). 그 외 유지.
    static func recommendBaselineTauSec(
        current: Double, meanAbsCorrectorPitchErr: Double, pitchStdev: Double, sampleCount: Int
    ) -> (value: Double, reason: String, confidence: Double) {
        let step = 1.0, minTau = 2.0
        if sampleCount < minSampleCountForRecommendation {
            return (current, "데이터 부족 — tau 유지", 0.0)
        }
        if meanAbsCorrectorPitchErr > correctorErrHighDeg
            && meanAbsCorrectorPitchErr > pitchStdev * 1.5 && current > minTau {
            let v = max(minTau, current - step)
            return (v, String(format: "corrector pitch 오차 %.1f°>동적 %.1f° → baseline 미추종, tau %.1f→%.1fs 하향",
                              meanAbsCorrectorPitchErr, pitchStdev, current, v), 0.60)
        }
        return (current, String(format: "baseline 추종 양호(오차 %.1f°) → tau %.1fs 유지",
                                meanAbsCorrectorPitchErr, current), 0.75)
    }

    // MARK: - Helpers

    private static func recommend(current: Int,
                                   meanTilt: Double,
                                   oscillation: Double,
                                   correlation: Double,
                                   sampleCount: Int) -> (Int, String, Double) {
        // 데이터 부족 — 유지 + low confidence.
        if sampleCount < minSampleCountForRecommendation {
            return (current, "분석에 충분한 데이터 부족 (3초 이상 보행 필요)", 0.0)
        }
        // 명백한 fall 가속 (correlation 음수 강함) → level 0 권고 (점검).
        if correlation < correlationNegativeThreshold && current > 0 {
            return (0, "자이로 보정이 회복 방향이 아닌 fall 방향 작동 중 — 보정 OFF 권고 (점검 후 재시도)", 0.85)
        }
        // Oscillation 높음 + tilt 낮음 = over-correction.
        if oscillation > oscillationHighHz && meanTilt < tiltLowDeg && current > 0 {
            return (max(0, current - 1),
                    String(format: "진동 %.1fHz 감지 (tilt %.1f° 안정) — 보정 강도 한 단계 낮춤 권고",
                           oscillation, meanTilt),
                    0.75)
        }
        // tilt 높음 + oscillation 낮음 = under-correction.
        if meanTilt > tiltHighDeg && oscillation < oscillationHighHz && current < 4 {
            return (min(4, current + 1),
                    String(format: "평균 기울기 %.1f° (높음) + 진동 낮음 — 보정 강도 한 단계 올림 권고",
                           meanTilt),
                    0.70)
        }
        // 안정 — 유지.
        return (current,
                String(format: "안정적 (평균 tilt %.1f°, 진동 %.1fHz) — 현재 강도 유지",
                       meanTilt, oscillation),
                0.80)
    }

    private static func stdev(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let sumSq = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sumSq / Double(values.count)).squareRoot()
    }

    private static func countZeroCrossings(_ values: [Double]) -> Int {
        guard values.count > 1 else { return 0 }
        var count = 0
        for i in 1..<values.count {
            if (values[i - 1] < 0 && values[i] > 0) || (values[i - 1] > 0 && values[i] < 0) {
                count += 1
            }
        }
        return count
    }

    /// Pearson correlation. 두 array 가 같은 길이 가정.
    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return 0 }
        let aMean = a.prefix(n).reduce(0, +) / Double(n)
        let bMean = b.prefix(n).reduce(0, +) / Double(n)
        var num: Double = 0
        var denA: Double = 0
        var denB: Double = 0
        for i in 0..<n {
            let da = a[i] - aMean
            let db = b[i] - bMean
            num += da * db
            denA += da * da
            denB += db * db
        }
        let den = (denA * denB).squareRoot()
        guard den > 1e-9 else { return 0 }
        return num / den
    }

    private static func emptySummary(preset: String,
                                      startTime: Date,
                                      durationSec: Double,
                                      intensityLevelUsed: Int) -> WalkSessionSummary {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return WalkSessionSummary(
            id: isoFormatter.string(from: startTime).replacingOccurrences(of: ":", with: "-"),
            preset: preset,
            startTimeIso: isoFormatter.string(from: startTime),
            durationSec: durationSec,
            sampleCount: 0,
            intensityLevelUsed: intensityLevelUsed,
            meanAbsRoll: 0, meanAbsPitch: 0,
            rollStdev: 0, pitchStdev: 0,
            peakAbsRoll: 0, peakAbsPitch: 0,
            oscillationScore: 0,
            correctorEffectivenessScore: 0,
            recommendedIntensityLevel: intensityLevelUsed,
            recommendationReason: "데이터 없음",
            confidence: 0
        )
    }
}
