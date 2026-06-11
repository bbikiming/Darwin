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
        case whiteShell    // body, thigh, shin, upper-arm, 프리미티브 bodyShell
        case servoBlack    // lower-arm, 모터 본체
        case aluminum      // shoulder, hip-yaw, hip-roll, ankle, neck
        case rubberFoot    // foot
        case helmetDark    // head
    }

    /// **옵션 플래그**: whiteShell clearcoat — 비용 + 번아웃 변수라 기본 off.
    static var whiteShellClearcoat = false

    // MARK: - 팩토리

    /// 카테고리별 PBR 머티리얼(개별 인스턴스).
    static func material(for category: Category) -> SCNMaterial {
        switch category {
        case .whiteShell:
            let m = pbr(diffuse: NSColor(calibratedRed: 0.80, green: 0.80, blue: 0.82, alpha: 1),
                        metalness: 0.0, roughness: 0.42)
            if whiteShellClearcoat {
                m.clearCoat.contents = 0.25
                m.clearCoatRoughness.contents = 0.5
            }
            return m
        case .servoBlack:
            return pbr(diffuse: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
                       metalness: 0.0, roughness: 0.55)
        case .aluminum:
            // metalness 1.0 금지 — 128×64 IBL 해상도에서 순금속은 얼룩짐.
            return pbr(diffuse: NSColor(calibratedRed: 0.62, green: 0.63, blue: 0.65, alpha: 1),
                       metalness: 0.85, roughness: 0.35)
        case .rubberFoot:
            return pbr(diffuse: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.08, alpha: 1),
                       metalness: 0.0, roughness: 0.90)
        case .helmetDark:
            return pbr(diffuse: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1),
                       metalness: 0.0, roughness: 0.30)
        }
    }

    /// 링크/메시 이름 → 카테고리 매칭(종전 `MeshRig.linkColor` 패턴 계승).
    static func material(forLinkNamed name: String) -> SCNMaterial {
        material(for: category(forLinkNamed: name))
    }

    static func category(forLinkNamed name: String) -> Category {
        if name.contains("head") { return .helmetDark }
        if name.contains("foot") { return .rubberFoot }
        if name.contains("ankle") || name.contains("neck") { return .aluminum }
        if name.contains("shoulder") || name.contains("hip") { return .aluminum }
        if name.contains("lower-arm") { return .servoBlack }
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
