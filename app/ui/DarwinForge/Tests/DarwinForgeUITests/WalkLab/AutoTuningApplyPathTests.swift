import XCTest
@testable import DarwinForgeUI

/// **데이터 기반 자동 튜닝 (2026-05-30)**: 실 로봇 승인 적용 경로 검증.
///
/// # Coverage (7 tests)
/// 1. ResponseAxis decode — "baselineTauSec"/"derivativeTimeSec" (JSON 계약).
/// 1b. ResponseAxis 미지원 → .unknown (forward-compat).
/// 2. applyExperimentChange — deltas 의 tau/D항이 세션 프로퍼티 + corrector 에 반영 (C1).
/// 3. rollback — 안정성 파라미터 복원 + corrector 재빌드.
/// 4. validateAxisRange — D항/tau 범위 밖 reject, 범위 내 accept.
@MainActor
final class AutoTuningApplyPathTests: XCTestCase {

    private func decodeAxis(_ json: String) throws -> ResponseAxis {
        try JSONDecoder().decode(ResponseAxis.self, from: Data(json.utf8))
    }

    private func safeConfig() -> BalanceExperimentConfig {
        BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
    }

    private func responseWith(axis: ResponseAxis, to: String) -> ClaudeCriticResponse {
        ClaudeCriticResponse(
            summary: "test", sessionsAnalyzed: ["s1"],
            dataQuality: DataQualityVerdict(verdict: .pass, reasons: []),
            diagnosis: [DiagnosisItem(axis: axis, severity: .med, evidence: ["x"], confidence: 0.7)],
            nextExperiment: NextExperiment(
                changeOneAxisOnly: true,
                axis: axis,
                from: "x", to: to,
                preset: "slowWalk", safety: "cradle",
                successMetric: "x", rollbackCondition: "x", riskNote: nil
            ),
            forbiddenChanges: [],
            recommendation: Recommendation(action: .holdAndObserve, requiresHumanApproval: true)
        )
    }

    // MARK: - ResponseAxis decode

    func test_responseAxis_decodesStabilityAxes() throws {
        XCTAssertEqual(try decodeAxis("\"baselineTauSec\""), .baselineTauSec)
        XCTAssertEqual(try decodeAxis("\"derivativeTimeSec\""), .derivativeTimeSec)
    }

    func test_responseAxis_unknownFallback() throws {
        XCTAssertEqual(try decodeAxis("\"nonexistentAxis\""), .unknown)
    }

    // MARK: - applyExperimentChange applies stability params (C1)

    func test_applyExperimentChange_appliesStabilityParams() {
        let session = WalkLabSession()
        var deltas = WalkLabSession.ExperimentDeltas()
        deltas.baselineTauSec = 3.5
        deltas.derivativeTimeSec = 0.18
        let result = session.applyExperimentChange(
            experimentId: "exp-tau",
            baselineSessionId: "base-1",
            proposedConfig: safeConfig(),
            deltas: deltas
        )
        guard case .applied = result else { return XCTFail("safe config — applied 기대") }
        XCTAssertEqual(session.baselineTauSec, 3.5, accuracy: 1e-12)
        XCTAssertEqual(session.derivativeTimeSec, 0.18, accuracy: 1e-12)
        // corrector 재빌드 — 튜닝된 D항이 live 보정 경로에 반영 (C1 보존).
        XCTAssertEqual(session.balanceCorrector.derivativeTimeSec, 0.18, accuracy: 1e-12)
    }

    /// (MEDIUM-1 리뷰) apply 경계 재클램프 — 범위 밖 값이 live corrector 에 도달 불가.
    func test_applyExperimentChange_clampsOutOfRange() {
        let session = WalkLabSession()
        var deltas = WalkLabSession.ExperimentDeltas()
        deltas.derivativeTimeSec = 0.5   // > 0.25 max
        deltas.baselineTauSec = 15.0     // > 10 max
        _ = session.applyExperimentChange(
            experimentId: "e", baselineSessionId: "b",
            proposedConfig: safeConfig(), deltas: deltas)
        XCTAssertEqual(session.derivativeTimeSec, 0.25, accuracy: 1e-12, "D항 상한 0.25 클램프")
        XCTAssertEqual(session.baselineTauSec, 10.0, accuracy: 1e-12, "tau 상한 10 클램프")
    }

    // MARK: - rollback restores stability params

    func test_rollback_restoresStabilityParams() {
        let session = WalkLabSession()
        let origTau = session.baselineTauSec       // 5.0
        let origDTerm = session.derivativeTimeSec   // 0.12
        var deltas = WalkLabSession.ExperimentDeltas()
        deltas.baselineTauSec = 7.0
        deltas.derivativeTimeSec = 0.20
        _ = session.applyExperimentChange(
            experimentId: "exp-roll",
            baselineSessionId: "base-1",
            proposedConfig: safeConfig(),
            deltas: deltas
        )
        XCTAssertEqual(session.derivativeTimeSec, 0.20, accuracy: 1e-12, "applied first")
        XCTAssertTrue(session.rollbackExperiment())
        XCTAssertEqual(session.baselineTauSec, origTau, accuracy: 1e-12, "rollback restores tau")
        XCTAssertEqual(session.derivativeTimeSec, origDTerm, accuracy: 1e-12, "rollback restores D-term")
        XCTAssertEqual(session.balanceCorrector.derivativeTimeSec, origDTerm, accuracy: 1e-12,
            "rollback rebuilds corrector to restored D-term")
    }

    // MARK: - validateAxisRange (안전 범위)

    func test_validateAxisRange_rejectsDTermOutOfRange() {
        // D항 0.5 > 0.25 max → issue.
        let v = responseWith(axis: .derivativeTimeSec, to: "0.5").validate(currentConfig: safeConfig())
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.issues.contains { $0.contains("D항") }, "issues: \(v.issues)")
    }

    func test_validateAxisRange_rejectsTauOutOfRange() {
        // tau 15 > 10 max → issue.
        let v = responseWith(axis: .baselineTauSec, to: "15").validate(currentConfig: safeConfig())
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.issues.contains { $0.contains("tau") }, "issues: \(v.issues)")
    }

    func test_validateAxisRange_acceptsInRange() {
        let v = responseWith(axis: .derivativeTimeSec, to: "0.15").validate(currentConfig: safeConfig())
        XCTAssertTrue(v.passed, "0.15 in range 0..0.25 — issues: \(v.issues)")
    }
}
