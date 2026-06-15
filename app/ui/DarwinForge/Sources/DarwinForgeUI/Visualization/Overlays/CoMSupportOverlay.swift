import ForgeCore
import SceneKit

/// **W3 (2026-06-12) · §3-A** — CoM 투영점 + 지지 다각형.
///
/// # 비유
/// 무게중심(CoM)을 바닥에 떨군 그림자(투영점)가 두 발이 만드는 "안전 구역"
/// (지지 다각형) 안에 있으면 안 넘어진다. 그림자가 구역 밖으로 나가면 위험.
///
/// 구성(전부 0-alloc 풀): 바닥 투영 disc 1 · CoM→투영 수직선 1 · 지지 다각형
/// 외곽선 실린더 8(hull ≤8변). 색은 `ZMPMonitor.Verdict`(safe 초록/borderline
/// 노랑/unsafe·veto 빨강). pose 변경 시에만 위치/색 갱신(자체 타이머 없음).
///
/// 설계의 반투명 fill plane 은 고정-토폴로지 0-alloc 풀로 구현 불가하여 제외했다
/// (성능 계약 우선 — 설계 §3-A 의 "8세그먼트 실린더 풀 대체" 경로 채택).
/// 외곽선+투영 disc 의 verdict 색만으로 안전/위험 신호는 충분히 전달된다.
final class CoMSupportOverlay {

    let container = SCNNode()
    private let projectionDisc: SCNNode
    private let verticalLine: SCNNode
    private let edges: [SCNNode]
    private var enabled = false

    /// 링크 질량(kg, ROBOTIS OP2 URDF inertial 근사 — 설계 §1).
    /// 키: 해당 링크의 distal joint. torso/foot 는 별도 처리.
    private static let torsoMass = 0.975
    private static let footMass = 0.206
    private static let linkMass: [JointID: Double] = [
        .headTilt: 0.158,
        .lShoulderRoll: 0.168, .rShoulderRoll: 0.168,
        .lElbow: 0.060, .rElbow: 0.060,
        .lHipPitch: 0.119, .rHipPitch: 0.119,
        .lKnee: 0.070, .rKnee: 0.070,
    ]

    init() {
        container.name = "comSupportOverlay"

        let disc = SCNCylinder(radius: 0.012, height: 0.0015)
        disc.firstMaterial = Self.emissiveMat(.systemCyan)
        projectionDisc = SCNNode(geometry: disc)
        projectionDisc.isHidden = true

        let line = SCNCylinder(radius: 0.0015, height: 1.0)   // 높이는 scale.y 로 조절(0-alloc).
        line.firstMaterial = Self.emissiveMat(NSColor.systemCyan.withAlphaComponent(0.6))
        verticalLine = SCNNode(geometry: line)
        verticalLine.isHidden = true

        edges = (0..<8).map { _ in
            let seg = SCNCylinder(radius: 0.003, height: 1.0)
            seg.firstMaterial = Self.emissiveMat(.systemGreen)
            let n = SCNNode(geometry: seg)
            n.isHidden = true
            return n
        }

        // 모든 stored property 초기화 후 그래프 부착(self 조기 사용 방지).
        container.addChildNode(projectionDisc)
        container.addChildNode(verticalLine)
        for e in edges { container.addChildNode(e) }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on { hideAll() }
    }

    /// pose 변경 경로에서 호출(applyPose 동급). 자체 타이머 없음.
    func update(rig: RigSkeleton, data: SceneOverlayData?,
                leftFoot: (x: Double, y: Double), rightFoot: (x: Double, y: Double)) {
        guard enabled else { return }

        // ── CoM(scene world) — 질량 가중 평균.
        var sum = SCNVector3(0, 0, 0)
        var total: CGFloat = 0
        func add(_ p: SCNVector3?, _ m: Double) {
            guard let p else { return }
            let w = CGFloat(m)
            sum = SCNVector3(sum.x + p.x * w, sum.y + p.y * w, sum.z + p.z * w)
            total += w
        }
        add(rig.rootNode.worldPosition, Self.torsoMass)
        for (j, m) in Self.linkMass { add(rig.linkWorldPosition(j), m) }
        add(rig.footNode(.left)?.worldPosition, Self.footMass)
        add(rig.footNode(.right)?.worldPosition, Self.footMass)
        guard total > 0 else { return hideAll() }
        let com = SCNVector3(sum.x / total, sum.y / total, sum.z / total)

        // ── verdict 색.
        let color = Self.verdictColor(data?.zmpVerdict)

        // ── 투영 disc(바닥).
        projectionDisc.position = SCNVector3(com.x, 0.0016, com.z)
        projectionDisc.geometry?.firstMaterial?.diffuse.contents = color
        projectionDisc.geometry?.firstMaterial?.emission.contents = color
        projectionDisc.isHidden = false

        // ── 수직선(CoM → 투영). 단위 실린더 scale.y 로 길이 조절.
        let h = max(0.001, com.y)
        verticalLine.position = SCNVector3(com.x, com.y / 2, com.z)
        verticalLine.scale = SCNVector3(1, h, 1)
        verticalLine.isHidden = false

        // ── 지지 다각형 외곽선(scene XZ): robot frame hull 을 scene 으로 매핑.
        let hull = SupportPolygonGeometry.hull(leftFoot: leftFoot, rightFoot: rightFoot)
        updateEdges(hull: hull, color: color)
    }

    /// hull(robot frame) 변들을 8개 실린더 풀에 0-alloc 배치.
    private func updateEdges(hull: [(x: Double, y: Double)], color: NSColor) {
        let n = hull.count
        for i in 0..<edges.count {
            guard i < n else { edges[i].isHidden = true; continue }
            let a = hull[i], b = hull[(i + 1) % n]
            // robot(x 전방,y 좌) → scene(x=-y, z=-x), 바닥 y≈0.003.
            let pa = SCNVector3(CGFloat(-a.y), 0.003, CGFloat(-a.x))
            let pb = SCNVector3(CGFloat(-b.y), 0.003, CGFloat(-b.x))
            placeSegment(edges[i], from: pa, to: pb, color: color)
        }
    }

    /// 단위 실린더(높이 1, Y축) 를 두 점 사이 선분으로 변환 — 위치/회전/스케일만(0-alloc).
    private func placeSegment(_ node: SCNNode, from a: SCNVector3, to b: SCNVector3, color: NSColor) {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let len = (dx * dx + dy * dy + dz * dz).squareRoot()
        guard len > 1e-6 else { node.isHidden = true; return }
        node.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        // Y축(0,1,0) → 방향벡터로 회전(rotation axis = cross, angle = acos(dot)).
        let uy = SCNVector3(0, 1, 0)
        let d = SCNVector3(dx / len, dy / len, dz / len)
        let cross = SCNVector3(uy.y * d.z - uy.z * d.y, uy.z * d.x - uy.x * d.z, uy.x * d.y - uy.y * d.x)
        let dot = uy.y * d.y   // uy.x=uy.z=0
        let clen = (cross.x * cross.x + cross.y * cross.y + cross.z * cross.z).squareRoot()
        if clen > 1e-6 {
            node.rotation = SCNVector4(cross.x / clen, cross.y / clen, cross.z / clen,
                                       acos(max(-1, min(1, dot))))
        } else {
            node.rotation = SCNVector4(1, 0, 0, dot >= 0 ? 0 : CGFloat.pi)
        }
        node.scale = SCNVector3(1, len, 1)
        node.geometry?.firstMaterial?.diffuse.contents = color
        node.geometry?.firstMaterial?.emission.contents = color
        node.isHidden = false
    }

    private func hideAll() {
        projectionDisc.isHidden = true
        verticalLine.isHidden = true
        for e in edges { e.isHidden = true }
    }

    // MARK: helpers

    private static func verdictColor(_ v: ZMPMonitor.Verdict?) -> NSColor {
        switch v {
        case .some(.safe), .none:   return .systemGreen
        case .some(.borderline):    return .systemYellow
        case .some(.unsafe), .some(.veto): return .systemRed
        }
    }

    private static func emissiveMat(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.emission.contents = color
        m.lightingModel = .constant
        m.isDoubleSided = true
        return m
    }
}
