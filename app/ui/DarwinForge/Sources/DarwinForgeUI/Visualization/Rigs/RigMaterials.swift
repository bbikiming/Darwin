import SceneKit
import SwiftUI

/// 부위 카테고리 → PBR `SCNMaterial` 팩토리.
///
/// **W1 (2026-06-11)**: Blinn-Phong 단색을 physicallyBased 로 전환. IBL
/// (`scene.lightingEnvironment`)이 base 를 깔아주므로 metalness/roughness 가
/// 형태감을 만든다. 메시가 21개뿐이라 배칭 이득이 작으므로 **메시별 개별 머티리얼**
/// 을 유지(프로토타입을 `copy()` 해 반환) — `emission` 채널 변경(highlight)이 전
/// 부위로 전파되는 충돌 방지. 기존 `originalEmissions` 캐시 로직 그대로 동작.
enum RigMaterials {

    enum Category {
        case whiteShell    // body, thigh, shin, upper-arm, head, lower-arm, 프리미티브 bodyShell
        case aluminum      // shoulder, hip-yaw, hip-roll, ankle, neck
        case rubberFoot    // foot
    }

    /// **옵션 플래그**: whiteShell clearcoat — 비용 + 번아웃 변수라 기본 off.
    static var whiteShellClearcoat = false

    // MARK: - 팩토리

    /// 카테고리별 PBR 머티리얼(개별 인스턴스). 값은 `SceneTuning.shared` 에서 읽고,
    /// 레지스트리에 등록해 이후 라이브 튜닝(`applyTuning`) 으로 갱신 가능하게 한다.
    static func material(for category: Category) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.isDoubleSided = true   // STL normal 이 가끔 뒤집혀 있어 양면 활성화.
        configure(m, category: category, tuning: SceneTuning.shared)
        register(m, category: category)
        return m
    }

    /// 카테고리 + 튜닝 → 머티리얼 속성 적용(생성·라이브 갱신 공용).
    /// emission 채널은 건드리지 않음 — highlight 상태 보존.
    private static func configure(_ m: SCNMaterial, category: Category, tuning t: SceneTuning) {
        switch category {
        case .whiteShell:
            m.diffuse.contents = NSColor(calibratedRed: 0.80, green: 0.80, blue: 0.82, alpha: 1)
            m.metalness.contents = 0.0
            m.roughness.contents = t.whiteShellRoughness
            m.clearCoat.contents = whiteShellClearcoat ? 0.25 : 0.0
            m.clearCoatRoughness.contents = 0.5
        case .aluminum:
            // metalness 1.0 금지 — 128×64 IBL 해상도에서 순금속은 얼룩짐.
            m.diffuse.contents = NSColor(calibratedRed: 0.62, green: 0.63, blue: 0.65, alpha: 1)
            m.metalness.contents = t.aluminumMetalness
            m.roughness.contents = t.aluminumRoughness
        case .rubberFoot:
            m.diffuse.contents = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
            m.metalness.contents = 0.0
            m.roughness.contents = 0.90
        }
    }

    // MARK: - 라이브 튜닝 레지스트리

    private final class WeakMat {
        weak var value: SCNMaterial?
        let category: Category
        init(_ v: SCNMaterial, _ c: Category) { value = v; category = c }
    }
    private static var registry: [WeakMat] = []

    private static func register(_ m: SCNMaterial, category: Category) {
        if registry.count > 2048 { registry.removeAll { $0.value == nil } }
        registry.append(WeakMat(m, category))
    }

    /// 현재 살아있는 모든 카테고리 머티리얼을 튜닝값으로 재구성(패널 슬라이더용).
    static func applyTuning(_ t: SceneTuning) {
        registry.removeAll { $0.value == nil }
        for entry in registry {
            if let m = entry.value { configure(m, category: entry.category, tuning: t) }
        }
    }

    /// 링크/메시 이름 → 카테고리 매칭(종전 `MeshRig.linkColor` 패턴 계승).
    static func material(forLinkNamed name: String) -> SCNMaterial {
        material(for: category(forLinkNamed: name))
    }

    static func category(forLinkNamed name: String) -> Category {
        // **발등 커버 흰색(사용자 요청 2026-06-19)**: 실기 DARwIn-OP 발 윗면은 흰 플라스틱
        // 커버다. foot STL 은 커버+밑창이 한 메시라 발 전체가 흰 쉘이 된다(밑창만 검게
        // 두려면 별도 sole 지오메트리 필요 — 현재 단일 메시). `.rubberFoot` 는 보존(미사용).
        if name.contains("foot") { return .whiteShell }
        if name.contains("ankle") || name.contains("neck") { return .aluminum }
        if name.contains("shoulder") || name.contains("hip") { return .aluminum }
        // head, lower-arm 은 흰 쉘로 통일(사용자 요청 2026-06-11).
        // body, thigh, shin, upper-arm → 흰 쉘.
        return .whiteShell
    }

    /// 임의 base color 로 만드는 PBR 머티리얼 — 프리미티브 rig 의 다채로운 색 보존용.
    /// 종전 Blinn makeBox/darkMat 가 IBL-only 조명에서 검게 죽지 않도록 PBR 로 승격.
    static func pbr(diffuse: NSColor,
                    metalness: CGFloat,
                    roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = diffuse
        m.metalness.contents = metalness
        m.roughness.contents = roughness
        m.isDoubleSided = true   // STL normal 이 가끔 뒤집혀 있어 양면 활성화.
        return m
    }
}
