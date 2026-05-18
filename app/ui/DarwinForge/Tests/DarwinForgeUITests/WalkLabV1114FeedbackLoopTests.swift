import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.14 (2026-05-19) — Feedback loop closure 회귀 가드**.
///
/// 진단 문서 6건 fix:
/// - #1 ExperimentApprovalUI 승인 → WalkLabSession.applyExperimentChange 실 호출
/// - #2 buildProposedConfig 가 현재 config 기준 (default 아님)
/// - #3 세션 종료 흐름 → ExperimentLoop 자동 폐루프
/// - #4 compareWithBaseline 다축 metric (roll/stale/bus/abort/sample)
/// - #5 ClaudeCriticResponse.validate(currentConfig:) — forbidden 조합 검증
/// - #6 fake CLI fail fixture 실 테스트 (별도 file)
@MainActor
final class WalkLabV1114FeedbackLoopTests: XCTestCase {

    // MARK: - #1 applyExperimentChange

    /// safetyVerdict.safe → applied + experimentId/baselineSessionId set.
    func testApplyExperimentChangeAppliesConfig() {
        let session = WalkLabSession()
        let safeConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        XCTAssertEqual(safeConfig.safetyVerdict, .safe, "test setup — safe 기대")

        let result = session.applyExperimentChange(
            experimentId: "exp-test",
            baselineSessionId: "base-1",
            proposedConfig: safeConfig,
            proposedHipPitchOffsetTrimDeg: 12.0
        )
        if case .applied = result {
            XCTAssertEqual(session.balanceExperimentConfig.gainProfile, .robotisOriginal)
            XCTAssertEqual(session.hipPitchOffsetTrimDeg, 12.0)
            XCTAssertEqual(session.activeExperimentId, "exp-test")
            XCTAssertEqual(session.activeBaselineSessionId, "base-1")
        } else {
            XCTFail("safe config — applied 기대")
        }
    }

    /// safetyVerdict.blocked → failed + 변경 안 됨.
    func testApplyExperimentChangeRejectsBlocked() {
        let session = WalkLabSession()
        let originalConfig = session.balanceExperimentConfig
        let originalTrim = session.hipPitchOffsetTrimDeg

        let blockedConfig = BalanceExperimentConfig(
            algorithmMode: .hybridBA,
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,
            applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        if case .blocked = blockedConfig.safetyVerdict { /* OK */ }
        else { XCTFail("test setup — blocked 기대"); return }

        let result = session.applyExperimentChange(
            experimentId: "exp-bad",
            baselineSessionId: "base-1",
            proposedConfig: blockedConfig,
            proposedHipPitchOffsetTrimDeg: 99.0
        )
        if case .failed(let reason) = result {
            XCTAssertTrue(reason.contains("blocked"), "reason: \(reason)")
            // config 와 trim 모두 미변경.
            XCTAssertEqual(session.balanceExperimentConfig.algorithmMode,
                           originalConfig.algorithmMode)
            XCTAssertEqual(session.hipPitchOffsetTrimDeg, originalTrim)
            XCTAssertNil(session.activeExperimentId)
        } else {
            XCTFail("blocked — failed 기대")
        }
    }

    // MARK: - #4 compareWithBaseline 다축 metric

    /// abort-like (sample ratio < 0.7) → failRollback.
    func testCompareWithBaselineAbortLike() async {
        let loop = ExperimentLoopController()
        let response = mockSafeResponse()
        let proposedConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let ok = await loop.startExperiment(
            from: response, baselineSessionId: "base-1", proposedConfig: proposedConfig
        )
        XCTAssertTrue(ok)

        let baseline = mockSummary(id: "base-1", sampleCount: 300, meanPitch: 13, peakPitch: 25)
        let exp = [mockSummary(id: "e1", sampleCount: 100, meanPitch: 13, peakPitch: 25)]
        // sampleRatio = 100/300 ≈ 0.33 < 0.7 → abort-like → failRollback.
        await loop.compareWithBaseline(
            baselineSummary: baseline, experimentSummaries: exp
        )
        XCTAssertEqual(loop.lastComparison?.verdict, .failRollback)
        XCTAssertTrue(
            loop.lastComparison?.reason.contains("sampleCount") ?? false,
            "reason: \(loop.lastComparison?.reason ?? "nil")"
        )
    }

    /// peakAbsRoll +10° → failRollback (lateral 악화).
    func testCompareWithBaselineRollDegradation() async {
        let loop = ExperimentLoopController()
        let response = mockSafeResponse()
        let proposedConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        _ = await loop.startExperiment(
            from: response, baselineSessionId: "base-1", proposedConfig: proposedConfig
        )
        let baseline = mockSummary(id: "base-1", peakPitch: 25, peakRoll: 15)
        let exp = [mockSummary(id: "e1", peakPitch: 25, peakRoll: 25)]
        // peakRollDelta = +10 ≥ 8 → failRollback.
        await loop.compareWithBaseline(
            baselineSummary: baseline, experimentSummaries: exp
        )
        XCTAssertEqual(loop.lastComparison?.verdict, .failRollback)
    }

    /// 모든 metric 개선 + 안전 범위 → success.
    func testCompareWithBaselineSuccess() async {
        let loop = ExperimentLoopController()
        let response = mockSafeResponse()
        let proposedConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        _ = await loop.startExperiment(
            from: response, baselineSessionId: "base-1", proposedConfig: proposedConfig
        )
        let baseline = mockSummary(id: "base-1", meanPitch: 15, peakPitch: 28,
                                    meanRoll: 6, peakRoll: 12)
        // 모든 축 개선: pitch -2, roll -1.
        let exp = [mockSummary(id: "e1", meanPitch: 12, peakPitch: 26,
                                meanRoll: 5, peakRoll: 11)]
        await loop.compareWithBaseline(
            baselineSummary: baseline, experimentSummaries: exp
        )
        XCTAssertEqual(loop.lastComparison?.verdict, .success)
    }

    // MARK: - #5 validate(currentConfig:)

    /// 현재 robotisPControl + 제안 hybridBA + applyToRobot=true → forbidden 검출.
    func testValidateCurrentConfigDetectsBlockedCombo() {
        let currentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        // critic 이 algorithmMode → hybridBA 제안. applyToRobot 은 그대로 true → blocked.
        let response = ClaudeCriticResponse(
            summary: "test", sessionsAnalyzed: ["s1"],
            dataQuality: DataQualityVerdict(verdict: .pass, reasons: []),
            diagnosis: [DiagnosisItem(axis: .algorithmMode, severity: .med,
                                      evidence: ["x"], confidence: 0.7)],
            nextExperiment: NextExperiment(
                changeOneAxisOnly: true,
                axis: .algorithmMode,
                from: "robotisPControl", to: "hybridBA",
                preset: "slowWalk", safety: "cradle",
                successMetric: "x", rollbackCondition: "x", riskNote: nil
            ),
            forbiddenChanges: [],
            recommendation: Recommendation(action: .holdAndObserve, requiresHumanApproval: true)
        )
        let result = response.validate(currentConfig: currentConfig)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(
            result.issues.contains { $0.contains("safetyVerdict=blocked") },
            "issues: \(result.issues)"
        )
    }

    /// hipPitchOffsetTrimDeg 변경 폭 > 10° → 위험 경고.
    func testValidateCurrentConfigDetectsLargeTrimChange() {
        let currentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let response = ClaudeCriticResponse(
            summary: "test", sessionsAnalyzed: ["s1"],
            dataQuality: DataQualityVerdict(verdict: .pass, reasons: []),
            diagnosis: [DiagnosisItem(axis: .hipPitchOffsetTrimDeg, severity: .med,
                                      evidence: ["x"], confidence: 0.7)],
            nextExperiment: NextExperiment(
                changeOneAxisOnly: true,
                axis: .hipPitchOffsetTrimDeg,
                from: "13", to: "30",  // +17° — large jump
                preset: "slowWalk", safety: "cradle",
                successMetric: "x", rollbackCondition: "x", riskNote: nil
            ),
            forbiddenChanges: [],
            recommendation: Recommendation(action: .holdAndObserve, requiresHumanApproval: true)
        )
        let result = response.validate(currentConfig: currentConfig, currentTrim: 13.0)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(
            result.issues.contains { $0.contains("hipPitchOffsetTrimDeg") },
            "issues: \(result.issues)"
        )
    }

    /// 안전한 axis 변경 (robotisPControl → observeOnly) → 통과.
    func testValidateCurrentConfigPassesSafeChange() {
        let currentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let response = ClaudeCriticResponse(
            summary: "test", sessionsAnalyzed: ["s1"],
            dataQuality: DataQualityVerdict(verdict: .pass, reasons: []),
            diagnosis: [DiagnosisItem(axis: .algorithmMode, severity: .low,
                                      evidence: ["x"], confidence: 0.7)],
            nextExperiment: NextExperiment(
                changeOneAxisOnly: true,
                axis: .algorithmMode,
                from: "robotisPControl", to: "observeOnly",
                preset: "slowWalk", safety: "cradle",
                successMetric: "x", rollbackCondition: "x", riskNote: nil
            ),
            forbiddenChanges: [],
            recommendation: Recommendation(action: .holdAndObserve, requiresHumanApproval: true)
        )
        let result = response.validate(currentConfig: currentConfig)
        XCTAssertTrue(result.passed, "issues: \(result.issues)")
    }

    // MARK: - Helpers

    private func mockSafeResponse() -> ClaudeCriticResponse {
        ClaudeCriticResponse(
            summary: "test", sessionsAnalyzed: ["s1"],
            dataQuality: DataQualityVerdict(verdict: .pass, reasons: []),
            diagnosis: [DiagnosisItem(axis: .hipPitchOffsetTrimDeg, severity: .med,
                                      evidence: ["x"], confidence: 0.7)],
            nextExperiment: NextExperiment(
                changeOneAxisOnly: true,
                axis: .hipPitchOffsetTrimDeg,
                from: "13", to: "8",
                preset: "slowWalk", safety: "cradle",
                successMetric: "x", rollbackCondition: "x", riskNote: nil
            ),
            forbiddenChanges: [],
            recommendation: Recommendation(action: .holdAndObserve, requiresHumanApproval: true)
        )
    }

    private func mockSummary(id: String,
                             sampleCount: Int = 200,
                             meanPitch: Double = 13,
                             peakPitch: Double = 25,
                             meanRoll: Double = 5,
                             peakRoll: Double = 15) -> WalkSessionSummary {
        WalkSessionSummary(
            id: id, preset: "march", startTimeIso: "x",
            durationSec: 10, sampleCount: sampleCount, intensityLevelUsed: 2,
            meanAbsRoll: meanRoll, meanAbsPitch: meanPitch,
            rollStdev: 3, pitchStdev: 4,
            peakAbsRoll: peakRoll, peakAbsPitch: peakPitch,
            oscillationScore: 1.5, correctorEffectivenessScore: 0.3,
            recommendedIntensityLevel: 3, recommendationReason: "test", confidence: 0.7
        )
    }
}
