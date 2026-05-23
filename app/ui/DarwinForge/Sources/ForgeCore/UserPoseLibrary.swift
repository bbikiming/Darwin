import Foundation

/// 사용자가 직접 캡처한 자세 라이브러리 — UserDefaults 영구 저장.
///
/// 정직: 내장 `PoseLibrary` 의 자세 raw 값은 추측 기반이라 ROBOTIS-OP2 실측과 다를 수 있다.
/// 가장 정확한 방법:
///   1. 티칭 모드에서 토크 해제 → 손으로 자세 잡기 → 캡처
///   2. `UserPoseLibrary.save(name:pose:)` 로 영구 저장
///   3. `MotionBuilder` / 대화 메뉴 / Motion Studio 에서 활용
///
/// 사용자 자세는 빌트인 PoseLibrary 보다 검색 우선순위 높음 — 사용자 실측이 신뢰도 1순위.
@MainActor
public final class UserPoseLibrary: ObservableObject {

    public static let shared = UserPoseLibrary()

    public struct Entry: Identifiable, Codable, Equatable {
        public let id: UUID
        public var name: String
        public var category: String  // "user"
        public var keywords: [String]
        public var pose: RobotPose
        public let capturedAt: Date

        public init(id: UUID = UUID(), name: String, category: String = "user",
                    keywords: [String] = [], pose: RobotPose,
                    capturedAt: Date = Date()) {
            self.id = id
            self.name = name
            self.category = category
            self.keywords = keywords
            self.pose = pose
            self.capturedAt = capturedAt
        }
    }

    @Published public private(set) var entries: [Entry] = []

    private static let storageKey = "df.userPoseLibrary.v1"

    private let defaults: UserDefaults

    /// DI 지원 init — 테스트에서 격리된 UserDefaults 주입 가능.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// 사용자 캡처 자세 저장.
    public func save(name: String, pose: RobotPose, keywords: [String] = []) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "캡처 \(entries.count + 1)" : trimmed
        let entry = Entry(name: finalName, keywords: keywords, pose: pose)
        entries.insert(entry, at: 0)
        persist()
    }

    public func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    public func rename(_ entry: Entry, to newName: String) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].name = newName
            persist()
        }
    }

    public func clear() {
        entries.removeAll()
        persist()
    }

    /// id 또는 name 매칭. 사용자 라이브러리 → 빌트인 라이브러리 순.
    public func search(_ query: String) -> Entry? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return entries.first { e in
            e.name.lowercased().contains(q)
            || e.id.uuidString.lowercased().contains(q)
            || e.keywords.contains { $0.lowercased().contains(q) }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
