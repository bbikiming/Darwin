import Foundation
import ForgeCore

/// **v1.22.0 (2026-05-22) — 사이클 89: god object Phase 1A 분할 (architect agent plan)**.
///
/// `WalkLabSession.swift` (4493 line) 의 Claude CLI 분석 method (~80 line) 를 본 extension
/// 으로 이동. stored property 4개 (markdown / inProgress / error / userReport) 는 Swift
/// extension 제약으로 본체 잔존 — method 만 이동.
///
/// # 비유
///
/// 거대한 도서관의 "보고서 작성" 코너만 별도 사무실로 이전. 책상 (state) 은 본 도서관에
/// 잔존, 작성 의자 (method) 만 이전. 작성자는 도서관 카탈로그 (internal(set)) 로 책상에
/// 접근.
///
/// # 분할 정책
///
/// - **stored property 본체 잔존** (Swift 제약): `claudeAnalysisMarkdown` /
///   `claudeAnalysisInProgress` / `claudeAnalysisError` / `claudeUserReport`.
/// - 본 cycle 에서 `public private(set)` → `public internal(set)` 으로 access 격상 —
///   extension 의 write 허용 + 외부 API 는 read-only 유지.
/// - method 2개 이동: `invokeClaudeAnalysis(limit:)` / `clearClaudeAnalysis()`.
///
/// # 회귀
///
/// 1233 tests 회귀 0 — 외부 API 변경 0 (read 시 동일, write 는 module 내부만).
extension WalkLabSession {

    /// **최근 N 세션 + 사용자 보고 → Claude CLI 분석 invoke**.
    ///
    /// - Parameter limit: 분석에 포함할 세션 수 (default 5, 최대 `WalkSessionClaudePrompt.maxSessions`)
    /// - 동작:
    ///   1. autoTuner.recentSummaries 의 최신 N session 가져옴
    ///   2. 각 session 의 jsonl 에서 sample 배열 load (메모리 buffer 우선, 없으면 디스크)
    ///   3. phase 별 통계 계산
    ///   4. WalkSessionClaudePrompt.build → markdown prompt
    ///   5. WalkSessionClaudeAnalyst.analyze → claude CLI 호출
    ///   6. 결과 markdown 을 claudeAnalysisMarkdown 에 publish
    public func invokeClaudeAnalysis(limit: Int = 5) async {
        claudeAnalysisInProgress = true
        claudeAnalysisError = nil
        defer { claudeAnalysisInProgress = false }

        let summaries = Array(autoTuner.recentSummaries.prefix(limit))
        if summaries.isEmpty {
            claudeAnalysisError = "분석할 보행 세션이 없습니다. 보행을 1회 이상 실행해주세요."
            return
        }

        // sample 통계 builder — sessionId → PhaseStats 배열.
        // 세션 jsonl 을 디스크에서 read.
        let builder: (String) -> [WalkSessionClaudePrompt.PhaseStats] = { sessionId in
            guard let dir = WalkSessionStore.sessionsDir else { return [] }
            // sessionId 기준으로 .jsonl 파일 찾기.
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                return []
            }
            let match = files.first { $0.lastPathComponent.contains(sessionId) && $0.pathExtension == "jsonl" }
            guard let url = match else { return [] }
            guard let data = try? Data(contentsOf: url) else { return [] }
            let lines = data.split(separator: 0x0a)  // newline
            let decoder = JSONDecoder()
            var samples: [WalkSessionSample] = []
            // 첫 줄은 header — skip.
            for line in lines.dropFirst() {
                if let sample = try? decoder.decode(WalkSessionSample.self, from: Data(line)) {
                    samples.append(sample)
                }
            }
            return WalkSessionClaudePrompt.phaseStats(from: samples)
        }

        let prompt = WalkSessionClaudePrompt.build(
            sessions: summaries,
            userReport: claudeUserReport,
            sampleStatsBuilder: builder
        )

        // Claude CLI 호출 (60초 timeout).
        let analyst = WalkSessionClaudeAnalyst(timeoutSeconds: 60)
        do {
            let markdown = try await analyst.analyze(prompt: prompt)
            claudeAnalysisMarkdown = markdown
        } catch {
            claudeAnalysisError = error.localizedDescription
        }
    }

    /// 분석 결과 초기화.
    public func clearClaudeAnalysis() {
        claudeAnalysisMarkdown = nil
        claudeAnalysisError = nil
    }
}
