import AppKit
import ForgeCore
import SceneKit

/// ROBOTIS-OP2-Common URDF에서 추출한 joint origin/axis를 따라 STL mesh로
/// 본 트리를 구성한다.
///
/// 좌표계: URDF는 X=정면, Y=좌, Z=위 (ROBOTIS world). 루트 노드에 한 번
/// `-π/2` X-rotation을 걸어 SceneKit Y-up으로 변환. 이후 모든 자식 노드는
/// URDF 좌표를 그대로 사용.
///
/// 출처:
/// - `vendor/robotis-op2-common/urdf/robotis_op2.structure.{leg,arm,head}.xacro`
/// - `vendor/robotis-op2-common/meshes/*.stl` (Apache 2.0)
final class MeshRig {

    let root: SCNNode

    /// 회전이 적용되는 joint anchor — JointID → SCNNode.
    private(set) var joints: [JointID: SCNNode] = [:]
    /// 각 link의 mesh node (highlight 대상).
    private var meshes: [JointID: SCNNode] = [:]
    private var allMeshNodes: [SCNNode] = []
    private var originalEmissions: [ObjectIdentifier: NSColor] = [:]

    /// URDF axis (ROBOTIS world): 회전 부호와 축 방향.
    /// 방향이 음수면 양수 명령에 음 방향 회전.
    private var jointAxes: [JointID: SCNVector3] = [:]

    init() throws {
        root = SCNNode()
        // ROS REP 103 (Z up, X forward, Y left) → SceneKit (Y up, X right, Z toward camera).
        // 변환: ROS X+(정면) → SceneKit Z-,  ROS Y+(좌) → SceneKit X-,  ROS Z+(위) → SceneKit Y+.
        // Maya/3ds Max viewport convention "Front view = looking in -Z" 와 정합.
        // 이 회전행렬은 axis-angle (120° around (-1,1,1)/√3) 와 동치.
        let n = CGFloat(1.0 / sqrt(3.0))
        root.transform = SCNMatrix4MakeRotation(
            2.0 * CGFloat.pi / 3.0,
            -n, n, n
        )
        // 발이 Y=0 평면에 닿도록 들어올림.
        // **Sprint 16 정정**: walkReady 가 deep squat (knee ±53°) 로 변경되면서
        // 발 IK 위치가 더 멀어짐. 이전 0.345 m 은 발이 floor 아래로 침수 →
        // robot 이 공중에 떠있어 보임 (의자에 앉기 등 깊은 squat 자세). 새 hip
        // 높이 0.265 m — walkReady deep squat 시 발 floor 정확 접지.
        root.position = SCNVector3(0, 0.265, 0)
        try buildBody()
    }

    // MARK: - Pose application

    func apply(pose: RobotPose) {
        for j in JointID.allCases {
            guard let node = joints[j], let axis = jointAxes[j] else { continue }
            let rad = Float(pose.radians(j))
            node.rotation = SCNVector4(axis.x, axis.y, axis.z, CGFloat(rad))
        }
    }

    func highlight(_ joint: JointID?) {
        for n in allMeshNodes {
            let key = ObjectIdentifier(n)
            n.geometry?.firstMaterial?.emission.contents =
                originalEmissions[key] ?? NSColor.black
        }
        guard let j = joint, let mesh = meshes[j] else { return }
        mesh.geometry?.firstMaterial?.emission.contents =
            NSColor.systemOrange.withAlphaComponent(0.55)
    }

    // MARK: - Build

    /// URDF 좌표계 그대로 본 트리 구성.
    /// 각 joint의 origin은 부모 link의 frame에서의 좌표 + 초기 회전(rpy).
    /// 시각 mesh는 visuals.xacro에 따라 `rpy(0,0,-π/2)` + `scale 0.001` 적용.
    private func buildBody() throws {
        // body link — 모든 부위의 부모.
        let body = SCNNode()
        root.addChildNode(body)
        attachVisualMesh(named: "geo_op_body", to: body)

        // ── 머리: head_pan → head_tilt
        let headPanAnchor = makeJointAnchor(parent: body,
                                             origin: SCNVector3(0, 0, 0.0205))
        joints[.headPan] = headPanAnchor
        jointAxes[.headPan] = SCNVector3(0, 0, 1)
        attachVisualMesh(named: "geo_op_neck", to: headPanAnchor,
                         meshOriginZ: 0.03,
                         linkID: .headPan)

        // head_tilt: rpy(0, 33°, 0). 33° 초기 pitch가 mesh의 head_tilt anchor에
        // 적용되어 있어 우리는 회전 0일 때 head_tilt mesh가 자연스럽게 정렬됨.
        let headTiltAnchor = makeJointAnchor(
            parent: headPanAnchor,
            origin: SCNVector3(0, 0, 0.03),
            initialRPY: SCNVector3(0, Float(33.0 * Double.pi / 180.0), 0))
        joints[.headTilt] = headTiltAnchor
        jointAxes[.headTilt] = SCNVector3(0, -1, 0)
        attachVisualMesh(named: "geo_op_head", to: headTiltAnchor,
                         meshRPY: SCNVector3(0, Float.pi, Float.pi / 2),
                         linkID: .headTilt,
                         applyDefaultZRotation: false)

        // ── 좌측 팔
        try buildArm(side: .left, body: body)
        // ── 우측 팔
        try buildArm(side: .right, body: body)
        // ── 좌측 다리
        try buildLeg(side: .left, body: body)
        // ── 우측 다리
        try buildLeg(side: .right, body: body)
    }

    private enum Side { case left, right }

    private func buildArm(side: Side, body: SCNNode) throws {
        let yMul: Float = (side == .left) ? 1 : -1
        let signMul: Float = (side == .left) ? 1 : -1
        let shoPitchKey: JointID = (side == .left) ? .lShoulderPitch : .rShoulderPitch
        let shoRollKey:  JointID = (side == .left) ? .lShoulderRoll  : .rShoulderRoll
        let elbowKey:    JointID = (side == .left) ? .lElbow         : .rElbow
        let shoulderMesh = (side == .left) ? "geo_op_left_shoulder"   : "geo_op_right_shoulder"
        let upperArmMesh = (side == .left) ? "geo_op_left_upper-arm"  : "geo_op_right_upper-arm"
        let lowerArmMesh = (side == .left) ? "geo_op_left_lower-arm"  : "geo_op_right_lower-arm"

        // sho_pitch: origin (0, ±0.0575, 0)
        let pitchAnchor = makeJointAnchor(parent: body,
                                           origin: SCNVector3(0, yMul * 0.0575, 0))
        joints[shoPitchKey] = pitchAnchor
        jointAxes[shoPitchKey] = SCNVector3(0, signMul * 1.0, 0)
        attachVisualMesh(named: shoulderMesh, to: pitchAnchor, linkID: shoPitchKey)

        // sho_roll: origin (0, ±0.0245, -0.016), rpy (±45°, 0, 0)
        let rollAnchor = makeJointAnchor(
            parent: pitchAnchor,
            origin: SCNVector3(0, yMul * 0.0245, -0.016),
            initialRPY: SCNVector3(signMul * Float(45.0 * Double.pi / 180.0), 0, 0))
        joints[shoRollKey] = rollAnchor
        jointAxes[shoRollKey] = SCNVector3(-1, 0, 0)
        attachVisualMesh(named: upperArmMesh, to: rollAnchor, linkID: shoRollKey)

        // elbow: origin (0.016, 0, -0.06), rpy (0, -π/2, 0)
        let elbowAnchor = makeJointAnchor(
            parent: rollAnchor,
            origin: SCNVector3(0.016, 0, -0.06),
            initialRPY: SCNVector3(0, -Float.pi / 2, 0))
        joints[elbowKey] = elbowAnchor
        jointAxes[elbowKey] = SCNVector3(0, signMul * 1.0, 0)
        attachVisualMesh(named: lowerArmMesh, to: elbowAnchor, linkID: elbowKey)
    }

    private func buildLeg(side: Side, body: SCNNode) throws {
        let yMul: Float = (side == .left) ? 1 : -1
        let pitchSign: Float = (side == .left) ? -1 : 1   // l_hip_pitch axis (0,-1,0); r 는 (0,1,0)
        let kneeSign:  Float = (side == .left) ? -1 : 1
        let yawKey:   JointID = (side == .left) ? .lHipYaw   : .rHipYaw
        let rollKey:  JointID = (side == .left) ? .lHipRoll  : .rHipRoll
        let pitchKey: JointID = (side == .left) ? .lHipPitch : .rHipPitch
        let kneeKey:  JointID = (side == .left) ? .lKnee     : .rKnee
        let prefix = (side == .left) ? "geo_op_left" : "geo_op_right"

        // hip_yaw: origin (-0.005, ±0.037, -0.0907)
        let yawAnchor = makeJointAnchor(
            parent: body,
            origin: SCNVector3(-0.005, yMul * 0.037, -0.0907))
        joints[yawKey] = yawAnchor
        jointAxes[yawKey] = SCNVector3(0, 0, -1)
        attachVisualMesh(named: "\(prefix)_hip-yaw", to: yawAnchor, linkID: yawKey)

        // hip_roll: origin (0, 0, -0.0315)
        let rollAnchor = makeJointAnchor(
            parent: yawAnchor,
            origin: SCNVector3(0, 0, -0.0315))
        joints[rollKey] = rollAnchor
        jointAxes[rollKey] = SCNVector3(-1, 0, 0)
        attachVisualMesh(named: "\(prefix)_hip-roll", to: rollAnchor, linkID: rollKey)

        // hip_pitch: origin (0, 0, 0)
        let pitchAnchor = makeJointAnchor(parent: rollAnchor, origin: SCNVector3(0, 0, 0))
        joints[pitchKey] = pitchAnchor
        jointAxes[pitchKey] = SCNVector3(0, pitchSign, 0)
        attachVisualMesh(named: "\(prefix)_thigh", to: pitchAnchor, linkID: pitchKey)

        // knee: origin (0, 0, -0.093)
        let kneeAnchor = makeJointAnchor(parent: pitchAnchor,
                                          origin: SCNVector3(0, 0, -0.093))
        joints[kneeKey] = kneeAnchor
        jointAxes[kneeKey] = SCNVector3(0, kneeSign, 0)
        // 우측 knee는 mesh visual origin이 (0,0,-0.093)으로 명시됨 (URDF visuals.xacro).
        let shinMeshOriginZ: Float = (side == .right) ? -0.093 : 0
        attachVisualMesh(named: "\(prefix)_shin", to: kneeAnchor,
                         meshOriginZ: shinMeshOriginZ,
                         linkID: kneeKey)

        // ── 발목 (정적): ank_pitch + ank_roll → foot.
        // 우리 16-DOF 모델은 ankle을 직접 제어하지 않지만, 발 mesh를 정확한 위치에
        // 표시하기 위해 정적 anchor로 둔다.
        let ankPitchAnchor = SCNNode()
        ankPitchAnchor.position = SCNVector3(0, 0, -0.093)
        kneeAnchor.addChildNode(ankPitchAnchor)
        attachVisualMesh(named: "\(prefix)_ankle", to: ankPitchAnchor, linkID: nil)

        let ankRollAnchor = SCNNode()
        // l_ank_roll origin (0,0,0) — URDF
        ankPitchAnchor.addChildNode(ankRollAnchor)
        attachVisualMesh(named: "\(prefix)_foot", to: ankRollAnchor, linkID: nil)
    }

    // MARK: - Helpers

    /// joint anchor 노드 생성 — 부모 frame에서의 origin + 초기 회전(rpy).
    /// URDF: 자식 link = parent에서 (origin 만큼 translate) 후 (rpy 만큼 rotate).
    /// SceneKit transform = T * R 이므로 같은 노드에 position/eulerAngles 둘 다
    /// 설정해도 URDF와 일치하지만, joint 동적 회전과 충돌하지 않도록 분리한다.
    ///
    /// 노드 구조: parent → frame(position=origin, rpy) → anchor(joint rotation 적용)
    private func makeJointAnchor(parent: SCNNode,
                                  origin: SCNVector3,
                                  initialRPY: SCNVector3 = SCNVector3(0, 0, 0)) -> SCNNode {
        if initialRPY.x != 0 || initialRPY.y != 0 || initialRPY.z != 0 {
            // T 다음 R: position이 parent local에서 적용된 후 rpy 회전.
            let frame = SCNNode()
            frame.position = origin
            frame.eulerAngles = initialRPY
            parent.addChildNode(frame)
            let anchor = SCNNode()
            frame.addChildNode(anchor)
            return anchor
        } else {
            let anchor = SCNNode()
            anchor.position = origin
            parent.addChildNode(anchor)
            return anchor
        }
    }

    /// 시각 mesh attach.
    /// - meshOriginZ: visuals.xacro의 (0,0,Z) origin offset (knee/neck 특수 케이스)
    /// - meshRPY: visuals.xacro의 추가 rpy (head_tilt 특수 케이스)
    /// - applyDefaultZRotation: visuals.xacro 모든 mesh의 기본 rpy(0,0,-π/2)을 적용.
    private func attachVisualMesh(named name: String,
                                   to parent: SCNNode,
                                   meshOriginZ: Float = 0,
                                   meshRPY: SCNVector3? = nil,
                                   linkID: JointID? = nil,
                                   applyDefaultZRotation: Bool = true) {
        do {
            let geom = try STLLoader.loadGeometry(
                named: name,
                scale: 0.001,
                diffuse: Self.linkColor(for: linkID, name: name)
            )
            let meshNode = SCNNode(geometry: geom)
            // visuals.xacro는 모든 mesh에 rpy(0, 0, -π/2)를 적용.
            // 일부 (head_tilt)는 별도 rpy를 가지므로 override.
            if let rpy = meshRPY {
                meshNode.eulerAngles = rpy
            } else if applyDefaultZRotation {
                meshNode.eulerAngles = SCNVector3(0, 0, -Float.pi / 2)
            }
            meshNode.position = SCNVector3(0, 0, meshOriginZ)
            parent.addChildNode(meshNode)
            allMeshNodes.append(meshNode)
            if let id = linkID {
                meshes[id] = meshNode
            }
            let key = ObjectIdentifier(meshNode)
            originalEmissions[key] = NSColor.black
        } catch {
            // mesh 로드 실패 시 그냥 plain color cube placeholder.
            print("STL load failed for \(name): \(error)")
        }
    }

    /// 부위별 색상 — 실제 OP2 사진을 참고한 회색 톤 + 디테일 강조.
    private static func linkColor(for joint: JointID?, name: String) -> NSColor {
        // 머리는 약간 darker, 본체는 light gray, foot은 dark.
        if name.contains("head") { return NSColor(white: 0.32, alpha: 1.0) }
        if name.contains("foot") { return NSColor(white: 0.18, alpha: 1.0) }
        if name.contains("ankle") { return NSColor(white: 0.25, alpha: 1.0) }
        if name.contains("body") { return NSColor(white: 0.78, alpha: 1.0) }
        if name.contains("shoulder") || name.contains("hip") {
            return NSColor(white: 0.52, alpha: 1.0)
        }
        // 기본: bodyShell 회색
        return NSColor(white: 0.74, alpha: 1.0)
    }
}
