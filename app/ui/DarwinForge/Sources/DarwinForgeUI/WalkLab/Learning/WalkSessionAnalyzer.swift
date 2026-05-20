import Foundation

/// 세션 단일 entry-point — decoder 결과를 받아 quality + metrics + recommendation
/// 을 한 번에 계산해 `WalkSessionSummaryV2` 로 반환.
///
/// caller (UI / 자동 학습) 는 이 함수만 알면 된다.
public enum WalkSessionAnalyzer {

    public static func summarize(session: DecodedWalkSession,
                                 currentIntensityLevel: Int? = nil,
                                 trialPurpose: WalkTrialPurpose? = nil) -> WalkSessionSummaryV2 {
        let quality = WalkSessionQualityAnalyzer.analyze(session: session)
        let metrics = WalkSessionMetricsAnalyzer.analyze(session: session)
        let intensity = currentIntensityLevel
            ?? session.header.intensityLevelAtStart
            ?? 1
        let purpose = trialPurpose
            ?? inferTrialPurpose(from: session)
        let recommendation = WalkSessionRecommender.recommend(
            quality: quality,
            metrics: metrics,
            currentIntensityLevel: intensity,
            trialPurpose: purpose
        )
        return WalkSessionSummaryV2(
            id: session.header.sessionId,
            preset: session.header.preset,
            startTimeIso: session.header.startTimeIso,
            durationSec: quality.durationSec,
            sessionId: session.header.sessionId,
            dataQuality: quality,
            meanRollDeg: metrics.meanRollDeg,
            meanPitchDeg: metrics.meanPitchDeg,
            meanAbsRollDeg: metrics.meanAbsRollDeg,
            meanAbsPitchDeg: metrics.meanAbsPitchDeg,
            peakAbsRollDeg: metrics.peakAbsRollDeg,
            peakAbsPitchDeg: metrics.peakAbsPitchDeg,
            rollStdevDeg: metrics.rollStdevDeg,
            pitchStdevDeg: metrics.pitchStdevDeg,
            pitchBiasDeg: metrics.pitchBiasDeg,
            rollBiasDeg: metrics.rollBiasDeg,
            oscillationPitchHz: metrics.oscillationPitchHz,
            oscillationRollHz: metrics.oscillationRollHz,
            laggedPitchEffectiveness: metrics.laggedPitchEffectiveness,
            laggedRollEffectiveness: metrics.laggedRollEffectiveness,
            bestLagMs: metrics.bestLagMs,
            phaseResidualPitchRms: metrics.phaseResidualPitchRms,
            phaseResidualRollRms: metrics.phaseResidualRollRms,
            recommendation: recommendation
        )
    }

    /// trialPurpose 가 명시 안 됐을 때 header / sample 의 algorithm / apply mode 로 추정.
    static func inferTrialPurpose(from session: DecodedWalkSession) -> WalkTrialPurpose {
        if session.schemaVersion == .v1 {
            return .baselineLegacy
        }
        let mode = session.header.balanceAlgorithmMode ?? ""
        let apply = session.header.correctionApplyMode ?? ""
        let sign = session.header.balanceSignConvention ?? ""
        switch (mode, apply, sign) {
        case ("off", _, _): return .calibrationIdle
        case ("robotisPControl", _, _): return .robotisPControl
        case ("hybridBA", "observeOnly", _): return .hybridObserveOnly
        case ("hybridBA", "robotApplied", _): return .hybridApplied
        case (_, "observeOnly", "alternateDiagnostic"): return .signDiagnosticObserveOnly
        case (_, "robotApplied", "alternateDiagnostic"): return .signDiagnosticApplied
        case ("observeOnly", _, _): return .hybridObserveOnly
        default: return .unknown
        }
    }
}
