import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.9 (2026-05-19) — Claude CLI 보행 분석 회귀 가드**.
///
/// 검증:
/// - WalkSessionClaudePrompt 의 markdown 직렬화 구조
/// - phaseStats 통계 정확성 (sample 배열 → bucket 평균)
/// - WalkSessionClaudeAnalyst CLI path resolution
/// - WalkLabSession 의 claudeAnalysisMarkdown / inProgress / error @Published 정합
@MainActor
final class WalkLabV119ClaudeAnalysisTests: XCTestCase {

    // MARK: - 1. Prompt 직렬화

    /// **회귀 가드**: 빈 session list 도 prompt 생성 가능 (에러 없음).
    func testPromptBuildWithEmptySessions() {
        let prompt = WalkSessionClaudePrompt.build(
            sessions: [],
            userReport: "",
            sampleStatsBuilder: { _ in [] }
        )
        XCTAssertTrue(prompt.contains("ROBOTIS-OP2"),
            "system section 포함")
        XCTAssertTrue(prompt.contains("세션 없음"),
            "빈 세션 안내 메시지")
        XCTAssertTrue(prompt.contains("분석 요청"),
            "분석 요청 section 포함")
    }

    /// **회귀 가드**: 사용자 보고 빈 문자열도 안전.
    func testPromptBuildWithoutUserReport() {
        let summary = mockSummary(id: "test1", preset: "march")
        let prompt = WalkSessionClaudePrompt.build(
            sessions: [summary],
            userReport: "",
            sampleStatsBuilder: { _ in [] }
        )
        XCTAssertTrue(prompt.contains("사용자 보고 없음"))
        XCTAssertTrue(prompt.contains("test1"))
        XCTAssertTrue(prompt.contains("march"))
    }

    /// **회귀 가드**: 사용자 보고 포함 시 quote 형식 (blockquote).
    func testPromptIncludesUserReport() {
        let summary = mockSummary(id: "test2", preset: "slowWalk")
        let prompt = WalkSessionClaudePrompt.build(
            sessions: [summary],
            userReport: "앞으로 넘어지려고 했어",
            sampleStatsBuilder: { _ in [] }
        )
        XCTAssertTrue(prompt.contains("앞으로 넘어지려고 했어"))
        XCTAssertTrue(prompt.contains("> "),
            "blockquote 형식")
    }

    /// **회귀 가드**: maxSessions 한도 적용.
    func testPromptCapsAtMaxSessions() {
        let many = (0..<10).map { mockSummary(id: "s\($0)", preset: "march") }
        let prompt = WalkSessionClaudePrompt.build(
            sessions: many,
            userReport: "",
            sampleStatsBuilder: { _ in [] }
        )
        // 최대 maxSessions (default 5) 만 포함.
        XCTAssertTrue(prompt.contains("s0"))
        XCTAssertTrue(prompt.contains("s4"))
        XCTAssertFalse(prompt.contains("s9"),
            "10개 중 첫 \(WalkSessionClaudePrompt.maxSessions)개만 포함")
    }

    // MARK: - 2. phaseStats 통계

    /// **회귀 가드**: phase bucket 평균 계산 정확.
    func testPhaseStatsBucketing() {
        let samples: [WalkSessionSample] = [
            mockSample(t: 0, walkPhase: 0.03, pitch: -10, roll: 0, applied: [0,0,0,0,2,0,0,0]),
            mockSample(t: 50, walkPhase: 0.03, pitch: -12, roll: 1, applied: [0,0,0,0,3,0,0,0]),
            mockSample(t: 100, walkPhase: 0.18, pitch: -8, roll: -1, applied: [0,0,0,0,1,0,0,0]),
        ]
        let stats = WalkSessionClaudePrompt.phaseStats(from: samples)
        XCTAssertEqual(stats.count, 2, "0.03, 0.18 두 phase bucket")
        let phase003 = stats.first { $0.phase == 0.03 }
        XCTAssertNotNil(phase003)
        XCTAssertEqual(phase003!.count, 2)
        XCTAssertEqual(phase003!.meanPitch, -11.0, accuracy: 0.01,
            "0.03 phase 의 imuPitch 평균 = (-10 + -12) / 2 = -11")
        XCTAssertEqual(phase003!.meanRAnklePitchDelta, 2.5, accuracy: 0.01,
            "0.03 phase 의 applied[4] 평균 = (2 + 3) / 2 = 2.5")
    }

    /// **회귀 가드**: walkPhase01 nil sample 은 skip.
    func testPhaseStatsSkipsNilPhase() {
        let samples: [WalkSessionSample] = [
            mockSample(t: 0, walkPhase: nil, pitch: -10, roll: 0, applied: []),
            mockSample(t: 50, walkPhase: 0.18, pitch: -8, roll: 0, applied: [0,0,0,0,1,0,0,0]),
        ]
        let stats = WalkSessionClaudePrompt.phaseStats(from: samples)
        XCTAssertEqual(stats.count, 1, "phase nil 은 제외")
        XCTAssertEqual(stats[0].phase, 0.18)
    }

    // MARK: - 3. CLI path resolution

    /// **회귀 가드**: claude CLI 가 시스템에 있으면 resolvedCliPath nil 아님.
    /// (개발 환경: /Users/bbikiming/.local/bin/claude 가정. CI 에서는 없을 수 있음 → skip)
    func testCliPathResolvesIfPresent() {
        let path = WalkSessionClaudeAnalyst.resolvedCliPath()
        // CI 환경에선 claude CLI 미설치 가능 — nil 도 허용.
        if let p = path {
            XCTAssertTrue(p.hasSuffix("/claude"),
                "claude path 마지막은 /claude: \(p)")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: p),
                "resolved path 가 실행 가능")
        }
    }

    /// **회귀 가드**: override path 가 잘못되면 nil fallback.
    func testCliPathOverrideInvalidFallback() {
        let path = WalkSessionClaudeAnalyst.resolvedCliPath(override: "/definitely/not/a/real/path/claude")
        // override 가 invalid 면 candidatePaths 또는 PATH 에서 fallback.
        // 본 테스트는 fallback path 존재 여부 무관 — 단지 crash 없이 nil 또는 valid 반환.
        if let p = path {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: p))
        }
    }

    // MARK: - 4. WalkLabSession integration

    /// **회귀 가드**: claudeAnalysisMarkdown default nil + clearClaudeAnalysis 효과.
    func testSessionClaudeAnalysisDefaults() {
        let s = WalkLabSession()
        XCTAssertNil(s.claudeAnalysisMarkdown)
        XCTAssertNil(s.claudeAnalysisError)
        XCTAssertFalse(s.claudeAnalysisInProgress)
        XCTAssertEqual(s.claudeUserReport, "")
    }

    /// **회귀 가드**: limit=0 → summaries.empty 분기 즉시 에러 (CLI 호출 X, fast path).
    func testInvokeClaudeAnalysisLimitZeroErrorsFast() async {
        let s = WalkLabSession()
        await s.invokeClaudeAnalysis(limit: 0)
        XCTAssertFalse(s.claudeAnalysisInProgress, "완료 후 inProgress=false")
        XCTAssertNotNil(s.claudeAnalysisError,
            "limit=0 → summaries.empty → error set (no CLI call)")
        XCTAssertNil(s.claudeAnalysisMarkdown,
            "에러 시 markdown nil")
    }

    /// **회귀 가드**: clearClaudeAnalysis 가 state 초기화.
    func testClearClaudeAnalysisResetsState() async {
        let s = WalkLabSession()
        // limit=0 으로 error 강제 발생.
        await s.invokeClaudeAnalysis(limit: 0)
        XCTAssertNotNil(s.claudeAnalysisError)
        s.clearClaudeAnalysis()
        XCTAssertNil(s.claudeAnalysisError, "clear 후 error nil")
        XCTAssertNil(s.claudeAnalysisMarkdown, "clear 후 markdown nil")
    }

    // MARK: - Helpers

    private func mockSummary(id: String, preset: String) -> WalkSessionSummary {
        WalkSessionSummary(
            id: id, preset: preset, startTimeIso: "2026-05-19T00:00:00Z",
            durationSec: 10.0, sampleCount: 200, intensityLevelUsed: 2,
            meanAbsRoll: 5.0, meanAbsPitch: 13.0,
            rollStdev: 3.0, pitchStdev: 4.0,
            peakAbsRoll: 18.0, peakAbsPitch: 25.0,
            oscillationScore: 1.5,
            correctorEffectivenessScore: 0.3,
            recommendedIntensityLevel: 3,
            recommendationReason: "test", confidence: 0.7
        )
    }

    private func mockSample(t: Double, walkPhase: Double?, pitch: Double, roll: Double,
                            applied: [Double]) -> WalkSessionSample {
        WalkSessionSample(
            t: t, preset: "march", intensityLevel: 2,
            imuRollDeg: roll, imuPitchDeg: pitch,
            correctorRollErrDeg: 0, correctorPitchErrDeg: 0,
            balanceState: "normal",
            correctorDeltas: applied.isEmpty ? Array(repeating: 0.0, count: 8) : applied,
            imuSource: "real",
            batteryVolts: nil, motorAvgTemp: nil,
            walkPhase01: walkPhase,
            appliedDeltas: applied.isEmpty ? nil : applied
        )
    }
}
