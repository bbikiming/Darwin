import Combine
import ForgeCore
import SceneKit
import SwiftUI

/// `RobotScene3D` 의 scene 그래프 소유자.
///
/// **W0 (2026-06-11)**: 종전 `RobotScene3D.Coordinator` 중첩 클래스를 최상위로 승격.
/// `RobotScene3D` 는 `public typealias Coordinator = RobotSceneCoordinator` 로 소스 호환.
/// 무대(조명/바닥/그리드/축) 구성은 `SceneStage` 로 위임 — 로직 변화 0, 픽셀 동일.
public final class RobotSceneCoordinator {
    public let scene: SCNScene
    public let cameraNode: SCNNode
    private let meshRig: MeshRig?
    private let primitiveRig: DarwinOP2Rig?
    private let traceNode: SCNNode
    private let axesNode: SCNNode

    /// **v1.11.18.1 (2026-05-20)** — IMU tilt 적용용 wrapper 노드.
    /// 종전 (v1.11.18): root.eulerAngles 직접 set → MeshRig 의 ROS→SceneKit
    /// 좌표 변환 transform 이 덮어쓰여 robot 이 잘못 보임.
    /// 신: rig.root 를 tiltNode 안에 add. tiltNode.eulerAngles 만 변경 →
    /// root 의 좌표 변환 보존 + IMU 기울기 외부 적용.
    private let tiltNode: SCNNode

    /// P0-F: STL mesh 로드에 실패해 primitive fallback rig을 쓴 경우 true.
    /// 호출자(RobotScene3D)가 SwiftUI overlay로 노란 banner를 띄우는 데 사용.
    public let usingMeshFallback: Bool

    /// 라이브 튜닝(SceneTuning)이 갱신할 조명/IBL/바닥 핸들.
    private let stageHandle: SceneStage.StageHandle
    /// SceneTuning 변경 구독 — 뷰 계층과 무관하게 모든 활성 씬에 즉시 반영.
    private var tuningCancellable: AnyCancellable?

    public init() {
        scene = SCNScene()
        scene.background.contents = NSColor.clear

        // ── 무대: 조명(key+rim) + IBL + 바닥 + 그리드 — SceneStage 로 위임.
        let lights = SceneStage.installLighting(into: scene)

        // ── 카메라 — InteractiveSceneView default와 동일 위치 (snapshot test consistency).
        let cam = SCNCamera()
        cam.fieldOfView = 28                                  // 살짝 좁혀서 perspective distortion 감소
        cam.zNear = 0.03
        cam.zFar = 60
        // HDR + bloom은 흰 robot에서 burn-out을 만들어 비활성화.
        cam.wantsHDR = false
        cam.bloomIntensity = 0
        cameraNode = SCNNode()
        cameraNode.camera = cam
        let dAz: CGFloat = InteractiveSceneView.defaultAzimuth
        let dEl: CGFloat = InteractiveSceneView.defaultElevation
        let dD:  CGFloat = InteractiveSceneView.defaultDistance
        let dT = InteractiveSceneView.defaultTarget
        let cosE: CGFloat = cos(dEl)
        let cx: CGFloat = dD * cosE * sin(dAz)
        let cy: CGFloat = dD * sin(dEl)
        let cz: CGFloat = dD * cosE * cos(dAz)
        cameraNode.position = SCNVector3(
            CGFloat(dT.x) + cx,
            CGFloat(dT.y) + cy,
            CGFloat(dT.z) + cz
        )
        cameraNode.look(at: dT)
        scene.rootNode.addChildNode(cameraNode)

        // ── 그라운드 + 그리드.
        let floorNode = SceneStage.makeFloor()
        scene.rootNode.addChildNode(floorNode)
        scene.rootNode.addChildNode(SceneStage.makeGrid())

        // 라이브 튜닝 핸들 — 조명/IBL/바닥 참조 보관.
        stageHandle = SceneStage.StageHandle(
            keyLight: lights.key, rimLight: lights.rim,
            floorMaterial: floorNode.geometry?.firstMaterial, scene: scene)

        axesNode = SceneStage.makeAxes()
        scene.rootNode.addChildNode(axesNode)

        // ── 휴머노이드: ROBOTIS-OP2-Common URDF + STL mesh (Apache 2.0).
        //    실패 시 primitive 폴백 rig 사용.
        // **v1.11.18.1**: tiltNode wrapper 도입 — IMU 기울기 적용을 별도 노드로 분리.
        tiltNode = SCNNode()
        scene.rootNode.addChildNode(tiltNode)
        if let mr = try? MeshRig() {
            meshRig = mr
            primitiveRig = nil
            usingMeshFallback = false
            tiltNode.addChildNode(mr.root)  // 종전: scene.rootNode 직접
        } else {
            meshRig = nil
            let pr = DarwinOP2Rig()
            primitiveRig = pr
            usingMeshFallback = true   // P0-F: SwiftUI overlay에서 banner를 띄우게 시그널.
            tiltNode.addChildNode(pr.root)  // 종전: scene.rootNode 직접
        }

        traceNode = SCNNode()
        scene.rootNode.addChildNode(traceNode)

        // 2026-05-17 perf audit CRITICAL fix: SCNNode pool 신규.
        // 종전: applyFootTrace 매 50ms 마다 200 SCNNode + SCNSphere + SCNMaterial
        //       alloc → ~600 object/tick × ARC churn = GC pressure 심각.
        // 신규: pool 200 개 1회 alloc, position + opacity 만 갱신, isHidden 으로
        //       활성 개수 조절.
        traceDotPool = (0..<Self.traceDotPoolSize).map { _ in
            let dot = SCNSphere(radius: 0.011)
            let m = SCNMaterial()
            m.diffuse.contents = NSColor.systemOrange
            m.emission.contents = NSColor.orange
            m.lightingModel = .constant
            dot.firstMaterial = m
            let n = SCNNode(geometry: dot)
            n.isHidden = true   // 초기 — trace 가 없으면 모두 숨김
            traceNode.addChildNode(n)
            return n
        }

        // 초기 1회 + SceneTuning 변경 구독으로 라이브 반영(뷰 계층 비의존).
        // objectWillChange 는 값 변경 직전 발화 → 다음 runloop 에서 최신값 읽기.
        applyTuning()
        tuningCancellable = SceneTuning.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyTuning() }
    }

    /// 2026-05-17 perf audit: footTrail max 200 (WalkLabSession.swift:1108) 정합.
    private static let traceDotPoolSize = 200
    private var traceDotPool: [SCNNode] = []

    // MARK: bindings

    public func applyPose(_ pose: RobotPose) {
        meshRig?.apply(pose: pose)
        primitiveRig?.apply(pose: pose)
    }

    public func applyHighlightPublic(_ joint: JointID?) {
        meshRig?.highlight(joint)
        primitiveRig?.highlight(joint)
    }

    /// 2026-05-17 perf audit fix: pool 재사용 — alloc 0.
    /// 종전 매 50ms 600+ object alloc/dealloc → 0 alloc, position/opacity 만 update.
    func applyFootTrace(_ trace: [SIMD3<Double>]) {
        let activeCount = min(trace.count, traceDotPool.count)

        // trace.count < 2 (점만 있음) — 전부 숨김.
        guard trace.count > 1 else {
            for node in traceDotPool where !node.isHidden {
                node.isHidden = true
            }
            return
        }

        // 활성 노드 — position + opacity update.
        for idx in 0..<activeCount {
            let p = trace[idx]
            let alpha = CGFloat(idx) / CGFloat(max(activeCount - 1, 1))
            let node = traceDotPool[idx]
            node.position = SCNVector3(-CGFloat(p.y),
                                       CGFloat(p.z) * 0.5 + 0.001,
                                       -CGFloat(p.x))
            // material 은 1회 alloc된 sphere 의 first material — opacity 만 갱신.
            if let mat = node.geometry?.firstMaterial {
                mat.diffuse.contents = NSColor.systemOrange
                    .withAlphaComponent(0.25 + alpha * 0.65)
                mat.emission.contents = NSColor.orange
                    .withAlphaComponent(alpha * 0.55)
            }
            if node.isHidden { node.isHidden = false }
        }

        // 비활성 노드 — 숨김 (alloc 없이 visibility 토글만).
        if activeCount < traceDotPool.count {
            for idx in activeCount..<traceDotPool.count {
                let node = traceDotPool[idx]
                if !node.isHidden { node.isHidden = true }
            }
        }
    }

    func applyHighlight(_ joint: JointID?) {
        applyHighlightPublic(joint)
    }

    func applyAxesVisible(_ visible: Bool) {
        axesNode.isHidden = !visible
    }

    /// 라이브 튜닝값(SceneTuning.shared)을 조명/IBL/바닥 + 모든 카테고리 머티리얼에 적용.
    /// `RobotScene3D.make/updateNSView` 에서 호출(패널 슬라이더 변경 → body 재평가 경유).
    func applyTuning() {
        let t = SceneTuning.shared
        SceneStage.apply(t, to: stageHandle)
        RigMaterials.applyTuning(t)
    }

    /// **v1.11.18 (2026-05-19)**: IMU 기반 robot tilt 적용.
    /// **v1.11.18.1 (2026-05-20) — bug fix**: tiltNode wrapper 사용. 종전 직접
    /// root.eulerAngles set → MeshRig 의 ROS→SceneKit 좌표 변환 transform (root)
    /// 덮어써져서 robot 이 잘못 보였음. tiltNode 는 transform 미설정이라 안전.
    ///
    /// 축 매핑 (SceneKit world frame, Y up):
    /// - pitchDeg → X 축 회전 (전후 기울기, robot 의 forward = -Z)
    /// - rollDeg → Z 축 회전 (좌우 기울기, robot 의 좌우 = X)
    /// SceneKit eulerAngles 는 radian. CGFloat 인자 (macOS).
    func applyImuTilt(rollDeg: Double, pitchDeg: Double) {
        let safeRoll = ImuAttitudeDisplayMapping.sanitize(rollDeg)
        let safePitch = ImuAttitudeDisplayMapping.sanitize(pitchDeg)
        let rollRad = CGFloat(safeRoll * .pi / 180.0)
        let pitchRad = CGFloat(safePitch * .pi / 180.0)
        tiltNode.eulerAngles = SCNVector3(x: pitchRad, y: 0, z: rollRad)
    }
}
