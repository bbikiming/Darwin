import SceneKit
import SwiftUI

/// 무대(stage) 구성 — 조명 rig · 바닥 · 그리드 · 원점 축.
///
/// **W0 (2026-06-11)**: `RobotScene3D.Coordinator` init 안에 흩어져 있던 조명/바닥/
/// 그리드/축 생성 로직을 이 파일로 집결. **조명·노출 수치는 전부 이 파일의 상수**이며
/// 이후 Wave(PBR/IBL 튜닝)는 이 상수만 수정한다.
///
/// 픽셀 동일성 계약: W0 시점 값은 종전 `Coordinator.init`(240/130/200 3점 조명,
/// floor reflectivity 0, 실린더 그리드)과 **완전히 동일**해야 한다.
enum SceneStage {

    // ───────────────────────────────────────────────────────────────────────
    // 조명 **구조** 상수 — 전 preset 공용. (강도·색·바닥·그리드 등 화면별 값은
    // **W2** 에서 `SceneEnvironmentSpec`(SceneEnvironment.swift)으로 이관. 여기엔
    // shadow 파라미터·광원 위치처럼 무드와 무관한 구조값만 남긴다.)
    // ───────────────────────────────────────────────────────────────────────

    /// Key directional — 그림자 캐스터(위치·shadow 는 공용, 강도·색은 spec).
    static let keyPosition = SCNVector3(0.6, 2.3, -2.0)
    static let keyShadowRadius: CGFloat = 7
    static let keyShadowSampleCount = 8
    static let keyShadowMapSize = CGSize(width: 1024, height: 1024)
    static let keyShadowColor = NSColor(white: 0, alpha: 0.5)

    /// Rim directional — 흰 쉘 윤곽을 배경에서 분리. 그림자 없음. 색은 공용(쿨 화이트).
    static let rimColor = NSColor(calibratedRed: 0.85, green: 0.90, blue: 1.00, alpha: 1.0)
    static let rimPosition = SCNVector3(0, 2.0, 2.2)

    /// 조명이 바라보는 robot 허리 높이.
    static let lightLookAt = SCNVector3(0, 0.30, 0)

    // MARK: - 조명 rig + IBL

    /// 라이브 튜닝(SceneTuning)에서 갱신할 무대 핸들 — 광원/IBL/바닥 참조.
    struct StageHandle {
        let keyLight: SCNLight
        let rimLight: SCNLight
        weak var floorMaterial: SCNMaterial?
        weak var scene: SCNScene?
    }

    /// key + rim 조명을 scene root 에 부착하고 절차적 IBL 을 환경맵으로 주입.
    /// **W1**: lightingEnvironment(IBL)와 background 는 독립이므로 background(clear)는
    /// SwiftUI 그라디언트가 계속 담당.
    /// **W2**: 강도·색·IBL tint 는 화면별 `SceneEnvironmentSpec` 이 소유.
    /// shadow/position 같은 구조 상수는 전 preset 공용으로 이 파일에 유지.
    @discardableResult
    static func installLighting(into scene: SCNScene,
                                spec: SceneEnvironmentSpec) -> (key: SCNLight, rim: SCNLight) {
        let root = scene.rootNode

        let key = SCNLight()
        key.type = .directional
        key.intensity = spec.keyIntensity
        key.castsShadow = true
        key.shadowRadius = keyShadowRadius
        key.shadowSampleCount = keyShadowSampleCount
        key.shadowMode = .deferred
        key.shadowMapSize = keyShadowMapSize
        key.shadowColor = keyShadowColor
        key.color = spec.keyColor
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = keyPosition
        keyNode.look(at: lightLookAt)
        root.addChildNode(keyNode)

        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = spec.rimIntensity
        rim.color = rimColor
        rim.castsShadow = false
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = rimPosition
        rimNode.look(at: lightLookAt)
        root.addChildNode(rimNode)

        // 절차적 IBL — PBR 머티리얼의 base 광량 + 금속 형태감. preset tint 소비.
        scene.lightingEnvironment.contents = ProceduralEnvironmentMap.image(for: spec)
        scene.lightingEnvironment.intensity = spec.iblIntensity

        return (key, rim)
    }

    /// 라이브 튜닝값을 무대 핸들에 적용(조명·IBL·바닥).
    static func apply(_ t: SceneTuning, to handle: StageHandle) {
        handle.keyLight.intensity = CGFloat(t.keyIntensity)
        handle.keyLight.shadowRadius = CGFloat(t.shadowRadius)
        handle.rimLight.intensity = CGFloat(t.rimIntensity)
        handle.scene?.lightingEnvironment.intensity = CGFloat(t.iblIntensity)
        if let fm = handle.floorMaterial {
            fm.diffuse.contents = NSColor(calibratedWhite: CGFloat(t.floorBrightness), alpha: 1)
            fm.roughness.contents = t.floorRoughness
        }
    }

    // MARK: - 바닥

    /// PBR 바닥 — IBL-only 조명에서 검게 죽지 않도록 physicallyBased. 반사는 IBL 로만.
    /// **W2**: albedo·roughness 는 preset 스펙이 소유.
    static func makeFloor(spec: SceneEnvironmentSpec) -> SCNNode {
        let ground = SCNFloor()
        ground.reflectivity = 0
        ground.firstMaterial = RigMaterials.pbr(diffuse: spec.floorAlbedo,
                                                metalness: 0.0,
                                                roughness: spec.floorRoughness)
        return SCNNode(geometry: ground)
    }

    // MARK: - 그리드 (W2: GridFloorMaterial 셰이더로 이관, 레거시는 거기 legacyGrid 로 보존)

    // MARK: - 소품 (W2 props)

    /// preset 의 props 를 단일 그룹 노드로 빌드. originAxes 는 기존 axesNode 가 담당하므로 제외.
    static func makeProps(spec: SceneEnvironmentSpec) -> SCNNode {
        let group = SCNNode()
        group.name = "sceneProps"
        for prop in spec.props {
            switch prop {
            case .originAxes:        break  // axesNode 가 별도 담당.
            case .distanceMarks:     group.addChildNode(makeDistanceMarks())
            case .startLine:         group.addChildNode(makeStartLine())
            case .workMat:           group.addChildNode(makeWorkMat())
            case .stageSpot:         group.addChildNode(makeStageSpot())
            }
        }
        return group
    }

    /// WalkLab 진행축(전방 = -Z) 0.5m 간격 거리 마킹 8개. `SCNText` 금지 →
    /// NSImage 로 사전 렌더한 텍스트 텍스처를 입힌 plane(폴리곤/alloc 최소).
    private static func makeDistanceMarks() -> SCNNode {
        let group = SCNNode()
        group.name = "distanceMarks"
        for i in 1...8 {
            let meters = Double(i) * 0.5
            let label = String(format: "%.1fm", meters)
            guard let tex = textTexture(label) else { continue }
            let plane = SCNPlane(width: 0.16, height: 0.08)
            let mat = SCNMaterial()
            mat.diffuse.contents = tex
            mat.lightingModel = .constant
            mat.isDoubleSided = true
            mat.blendMode = .alpha
            plane.firstMaterial = mat
            let node = SCNNode(geometry: plane)
            node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)  // 바닥에 눕힘.
            node.position = SCNVector3(0.32, 0.002, -CGFloat(meters))  // 진행축 옆.
            node.castsShadow = false
            group.addChildNode(node)
        }
        return group
    }

    private static func makeStartLine() -> SCNNode {
        let box = SCNBox(width: 1.2, height: 0.004, length: 0.02, chamferRadius: 0)
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(calibratedRed: 0.30, green: 0.95, blue: 0.55, alpha: 1)
        mat.emission.contents = NSColor(calibratedRed: 0.20, green: 0.70, blue: 0.40, alpha: 1)
        mat.lightingModel = .constant
        box.firstMaterial = mat
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(0, 0.002, 0)
        node.castsShadow = false
        node.name = "startLine"
        return node
    }

    private static func makeWorkMat() -> SCNNode {
        let plane = SCNPlane(width: 0.6, height: 0.6)
        plane.cornerRadius = 0.04
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(calibratedWhite: 0.16, alpha: 1)
        mat.roughness.contents = 0.95
        mat.metalness.contents = 0.0
        mat.lightingModel = .physicallyBased
        plane.firstMaterial = mat
        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
        node.position = SCNVector3(0, 0.0008, 0)
        node.castsShadow = false
        node.name = "workMat"
        return node
    }

    private static func makeStageSpot() -> SCNNode {
        let spot = SCNLight()
        spot.type = .spot
        spot.intensity = 300
        spot.spotInnerAngle = 25
        spot.spotOuterAngle = 50
        spot.castsShadow = false   // 그림자 패스는 key 1개만 유지(perf).
        spot.color = NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.94, alpha: 1)
        let node = SCNNode()
        node.light = spot
        node.position = SCNVector3(0, 2.5, 0.5)
        node.look(at: lightLookAt)
        node.name = "stageSpot"
        return node
    }

    /// 짧은 라벨을 투명 배경 텍스처(NSImage)로 1회 렌더. 거리 마킹 텍스트용.
    private static func textTexture(_ text: String) -> NSImage? {
        let size = NSSize(width: 128, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 0.9),
            .paragraphStyle: style
        ]
        let rect = NSRect(x: 0, y: 12, width: size.width, height: 40)
        text.draw(in: rect, withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    // MARK: - 원점 축

    static func makeAxes() -> SCNNode {
        let group = SCNNode()
        func arrow(color: NSColor, axis: SCNVector3) -> SCNNode {
            let cyl = SCNCylinder(radius: 0.004, height: 0.13)
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.lightingModel = .constant
            cyl.firstMaterial = m
            let n = SCNNode(geometry: cyl)
            let yAxis = SCNVector3(0, 1, 0)
            let cross = SCNVector3(yAxis.y * axis.z - yAxis.z * axis.y,
                                   yAxis.z * axis.x - yAxis.x * axis.z,
                                   yAxis.x * axis.y - yAxis.y * axis.x)
            let dot = yAxis.x * axis.x + yAxis.y * axis.y + yAxis.z * axis.z
            if abs(dot - 1) > 1e-6 {
                let angle = acos(max(-1, min(1, dot)))
                n.rotation = SCNVector4(cross.x, cross.y, cross.z, angle)
            }
            n.position = SCNVector3(axis.x * 0.065, axis.y * 0.065, axis.z * 0.065)
            return n
        }
        group.addChildNode(arrow(color: .systemRed,    axis: SCNVector3( 1, 0, 0)))
        group.addChildNode(arrow(color: .systemGreen,  axis: SCNVector3( 0, 1, 0)))
        group.addChildNode(arrow(color: .systemBlue,   axis: SCNVector3( 0, 0, -1)))
        group.position = SCNVector3(-0.78, 0.005, -0.78)
        return group
    }
}
