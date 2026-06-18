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
final class MeshRig: RigSkeleton {

    let root: SCNNode

    /// 회전이 적용되는 joint anchor — JointID → SCNNode.
    private(set) var joints: [JointID: SCNNode] = [:]
    /// 각 link의 mesh node (highlight 대상).
    private var meshes: [JointID: SCNNode] = [:]
    private var allMeshNodes: [SCNNode] = []
    private var originalEmissions: [ObjectIdentifier: NSColor] = [:]
    /// **W3**: 발 anchor(ank_roll) — 지지 다각형·FSR 접지 worldTransform 원천.
    private var footNodes: [FootSide: SCNNode] = [:]

    // MARK: emission 채널 (W3) — highlight 와 한계 경고가 같은 채널 공유.
    /// 현재 highlight 된 선택 관절(highlight 채널).
    private var highlightedJoint: JointID?
    /// 관절별 한계 경고 상태(warn 채널) — .warn85/.warn95 만 보관.
    private var warnStates: [JointID: EmissionState] = [:]

    /// **사이클 125 (audit #19/#36, P1/P2)**: 개별 STL 로드 실패 카운트. 호출자 (Robot3DViewport)
    /// 가 본 count 를 구독 → ≥1 이면 사용자에게 "일부 mesh 실패 (plain cube fallback)" overlay.
    /// 종전 silent fallback (OSLog only) → caller flag 구독 안 하면 사용자 통지 0.
    private(set) var stlLoadFailureCount: Int = 0
    /// **사이클 125 (audit #36)**: 실패 mesh 이름 — debugging + UI 표시용.
    private(set) var stlLoadFailureNames: [String] = []

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
        // 발이 Y=0 평면에 닿도록 들어올림(초기 추정값). 정확한 접지는 buildBody 후
        // groundToFloor() 가 실제 지오메트리 최저점을 측정해 보정한다 — 하드코딩 0.265 m 는
        // walkReady deep-squat 전용이라 .center(다리 곧음) 등 다른 포즈에선 발이 바닥을 뚫었다.
        root.position = SCNVector3(0, 0.265, 0)
        try buildBody()
        groundToFloor()
    }

    // MARK: - Pose application

    func apply(pose: RobotPose) {
        for j in JointID.allCases {
            guard let node = joints[j], let axis = jointAxes[j] else { continue }
            let rad = Float(pose.radians(j))
            node.rotation = SCNVector4(axis.x, axis.y, axis.z, CGFloat(rad))
        }
        // 포즈가 바뀌면 발 높이도 바뀌므로 다시 접지(최저 발이 항상 바닥에).
        groundToFloor()
    }

    /// 현재 포즈의 최저 지오메트리 정점이 바닥(Y=0)에 닿도록 root 높이를 자동 보정.
    /// 모든 mesh 노드의 bounding-box 8코너를 월드(=root parent) 좌표로 변환해 최소 Y 를
    /// 구하고, 그만큼 root.position.y 를 올린다(음수면 침수 → 들어올림, 양수면 부유 → 내림).
    /// 포즈/메시 무관하게 항상 정확 접지하므로 pose-tuned 상수의 한계를 제거한다.
    func groundToFloor() {
        var minY = CGFloat.greatestFiniteMagnitude
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let lo = node.boundingBox.min
            let hi = node.boundingBox.max
            let corners = [
                SCNVector3(lo.x, lo.y, lo.z), SCNVector3(hi.x, lo.y, lo.z),
                SCNVector3(lo.x, hi.y, lo.z), SCNVector3(hi.x, hi.y, lo.z),
                SCNVector3(lo.x, lo.y, hi.z), SCNVector3(hi.x, lo.y, hi.z),
                SCNVector3(lo.x, hi.y, hi.z), SCNVector3(hi.x, hi.y, hi.z),
            ]
            for c in corners {
                let w = node.convertPosition(c, to: nil)   // root parent(=scene) 좌표
                if w.y < minY { minY = w.y }
            }
        }
        guard minY.isFinite else { return }
        root.position.y -= minY
    }

    /// **W3**: 선택 관절 highlight. emission 채널을 직접 쓰지 않고 우선순위 합성을
    /// 경유 — 한계 경고(warn85/warn95)가 켜진 관절은 highlight 가 덮어쓰지 않는다.
    func highlight(_ joint: JointID?) {
        let prev = highlightedJoint
        highlightedJoint = joint
        if let p = prev { refreshEmission(p) }
        if let j = joint { refreshEmission(j) }
    }

    // MARK: - RigSkeleton (W3)

    var rootNode: SCNNode { root }

    func jointAnchor(_ joint: JointID) -> SCNNode? { joints[joint] }

    func linkWorldPosition(_ joint: JointID) -> SCNVector3? {
        joints[joint]?.worldPosition
    }

    func footNode(_ side: FootSide) -> SCNNode? { footNodes[side] }

    func jointAxisDirection(_ joint: JointID) -> SCNVector3? { jointAxes[joint] }

    /// 한계 경고(warn) 채널 갱신 — highlight 채널은 `highlight(_:)` 소유.
    /// `.highlight` 입력은 무시(설계: highlight 는 별도 경로). `.none` 은 warn 해제.
    func setEmissionState(_ joint: JointID, _ state: EmissionState) {
        guard state != .highlight else { return }
        if state == .none {
            warnStates[joint] = nil
        } else {
            warnStates[joint] = state
        }
        refreshEmission(joint)
    }

    /// 관절의 최종 emission 상태 = warn(95>85) > highlight > none.
    private func resolvedEmission(_ joint: JointID) -> EmissionState {
        if let w = warnStates[joint] { return w }
        if joint == highlightedJoint { return .highlight }
        return .none
    }

    /// 합성 결과를 실제 mesh emission 에 반영. 원래 색은 originalEmissions 캐시.
    private func refreshEmission(_ joint: JointID) {
        guard let mesh = meshes[joint] else { return }
        let key = ObjectIdentifier(mesh)
        mesh.geometry?.firstMaterial?.emission.contents =
            resolvedEmission(joint).emissionColor ?? originalEmissions[key] ?? NSColor.black
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
        // 눈·이마 카메라·정수리 LED 액센트는 제거 — 실기와 무관한 장식이라 STL 원형만
        // 표시한다 (사용자 결정 2026-06-12).

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
        // **W3**: 발 anchor 기록 — 지지 다각형·FSR 접지 오버레이의 worldTransform 원천.
        footNodes[side == .left ? .left : .right] = ankRollAnchor
    }

    // MARK: - Head details (W4)

    /// **W4 (2026-06-12)**: 프리미티브 rig(`DarwinOP2Rig`)에만 있던 얼굴 디테일을
    /// STL 머리에도 이식 — 보라 LED 눈 2개(디스크, emission 0.85) + 이마 카메라 +
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
            let geom = try STLLoader.loadGeometry(named: name, scale: 0.001)
            // **W1**: PBR 머티리얼 주입(부위 카테고리별 metalness/roughness).
            geom.firstMaterial = RigMaterials.material(forLinkNamed: name)
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
            // v1.11.23: print → OSLog (subsystem "com.darwinforge" / category "visualization").
            // Codex HIGH fix: privacy=.public — name + error 명시 공개 (Console 에서 표시).
            // **사이클 125 (audit #19/#36, P1/P2)**: stlLoadFailureCount 누적 — caller 가 구독
            // 가능한 flag. plain cube fallback 도 명시 — 종전 silent fallback 위험.
            stlLoadFailureCount += 1
            if !stlLoadFailureNames.contains(name) {
                stlLoadFailureNames.append(name)
            }
            DFLog.visualization.warning("STL load failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

}
