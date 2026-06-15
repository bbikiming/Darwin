import Foundation

/// 프로파일 슬롯 모음 — Xbox 액세서리 패턴 (설계 §E). 순수 값 타입.
///
/// 모든 편집은 새 값을 반환하는 순수 함수. 활성 슬롯 1개가 항상 존재하며
/// (`profiles` 는 비지 않음), v1 단일 프로파일 저장과의 호환은 스토어가 책임진다.
public struct ControllerProfileSlots: Codable, Equatable, Sendable {

    /// 슬롯 상한 — 메뉴 가독성을 위한 보수적 한도.
    public static let maxSlots = 8

    public var profiles: [ControllerBindingProfile]
    public var activeIndex: Int

    public init(profiles: [ControllerBindingProfile], activeIndex: Int) {
        let safeProfiles = profiles.isEmpty ? [.xbox] : profiles
        self.profiles = safeProfiles
        self.activeIndex = min(max(0, activeIndex), safeProfiles.count - 1)
    }

    /// 기본 — Xbox 프리셋 슬롯 1개.
    public static let `default` = ControllerProfileSlots(profiles: [.xbox], activeIndex: 0)

    /// 활성 프로파일 (인덱스는 init 에서 클램프됨).
    public var active: ControllerBindingProfile { profiles[activeIndex] }

    // MARK: - 불변 편집

    /// 활성 슬롯 변경 — 범위 밖이면 현재 유지.
    public func selecting(_ index: Int) -> ControllerProfileSlots {
        guard profiles.indices.contains(index) else { return self }
        return ControllerProfileSlots(profiles: profiles, activeIndex: index)
    }

    /// 활성 슬롯의 프로파일 교체.
    public func updatingActive(_ profile: ControllerBindingProfile) -> ControllerProfileSlots {
        var next = profiles
        next[activeIndex] = profile
        return ControllerProfileSlots(profiles: next, activeIndex: activeIndex)
    }

    /// 활성 프로파일을 복제해 뒤에 추가하고 새 슬롯을 선택.
    /// 이름은 "{원본} 사본", 충돌 시 "{원본} 사본 2" … 상한 도달 시 무시.
    public func addingDuplicateOfActive() -> ControllerProfileSlots {
        guard profiles.count < Self.maxSlots else { return self }
        var copy = active
        copy.name = uniqueCopyName(of: active.name)
        let next = profiles + [copy]
        return ControllerProfileSlots(profiles: next, activeIndex: next.count - 1)
    }

    /// 활성 슬롯 삭제 — 마지막 1개는 유지. 삭제 후 직전 인덱스 선택.
    public func removingActive() -> ControllerProfileSlots {
        guard profiles.count > 1 else { return self }
        var next = profiles
        next.remove(at: activeIndex)
        return ControllerProfileSlots(profiles: next, activeIndex: max(0, activeIndex - 1))
    }

    // MARK: - 이름 충돌 해소

    private func uniqueCopyName(of base: String) -> String {
        let existing = Set(profiles.map(\.name))
        let candidate = "\(base) 사본"
        if !existing.contains(candidate) { return candidate }
        var counter = 2
        while existing.contains("\(candidate) \(counter)") { counter += 1 }
        return "\(candidate) \(counter)"
    }
}
