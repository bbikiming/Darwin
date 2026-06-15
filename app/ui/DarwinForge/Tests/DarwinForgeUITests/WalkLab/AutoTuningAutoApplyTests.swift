import XCTest
@testable import DarwinForgeUI

/// **데이터 기반 자동 튜닝 (2026-05-30)**: WalkSessionAutoTuner 안정성 권고 + SIM 자동 적용.
@MainActor
final class AutoTuningAutoTunerTests: XCTestCase {

    /// 안정성 필드를 가진 summary 빌드 (나머지는 안정 기본값).
    private func summary(
        id: String,
        dUsed: Double?, dRec: Double?,
        tauUsed: Double?, tauRec: Double?,
        stabConf: Double?
    ) -> WalkSessionSummary {
        WalkSessionSummary(
            id: id, preset: "slowWalk", startTimeIso: "2026-05-30T00:00:00.000Z",
            durationSec: 10, sampleCount: 200, intensityLevelUsed: 2,
            meanAbsRoll: 3, meanAbsPitch: 3, rollStdev: 2, pitchStdev: 2,
            peakAbsRoll: 5, peakAbsPitch: 5, oscillationScore: 1,
            correctorEffectivenessScore: 0.3,
            recommendedIntensityLevel: 2, recommendationReason: "x", confidence: 0.8,
            derivativeTimeSecUsed: dUsed, recommendedDerivativeTimeSec: dRec,
            baselineTauSecUsed: tauUsed, recommendedBaselineTauSec: tauRec,
            stabilityRecommendationReason: "test", stabilityConfidence: stabConf, cautionRatio: 0.2
        )
    }

    /// D항 변경 권고 + confidence 충분 → pendingStabilityRecommendation 설정.
    func test_record_setsStabilityRecommendation() {
        let t = WalkSessionAutoTuner()
        t.record(summary(id: "s1", dUsed: 0.12, dRec: 0.15, tauUsed: 5.0, tauRec: 5.0, stabConf: 0.7),
                 currentLevel: 2)
        XCTAssertNotNil(t.pendingStabilityRecommendation)
        XCTAssertEqual(t.pendingStabilityRecommendation?.derivativeTimeSec ?? -1, 0.15, accuracy: 1e-12)
    }

    /// confidence < 0.5 → 권고 없음.
    func test_record_lowConfidence_noRecommendation() {
        let t = WalkSessionAutoTuner()
        t.record(summary(id: "s1", dUsed: 0.12, dRec: 0.15, tauUsed: 5.0, tauRec: 5.0, stabConf: 0.3),
                 currentLevel: 2)
        XCTAssertNil(t.pendingStabilityRecommendation)
    }

    /// 변경 없음 (rec == used) → 권고 없음.
    func test_record_noChange_noRecommendation() {
        let t = WalkSessionAutoTuner()
        t.record(summary(id: "s1", dUsed: 0.12, dRec: 0.12, tauUsed: 5.0, tauRec: 5.0, stabConf: 0.8),
                 currentLevel: 2)
        XCTAssertNil(t.pendingStabilityRecommendation)
    }

    /// legacy summary (stability 필드 nil) → 권고 없음 (안전).
    func test_record_legacySummary_noRecommendation() {
        let t = WalkSessionAutoTuner()
        t.record(summary(id: "s1", dUsed: nil, dRec: nil, tauUsed: nil, tauRec: nil, stabConf: nil),
                 currentLevel: 2)
        XCTAssertNil(t.pendingStabilityRecommendation)
    }

    /// 최근 2세션 D항 권고 방향 상·하 혼재 → 보수적 차단 (oscillation 방지).
    func test_record_conflictingDirections_noRecommendation() {
        let t = WalkSessionAutoTuner()
        // 첫 세션: 하향 (0.12→0.09).
        t.record(summary(id: "s1", dUsed: 0.12, dRec: 0.09, tauUsed: 5.0, tauRec: 5.0, stabConf: 0.7),
                 currentLevel: 2)
        // 두 번째 세션: 상향 (0.12→0.15) → 방향 충돌.
        t.record(summary(id: "s2", dUsed: 0.12, dRec: 0.15, tauUsed: 5.0, tauRec: 5.0, stabConf: 0.7),
                 currentLevel: 2)
        XCTAssertNil(t.pendingStabilityRecommendation, "상·하 혼재 → 차단")
    }

    /// stabilityToApply: autoApply OFF → 현재값 유지.
    func test_stabilityToApply_disabled_returnsCurrent() {
        let t = WalkSessionAutoTuner()
        t.autoApplyEnabled = false
        t.record(summary(id: "s1", dUsed: 0.12, dRec: 0.18, tauUsed: 5.0, tauRec: 4.0, stabConf: 0.7),
                 currentLevel: 2)
        let r = t.stabilityToApply(currentDTerm: 0.12, currentTau: 5.0)
        XCTAssertEqual(r.dTerm, 0.12, accuracy: 1e-12)
        XCTAssertEqual(r.tau, 5.0, accuracy: 1e-12)
    }

    /// stabilityToApply: autoApply ON + pending → 권고값 (범위 클램프).
    func test_stabilityToApply_enabled_returnsRecommended() {
        let t = WalkSessionAutoTuner()
        t.autoApplyEnabled = true
        t.record(summary(id: "s1", dUsed: 0.12, dRec: 0.18, tauUsed: 5.0, tauRec: 4.0, stabConf: 0.7),
                 currentLevel: 2)
        let r = t.stabilityToApply(currentDTerm: 0.12, currentTau: 5.0)
        XCTAssertEqual(r.dTerm, 0.18, accuracy: 1e-12)
        XCTAssertEqual(r.tau, 4.0, accuracy: 1e-12)
    }

    /// userOverride → pendingStabilityRecommendation reset.
    func test_userOverride_resetsStabilityRecommendation() {
        let t = WalkSessionAutoTuner()
        t.record(summary(id: "s1", dUsed: 0.12, dRec: 0.15, tauUsed: 5.0, tauRec: 5.0, stabConf: 0.7),
                 currentLevel: 2)
        XCTAssertNotNil(t.pendingStabilityRecommendation)
        t.userOverride()
        XCTAssertNil(t.pendingStabilityRecommendation)
    }
}

#if DEBUG
@testable import ForgeCore

/// **데이터 기반 자동 튜닝 (2026-05-30)**: 세션 SIM 자동 적용 게이트 (robotApplied 차단).
@MainActor
final class AutoTuningSessionGateTests: XCTestCase {

    private func summaryDChange() -> WalkSessionSummary {
        WalkSessionSummary(
            id: "s1", preset: "slowWalk", startTimeIso: "2026-05-30T00:00:00.000Z",
            durationSec: 10, sampleCount: 200, intensityLevelUsed: 2,
            meanAbsRoll: 3, meanAbsPitch: 3, rollStdev: 2, pitchStdev: 2,
            peakAbsRoll: 5, peakAbsPitch: 5, oscillationScore: 1,
            correctorEffectivenessScore: 0.3,
            recommendedIntensityLevel: 2, recommendationReason: "x", confidence: 0.8,
            derivativeTimeSecUsed: 0.12, recommendedDerivativeTimeSec: 0.15,
            baselineTauSecUsed: 5.0, recommendedBaselineTauSec: 5.0,
            stabilityRecommendationReason: "test", stabilityConfidence: 0.7, cautionRatio: 0.2
        )
    }

    /// robotApplied 모드 → 안정성 자동 적용 차단 (derivativeTimeSec 유지).
    func test_swcApplyStability_robotApplied_blocks() {
        let session = WalkLabSession(harness: RecordingHarness())
        let store = ConnectionStore()
        store.bus = MockBus()
        session.attach(store: store)
        session.cradleConfirmed = true
        session.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true)
        XCTAssertEqual(session.correctionApplyMode, "robotApplied", "precondition")

        session.autoTuner.autoApplyEnabled = true
        session.autoTuner.record(summaryDChange(), currentLevel: 2)
        XCTAssertNotNil(session.autoTuner.pendingStabilityRecommendation, "precondition: pending set")

        let before = session.derivativeTimeSec
        session.swcApplyAutoTuningStability()
        XCTAssertEqual(session.derivativeTimeSec, before, accuracy: 1e-12,
            "robotApplied → 자동 변경 차단 (승인 게이트 경유만)")
    }

    /// simOnly 모드 → 안정성 자동 적용 (derivativeTimeSec 권고값 반영).
    func test_swcApplyStability_simOnly_applies() {
        let session = WalkLabSession(harness: RecordingHarness())
        XCTAssertEqual(session.correctionApplyMode, "simOnly", "precondition: bus 없음")
        session.autoTuner.autoApplyEnabled = true
        session.autoTuner.record(summaryDChange(), currentLevel: 2)
        XCTAssertNotNil(session.autoTuner.pendingStabilityRecommendation, "precondition: pending set")

        session.swcApplyAutoTuningStability()
        XCTAssertEqual(session.derivativeTimeSec, 0.15, accuracy: 1e-12,
            "simOnly → 권고 D항 자동 적용")
        // corrector 도 재빌드되어 반영.
        XCTAssertEqual(session.balanceCorrector.derivativeTimeSec, 0.15, accuracy: 1e-12)
    }
}
#endif
