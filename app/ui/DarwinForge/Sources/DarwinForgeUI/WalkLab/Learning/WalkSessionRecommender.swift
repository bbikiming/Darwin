import Foundation

/// 품질 게이트가 적용된 추천 엔진. 핵심 규칙:
/// - low quality (D/F/inconclusive) 에서는 절대 `raiseIntensity` 추천 금지.
/// - emergency 발생 세션은 항상 `doNotUseForLearning`.
/// - bias bound only 에서는 `keepCurrent` 또는 `collectMoreData` 만 허용.
/// - lagged effectiveness 가 음수면 sign suspicious (단 한 세션으로 확정 금지).
public enum WalkSessionRecommender {

    public static func recommend(quality: WalkSessionDataQuality,
                                 metrics: WalkSessionMetricsAnalyzer.Metrics,
                                 currentIntensityLevel: Int,
                                 trialPurpose: WalkTrialPurpose = .unknown) -> WalkSessionRecommendation {
        // 1) emergency / rejected → 학습 제외.
        if quality.emergencyCount > 0 {
            return WalkSessionRecommendation(
                action: .doNotUseForLearning,
                confidence: 1.0,
                reason: "비상 정지 발생 — 자동 학습/추천에 사용하지 않습니다.",
                recommendedIntensityLevel: currentIntensityLevel,
                trialPurpose: .safetyIncident
            )
        }
        switch quality.useClass {
        case .rejected:
            return WalkSessionRecommendation(
                action: .doNotUseForLearning,
                confidence: 1.0,
                reason: "데이터 품질 \(quality.grade.rawValue) — 분석에서 제외합니다.",
                recommendedIntensityLevel: currentIntensityLevel,
                trialPurpose: trialPurpose
            )
        case .inconclusive:
            return WalkSessionRecommendation(
                action: .collectMoreData,
                confidence: 0.4,
                reason: "독립 IMU 샘플 또는 보행 시간이 부족합니다 — 같은 조건에서 더 길게 측정하세요.",
                recommendedIntensityLevel: currentIntensityLevel,
                trialPurpose: trialPurpose
            )
        case .usableForSafetyReview:
            return WalkSessionRecommendation(
                action: .doNotUseForLearning,
                confidence: 0.8,
                reason: "안전 사고 / 비상 이벤트 발생 — 안전 검토에만 사용합니다.",
                recommendedIntensityLevel: currentIntensityLevel,
                trialPurpose: .safetyIncident
            )
        case .usableForBiasOnly:
            // C 등급 — bias 만 확인. intensity 조정 금지.
            let absBiasPitch = abs(metrics.pitchBiasDeg)
            if absBiasPitch > 5 {
                return WalkSessionRecommendation(
                    action: .keepCurrent,
                    confidence: 0.5,
                    reason: "만성 pitch bias \(format(metrics.pitchBiasDeg))° 확인 — 보정 강도 조정은 더 좋은 데이터가 필요합니다.",
                    recommendedIntensityLevel: currentIntensityLevel,
                    trialPurpose: trialPurpose
                )
            }
            return WalkSessionRecommendation(
                action: .keepCurrent,
                confidence: 0.4,
                reason: "기울기 평균값 확인만 가능 — 알고리즘 비교는 보류합니다.",
                recommendedIntensityLevel: currentIntensityLevel,
                trialPurpose: trialPurpose
            )
        case .usableForComparison:
            return recommendForComparison(quality: quality,
                                           metrics: metrics,
                                           currentIntensityLevel: currentIntensityLevel,
                                           trialPurpose: trialPurpose)
        }
    }

    static func recommendForComparison(quality: WalkSessionDataQuality,
                                       metrics: WalkSessionMetricsAnalyzer.Metrics,
                                       currentIntensityLevel: Int,
                                       trialPurpose: WalkTrialPurpose) -> WalkSessionRecommendation {
        // sign suspicious 판정: lagged effectiveness 가 -0.3 이하.
        let signEffPitch = metrics.laggedPitchEffectiveness ?? 0
        let signEffRoll = metrics.laggedRollEffectiveness ?? 0
        if signEffPitch < -0.3 || signEffRoll < -0.3 {
            return WalkSessionRecommendation(
                action: .markSignSuspicious,
                confidence: 0.6,
                reason: "보정 후 tilt 가 오히려 증가하는 경향 — 부호 의심. 같은 조건에서 2-3회 추가 검증이 필요합니다.",
                recommendedIntensityLevel: currentIntensityLevel,
                trialPurpose: trialPurpose
            )
        }

        // 평균 abs tilt 가 크고 lagged effectiveness 가 양수 → 보정 강도 한 단계 올림.
        let avgAbs = (metrics.meanAbsRollDeg + metrics.meanAbsPitchDeg) / 2.0
        let positiveEffect = (signEffPitch > 0.3) || (signEffRoll > 0.3)
        let cleanQuality = quality.staleRatio < 0.10 && quality.imuDuplicateRatio < 0.40

        if avgAbs > 12, positiveEffect, cleanQuality, currentIntensityLevel < 3 {
            return WalkSessionRecommendation(
                action: .raiseIntensity,
                confidence: 0.7,
                reason: "평균 기울기 \(format(avgAbs))° + 보정 회복 신호 양수 — 한 단계 올림 권고.",
                recommendedIntensityLevel: currentIntensityLevel + 1,
                trialPurpose: trialPurpose
            )
        }

        // 진동이 큰데 boost 보정 들어가면 더 흔들릴 수 있음 → 한 단계 내림.
        let highOscillation = max(metrics.oscillationPitchHz, metrics.oscillationRollHz) > 2.5
        if highOscillation, currentIntensityLevel > 1 {
            return WalkSessionRecommendation(
                action: .lowerIntensity,
                confidence: 0.6,
                reason: "진동 \(format(max(metrics.oscillationPitchHz, metrics.oscillationRollHz)))Hz 가 높음 — 한 단계 내림 권고.",
                recommendedIntensityLevel: currentIntensityLevel - 1,
                trialPurpose: trialPurpose
            )
        }

        return WalkSessionRecommendation(
            action: .keepCurrent,
            confidence: 0.7,
            reason: "현재 설정에서 보정 신호가 안정적입니다.",
            recommendedIntensityLevel: currentIntensityLevel,
            trialPurpose: trialPurpose
        )
    }

    static func format(_ x: Double) -> String { String(format: "%.1f", x) }
}
