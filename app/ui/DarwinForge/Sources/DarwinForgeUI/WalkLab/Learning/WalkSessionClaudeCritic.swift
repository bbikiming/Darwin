import Foundation
import SwiftUI

/// **v1.11.11 (2026-05-19)** — Claude critic 단일 entry point.
///
/// 진단 문서 §HIGH 4 (path 이중화 fix) + §5 (experiment unit) + Agent 5 architect 설계.
///
/// **단일 책임**:
/// - Claude CLI 호출 + JSON 응답 받기
/// - 결과 디스크 저장 (`~/Library/Application Support/DarwinForge/analyses/<id>.json`)
/// - history 보관 (메모리 + UI binding)
/// - deterministic re-validation
///
/// **사용**: WalkLabSession / WalkDataView 가 직접 Analyst 사용 X → 본 singleton 만 호출.
@MainActor
public final class WalkSessionClaudeCritic: ObservableObject {

    @Published public private(set) var currentResponse: ClaudeCriticResponse? = nil
    @Published public private(set) var inProgress: Bool = false
    @Published public private(set) var error: String? = nil
    @Published public var userReport: String = ""
    @Published public private(set) var history: [SavedAnalysis] = []

    /// 분석 한 건 — 저장 + history binding 용.
    public struct SavedAnalysis: Codable, Identifiable, Sendable, Equatable {
        public let id: String           // UUID
        public let timestampIso: String
        public let response: ClaudeCriticResponse
        public let userReport: String
        public let sessionsAnalyzed: [String]

        public init(id: String, timestampIso: String,
                    response: ClaudeCriticResponse,
                    userReport: String, sessionsAnalyzed: [String]) {
            self.id = id
            self.timestampIso = timestampIso
            self.response = response
            self.userReport = userReport
            self.sessionsAnalyzed = sessionsAnalyzed
        }
    }

    /// 의존성 inject 가능 — fake CLI test 용.
    private let analystFactory: (TimeInterval) -> AnalystProtocol

    public init(analystFactory: @escaping (TimeInterval) -> AnalystProtocol = { timeout in
        DefaultClaudeAnalystAdapter(timeoutSeconds: timeout)
    }) {
        self.analystFactory = analystFactory
        Task { @MainActor in
            self.history = (try? Self.loadAllSavedAnalyses()) ?? []
        }
    }

    /// **단일 entry point** — 세션 list + 헤더 + 사용자 보고 → Critic 응답.
    /// PromptV2 → JSON → ClaudeCriticResponse → validate → 디스크 저장.
    public func analyze(
        sessions: [WalkSessionSummary],
        headers: [String: WalkSessionHeader],
        sampleStatsBuilder: (String) -> [WalkSessionClaudePromptV2.PhaseStatsV2],
        timeoutSeconds: TimeInterval = 90
    ) async {
        inProgress = true
        error = nil
        defer { inProgress = false }

        if sessions.isEmpty {
            error = "분석할 세션이 없습니다."
            return
        }

        let prompt = WalkSessionClaudePromptV2.build(
            sessions: sessions,
            headers: headers,
            userReport: userReport,
            sampleStatsBuilder: sampleStatsBuilder
        )

        let analyst = analystFactory(timeoutSeconds)
        do {
            let response = try await analyst.analyzeAsCritic(prompt: prompt)
            currentResponse = response
            // 디스크 저장.
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let saved = SavedAnalysis(
                id: UUID().uuidString,
                timestampIso: isoFormatter.string(from: Date()),
                response: response,
                userReport: userReport,
                sessionsAnalyzed: sessions.map(\.id)
            )
            try? Self.saveAnalysis(saved)
            history.insert(saved, at: 0)
            if history.count > 50 { history.removeLast(history.count - 50) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func clear() {
        currentResponse = nil
        error = nil
    }

    // MARK: - Disk persistence (P2-3)

    /// `~/Library/Application Support/DarwinForge/analyses/`
    public static var analysesDir: URL? {
        let fm = FileManager.default
        return try? fm.url(for: .applicationSupportDirectory,
                           in: .userDomainMask,
                           appropriateFor: nil,
                           create: true)
            .appendingPathComponent("DarwinForge", isDirectory: true)
            .appendingPathComponent("analyses", isDirectory: true)
    }

    public static func saveAnalysis(_ analysis: SavedAnalysis) throws {
        guard let dir = analysesDir else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(analysis.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(analysis)
        try data.write(to: url, options: .atomic)
    }

    public static func loadAllSavedAnalyses() throws -> [SavedAnalysis] {
        guard let dir = analysesDir else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        let analyses = files.compactMap { url -> SavedAnalysis? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(SavedAnalysis.self, from: data)
        }
        return analyses.sorted { $0.timestampIso > $1.timestampIso }
    }
}

// MARK: - Analyst protocol (DI for testing)

public protocol AnalystProtocol: Sendable {
    func analyzeAsCritic(prompt: String) async throws -> ClaudeCriticResponse
}

/// 실 claude CLI 호출 adapter.
public struct DefaultClaudeAnalystAdapter: AnalystProtocol {
    public let timeoutSeconds: TimeInterval
    public init(timeoutSeconds: TimeInterval) {
        self.timeoutSeconds = timeoutSeconds
    }
    public func analyzeAsCritic(prompt: String) async throws -> ClaudeCriticResponse {
        let actor = WalkSessionClaudeAnalyst(timeoutSeconds: timeoutSeconds)
        return try await actor.analyzeAsCritic(prompt: prompt)
    }
}
