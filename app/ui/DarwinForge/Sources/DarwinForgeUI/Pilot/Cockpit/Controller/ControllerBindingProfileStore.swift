import Foundation

// MARK: - 상수

/// UserDefaults 저장 키. 버전 접미사로 마이그레이션 관리.
private let kControllerBindingProfileKey = "cockpit.controller.binding.profile.v1"
/// 슬롯 모음 저장 키 (설계 §E). v1 키는 활성 슬롯과 항상 동기화해 하위 호환 유지.
private let kControllerProfileSlotsKey = "cockpit.controller.binding.profiles.v2"

// MARK: - ControllerBindingProfileStore

/// `ControllerBindingProfile` 의 UserDefaults JSON 영속화.
///
/// `DJIBindingProfileStore` 와 동일한 패턴. JSON export/import 도 지원해
/// 프로파일을 파일로 공유하거나 PC↔로봇 간 이식할 수 있다 (PRD PROF-03).
public enum ControllerBindingProfileStore {

    // MARK: - 로드/저장/초기화

    /// 저장된 프로파일을 로드. 없으면 `.xbox` 기본 프리셋 반환.
    public static func load(_ defaults: UserDefaults = .standard) -> ControllerBindingProfile {
        guard
            let data = defaults.data(forKey: kControllerBindingProfileKey),
            let profile = try? JSONDecoder().decode(ControllerBindingProfile.self, from: data)
        else {
            return .xbox
        }
        return profile
    }

    /// 프로파일을 UserDefaults 에 JSON 직렬화 저장.
    public static func save(
        _ profile: ControllerBindingProfile,
        into defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: kControllerBindingProfileKey)
    }

    /// 저장된 프로파일을 삭제 (다음 load 시 기본 프리셋 반환).
    public static func reset(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: kControllerBindingProfileKey)
    }

    // MARK: - 슬롯 (v2)

    /// 슬롯 모음 로드. v2 가 없으면 v1 단일 프로파일을 슬롯 0 으로 마이그레이션,
    /// 둘 다 없으면 기본(Xbox 1개).
    public static func loadSlots(_ defaults: UserDefaults = .standard) -> ControllerProfileSlots {
        if let data = defaults.data(forKey: kControllerProfileSlotsKey),
           let slots = try? JSONDecoder().decode(ControllerProfileSlots.self, from: data) {
            return slots
        }
        if let data = defaults.data(forKey: kControllerBindingProfileKey),
           let legacy = try? JSONDecoder().decode(ControllerBindingProfile.self, from: data) {
            return ControllerProfileSlots(profiles: [legacy], activeIndex: 0)
        }
        return .default
    }

    /// 슬롯 모음 저장 — v1 키도 활성 슬롯으로 동기화해 기존 `load()` 경로
    /// (드라이버 등)가 항상 활성 프로파일을 본다.
    public static func saveSlots(
        _ slots: ControllerProfileSlots,
        into defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(slots) else { return }
        defaults.set(data, forKey: kControllerProfileSlotsKey)
        save(slots.active, into: defaults)
    }

    // MARK: - JSON import / export (PROF-03)

    /// 프로파일을 JSON `Data` 로 내보내기. 직렬화 실패 시 nil.
    public static func export(_ profile: ControllerBindingProfile) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(profile)
    }

    /// JSON `Data` 에서 프로파일 가져오기. 파싱 실패 시 nil.
    public static func `import`(_ data: Data) -> ControllerBindingProfile? {
        try? JSONDecoder().decode(ControllerBindingProfile.self, from: data)
    }
}
