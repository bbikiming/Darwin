import Foundation

/// v2 JSONL writer. line type + schemaVersion 을 모든 줄에 기록한다.
///
/// 설계:
/// - 한 세션 = 한 파일. `~/Library/Application Support/DarwinForge/sessions/<sessionId>-<preset>.jsonl`
/// - 첫 줄에 header 한 줄, 이후 sample/event 가 시간순으로 섞임, 마지막에 footer.
/// - actor-isolated 하지 않음 — caller (WalkLabSession) 가 `MainActor` 에서만 호출.
///   백그라운드 dispatch 필요 시 caller 가 책임.
/// - encode 실패는 silent — sample 한 줄 실패가 세션 전체를 깨면 안 된다. 대신 internal
///   counter (`writeFailures`) 를 노출해서 footer 에 기록.
public final class WalkSessionLogger {
    public struct Configuration: Sendable {
        public let directory: URL
        public let fileNameOverride: String?

        public init(directory: URL, fileNameOverride: String? = nil) {
            self.directory = directory
            self.fileNameOverride = fileNameOverride
        }

        public static func defaultUserDirectory() -> URL {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask).first!
            return appSupport
                .appendingPathComponent("DarwinForge", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
    }

    public let configuration: Configuration
    public private(set) var fileURL: URL?
    public private(set) var totalSamples: Int = 0
    public private(set) var totalEvents: Int = 0
    public private(set) var writeFailures: Int = 0

    private var handle: FileHandle?
    private let encoder: JSONEncoder

    public init(configuration: Configuration = .init(directory: Configuration.defaultUserDirectory())) {
        self.configuration = configuration
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = enc
    }

    // MARK: - lifecycle

    @discardableResult
    public func open(header: WalkSessionHeaderV2) throws -> URL {
        try FileManager.default.createDirectory(at: configuration.directory,
                                                withIntermediateDirectories: true)
        let baseName = configuration.fileNameOverride ?? "\(header.sessionId)-\(header.preset)"
        let url = configuration.directory.appendingPathComponent(baseName).appendingPathExtension("jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.fileURL = url
        self.handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
        write(header)
        return url
    }

    public func write(_ header: WalkSessionHeaderV2) {
        writeLine(header)
    }

    public func write(_ sample: WalkSessionSampleV2) {
        writeLine(sample)
        if handle != nil { totalSamples += 1 }
    }

    public func write(_ event: WalkSessionEventV2) {
        writeLine(event)
        if handle != nil { totalEvents += 1 }
    }

    public func close(reason: String = "userStop", endedNormally: Bool = true) {
        let footer = WalkSessionFooterV2(
            endTimeIso: WalkSessionClock.iso8601(Date()),
            totalSamples: totalSamples,
            totalEvents: totalEvents,
            endedNormally: endedNormally,
            endReason: reason
        )
        writeLine(footer)
        try? handle?.close()
        handle = nil
    }

    deinit {
        try? handle?.close()
    }

    // MARK: - internals

    private func writeLine<T: Encodable>(_ value: T) {
        guard let handle = handle else { writeFailures += 1; return }
        do {
            let data = try encoder.encode(value)
            handle.write(data)
            handle.write(Data([0x0A])) // \n
        } catch {
            writeFailures += 1
        }
    }
}

/// 시간 / 시계 유틸. ISO8601 변환과 sessionId 생성에 같은 fmt 를 쓰기 위해 따로 분리.
public enum WalkSessionClock {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    /// 파일명 / sessionId 친화적 형태. `:` 와 `.` 를 `-` 로 치환.
    public static func sessionId(_ date: Date) -> String {
        iso8601(date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }
}
