import AppKit
import ForgeCore
import SceneKit

/// **W3 (2026-06-12) · §3-B** — 선택 관절의 회전축 + 한계각 아크 + 현재각 마커.
///
/// # 비유
/// 문을 열 때 경첩(축)이 어디고, 얼마까지 열 수 있는지(한계각), 지금 얼마나
/// 열렸는지(현재각)를 한눈에 보여주는 것.
///
/// 트리거: `highlight` 와 동기 — 선택 관절에만 표시. 축 화살표/아크 geometry 는
/// **관절 변경 시에만** 재생성하고, pose 마다는 현재각 마커 위치/색만 갱신(0-alloc).
/// 색: pitch=green / roll=red / yaw=blue(RViz 관례). 한계 85% 초과 amber, 95% red.
final class JointAxisOverlay {

    let container = SCNNode()
    /// 관절 anchor 의 부모(frame)에 부착하는 회전·아크 그룹 — joint 회전 비추종.
    private let group = SCNNode()
    private let arrowPos: SCNNode    // +축 화살표
    private let arrowNeg: SCNNode    // −축 화살표
    private var arcNode: SCNNode?    // 한계각 아크(joint 변경 시 재생성)
    private let marker: SCNNode      // 현재각 마커
    private var enabled = false
    private var currentJoint: JointID?

    private static let arcRadius: CGFloat = 0.045
    private static let armLength: CGFloat = 0.09

    init() {
        container.name = "jointAxisOverlay"
        arrowPos = Self.makeArrow()
        arrowNeg = Self.makeArrow()
        marker = SCNNode(geometry: {
            let s = SCNSphere(radius: 0.005)
            s.firstMaterial = Self.constMat(.white)
            return s
        }())
        group.addChildNode(arrowPos)
        group.addChildNode(arrowNeg)
        group.addChildNode(marker)
        group.isHidden = true
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on { group.isHidden = true; detach() }
    }

    /// highlight + pose 변경 경로에서 호출. joint 가 바뀌면 reparent + geometry 재생성.
    func update(rig: RigSkeleton, highlight: JointID?, pose: RobotPose) {
        guard enabled, let joint = highlight,
              let anchor = rig.jointAnchor(joint),
              let parent = anchor.parent,
              let axis = rig.jointAxisDirection(joint) else {
            group.isHidden = true
            currentJoint = nil
            detach()
            return
        }

        if joint != currentJoint {
            currentJoint = joint
            attach(to: parent, at: anchor.position, axis: axis, joint: joint)
        }
        group.isHidden = false
        updateMarker(joint: joint, pose: pose)
    }

    // MARK: - attach / geometry (joint 변경 시 1회)

    private func attach(to parent: SCNNode, at pos: SCNVector3, axis: SCNVector3, joint: JointID) {
        detach()
        parent.addChildNode(group)
        group.position = pos
        // 로컬 +Z 를 회전축에 정렬 → 회전 평면 = 로컬 XY.
        group.rotation = Self.rotationAligning(localZTo: axis)

        let color = Self.axisColor(joint)
        // 양방향 축 화살표(로컬 X 를 따라 그린 뒤, 축은 group 회전으로 정렬됨).
        // group 은 +Z=axis 이므로 화살표는 평면 위가 아니라 축 방향(±Z)으로 둔다.
        orientArrow(arrowPos, alongLocalZ: 1, color: color)
        orientArrow(arrowNeg, alongLocalZ: -1, color: color)

        // 한계각 아크(로컬 XY 평면, degreeLimits 범위).
        arcNode?.removeFromParentNode()
        let arc = Self.makeArc(limits: joint.degreeLimits, color: color)
        group.addChildNode(arc)
        arcNode = arc
    }

    private func detach() {
        if group.parent != nil { group.removeFromParentNode() }
    }

    private func updateMarker(joint: JointID, pose: RobotPose) {
        let rad = pose.radians(joint)
        // 로컬 XY 평면 위 현재각 위치.
        marker.position = SCNVector3(Self.arcRadius * CGFloat(cos(rad)),
                                     Self.arcRadius * CGFloat(sin(rad)),
                                     0)
        let deg = rad * 180 / .pi
        let limit = deg >= 0 ? joint.degreeLimits.upperBound : joint.degreeLimits.lowerBound
        let ratio = limit != 0 ? abs(deg / limit) : 0
        let warnColor: NSColor
        if ratio >= 0.95 { warnColor = .systemRed }
        else if ratio >= 0.85 { warnColor = .systemOrange }
        else { warnColor = .white }
        marker.geometry?.firstMaterial?.diffuse.contents = warnColor
        marker.geometry?.firstMaterial?.emission.contents = warnColor
        // 한계 근접 시 아크도 경고색.
        if let arcMat = arcNode?.geometry?.firstMaterial {
            let base = Self.axisColor(joint)
            arcMat.emission.contents = ratio >= 0.85 ? warnColor.withAlphaComponent(0.6)
                                                     : base.withAlphaComponent(0.35)
        }
    }

    // MARK: - static builders

    private static func makeArrow() -> SCNNode {
        // 얇은 실린더 + 끝 cone. 로컬 +Y 를 따라 생성 후 orientArrow 가 ±Z 로 회전.
        let shaft = SCNCylinder(radius: 0.0025, height: armLength)
        shaft.firstMaterial = constMat(.white)
        let node = SCNNode(geometry: shaft)
        let tip = SCNCone(topRadius: 0, bottomRadius: 0.006, height: 0.015)
        tip.firstMaterial = constMat(.white)
        let tipNode = SCNNode(geometry: tip)
        tipNode.position = SCNVector3(0, armLength / 2 + 0.0075, 0)
        node.addChildNode(tipNode)
        return node
    }

    private func orientArrow(_ node: SCNNode, alongLocalZ sign: CGFloat, color: NSColor) {
        // 화살표는 +Y 기준 생성 → 로컬 Z 로 회전(+Z: X축 -90°, −Z: X축 +90°).
        node.eulerAngles = SCNVector3(sign > 0 ? -CGFloat.pi / 2 : CGFloat.pi / 2, 0, 0)
        node.position = SCNVector3(0, 0, sign * Self.armLength / 2)
        node.enumerateHierarchy { n, _ in
            n.geometry?.firstMaterial?.diffuse.contents = color
            n.geometry?.firstMaterial?.emission.contents = color.withAlphaComponent(0.5)
        }
    }

    private static func makeArc(limits: ClosedRange<Double>, color: NSColor) -> SCNNode {
        let lo = CGFloat(limits.lowerBound * .pi / 180)
        let hi = CGFloat(limits.upperBound * .pi / 180)
        let rOuter = arcRadius, rInner = arcRadius - 0.005
        let path = NSBezierPath()
        let steps = 48
        // 외곽 호.
        for i in 0...steps {
            let t = lo + (hi - lo) * CGFloat(i) / CGFloat(steps)
            let p = NSPoint(x: rOuter * cos(t), y: rOuter * sin(t))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        // 내곽 호(역방향).
        for i in stride(from: steps, through: 0, by: -1) {
            let t = lo + (hi - lo) * CGFloat(i) / CGFloat(steps)
            path.line(to: NSPoint(x: rInner * cos(t), y: rInner * sin(t)))
        }
        path.close()
        let shape = SCNShape(path: path, extrusionDepth: 0.002)
        let mat = SCNMaterial()
        mat.diffuse.contents = color.withAlphaComponent(0.35)
        mat.emission.contents = color.withAlphaComponent(0.35)
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.blendMode = .alpha
        shape.firstMaterial = mat
        let node = SCNNode(geometry: shape)
        node.name = "limitArc"
        return node
    }

    /// pitch=green / roll=red / yaw=blue (RViz 관례) — rotationAxis 로 분류.
    private static func axisColor(_ joint: JointID) -> NSColor {
        switch joint.rotationAxis {
        case SIMD3(0, 1, 0): return .systemGreen   // pitch
        case SIMD3(1, 0, 0): return .systemRed     // roll
        default:             return .systemBlue    // yaw
        }
    }

    private static func constMat(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.emission.contents = color.withAlphaComponent(0.5)
        m.lightingModel = .constant
        return m
    }

    /// 로컬 +Z(0,0,1) 를 주어진 축으로 회전시키는 SCNVector4.
    private static func rotationAligning(localZTo axis: SCNVector3) -> SCNVector4 {
        let len = (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z).squareRoot()
        guard len > 1e-6 else { return SCNVector4(0, 0, 1, 0) }
        let a = SCNVector3(axis.x / len, axis.y / len, axis.z / len)
        let z = SCNVector3(0, 0, 1)
        let dot = z.z * a.z   // z.x=z.y=0
        if dot > 0.9999 { return SCNVector4(0, 0, 1, 0) }
        if dot < -0.9999 { return SCNVector4(1, 0, 0, CGFloat.pi) }
        let cross = SCNVector3(z.y * a.z - z.z * a.y, z.z * a.x - z.x * a.z, z.x * a.y - z.y * a.x)
        let clen = (cross.x * cross.x + cross.y * cross.y + cross.z * cross.z).squareRoot()
        return SCNVector4(cross.x / clen, cross.y / clen, cross.z / clen,
                          acos(max(-1, min(1, dot))))
    }
}
