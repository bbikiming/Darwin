import Foundation

/// **v1.20.22 (2026-05-22) 사이클 28 — Motion catalog resolution**.
///
/// PilotIntent.motion(String) 의 String id 를 MotionDescriptor 로 변환.
/// 사용자가 "wave" / "preset.march" / "page.bow" 같은 id 를 send → catalog 가 해석 → bridge
/// 가 handleMotion 호출 → MotionBlender 실행.
///
/// # 비유
///
/// macOS DNS 같음 — 사용자가 "google.com" 입력 (= id), DNS 가 IP (= MotionDescriptor) 로
/// 변환. 다양한 backend (Hosts file / public DNS / local cache) 가 같은 인터페이스 구현.
///
/// # 기본 backend
///
/// `PresetBackedPilotMotionCatalog` — id 가 `"preset.<name>"` 형식이면 `WalkLabPreset` enum
/// 매칭 → `.walk(preset)` descriptor. e.g. "preset.march", "preset.idle".
///
/// 미래: PageBackedCatalog (RoboPlus page), TeachBackedCatalog (사용자 저장 자세).
public protocol PilotMotionCatalog: Sendable {
    /// id → MotionDescriptor 변환. nil = 알 수 없는 id.
    func resolve(_ id: String) -> MotionDescriptor?
    /// 본 catalog 가 인식하는 모든 id (UI 자동 완성 / help).
    var knownIds: [String] { get }
}

/// **v1.20.22 사이클 28** — WalkLabPreset 매핑만 지원하는 minimal backend.
/// id format: `"preset.<rawValue>"` (e.g. "preset.march", "preset.slowWalk").
/// case-insensitive prefix match.
public struct PresetBackedPilotMotionCatalog: PilotMotionCatalog {
    public init() {}

    public func resolve(_ id: String) -> MotionDescriptor? {
        let lower = id.lowercased()
        guard lower.hasPrefix("preset.") else { return nil }
        let presetName = String(lower.dropFirst("preset.".count))
        guard let preset = WalkLabPreset.allCases.first(where: { $0.rawValue.lowercased() == presetName }) else {
            return nil
        }
        return .walk(preset)
    }

    public var knownIds: [String] {
        WalkLabPreset.allCases.map { "preset.\($0.rawValue)" }
    }
}

/// **v1.20.24 사이클 30** — motion_4096 페이지 backed catalog.
/// id format: `"page.<slot>"` (숫자 slot, e.g. "page.1", "page.24")
///           또는 `"page.<rawName>"` (e.g. "page.Bow", "page.Wave")
/// 기존 enum `MotionCatalog.all` (motion_4096 메타데이터) → `.page(MotionPageMetadata)` descriptor.
public struct PageBackedPilotMotionCatalog: PilotMotionCatalog {
    public init() {}

    public func resolve(_ id: String) -> MotionDescriptor? {
        let lower = id.lowercased()
        guard lower.hasPrefix("page.") else { return nil }
        let key = String(lower.dropFirst("page.".count))
        // slot 숫자 시도.
        if let slot = UInt8(key), let page = MotionCatalog.find(slot: slot) {
            return .page(page)
        }
        // rawName / displayName 매칭.
        if let page = MotionCatalog.all.first(where: {
            $0.rawName.lowercased() == key
                || $0.displayName.lowercased() == key
                || $0.displayNameKo.lowercased() == key
        }) {
            return .page(page)
        }
        return nil
    }

    public var knownIds: [String] {
        MotionCatalog.all.map { "page.\($0.slot)" }
    }
}

/// **v1.20.22 사이클 28** — 여러 catalog 합성 (chain of responsibility).
/// 순서대로 resolve 시도 → 첫 hit 반환. 명시 우선순위 제어.
public struct CompositePilotMotionCatalog: PilotMotionCatalog {
    public let catalogs: [PilotMotionCatalog]

    public init(_ catalogs: [PilotMotionCatalog]) {
        self.catalogs = catalogs
    }

    public func resolve(_ id: String) -> MotionDescriptor? {
        for catalog in catalogs {
            if let descriptor = catalog.resolve(id) {
                return descriptor
            }
        }
        return nil
    }

    public var knownIds: [String] {
        catalogs.flatMap(\.knownIds)
    }
}
