import Foundation

/// **v1.15.0 (2026-05-21) — Phase 1 영속 저장**.
///
/// `WalkTrialStore` 는 `WalkTrial` 의 영속 저장 + 검색 backend 입니다.
///
/// # 저장 구조
///
/// ```
/// ~/Library/Application Support/DarwinForge/trials/
///   ├── index.json              // 전체 trial 요약 (TrialIndexEntry 배열, 검색 가속)
///   ├── <uuid-1>.trial.json     // 개별 WalkTrial 전체 데이터
///   ├── <uuid-2>.trial.json
///   └── ...
/// ```
///
/// timeseries (`.jsonl`) 은 기존 `WalkSessionStore` (`sessions/` 디렉토리) 에 있는 그대로 사용.
/// WalkTrial 의 `timeseries.jsonlRelativePath` 가 그 파일 가리킴 — duplicate encoding X.
///
/// # 동시성
///
/// **v1.15.0.1 (2026-05-21) fix** — @MainActor 제거. 종전: WalkLabSession 의 Task.detached
/// 안에서 `loadTimeseriesSamples(ref:)` 호출 시 background queue 에서 `.shared` 의 lazy init
/// 이 fire → @MainActor isolation 위반 → SIGTRAP. 신규: nonisolated 로 두고 file I/O 의
/// 자체 thread-safety (FileManager + atomic write) 에 의존. swift Dictionary write 가 race 없음.
///
/// # 비유
///
/// 도서관 카드 catalog — `index.json` 은 카드 목록 (제목/저자/위치), `<id>.trial.json` 은 책
/// 자체. 도서관 직원이 카드 보고 책 위치 찾아오듯 query 는 index 만 보고 빠르게 filter.
///
/// # Retention
///
/// trial 자체는 영구 보관 (작은 metadata 파일). timeseries jsonl 은 `WalkSessionStore.
/// cleanupOldSessions` 가 30일 cap 별도 관리. trial 의 timeseries ref 가 stale 일 수 있음 —
/// `loadTimeseries(_:)` 호출 시 file 존재 확인 후 nil 반환.
public final class WalkTrialStore: @unchecked Sendable {
    // @unchecked Sendable — 모든 mutation 이 file I/O (atomic write) + Swift atomic.

    /// 전역 shared instance — 앱 launch 시 1회 init, 어디서나 같은 store.
    public static let shared = WalkTrialStore()

    // MARK: - Storage paths

    private let trialsDir: URL
    private let indexURL: URL
    private let sessionsDir: URL  // 기존 WalkSessionStore 와 같은 위치 — timeseries 검증용.

    /// init — Application Support 디렉토리 생성. 실패 시 falls back to /tmp (테스트 환경).
    public init() {
        let fm = FileManager.default
        let appSupport: URL
        do {
            appSupport = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            // Test or sandbox failure — temp 사용.
            appSupport = URL(fileURLWithPath: NSTemporaryDirectory())
        }
        let darwinForge = appSupport.appendingPathComponent("DarwinForge", isDirectory: true)
        self.trialsDir = darwinForge.appendingPathComponent("trials", isDirectory: true)
        self.indexURL = trialsDir.appendingPathComponent("index.json")
        self.sessionsDir = darwinForge.appendingPathComponent("sessions", isDirectory: true)
        try? fm.createDirectory(at: trialsDir, withIntermediateDirectories: true)
    }

    /// **테스트 전용** — 디렉토리 override (실 App Support 와 격리).
    /// 사용 패턴: `WalkTrialStore(testDirectory: tmpURL)`.
    public init(testDirectory: URL) {
        self.trialsDir = testDirectory.appendingPathComponent("trials", isDirectory: true)
        self.indexURL = trialsDir.appendingPathComponent("index.json")
        self.sessionsDir = testDirectory.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: trialsDir, withIntermediateDirectories: true)
    }

    // MARK: - CRUD

    /// 신규 trial 저장 + index update. 같은 id 가 이미 있으면 overwrite.
    @discardableResult
    public func append(_ trial: WalkTrial) -> Bool {
        let trialURL = trialFileURL(id: trial.id)
        guard let data = try? jsonEncoder.encode(trial) else { return false }
        do {
            try data.write(to: trialURL, options: .atomic)
        } catch {
            return false
        }
        // Index 갱신 — 같은 id 가 있으면 replace.
        var index = loadIndex()
        if let existing = index.firstIndex(where: { $0.id == trial.id }) {
            index[existing] = TrialIndexEntry.from(trial)
        } else {
            index.append(TrialIndexEntry.from(trial))
        }
        saveIndex(index)
        return true
    }

    /// id 로 trial 단건 로드. 없으면 nil.
    public func load(id: String) -> WalkTrial? {
        let url = trialFileURL(id: id)
        guard let data = try? Data(contentsOf: url),
              let trial = try? jsonDecoder.decode(WalkTrial.self, from: data)
        else { return nil }
        return trial
    }

    /// label 만 갱신 — 전체 trial 로드 → label 교체 → 저장. index 의 rating/tagsCount 도 갱신.
    @discardableResult
    public func updateLabel(id: String, label: UserLabel) -> Bool {
        guard let trial = load(id: id) else { return false }
        let updated = WalkTrial(
            id: trial.id,
            startedAtIso: trial.startedAtIso,
            endedAtIso: trial.endedAtIso,
            durationSec: trial.durationSec,
            endReason: trial.endReason,
            config: trial.config,
            outcome: trial.outcome,
            label: label,
            timeseries: trial.timeseries
        )
        return append(updated)  // overwrite + index update.
    }

    /// trial 삭제. timeseries jsonl 은 건드리지 않음 (별도 retention 정책).
    @discardableResult
    public func delete(id: String) -> Bool {
        let url = trialFileURL(id: id)
        try? FileManager.default.removeItem(at: url)
        var index = loadIndex()
        index.removeAll { $0.id == id }
        saveIndex(index)
        return true
    }

    /// 모든 trial 의 index 반환 (시각 역순 — 최신이 먼저).
    public func allIndex() -> [TrialIndexEntry] {
        loadIndex().sorted { $0.startedAtIso > $1.startedAtIso }
    }

    /// query — filter + sort 통합.
    public func query(filter: TrialFilter = .init(), sort: TrialSort = .startedDesc) -> [TrialIndexEntry] {
        let index = loadIndex()
        let filtered = index.filter(filter.matches)
        return filtered.sorted(by: sort.comparator)
    }

    // MARK: - Timeseries helpers

    /// timeseries jsonl 파일 존재 확인. 30일 retention 초과 시 false.
    public func hasTimeseries(_ ref: TimeseriesRef) -> Bool {
        let url = sessionsDir.appendingPathComponent(ref.jsonlRelativePath, isDirectory: false)
            .standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// timeseries 전체 로드 — 분석/시각화 용. 대용량 가능 → background queue 권장.
    /// 파일 없으면 nil.
    public func loadTimeseriesSamples(ref: TimeseriesRef) -> [WalkSessionSample]? {
        let url = sessionsDir.appendingPathComponent(ref.jsonlRelativePath, isDirectory: false)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var samples: [WalkSessionSample] = []
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard let data = String(line).data(using: .utf8) else { continue }
            // 첫 줄은 header 일 수 있음 — sessionId 필드로 구분.
            if let sample = try? jsonDecoder.decode(WalkSessionSample.self, from: data) {
                samples.append(sample)
            }
        }
        return samples
    }

    // MARK: - Internal — file helpers

    private func trialFileURL(id: String) -> URL {
        trialsDir.appendingPathComponent("\(id).trial.json")
    }

    private func loadIndex() -> [TrialIndexEntry] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? jsonDecoder.decode([TrialIndexEntry].self, from: data)
        else { return [] }
        return index
    }

    private func saveIndex(_ index: [TrialIndexEntry]) {
        guard let data = try? jsonEncoder.encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private var jsonEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private var jsonDecoder: JSONDecoder {
        JSONDecoder()
    }
}

// MARK: - Filter & Sort

/// trial query 의 filter 조건. 모든 필드 nil = filter 안 함.
public struct TrialFilter: Equatable, Sendable {
    public var preset: String? = nil
    public var minRating: Int? = nil  // 1..5, 0 인 미평가는 제외 (rating > 0).
    public var endReason: EndReason? = nil
    /// 최소 overall score (0..1).
    public var minOverallScore: Double? = nil
    public var minStabilityScore: Double? = nil
    /// "fall event 0 만" 필터.
    public var noFallsOnly: Bool = false
    /// "실 robot 만" (sim 제외).
    public var realRobotOnly: Bool = false
    /// 시작 ISO 이후 (포함). nil = 전부.
    public var startedAfterIso: String? = nil
    /// 시작 ISO 이전 (포함). nil = 전부.
    public var startedBeforeIso: String? = nil

    public init(
        preset: String? = nil, minRating: Int? = nil, endReason: EndReason? = nil,
        minOverallScore: Double? = nil, minStabilityScore: Double? = nil,
        noFallsOnly: Bool = false, realRobotOnly: Bool = false,
        startedAfterIso: String? = nil, startedBeforeIso: String? = nil
    ) {
        self.preset = preset
        self.minRating = minRating
        self.endReason = endReason
        self.minOverallScore = minOverallScore
        self.minStabilityScore = minStabilityScore
        self.noFallsOnly = noFallsOnly
        self.realRobotOnly = realRobotOnly
        self.startedAfterIso = startedAfterIso
        self.startedBeforeIso = startedBeforeIso
    }

    public func matches(_ e: TrialIndexEntry) -> Bool {
        if let p = preset, e.preset != p { return false }
        if let r = minRating, e.rating < r { return false }
        if let er = endReason, e.endReason != er { return false }
        if let s = minOverallScore, e.overallScore < s { return false }
        if let s = minStabilityScore, e.stabilityScore < s { return false }
        if noFallsOnly, e.fallEventCount > 0 { return false }
        if realRobotOnly, !e.isRealRobot { return false }
        if let after = startedAfterIso, e.startedAtIso < after { return false }
        if let before = startedBeforeIso, e.startedAtIso > before { return false }
        return true
    }
}

/// trial query 의 sort 순서.
public enum TrialSort: String, CaseIterable, Sendable, Identifiable {
    case startedDesc      // 최신이 먼저 (default).
    case startedAsc
    case overallDesc      // 점수 높은 순.
    case overallAsc
    case stabilityDesc
    case durationDesc     // 오래 보행한 순.
    case ratingDesc       // 별점 높은 순 (rating 0 = 마지막).

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .startedDesc:   return "최신순"
        case .startedAsc:    return "오래된순"
        case .overallDesc:   return "총점 높은순"
        case .overallAsc:    return "총점 낮은순"
        case .stabilityDesc: return "안정성 높은순"
        case .durationDesc:  return "오래 보행순"
        case .ratingDesc:    return "별점 높은순"
        }
    }

    func comparator(_ a: TrialIndexEntry, _ b: TrialIndexEntry) -> Bool {
        switch self {
        case .startedDesc:   return a.startedAtIso > b.startedAtIso
        case .startedAsc:    return a.startedAtIso < b.startedAtIso
        case .overallDesc:   return a.overallScore > b.overallScore
        case .overallAsc:    return a.overallScore < b.overallScore
        case .stabilityDesc: return a.stabilityScore > b.stabilityScore
        case .durationDesc:  return a.durationSec > b.durationSec
        case .ratingDesc:
            // rating 0 (미평가) 는 항상 마지막. 그 외는 내림차순.
            if a.rating == 0 && b.rating != 0 { return false }
            if a.rating != 0 && b.rating == 0 { return true }
            return a.rating > b.rating
        }
    }
}
