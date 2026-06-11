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
    // 조명 상수 (3점) — burn-out 방지를 위해 강도 하향 (v1.14.8 이력).
    // ───────────────────────────────────────────────────────────────────────

    /// Key directional — warm, 그림자 캐스터.
    static let keyIntensity: CGFloat = 240
    static let keyColor = NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.95, alpha: 1.0)
    static let keyPosition = SCNVector3(0.6, 2.3, -2.0)
    static let keyShadowRadius: CGFloat = 4
    static let keyShadowSampleCount = 12

    /// Fill directional — cool.
    static let fillIntensity: CGFloat = 130
    static let fillColor = NSColor(calibratedRed: 0.86, green: 0.92, blue: 1.00, alpha: 1.0)
    static let fillPosition = SCNVector3(-1.5, 1.4, 0.5)

    /// Ambient.
    static let ambientIntensity: CGFloat = 200

    /// 조명이 바라보는 robot 허리 높이.
    static let lightLookAt = SCNVector3(0, 0.30, 0)

    // ───────────────────────────────────────────────────────────────────────
    // 바닥/그리드 상수.
    // ───────────────────────────────────────────────────────────────────────

    static let floorDiffuse = NSColor(white: 0.10, alpha: 1.0)
    static let gridColor = NSColor(white: 0.18, alpha: 1.0)
    static let gridHalf = 0.85
    static let gridStep = 0.10

    // MARK: - 조명 rig

    /// 3점 조명 노드를 scene root 에 부착.
    static func installLighting(into root: SCNNode) {
        let key = SCNLight()
        key.type = .directional
        key.intensity = keyIntensity
        key.castsShadow = true
        key.shadowRadius = keyShadowRadius
        key.shadowSampleCount = keyShadowSampleCount
        key.shadowMode = .deferred
        key.color = keyColor
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = keyPosition
        keyNode.look(at: lightLookAt)
        root.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = fillIntensity
        fill.color = fillColor
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = fillPosition
        fillNode.look(at: lightLookAt)
        root.addChildNode(fillNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = ambientIntensity
        let aNode = SCNNode()
        aNode.light = ambient
        root.addChildNode(aNode)
    }

    // MARK: - 바닥

    /// 반사 없는 어두운 바닥 — 흰 robot 의 후광 burn-out 차단.
    static func makeFloor() -> SCNNode {
        let ground = SCNFloor()
        ground.reflectivity = 0
        let gMat = SCNMaterial()
        gMat.diffuse.contents = floorDiffuse
        gMat.specular.contents = NSColor.black
        gMat.lightingModel = .blinn
        ground.firstMaterial = gMat
        return SCNNode(geometry: ground)
    }

    // MARK: - 그리드

    static func makeGrid() -> SCNNode {
        let group = SCNNode()
        let half = gridHalf
        let step = gridStep
        let mat = SCNMaterial()
        mat.diffuse.contents = gridColor
        mat.lightingModel = .constant
        for i in stride(from: -half, through: half, by: step) {
            let xLine = SCNCylinder(radius: 0.0012, height: CGFloat(half * 2))
            xLine.firstMaterial = mat
            let nx = SCNNode(geometry: xLine)
            nx.position = SCNVector3(0, 0.0006, CGFloat(i))
            nx.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
            group.addChildNode(nx)

            let zLine = SCNCylinder(radius: 0.0012, height: CGFloat(half * 2))
            zLine.firstMaterial = mat
            let nz = SCNNode(geometry: zLine)
            nz.position = SCNVector3(CGFloat(i), 0.0006, 0)
            group.addChildNode(nz)
        }
        return group
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
