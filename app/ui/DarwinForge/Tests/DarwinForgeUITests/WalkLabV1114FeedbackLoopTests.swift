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

        var deltas = WalkLabSession.ExperimentDeltas()
        deltas.hipPitchOffsetTrimDeg = 12.0
        let result = session.applyExperimentChange(
            experimentId: "exp-test",
            baselineSessionId: "base-1",
            proposedConfig: safeConfig,
            deltas: deltas
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

        var deltas = WalkLabSession.ExperimentDeltas()
        deltas.hipPitchOffsetTrimDeg = 99.0
        let result = session.applyExperimentChange(
            experimentId: "exp-bad",
            baselineSessionId: "base-1",
            proposedConfig: blockedConfig,
            deltas: deltas
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

    // MARK: - v1.11.14.1 — activeExperimentId clear + reentry guard + 새 axis

    /// finalize → activeExperimentId/baselineSessionId clear.
    func testFinalizeClearsActiveContext() async {
        let session = WalkLabSession()
        let controller = ExperimentLoopController()
        session.setExperimentLoop(controller)

        let safeConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let response = mockSafeResponse()
        _ = await controller.startExperiment(
            from: response, baselineSessionId: "base-1", proposedConfig: safeConfig
        )
        _ = session.applyExperimentChange(
            experimentId: controller.current?.id ?? "exp-?",
            baselineSessionId: "base-1",
            proposedConfig: safeConfig
        )
        XCTAssertNotNil(session.activeExperimentId)
        XCTAssertNotNil(session.activeBaselineSessionId)

        await controller.finalize()
        // onCleared callback 이 호출되어 activeExperimentId/BaselineSessionId clear.
        XCTAssertNil(session.activeExperimentId)
        XCTAssertNil(session.activeBaselineSessionId)
    }

    /// cancel → activeExperimentId/baselineSessionId clear.
    func testCancelClearsActiveContext() async {
        let session = WalkLabSession()
        let controller = ExperimentLoopController()
        session.setExperimentLoop(controller)

        let safeConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let response = mockSafeResponse()
        _ = await controller.startExperiment(
            from: response, baselineSessionId: "base-1", proposedConfig: safeConfig
        )
        _ = session.applyExperimentChange(
            experimentId: controller.current?.id ?? "exp-?",
            baselineSessionId: "base-1",
            proposedConfig: safeConfig
        )
        XCTAssertNotNil(session.activeExperimentId)

        await controller.cancel()
        XCTAssertNil(session.activeExperimentId)
    }

    /// reentry — 이미 활성 실험 진행 중이면 새 applyExperimentChange reject.
    func testApplyExperimentChangeRejectsReentry() {
        let session = WalkLabSession()
        let safeConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let result1 = session.applyExperimentChange(
            experimentId: "exp-1", baselineSessionId: "base-1",
            proposedConfig: safeConfig
        )
        if case .applied = result1 { /* OK */ }
        else { XCTFail("첫 호출 applied 기대"); return }

        let result2 = session.applyExperimentChange(
            experimentId: "exp-2", baselineSessionId: "base-2",
            proposedConfig: safeConfig
        )
        if case .failed(let reason) = result2 {
            XCTAssertTrue(reason.contains("이미 활성 실험"), "reason: \(reason)")
            XCTAssertEqual(session.activeExperimentId, "exp-1",
                           "이전 실험 ID 유지 (덮어쓰기 X)")
        } else {
            XCTFail("두번째 호출 reject 기대")
        }
    }

    /// tuning slider axis (strideMm) — deltas 로 적용.
    func testApplyExperimentChangeAppliesTuningSliderAxis() {
        let session = WalkLabSession()
        let originalStride = session.strideMm
        let safeConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        var deltas = WalkLabSession.ExperimentDeltas()
        deltas.strideMm = originalStride + 5.0
        _ = session.applyExperimentChange(
            experimentId: "exp-slider", baselineSessionId: "base-1",
            proposedConfig: safeConfig, deltas: deltas
        )
        XCTAssertEqual(session.strideMm, originalStride + 5.0)
    }

    /// customGain axis (customHipRollGain) — deltas 로 적용.
    func testApplyExperimentChangeAppliesCustomGainAxis() {
        let session = WalkLabSession()
        let original = session.customHipRollGain
        let safeConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .custom, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        var deltas = WalkLabSession.ExperimentDeltas()
        deltas.customHipRollGain = original + 0.2
        _ = session.applyExperimentChange(
            experimentId: "exp-cg", baselineSessionId: "base-1",
            proposedConfig: safeConfig, deltas: deltas
        )
        XCTAssertEqual(session.customHipRollGain, original + 0.2, accuracy: 1e-6)
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
