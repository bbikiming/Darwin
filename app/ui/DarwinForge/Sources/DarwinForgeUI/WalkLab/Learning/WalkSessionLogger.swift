import Foundation

/// **v1.9 (2026-05-17)**: 보행 session 실시간 데이터 로거.
///
/// 매 tick (50ms) `WalkSessionSample` 을 JSONL 한 줄로 append. session 종료 시 close
/// 호출 → header / 마지막 줄 flush + 종료 시간 기록.
///
/// **파일 위치**:
/// `~/Library/Application Support/DarwinForge/sessions/{ISO timestamp}-{preset}.jsonl`
///
/// **파일 포맷**:
/// - 첫 줄: `WalkSessionHeader` JSON
/// - 이후 줄: `WalkSessionSample` JSON 각각 한 줄
///
/// **Privacy**: 로봇 데이터는 사용자 Mac 에만 저장 — 외부 전송 없음. 사용자가 직접 삭제 가능.
public final class WalkSessionLogger {

    /// 활성 session 의 file handle.
    private let fileHandle: FileHandle
    private let encoder: JSONEncoder
    public let sessionId: String
    public let filePath: URL
    public let header: WalkSessionHeader
    private(set) public var sampleCount: Int = 0
    /// **v1.9.2 (2026-05-17)**: Logger 가 사용한 startTime — caller (`WalkLabSession`) 이
    /// summary 생성 시 동일 timestamp 사용해야 jsonl filename 과 summary.id 일치.
    /// 종전: caller 가 별도 `Date()` 를 만들어 3ms 정도 drift → matching 실패.
    public let startedAt: Date

    /// 누적 sample buffer — 분석 시 메모리에서 직접 사용 (디스크 read 우회).
    public private(set) var samples: [WalkSessionSample] = []

    /// 신규 session 생성 + JSONL 파일 open + header 작성.
    /// **v1.11 (Codex review 2026-05-18 HIGH-2)**: handoff §3 5 + 3 필드를 헤더에
    /// 직접 기록. v2 pipeline 의 quality analyzer 가 어떤 corrector 설정 인지 인식
    /// 가능. 모든 신규 필드는 Optional — 기존 caller (test fixtures 등) backward-compat.
    public init(preset: String,
                intensityLevel: Int,
                appVersion: String,
                isRealRobot: Bool,
                balanceAlgorithmMode: String? = nil,
                balanceSignConvention: String? = nil,
                balanceGainProfile: String? = nil,
                correctionApplyMode: String? = nil,
                imuSourceAtStart: String? = nil,
                imuScaleSuspicionAtStart: String? = nil,
                operatorNoteAtStart: String? = nil,
                comparisonTag: WalkComparisonTag? = nil) throws {
        let fm = FileManager.default
        let baseDir = try fm.url(for: .applicationSupportDirectory,
                                 in: .userDomainMask,
                                 appropriateFor: nil,
                                 create: true)
            .appendingPathComponent("DarwinForge", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = isoFormatter.string(from: now)
        let safeStamp = iso.replacingOccurrences(of: ":", with: "-")
        let fileName = "\(safeStamp)-\(preset).jsonl"
        let url = baseDir.appendingPathComponent(fileName)

        self.sessionId = safeStamp
        self.filePath = url
        self.startedAt = now
        self.header = WalkSessionHeader(
            sessionId: safeStamp,
            startTimeIso: iso,
            preset: preset,
            intensityLevelAtStart: intensityLevel,
            appVersion: appVersion,
            isRealRobot: isRealRobot,
            balanceAlgorithmMode: balanceAlgorithmMode,
            balanceSignConvention: balanceSignConvention,
            balanceGainProfile: balanceGainProfile,
            correctionApplyMode: correctionApplyMode,
            imuSourceAtStart: imuSourceAtStart,
            imuScaleSuspicionAtStart: imuScaleSuspicionAtStart,
            operatorNoteAtStart: operatorNoteAtStart,
            comparisonTag: comparisonTag
        )

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.withoutEscapingSlashes]

        // 파일 생성 + 첫 줄 = header.
        fm.createFile(atPath: url.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: url)
        try writeLine(header)
    }

    /// 매 tick 호출 — sample 한 줄 append + 메모리 buffer 에도 보관.
    public func append(_ sample: WalkSessionSample) {
        samples.append(sample)
        sampleCount += 1
        // file write 는 throw 가능 — silent 처리 (디스크 full 같은 edge case).
        try? writeLine(sample)
    }

    /// session 종료 — file close + sync.
    public func close() {
        try? fileHandle.close()
    }

    /// 분석 결과 (`WalkSessionSummary`) 를 별도 `.summary.json` 파일로 저장.
    public func writeSummary(_ summary: WalkSessionSummary) throws {
        let summaryURL = filePath.deletingPathExtension().appendingPathExtension("summary.json")
        let data = try encoder.encode(summary)
        try data.write(to: summaryURL, options: .atomic)
    }

    // MARK: - Private

    private func writeLine<T: Encodable>(_ value: T) throws {
        let data = try encoder.encode(value)
        try fileHandle.write(contentsOf: data)
        try fileHandle.write(contentsOf: "\n".data(using: .utf8)!)
    }
}

/// 디스크 cleanup — N개 이상 session 시 가장 오래된 것 삭제.
public enum WalkSessionStore {
    /// 보관 최대 session 수. 30개 = 약 ~1GB (1시간 session × 30).
    public static let maxRetainedSessions: Int = 30

    /// 모든 session 디렉토리 path.
    public static var sessionsDir: URL? {
        let fm = FileManager.default
        return try? fm.url(for: .applicationSupportDirectory,
                           in: .userDomainMask,
                           appropriateFor: nil,
                           create: true)
            .appendingPathComponent("DarwinForge", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// 디스크의 모든 summary 파일 load (최신 순).
    public static func loadAllSummaries() -> [WalkSessionSummary] {
        guard let dir = sessionsDir else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: nil) else {
            return []
        }
        let summaryFiles = contents.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".summary.json") }
        let decoder = JSONDecoder()
        let summaries = summaryFiles.compactMap { url -> WalkSessionSummary? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(WalkSessionSummary.self, from: data)
        }
        return summaries.sorted { $0.startTimeIso > $1.startTimeIso }
    }

    /// 오래된 session 정리 — 보관 한도 초과 분 삭제.
    public static func cleanupOldSessions() {
        guard let dir = sessionsDir else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        // jsonl 기준 정렬 (각 session 은 .jsonl + .summary.json 2 파일).
        let jsonlFiles = contents.filter { $0.pathExtension == "jsonl" }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return aDate > bDate
            }
        guard jsonlFiles.count > maxRetainedSessions else { return }
        for old in jsonlFiles.dropFirst(maxRetainedSessions) {
            try? fm.removeItem(at: old)
            // summary 도 함께.
            let summaryURL = old.deletingPathExtension().appendingPathExtension("summary.json")
            try? fm.removeItem(at: summaryURL)
        }
    }
}
