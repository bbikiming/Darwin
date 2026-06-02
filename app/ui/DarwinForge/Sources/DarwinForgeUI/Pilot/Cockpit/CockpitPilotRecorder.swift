import Foundation

/// **Cockpit 실 robot 테스트 데이터 recorder** — JSONL 영속화 + 메모리 ring.
///
/// `CockpitPilotTestData` 스키마를 디스크에 기록. `PilotCockpitView` 가 setup 시
/// 생성, dispatch/event 마다 append, teardown 시 finalize (summary 산출).
///
/// # 비유
///
/// 비행 기록 장치 (black box). 비행 (조종) 중 모든 입력·자세를 끊임없이 디스크에
/// 적고, 착륙 (세션 종료) 시 요약 카드 한 장 (summary.json) 을 남긴다. 추후 사고
/// 분석 (개선) 시 black box 를 열어 원인 추적.
///
/// # 설계
///
/// - `@MainActor` — CockpitState / WalkLabSession 과 동일 isolation (await 비용 0).
/// - append 는 `FileHandle` 직접 write (WalkSessionLogger 와 동일 패턴, 매 줄 flush).
/// - 메모리에도 dispatches/events 보존 → finalize 시 summary 순수 계산 + UI 라이브
///   inspection 가능.
/// - 파일 I/O 실패는 silent (조종 자체는 진행 — 기록은 best-effort).
@MainActor
public final class CockpitPilotRecorder {

    public let sessionDir: URL
    public let manifest: CockpitPilotManifest

    private let dispatchHandle: FileHandle?
    private let eventHandle: FileHandle?
    private let encoder: JSONEncoder
    private let startWall: Date

    private var dispatches: [CockpitPilotDispatch] = []
    private var events: [CockpitPilotEvent] = []
    private var finalized = false

    /// `~/Library/Application Support/DarwinForge/CockpitPilot/`
    public static func rootDirectory() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("DarwinForge", isDirectory: true)
            .appendingPathComponent("CockpitPilot", isDirectory: true)
    }

    /// 세션 디렉토리 생성 + manifest.json write + dispatches/events.jsonl open.
    ///
    /// - Parameters:
    ///   - manifest: 세션 시작 환경. `sessionId` 가 디렉토리명.
    ///   - rootOverride: 테스트용 디렉토리 주입 (default = rootDirectory()).
    public init(manifest: CockpitPilotManifest, rootOverride: URL? = nil) {
        self.manifest = manifest
        self.startWall = Date()
        let root = rootOverride ?? Self.rootDirectory()
        let dir = root.appendingPathComponent(manifest.sessionId, isDirectory: true)
        self.sessionDir = dir

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc

        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // manifest.json (atomic).
        if let data = try? enc.encode(manifest) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"),
                            options: .atomic)
        }

        // dispatches.jsonl / events.jsonl 빈 파일 생성 후 handle open.
        let dispatchURL = dir.appendingPathComponent("dispatches.jsonl")
        let eventURL = dir.appendingPathComponent("events.jsonl")
        fm.createFile(atPath: dispatchURL.path, contents: nil)
        fm.createFile(atPath: eventURL.path, contents: nil)
        self.dispatchHandle = try? FileHandle(forWritingTo: dispatchURL)
        self.eventHandle = try? FileHandle(forWritingTo: eventURL)
    }

    /// 세션 시작 기준 경과 ms.
    private func nowTMs() -> Double {
        Date().timeIntervalSince(startWall) * 1000.0
    }

    // MARK: - Append

    public func logDispatch(source: String,
                            cmdStrideMm: Double, cmdSideMm: Double,
                            cmdTurnDeg: Double, periodMs: Double,
                            effStrideMm: Double, effSideMm: Double,
                            effTurnDeg: Double, robotSpeedMmPerSec: Double,
                            imuRollDeg: Double, imuPitchDeg: Double,
                            balanceOn: Bool, accepted: Bool, gateReason: String?) {
        guard !finalized else { return }
        let record = CockpitPilotDispatch(
            tMs: nowTMs(), source: source,
            cmdStrideMm: cmdStrideMm, cmdSideMm: cmdSideMm, cmdTurnDeg: cmdTurnDeg,
            periodMs: periodMs,
            effStrideMm: effStrideMm, effSideMm: effSideMm, effTurnDeg: effTurnDeg,
            robotSpeedMmPerSec: robotSpeedMmPerSec,
            imuRollDeg: imuRollDeg, imuPitchDeg: imuPitchDeg,
            balanceOn: balanceOn, accepted: accepted, gateReason: gateReason)
        dispatches.append(record)
        appendLine(record, to: dispatchHandle)
    }

    public func logEvent(_ kind: CockpitPilotEventKind, detail: String? = nil) {
        guard !finalized else { return }
        let record = CockpitPilotEvent(tMs: nowTMs(), kind: kind, detail: detail)
        events.append(record)
        appendLine(record, to: eventHandle)
    }

    private func appendLine<T: Encodable>(_ value: T, to handle: FileHandle?) {
        guard let handle, let data = try? encoder.encode(value) else { return }
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data("\n".utf8))
    }

    // MARK: - Finalize

    /// summary.json write + handle close. 중복 호출 안전 (finalized guard).
    /// - Returns: 산출된 summary (UI 표시 / 테스트 검증용). 이미 finalize 됐으면 nil.
    @discardableResult
    public func finalize() -> CockpitPilotSummary? {
        guard !finalized else { return nil }
        finalized = true
        let summary = CockpitPilotSummary.compute(
            sessionId: manifest.sessionId,
            dispatches: dispatches,
            events: events,
            endTMs: nowTMs())
        if let data = try? encoder.encode(summary) {
            try? data.write(to: sessionDir.appendingPathComponent("summary.json"),
                            options: .atomic)
        }
        try? dispatchHandle?.close()
        try? eventHandle?.close()
        return summary
    }

    // MARK: - Inspection (테스트 / 라이브 UI)

    public var dispatchCount: Int { dispatches.count }
    public var eventCount: Int { events.count }
}
