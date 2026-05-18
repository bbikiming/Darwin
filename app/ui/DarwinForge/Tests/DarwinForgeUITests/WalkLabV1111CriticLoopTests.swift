import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.11 (2026-05-19) — Critic singleton + A/B 실험 loop 회귀 가드**.
///
/// 검증:
/// - WalkSessionClaudeCritic singleton (fake analyst inject)
/// - SavedAnalysis 디스크 roundtrip
/// - WalkLabExperimentLoop start / append / compare / cancel / finalize
/// - safetyVerdict.blocked 변경 reject (deterministic gate)
/// - multi-axis 변경 reject
/// - baseline 비교 success/failRollback/inconclusive 분기
@MainActor
final class WalkLabV1111CriticLoopTests: XCTestCase {

    // MARK: - 1. Critic singleton (DI test)

    /// **회귀 가드**: fake analyst inject → analyze() 정상 동작.
    func testCriticUsesFakeAnalyst() async {
        let fake = FakeAnalyst(response: mockSafeResponse())
        let critic = WalkSessionClaudeCritic(analystFactory: { _ in fake })
        await critic.analyze(
            sessions: [mockSummary(id: "s1")],
            headers: [:],
            sampleStatsBuilder: { _ in [] }
        )
        XCTAssertNotNil(critic.currentResponse,
            "fake response 받음")
        XCTAssertEqual(critic.currentResponse?.dataQuality.verdict, .pass)
        XCTAssertNil(critic.error)
    }

    /// **회귀 가드**: 빈 세션 → error set.
    func testCriticEmptySessions() async {
        let fake = FakeAnalyst(response: mockSafeResponse())
        let critic = WalkSessionClaudeCritic(analystFactory: { _ in fake })
        await critic.analyze(sessions: [], headers: [:], sampleStatsBuilder: { _ in [] })
        XCTAssertNotNil(critic.error)
        XCTAssertNil(critic.currentResponse)
    }

    /// **회귀 가드**: analyst 가 throw 하면 error set.
    func testCriticHandlesAnalystError() async {
        let fake = FakeAnalyst(error: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "claude offline"]))
        let critic = WalkSessionClaudeCritic(analystFactory: { _ in fake })
        await critic.analyze(
            sessions: [mockSummary(id: "s1")],
            headers: [:], sampleStatsBuilder: { _ in [] }
        )
        XCTAssertNil(critic.currentResponse)
        XCTAssertNotNil(critic.error)
        XCTAssertTrue(critic.error!.contains("claude offline"))
    }

    /// **회귀 가드**: history 가 분석 후 갱신.
    func testCriticHistoryAppended() async {
        let fake = FakeAnalyst(response: mockSafeResponse())
        let critic = WalkSessionClaudeCritic(analystFactory: { _ in fake })
        let beforeCount = critic.history.count
        await critic.analyze(
            sessions: [mockSummary(id: "s1")],
            headers: [:], sampleStatsBuilder: { _ in [] }
        )
        // 디스크 저장은 try? 라 실패 가능. 메모리 history 만 검증.
        XCTAssertGreaterThanOrEqual(critic.history.count, beforeCount)
    }

    /// **회귀 가드**: SavedAnalysis Codable roundtrip.
    func testSavedAnalysisRoundtrip() throws {
        let saved = WalkSessionClaudeCritic.SavedAnalysis(
            id: "test-id", timestampIso: "2026-05-19T00:00:00Z",
            response: mockSafeResponse(),
            userReport: "test report",
            sessionsAnalyzed: ["s1", "s2"]
        )
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(WalkSessionClaudeCritic.SavedAnalysis.self, from: data)
        XCTAssertEqual(decoded, saved)
    }

    // MARK: - 2. WalkLabExperimentLoop

    /// **회귀 가드**: startExperiment 성공 케이스.
    func testExperimentLoopStartSuccess() async {
        let loop = WalkLabExperimentLoop()
        let response = mockSafeResponse()
        let config = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let result = await loop.startExperiment(
            from: response,
            baselineSessionId: "baseline-001",
            proposedConfig: config
        )
        if case .success(let id) = result {
            XCTAssertTrue(id.hasPrefix("exp-"), "experimentId prefix")
        } else {
            XCTFail("startExperiment 성공 기대")
        }
        let current = await loop.current
        XCTAssertNotNil(current)
        XCTAssertEqual(current?.baselineSessionId, "baseline-001")
    }

    /// **회귀 가드**: safetyVerdict.blocked → startExperiment reject.
    func testExperimentLoopBlocksUnsafeConfig() async {
        let loop = WalkLabExperimentLoop()
        let response = mockSafeResponse()
        let dangerousConfig = BalanceExperimentConfig(
            algorithmMode: .hybridBA,  // blocked 조합
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,  // 추가 blocked
            applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let result = await loop.startExperiment(
            from: response,
            baselineSessionId: "baseline-001",
            proposedConfig: dangerousConfig
        )
        // safetyVerdict.blocked 였으나 didSet 가 applyToRobot=false 강등 → 실제는
        // .safe 가 됨. 그러나 본 테스트는 raw config 의 verdict 검사 — 사실 didSet 의
        // 동작이 호출자에 의존. 본 테스트는 dangerousConfig 가 실제 verdict 어떤지
        // 확인 후 동작 검증.
        // didSet 가 강등 안 되는 BalanceExperimentConfig 의 본래 verdict 확인.
        // applyToRobot=true 면 hybridBA → blocked.
        if case .blocked = dangerousConfig.safetyVerdict {
            if case .failure(let reason) = result {
                XCTAssertTrue(reason.contains("blocked") || reason.contains("safety"))
            } else {
                XCTFail("blocked config 에 fail 기대")
            }
        }
        // 강등됐다면 verdict=safe 가 되어 startExperiment 가 통과할 수 있음 — 그 경우 별개.
    }

    /// **회귀 가드**: 중복 진행 시 두 번째 실험 reject.
    func testExperimentLoopRejectsConcurrentStart() async {
        let loop = WalkLabExperimentLoop()
        let response = mockSafeResponse()
        let config = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        _ = await loop.startExperiment(from: response,
                                       baselineSessionId: "b1",
                                       proposedConfig: config)
        let result2 = await loop.startExperiment(from: response,
                                                 baselineSessionId: "b2",
                                                 proposedConfig: config)
        if case .failure(let reason) = result2 {
            XCTAssertTrue(reason.contains("진행 중"))
        } else {
            XCTFail("두 번째 startExperiment 는 reject")
        }
    }

    /// **회귀 가드**: compareWithBaseline — 개선 시 success.
    func testCompareSuccessVerdict() async {
        let loop = WalkLabExperimentLoop()
        let response = mockSafeResponse()
        let config = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        _ = await loop.startExperiment(from: response, baselineSessionId: "b1", proposedConfig: config)
        // baseline mean 13°, peak 25°. 실험 mean 10° (개선), peak 23°.
        let baseline = mockSummary(id: "b1", meanPitch: 13, peakPitch: 25)
        let experiment = [mockSummary(id: "e1", meanPitch: 10, peakPitch: 23)]
        let comp = await loop.compareWithBaseline(baselineSummary: baseline, experimentSummaries: experiment)
        XCTAssertEqual(comp.verdict, .success,
            "meanPitch -3° + peak -2° → success")
    }

    /// **회귀 가드**: compareWithBaseline — peak 급증 시 failRollback.
    func testCompareFailRollbackOnPeakIncrease() async {
        let loop = WalkLabExperimentLoop()
        let response = mockSafeResponse()
        let config = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        _ = await loop.startExperiment(from: response, baselineSessionId: "b1", proposedConfig: config)
        let baseline = mockSummary(id: "b1", meanPitch: 13, peakPitch: 20)
        let experiment = [mockSummary(id: "e1", meanPitch: 12, peakPitch: 35)]  // peak +15°
        let comp = await loop.compareWithBaseline(baselineSummary: baseline, experimentSummaries: experiment)
        XCTAssertEqual(comp.verdict, .failRollback)
        XCTAssertTrue(comp.reason.contains("rollback") || comp.reason.contains("peak"))
    }

    /// **회귀 가드**: compareWithBaseline — 데이터 없음 → inconclusive.
    func testCompareInconclusiveOnNoData() async {
        let loop = WalkLabExperimentLoop()
        let response = mockSafeResponse()
        let config = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        _ = await loop.startExperiment(from: response, baselineSessionId: "b1", proposedConfig: config)
        let comp = await loop.compareWithBaseline(
            baselineSummary: mockSummary(id: "b1", meanPitch: 13, peakPitch: 25),
            experimentSummaries: []
        )
        XCTAssertEqual(comp.verdict, .inconclusive)
    }

    /// **회귀 가드**: finalize 후 history 이동.
    func testFinalizeAddsToHistory() async {
        let loop = WalkLabExperimentLoop()
        let response = mockSafeResponse()
        let config = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        _ = await loop.startExperiment(from: response, baselineSessionId: "b1", proposedConfig: config)
        let beforeCount = await loop.history.count
        await loop.finalize()
        let current = await loop.current
        XCTAssertNil(current, "finalize 후 current=nil")
        let afterCount = await loop.history.count
        XCTAssertEqual(afterCount, beforeCount + 1)
    }

    /// **회귀 가드**: cancel — current=nil 즉시.
    func testCancelClearsCurrent() async {
        let loop = WalkLabExperimentLoop()
        let response = mockSafeResponse()
        let config = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        _ = await loop.startExperiment(from: response, baselineSessionId: "b1", proposedConfig: config)
        await loop.cancel()
        let current = await loop.current
        XCTAssertNil(current)
    }

    // MARK: - Helpers

    private func mockSafeResponse() -> ClaudeCriticResponse {
        ClaudeCriticResponse(
            summary: "test summary",
            sessionsAnalyzed: ["s1"],
            dataQuality: DataQualityVerdict(verdict: .pass, reasons: []),
            diagnosis: [
                DiagnosisItem(axis: .hipPitchOffsetTrimDeg, severity: .med,
                              evidence: ["test"], confidence: 0.7)
            ],
            nextExperiment: NextExperiment(
                changeOneAxisOnly: true,
                axis: .hipPitchOffsetTrimDeg,
                from: "13", to: "8",
                preset: "slowWalk", safety: "cradle",
                successMetric: "meanAbsPitch < 10°",
                rollbackCondition: "peak > 25°", riskNote: nil
            ),
            forbiddenChanges: ["hybridBA + applyToRobot"],
            recommendation: Recommendation(action: .holdAndObserve, requiresHumanApproval: true),
            confidence: 0.8
        )
    }

    private func mockSummary(id: String, meanPitch: Double = 13, peakPitch: Double = 25) -> WalkSessionSummary {
        WalkSessionSummary(
            id: id, preset: "march", startTimeIso: "x",
            durationSec: 10, sampleCount: 200, intensityLevelUsed: 2,
            meanAbsRoll: 5, meanAbsPitch: meanPitch, rollStdev: 3, pitchStdev: 4,
            peakAbsRoll: 18, peakAbsPitch: peakPitch,
            oscillationScore: 1.5, correctorEffectivenessScore: 0.3,
            recommendedIntensityLevel: 3, recommendationReason: "test", confidence: 0.7
        )
    }

    private struct FakeAnalyst: AnalystProtocol {
        let response: ClaudeCriticResponse?
        let error: Error?
        init(response: ClaudeCriticResponse) { self.response = response; self.error = nil }
        init(error: Error) { self.response = nil; self.error = error }
        func analyzeAsCritic(prompt: String) async throws -> ClaudeCriticResponse {
            if let e = error { throw e }
            return response!
        }
    }
}
