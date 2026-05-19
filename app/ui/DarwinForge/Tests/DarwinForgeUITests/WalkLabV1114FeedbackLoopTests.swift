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
    /// **v1.11.14.3**: finalize 가 shared history file 에 write 하므로 cleanup 필수
    /// (다른 테스트의 history 누적 가드와 충돌 방지).
    func testFinalizeClearsActiveContext() async throws {
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

        let historyBefore = await readSharedHistoryFile()
        await controller.finalize()
        // onCleared callback 이 호출되어 activeExperimentId/BaselineSessionId clear.
        XCTAssertNil(session.activeExperimentId)
        XCTAssertNil(session.activeBaselineSessionId)
        // finalize 가 Task { await saveHistory() } fire-and-forget 이라 잠시 대기 후
        // 원래 상태로 복원 (cap 30 누적 + 다른 test 의 history 가드 충돌 방지).
        try await Task.sleep(nanoseconds: 300_000_000)  // 300ms
        await restoreSharedHistoryFile(historyBefore)
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

    // MARK: - v1.11.14.3 — 자동 폐루프 e2e (실 disk IO)

    /// **진단 cold #B fix**: 실 jsonl + summary.json 을 임시 디렉토리에 작성한 후
    /// loadSummaryFromDisk + loadAllExperimentSummaries 통합 path 검증.
    /// 종전 14 test 는 mock summary 만 — 실 디스크 IO path 미검증.
    func testLoadSummaryFromDiskFindsCorrectFile() throws {
        let tempDir = try makeTempSessionsDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionId = "2026-05-19T08-30-15.123Z"
        let summary = makeMockSummary(id: sessionId)
        try writeSummaryFile(summary, sessionId: sessionId, preset: "march", to: tempDir)

        let loaded = WalkLabSession.loadSummaryFromDisk(sessionId: sessionId, baseDir: tempDir)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, sessionId)
    }

    /// **진단 cold #B fix**: prefix match 검증 — 다른 sessionId 의 substring 이 false
    /// positive 안 만드는지 확인.
    func testLoadSummaryFromDiskRejectsSubstringFalsePositive() throws {
        let tempDir = try makeTempSessionsDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 종전 substring 매치였으면 "2026-05-19T08-30" 이 "2026-05-19T08-30-15" 의
        // prefix 라 잘못 매치. 현재 prefix("\(sessionId)-") 매치라 그래도 OK 인지 확인.
        let shortId = "2026-05-19T08-30"
        let longId = "2026-05-19T08-30-15.123Z"
        try writeSummaryFile(makeMockSummary(id: longId), sessionId: longId, preset: "march", to: tempDir)

        // shortId 로 찾으면 longId 파일이 매치되면 안 됨.
        // 단, longId 파일 이름은 "{longId}-march.summary.json" 라 hasPrefix("{shortId}-") 는 false.
        // (hyphen 이 분리 마커)
        let loaded = WalkLabSession.loadSummaryFromDisk(sessionId: shortId, baseDir: tempDir)
        XCTAssertNil(loaded, "shortId 가 longId 의 prefix substring 이라도 match X")
    }

    /// **진단 cold #B fix**: jsonl header 의 experimentId 매치로 multi-session 수집.
    /// streaming first-line read 가 정상 동작하는지 확인.
    func testLoadAllExperimentSummariesMatchesByExperimentId() throws {
        let tempDir = try makeTempSessionsDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let expId = "exp-test-001"
        // 3 세션 — 2개는 같은 experimentId, 1개는 다른 expId.
        try writeJsonlPair(sessionId: "s1", preset: "march", experimentId: expId, to: tempDir)
        try writeJsonlPair(sessionId: "s2", preset: "march", experimentId: expId, to: tempDir)
        try writeJsonlPair(sessionId: "s3", preset: "march", experimentId: "exp-other", to: tempDir)

        let summaries = WalkLabSession.loadAllExperimentSummaries(experimentId: expId, baseDir: tempDir)
        XCTAssertEqual(summaries.count, 2, "expId=\(expId) 만 매치, exp-other 제외")
        let ids = Set(summaries.map { $0.id })
        XCTAssertEqual(ids, Set(["s1", "s2"]))
    }

    /// **진단 cold #B fix**: streaming first-line read 가 큰 jsonl 에서도 빠르게 동작.
    /// 1000+ sample line 의 jsonl 도 header (첫 줄) 만 읽고 매치 결정.
    func testLoadAllExperimentSummariesStreamingFirstLineLarge() throws {
        let tempDir = try makeTempSessionsDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let expId = "exp-large-001"
        // 큰 jsonl 파일 작성 — header + 1000 sample lines.
        try writeLargeJsonlPair(sessionId: "big1", preset: "march", experimentId: expId,
                                 sampleLines: 1000, to: tempDir)

        let start = Date()
        let summaries = WalkLabSession.loadAllExperimentSummaries(experimentId: expId, baseDir: tempDir)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(summaries.count, 1)
        // streaming read 라 1000 lines 도 < 100ms 기대 (전체 load 면 더 오래).
        XCTAssertLessThan(elapsed, 0.5, "streaming first-line — 1000 sample lines 도 빠름")
    }

    // MARK: - Shared history file backup/restore (v1.11.14.3)

    /// finalize 가 shared file 에 write 하므로, 본 test 의 영향이 다른 test 에 누적
    /// 되지 않도록 backup/restore. ExperimentLoopController 의 actor private path
    /// 와 동일 로직.
    private func sharedHistoryFileURL() -> URL? {
        let fm = FileManager.default
        guard let appSup = try? fm.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil, create: false) else {
            return nil
        }
        return appSup
            .appendingPathComponent("DarwinForge", isDirectory: true)
            .appendingPathComponent("analyses", isDirectory: true)
            .appendingPathComponent("experiment-loop-history.json")
    }

    private func readSharedHistoryFile() async -> Data? {
        guard let url = sharedHistoryFileURL() else { return nil }
        return try? Data(contentsOf: url)
    }

    private func restoreSharedHistoryFile(_ data: Data?) async {
        guard let url = sharedHistoryFileURL() else { return }
        if let data = data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Disk IO test helpers

    private func makeTempSessionsDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarwinForgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeMockSummary(id: String) -> WalkSessionSummary {
        WalkSessionSummary(
            id: id, preset: "march", startTimeIso: "2026-05-19T08:30:15.123Z",
            durationSec: 10, sampleCount: 200, intensityLevelUsed: 2,
            meanAbsRoll: 5, meanAbsPitch: 13, rollStdev: 3, pitchStdev: 4,
            peakAbsRoll: 18, peakAbsPitch: 25,
            oscillationScore: 1.5, correctorEffectivenessScore: 0.3,
            recommendedIntensityLevel: 3, recommendationReason: "test", confidence: 0.7
        )
    }

    private func writeSummaryFile(_ summary: WalkSessionSummary,
                                   sessionId: String,
                                   preset: String,
                                   to dir: URL) throws {
        let url = dir.appendingPathComponent("\(sessionId)-\(preset).summary.json")
        let data = try JSONEncoder().encode(summary)
        try data.write(to: url)
    }

    private func writeJsonlPair(sessionId: String,
                                preset: String,
                                experimentId: String?,
                                to dir: URL) throws {
        let header = makeMockHeader(sessionId: sessionId, preset: preset, experimentId: experimentId)
        let summary = makeMockSummary(id: sessionId)
        // jsonl: 첫 줄 = header
        let jsonlURL = dir.appendingPathComponent("\(sessionId)-\(preset).jsonl")
        let headerData = try JSONEncoder().encode(header)
        var jsonlContent = headerData
        jsonlContent.append(0x0a)  // newline
        try jsonlContent.write(to: jsonlURL)
        // summary.json
        try writeSummaryFile(summary, sessionId: sessionId, preset: preset, to: dir)
    }

    private func writeLargeJsonlPair(sessionId: String,
                                      preset: String,
                                      experimentId: String,
                                      sampleLines: Int,
                                      to dir: URL) throws {
        let header = makeMockHeader(sessionId: sessionId, preset: preset, experimentId: experimentId)
        let summary = makeMockSummary(id: sessionId)
        let jsonlURL = dir.appendingPathComponent("\(sessionId)-\(preset).jsonl")
        let headerData = try JSONEncoder().encode(header)
        var content = headerData
        content.append(0x0a)
        // 1000 dummy sample lines — 각 줄은 큰 JSON object.
        let dummyLine = String(repeating: #"{"t":0.1,"preset":"march","intensityLevel":2,"imuRollDeg":0,"imuPitchDeg":0,"correctorRollErrDeg":0,"correctorPitchErrDeg":0,"balanceState":"normal","correctorDeltas":[0,0,0,0,0,0],"imuSource":"sim"}"#, count: 1)
        let dummyData = (dummyLine + "\n").data(using: .utf8)!
        for _ in 0..<sampleLines {
            content.append(dummyData)
        }
        try content.write(to: jsonlURL)
        try writeSummaryFile(summary, sessionId: sessionId, preset: preset, to: dir)
    }

    private func makeMockHeader(sessionId: String,
                                 preset: String,
                                 experimentId: String?) -> WalkSessionHeader {
        WalkSessionHeader(
            sessionId: sessionId,
            startTimeIso: "2026-05-19T08:30:15.123Z",
            preset: preset,
            intensityLevelAtStart: 2,
            appVersion: "1.11.14.3",
            isRealRobot: false,
            balanceAlgorithmMode: nil,
            balanceSignConvention: nil,
            balanceGainProfile: nil,
            correctionApplyMode: nil,
            imuSourceAtStart: nil,
            imuScaleSuspicionAtStart: nil,
            operatorNoteAtStart: nil,
            comparisonTag: nil,
            walkingEngine: nil,
            pitchInputConvention: nil,
            enableBalanceCorrectionAtStart: nil,
            autoOnboardBrokeringAtStart: nil,
            hipPitchOffsetTrimDegAtStart: nil,
            tuningStrideMm: nil,
            tuningSideMm: nil,
            tuningTurnDeg: nil,
            tuningPeriodMs: nil,
            tuningFootHeightMm: nil,
            tuningBalanceGain: nil,
            customGainHipRoll: nil,
            customGainKnee: nil,
            customGainAnklePitch: nil,
            customGainAnkleRoll: nil,
            robotModel: nil,
            firmwareVersion: nil,
            onboardPatchVersion: nil,
            experimentId: experimentId,
            baselineSessionId: nil
        )
    }

    // MARK: - v1.11.14.3 — trim 및 axis 범위 가드 회귀 가드 (High A/C/G fix)

    /// trim 변경 폭이 5° 초과 → issue. 종전 10° 임계는 너무 관대.
    func testValidateRejectsLargeTrimChange() {
        let currentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let response = makeTrimResponse(from: "13", to: "21")  // +8° jump
        let result = response.validate(currentConfig: currentConfig, currentTrim: 13.0)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.issues.contains { $0.contains("변경 폭") },
                      "issues: \(result.issues)")
    }

    /// trim 절대 안전 범위 5..25 밖 → blocked issue.
    func testValidateRejectsAbsoluteTrimOutOfRange() {
        let currentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let response = makeTrimResponse(from: "13", to: "30")  // 절대값 25 초과
        let result = response.validate(currentConfig: currentConfig, currentTrim: 13.0)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.issues.contains { $0.contains("절대 안전 범위") },
                      "issues: \(result.issues)")
    }

    /// trim 권장 범위 8..20 밖 → caution issue.
    func testValidateWarnsTrimOutOfRecommendedRange() {
        let currentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        // 13 → 22: 변경폭 +9° (5 초과) + 권장 8..20 밖 (22) → 2건 issue.
        let response = makeTrimResponse(from: "13", to: "22")
        let result = response.validate(currentConfig: currentConfig, currentTrim: 13.0)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.issues.contains { $0.contains("권장 범위") },
                      "issues: \(result.issues)")
    }

    /// tuning slider customPeriodMs 범위 (400..800) 밖 → issue.
    func testValidateRejectsTuningAxisOutOfRange() {
        let currentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let response = ClaudeCriticResponse(
            summary: "test", sessionsAnalyzed: ["s1"],
            dataQuality: DataQualityVerdict(verdict: .pass, reasons: []),
            diagnosis: [DiagnosisItem(axis: .periodMs, severity: .med,
                                      evidence: ["x"], confidence: 0.7)],
            nextExperiment: NextExperiment(
                changeOneAxisOnly: true,
                axis: .periodMs,
                from: "600", to: "1500",  // 800 초과
                preset: "slowWalk", safety: "cradle",
                successMetric: "x", rollbackCondition: "x", riskNote: nil
            ),
            forbiddenChanges: [],
            recommendation: Recommendation(action: .holdAndObserve, requiresHumanApproval: true)
        )
        let result = response.validate(currentConfig: currentConfig, currentTrim: 13.0)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.issues.contains { $0.contains("주기") || $0.contains("안전 범위") },
                      "issues: \(result.issues)")
    }

    /// customGain 안전 범위 (0.0..2.0) 밖 → issue.
    func testValidateRejectsCustomGainOutOfRange() {
        let currentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl, signConvention: .robotisWalkingCpp,
            gainProfile: .custom, applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        let response = ClaudeCriticResponse(
            summary: "test", sessionsAnalyzed: ["s1"],
            dataQuality: DataQualityVerdict(verdict: .pass, reasons: []),
            diagnosis: [DiagnosisItem(axis: .customGainHipRoll, severity: .med,
                                      evidence: ["x"], confidence: 0.7)],
            nextExperiment: NextExperiment(
                changeOneAxisOnly: true,
                axis: .customGainHipRoll,
                from: "0.5", to: "3.5",  // 2.0 초과
                preset: "slowWalk", safety: "cradle",
                successMetric: "x", rollbackCondition: "x", riskNote: nil
            ),
            forbiddenChanges: [],
            recommendation: Recommendation(action: .holdAndObserve, requiresHumanApproval: true)
        )
        let result = response.validate(currentConfig: currentConfig, currentTrim: 13.0)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.issues.contains { $0.contains("custom hip roll") || $0.contains("안전 범위") },
                      "issues: \(result.issues)")
    }

    private func makeTrimResponse(from f: String, to t: String) -> ClaudeCriticResponse {
        ClaudeCriticResponse(
            summary: "test", sessionsAnalyzed: ["s1"],
            dataQuality: DataQualityVerdict(verdict: .pass, reasons: []),
            diagnosis: [DiagnosisItem(axis: .hipPitchOffsetTrimDeg, severity: .med,
                                      evidence: ["x"], confidence: 0.7)],
            nextExperiment: NextExperiment(
                changeOneAxisOnly: true,
                axis: .hipPitchOffsetTrimDeg,
                from: f, to: t,
                preset: "slowWalk", safety: "cradle",
                successMetric: "x", rollbackCondition: "x", riskNote: nil
            ),
            forbiddenChanges: [],
            recommendation: Recommendation(action: .holdAndObserve, requiresHumanApproval: true)
        )
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
