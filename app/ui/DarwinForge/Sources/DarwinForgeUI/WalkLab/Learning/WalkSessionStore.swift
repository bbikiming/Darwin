import Foundation

/// Walk session 파일들을 디스크에서 발견 / 정렬 / 로드한다. UI 가 직접 FileManager 를
/// 쓰지 않고 이 store 만 의존하도록.
public final class WalkSessionStore {
    public let directory: URL

    public init(directory: URL = WalkSessionLogger.Configuration.defaultUserDirectory()) {
        self.directory = directory
    }

    /// 디렉토리에서 모든 `.jsonl` 파일을 찾아 시간 역순으로 정렬.
    public func discoverSessions() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.creationDateKey],
                                                      options: [.skipsHiddenFiles]) else {
            return []
        }
        return items
            .filter { $0.pathExtension == "jsonl" }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return lDate > rDate
            }
    }

    /// 디렉토리의 세션 파일들을 디코드. 실패한 파일은 건너뛰고 계속.
    public func loadAllSessions() -> [DecodedWalkSession] {
        discoverSessions().compactMap { url in
            try? WalkSessionDecoder.decode(file: url)
        }
    }

    /// 한 파일만 로드.
    public func loadSession(file url: URL) throws -> DecodedWalkSession {
        try WalkSessionDecoder.decode(file: url)
    }

    /// `<sessionId>-<preset>.jsonl` 의 짝이 되는 summary 파일 경로.
    public func summaryURL(for sessionURL: URL) -> URL {
        let base = sessionURL.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent(base).appendingPathExtension("summary.json")
    }

    public func writeSummary(_ summary: WalkSessionSummaryV2, for sessionURL: URL) throws {
        let url = summaryURL(for: sessionURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        try data.write(to: url, options: .atomic)
    }

    public func readSummary(for sessionURL: URL) -> WalkSessionSummaryV2? {
        let url = summaryURL(for: sessionURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WalkSessionSummaryV2.self, from: data)
    }
}
