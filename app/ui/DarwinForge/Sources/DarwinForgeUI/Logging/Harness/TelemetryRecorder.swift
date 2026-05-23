import Foundation
import OSLog

// MARK: - TelemetryRecorder (Harness v1)
//
// Background actor that owns the on-disk JSONL writer.
// UI 는 `Harness.record(...)` 만 호출하고, 이 actor 가 enqueue → 배치 → fsync.
//
// 자세한 설계: docs/harness/telemetry-harness.md

/// 세션 메타 — 파일 상단에 함께 저장되는 정적 정보.
///
/// **v1.14.0 (2026-05-20)** — `isBaseline` 추가. cross-session diff 의 기준점 — 사용자가
/// "이 세션을 기준으로 다음 세션 변화 추적" 으로 지정. 동시 1개만 (Harness 가 관리).
public struct TelemetrySessionMeta: Codable, Sendable {
    public var schema: Int
    public var id: String
    public var started: String        // ISO-8601
    public var ended: String?         // ISO-8601 (nil = 진행 중 or 비정상 종료)
    public var appVersion: String
    public var appBuild: String
    public var os: String
    public var device: String
    public var eventCount: UInt64
    public var sizeBytes: UInt64
    public var droppedCount: UInt64
    public var connectCount: UInt64
    public var errorCount: UInt64
    public var pinned: Bool
    public var isBaseline: Bool

    public init(schema: Int = 1,
                id: String,
                started: String,
                ended: String? = nil,
                appVersion: String,
                appBuild: String,
                os: String,
                device: String,
                eventCount: UInt64 = 0,
                sizeBytes: UInt64 = 0,
                droppedCount: UInt64 = 0,
                connectCount: UInt64 = 0,
                errorCount: UInt64 = 0,
                pinned: Bool = false,
                isBaseline: Bool = false) {
        self.schema = schema
        self.id = id
        self.started = started
        self.ended = ended
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.os = os
        self.device = device
        self.eventCount = eventCount
        self.sizeBytes = sizeBytes
        self.droppedCount = droppedCount
        self.connectCount = connectCount
        self.errorCount = errorCount
        self.pinned = pinned
        self.isBaseline = isBaseline
    }

    /// **v1.14.0** Forward-compatibility — 이전 버전 meta.json 에 `isBaseline` 없으면 `false`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try c.decode(Int.self, forKey: .schema)
        self.id = try c.decode(String.self, forKey: .id)
        self.started = try c.decode(String.self, forKey: .started)
        self.ended = try c.decodeIfPresent(String.self, forKey: .ended)
        self.appVersion = try c.decode(String.self, forKey: .appVersion)
        self.appBuild = try c.decode(String.self, forKey: .appBuild)
        self.os = try c.decode(String.self, forKey: .os)
        self.device = try c.decode(String.self, forKey: .device)
        self.eventCount = try c.decodeIfPresent(UInt64.self, forKey: .eventCount) ?? 0
        self.sizeBytes = try c.decodeIfPresent(UInt64.self, forKey: .sizeBytes) ?? 0
        self.droppedCount = try c.decodeIfPresent(UInt64.self, forKey: .droppedCount) ?? 0
        self.connectCount = try c.decodeIfPresent(UInt64.self, forKey: .connectCount) ?? 0
        self.errorCount = try c.decodeIfPresent(UInt64.self, forKey: .errorCount) ?? 0
        self.pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        self.isBaseline = try c.decodeIfPresent(Bool.self, forKey: .isBaseline) ?? false
    }
}

/// In-flight queue 가 받는 record 명령.
fileprivate enum RecorderCommand: Sendable {
    case event(TelemetryEvent)
    case flush
    case finalize(endIso: String)
}

/// 단일 세션을 디스크에 굽는 actor. App 전역에 1개.
public actor TelemetryRecorder {
    // MARK: Public configuration

    public static let schemaVersion = 1
    public static let maxFileBytes: UInt64 = 50 * 1024 * 1024     // 50 MB rotation
    public static let flushBatch = 64
    public static let flushIntervalMs: UInt64 = 250
    public static let queueCapacity = 4096                        // overflow → drop

    // MARK: - errorCount mapping (cycle 192, codex critic MAJOR-1 cycle 188 fix)

    /// 사이클 192: errorCount switch 단일 source of truth.
    /// 본 list 의 kind 가 level=.error 로 emit 시 meta.errorCount += 1.
    ///
    /// # 비유
    ///
    /// 회사 의 사고 보고서 분류 표 — 신규 사고 유형 (cycle 181 plan_execution_failed,
    /// cycle 182 remote.command_error 등) 추가 시 본 표 + 테스트 둘 다 update 강제.
    /// 한 곳 만 바뀌면 분석 통계 false zero.
    ///
    /// # 포함
    ///
    /// 시스템 오류 / 안전 위반 / 통신 실패 — 운영자 가 즉시 알아야 하는 사건.
    ///
    /// # 제외
    ///
    /// `pilotEStop` (level=.warn, 사용자 안전 액션 — 시스템 오류 X). 분석 시 별도 카운트.
    public static let errorCountedKinds: [TelemetryKind] = [
        // System
        .errorException,
        // Connection
        .connectFailure,
        // Bus
        .busReadFail,
        .busWriteFail,
        .busEStop,
        // Pose
        .poseApplyFailed,
        // WalkLab
        .walkLabEmergencyStop,
        // Claude
        .claudeError,
        .claudePlanExecutionFailed,
        // Remote (cycle 182)
        .remoteCommandError,
        // Joint control (cycle 196)
        .jointActionFailed
    ]

    /// 사이클 192: O(1) lookup set — every record() 호출 마다 contains() check.
    /// 정적 — `errorCountedKinds` 의 raw value 만 사용.
    public static let errorCountedRawValues: Set<String> =
        Set(errorCountedKinds.map { $0.rawValue })

    // MARK: State

    public private(set) var meta: TelemetrySessionMeta
    public let directory: URL
    public let eventsURL: URL
    public let metaURL: URL

    private var handle: FileHandle?
    private var seq: UInt64 = 0
    private var inFlight: [TelemetryEvent] = []
    private var lastFlush: Date = .distantPast
    private var dropped: UInt64 = 0
    private var fileBytes: UInt64 = 0
    private var rotationIndex: Int = 0
    private var finalized: Bool = false

    // OSLog mirror — 디스크 외에 Console.app 에도 흐름 보조.
    private let mirror = Logger(subsystem: "com.darwinforge", category: "harness")

    // MARK: Init

    public init(directory: URL, meta: TelemetrySessionMeta) throws {
        self.directory = directory
        self.meta = meta
        self.eventsURL = directory.appendingPathComponent("events.jsonl")
        self.metaURL = directory.appendingPathComponent("meta.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: eventsURL)
        try handle?.seekToEnd()
        try Self.writeMetaSync(meta, to: metaURL)
    }

    deinit {
        try? handle?.close()
    }

    // MARK: Public API (called via Harness façade)

    /// Enqueue + 비차단. 즉시 반환. 호출자는 어떤 actor 든 가능 (nonisolated).
    public func enqueue(_ event: TelemetryEvent) {
        guard !finalized else { return }
        if inFlight.count >= Self.queueCapacity {
            dropped &+= 1
            return
        }
        var stamped = event
        seq &+= 1
        stamped = TelemetryEvent(
            schema: stamped.v,
            session: stamped.s,
            seq: seq,
            wall: stamped.tw,
            mono: stamped.tm,
            kind: stamped.k,
            level: stamped.lv,
            actor: stamped.a,
            data: stamped.d,
            context: stamped.c
        )
        inFlight.append(stamped)

        // Counter updates for meta.
        // 사이클 192 (codex critic MAJOR-1 cycle 188 fix): error-level emit sites 전수
        // 매핑. 종전 6 kind 만 → 4 누락 (connectFailure / poseApplyFailed / busEStop /
        // walkLabEmergencyStop) 추가. `Self.errorCountedKinds` 단일 source of truth —
        // 신규 error kind 추가 시 본 constant + 테스트 update 강제.
        //
        // **regression-proof**: 매 추가 시점에 errorCountedKinds + errorCountedRawValues
        // 둘 다 sync 필요 — 테스트 (testErrorCountedKindsRawValuesMatch) 가 강제.
        if Self.errorCountedRawValues.contains(stamped.k.rawValue) {
            if stamped.lv == .error { meta.errorCount &+= 1 }
        }
        if stamped.k.rawValue == TelemetryKind.connectSuccess.rawValue {
            meta.connectCount &+= 1
        }

        let now = Date()
        if inFlight.count >= Self.flushBatch
            || now.timeIntervalSince(lastFlush) * 1000 >= Double(Self.flushIntervalMs) {
            flushLocked()
        }
    }

    /// Flush in-flight buffer to disk + fsync.
    public func flush() {
        flushLocked()
    }

    /// 세션 종료 — meta.ended 채우고 finalize.
    public func finalize(endIso: String) {
        guard !finalized else { return }
        meta.ended = endIso
        flushLocked()
        try? Self.writeMetaSync(meta, to: metaURL)
        try? handle?.close()
        handle = nil
        finalized = true
    }

    // MARK: Internal

    private func flushLocked() {
        guard !inFlight.isEmpty else {
            lastFlush = Date()
            return
        }
        guard let handle else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var batchBytes = 0
        var written = 0     // **v1.12.2 Codex P2 fix** — 실제 성공한 write 만 카운트.
        for event in inFlight {
            do {
                var line = try encoder.encode(event)
                line.append(0x0A)  // '\n'
                try handle.write(contentsOf: line)
                batchBytes += line.count
                written += 1
            } catch {
                mirror.error("encode/write failed: \(error.localizedDescription, privacy: .public)")
                // 디스크 쓰기 실패 — handle 손상 가능. drop counter ↑, eventCount 는 영향 X.
                dropped &+= 1
            }
        }
        try? handle.synchronize()    // fsync — 정전/crash 손실 최소화.
        let writtenBytes = UInt64(batchBytes)
        fileBytes &+= writtenBytes
        meta.sizeBytes &+= writtenBytes
        meta.eventCount &+= UInt64(written)     // 성공한 것만 — Codex P2 fix.
        meta.droppedCount &+= dropped
        dropped = 0
        inFlight.removeAll(keepingCapacity: true)
        lastFlush = Date()

        // Periodic meta refresh — 0.1% overhead, 매 flush.
        try? Self.writeMetaSync(meta, to: metaURL)

        if fileBytes >= Self.maxFileBytes {
            rotateLocked()
        }
    }

    private func rotateLocked() {
        do {
            try handle?.close()
            handle = nil
            rotationIndex += 1
            let rotated = directory.appendingPathComponent("events.\(rotationIndex).jsonl")
            try FileManager.default.moveItem(at: eventsURL, to: rotated)
            FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: eventsURL)
            try handle?.seekToEnd()
            fileBytes = 0
        } catch {
            mirror.error("rotation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    fileprivate static func writeMetaSync(_ meta: TelemetrySessionMeta, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        try data.write(to: url, options: [.atomic])
    }
}

// MARK: - Session directory helpers

public enum TelemetryStore {
    public static let appSupportFolderName = "DarwinForge"
    public static let harnessFolderName = "Harness"
    public static let maxRetainedSessions = 30
    public static let maxRetainedBytes: UInt64 = 500 * 1024 * 1024

    /// `~/Library/Application Support/DarwinForge/Harness/`
    public static func rootDirectory() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent(appSupportFolderName, isDirectory: true)
            .appendingPathComponent(harnessFolderName, isDirectory: true)
    }

    public static func currentSessionDirectory(id: String) -> URL {
        rootDirectory().appendingPathComponent("current-\(id)", isDirectory: true)
    }

    public static func archivedSessionsDirectory() -> URL {
        rootDirectory().appendingPathComponent("sessions", isDirectory: true)
    }

    /// 진행 중 세션을 sessions/ 로 이동. 앱 종료 / 크래시 복구 시 호출.
    public static func archive(currentDir: URL) {
        let target = archivedSessionsDirectory()
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let final = target.appendingPathComponent(currentDir.lastPathComponent.replacingOccurrences(of: "current-", with: ""))
        try? FileManager.default.moveItem(at: currentDir, to: final)
    }

    /// 부팅 시 호출 — 이전 실행이 비정상 종료해 current-* 가 남아 있으면 archive 로 옮김.
    public static func archiveOrphanedSessions() {
        let root = rootDirectory()
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for url in items where url.lastPathComponent.hasPrefix("current-") {
            archive(currentDir: url)
        }
    }

    /// 보존 정책 적용 — 30 세션 또는 500 MB 초과 시 오래된 것부터 삭제 (`pinned` 제외).
    ///
    /// **v1.12.2 (Codex P1-4 fix)** — 종전 dir attribute 의 `.size` 는 디렉토리 자체
    /// inode 크기(보통 0~수십 KB)라 cap 평가가 무의미. 재귀 enumerator 로 events.jsonl
    /// + rotation files + meta.json 까지 합산해야 실 디스크 사용량 반영.
    @discardableResult
    public static func enforceRetention() -> Int {
        let archive = archivedSessionsDirectory()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: archive,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }

        struct Entry { let url: URL; let date: Date; let size: UInt64; let pinned: Bool }
        var entries: [Entry] = []
        for url in items {
            let meta = loadMeta(in: url)
            let pinned = meta?.pinned ?? false
            let size = directorySize(url)
            let date: Date = {
                if let ended = meta?.ended, let d = ISO8601DateFormatter().date(from: ended) { return d }
                if let started = meta.map({ $0.started }), let d = ISO8601DateFormatter().date(from: started) { return d }
                return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            }()
            entries.append(Entry(url: url, date: date, size: size, pinned: pinned))
        }
        entries.sort { $0.date < $1.date }  // 오래된 순.
        var removed = 0

        // Pinned 제외 후 카운트 / 사이즈 평가.
        let prunable = entries.filter { !$0.pinned }
        let total = prunable.count
        var totalBytes = prunable.reduce(0) { $0 + $1.size }

        var pruneList: [Entry] = []
        if total > maxRetainedSessions {
            pruneList.append(contentsOf: prunable.prefix(total - maxRetainedSessions))
        }
        if totalBytes > maxRetainedBytes {
            for e in prunable where !pruneList.contains(where: { $0.url == e.url }) {
                if totalBytes <= maxRetainedBytes { break }
                pruneList.append(e)
                totalBytes &-= e.size
            }
        }
        for e in pruneList {
            try? FileManager.default.removeItem(at: e.url)
            removed += 1
        }
        return removed
    }

    /// 디렉토리 안 모든 파일 크기 합산 (재귀).
    /// events.jsonl + 모든 events.N.jsonl rotation + meta.json 등 포함.
    static func directorySize(_ url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let file as URL in en {
            let v = try? file.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            if let s = v?.totalFileAllocatedSize ?? v?.fileAllocatedSize {
                total &+= UInt64(s)
            }
        }
        return total
    }

    public static func loadMeta(in sessionDir: URL) -> TelemetrySessionMeta? {
        let url = sessionDir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TelemetrySessionMeta.self, from: data)
    }

    /// `sessions/` 하위 archived 세션 목록 — 최신순.
    public static func archivedSessions() -> [(dir: URL, meta: TelemetrySessionMeta)] {
        let archive = archivedSessionsDirectory()
        guard let items = try? FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [(URL, TelemetrySessionMeta)] = []
        for url in items {
            guard let meta = loadMeta(in: url) else { continue }
            out.append((url, meta))
        }
        out.sort {
            let a = $0.1.started, b = $1.1.started
            return a > b
        }
        return out
    }
}
