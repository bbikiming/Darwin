import AppKit
import ForgeCore
import SceneKit
import SwiftUI

/// SCNView subclass that intercepts scroll-wheel / trackpad events to drive
/// chase-camera zoom. The chase camera is a child of the robot's rig anchor,
/// so we only mutate its local `position` along the Z axis (camera-to-robot
/// distance). Roll/yaw/pitch follow the anchor automatically.
public final class CockpitChaseSCNView: SCNView {
    /// **W4 (2026-06-12)**: zoom 입력은 더 이상 카메라 노드를 직접 만지지 않고
    /// 체이스 follower 의 `distance` 를 조정한다(카메라는 이제 scene root 직속이며
    /// 렌더 델리게이트가 위치를 lerp 추종). coordinator 가 follower 를 소유.
    public weak var coordinator: CockpitChaseSceneView.Coordinator?

    public override func scrollWheel(with event: NSEvent) {
        guard let coordinator else { return super.scrollWheel(with: event) }

        // **방법론 (Apple HIG + SceneKit best practice)**:
        //   - 트랙패드: hasPreciseScrollingDeltas == true, deltaY 가 작고 정밀.
        //   - 마우스 휠: hasPreciseScrollingDeltas == false, deltaY 가 큰 step.
        let raw = event.scrollingDeltaY
        let delta: Double = event.hasPreciseScrollingDeltas
            ? Double(-raw * 0.008)
            : Double(-raw * 0.06)
        // ±0.4m 로 limit — 트랙패드 inertial flick 의 과한 튐 차단.
        let clamped = max(-0.4, min(0.4, delta))
        // distance 부호: 멀어짐 = +. 종전 z(−distance) 기준 "-clampedDelta" 와 등가.
        coordinator.zoom(by: -clamped)
    }

    /// Trackpad pinch zoom.
    public override func magnify(with event: NSEvent) {
        guard let coordinator else { return super.magnify(with: event) }
        // pinch in (양수) = 가까이 = distance 감소.
        coordinator.zoom(by: Double(-event.magnification) * 0.8)
    }
}

/// FPV 드론 시뮬레이터 스타일 3인칭 chase camera scene.
///
/// # 정직성 (사용자 지적 반영)
///
/// **종전**: 단순화된 직접 만든 robot rig (cylinder + sphere 다리).
///   → 사용자가 "다윈 모델링 그대로 사용해" 라고 지적. 다른 모델이라 혼란.
///
/// **현재**: WalkLab 의 `RobotScene3D` 와 **동일한** `MeshRig` (ROBOTIS-OP2-Common
/// URDF + STL mesh) 를 재사용. STL mesh 로드 실패 시 동일한 `DarwinOP2Rig`
/// primitive fallback. 두 화면에서 사용자가 보는 robot 의 외형이 일치.
///
/// # 카메라 동작
///
/// 카메라는 robot 의 `root` 노드의 child 로 attach. SceneKit 에서 parent transform
/// 이 자식에 전파되므로 robot 이 yaw 회전/이동하면 카메라가 자동으로 따라온다.
///
/// # Robot pose 우선순위
///
/// 1. 외부에서 전달된 `pose` (ConnectionStore.lastTelemetry?.pose 등 실 robot 자세)
/// 2. fallback: `RobotPose.walkReady` (정자세)
///
/// 외부 `simulatedHeadingDeg` / `simulatedPositionMM` 은 명시적 시뮬레이션 모드
/// 에서만 적용 (호출자가 인지하고 토글).
public struct CockpitChaseSceneView: NSViewRepresentable {

    public var pose: RobotPose
    public var simulatedHeadingDeg: Double
    public var simulatedPositionMM: SIMD2<Double>
    public var imuRollDeg: Double
    public var imuPitchDeg: Double

    public init(pose: RobotPose = .walkReady,
                simulatedHeadingDeg: Double = 0,
                simulatedPositionMM: SIMD2<Double> = .zero,
                imuRollDeg: Double = 0,
                imuPitchDeg: Double = 0) {
        self.pose = pose
        self.simulatedHeadingDeg = simulatedHeadingDeg
        self.simulatedPositionMM = simulatedPositionMM
        self.imuRollDeg = imuRollDeg
        self.imuPitchDeg = imuPitchDeg
    }

    public func makeNSView(context: Context) -> CockpitChaseSCNView {
        let view = CockpitChaseSCNView(frame: .zero)
        view.coordinator = context.coordinator
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 30
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.pointOfView = context.coordinator.cameraNode
        // **W4**: 체이스 follower 를 30fps 렌더 루프에서 구동. delegate 는 약참조라
        // coordinator 가 소유권 유지. `rendersContinuously` 로 매 프레임 delegate 가
        // 발화하도록 보장(Cockpit 은 chase 추종이 본질이라 연속 렌더가 필요·정당 —
        // WalkLab/Studio 의 idle tick 계약과는 무관한 별도 화면).
        view.rendersContinuously = true
        view.delegate = context.coordinator.renderDelegate
        applyState(to: context.coordinator)
        return view
    }

    public func updateNSView(_ nsView: CockpitChaseSCNView, context: Context) {
        applyState(to: context.coordinator)
    }

    private func applyState(to c: Coordinator) {
        c.applyPose(pose)

        let xMeters = simulatedPositionMM.x / 1000.0
        let zMeters = simulatedPositionMM.y / 1000.0
        let newPos = SCNVector3(xMeters, 0, zMeters)
        if c.lastPosition?.x != newPos.x || c.lastPosition?.z != newPos.z {
            c.rigAnchor.position = newPos
            c.lastPosition = newPos
        }

        let newHeading = CGFloat(simulatedHeadingDeg * .pi / 180.0)
        if c.lastHeadingRad != newHeading {
            c.rigAnchor.eulerAngles.y = newHeading
            c.lastHeadingRad = newHeading
        }

        // IMU tilt — pitch around X, roll around Z.
        let newPitch = CGFloat(imuPitchDeg * .pi / 180.0)
        let newRoll = CGFloat(imuRollDeg * .pi / 180.0)
        if c.lastTiltPitchRad != newPitch || c.lastTiltRollRad != newRoll {
            c.tiltWrapper.eulerAngles = SCNVector3(x: newPitch, y: 0, z: newRoll)
            c.lastTiltPitchRad = newPitch
            c.lastTiltRollRad = newRoll
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    /// **W4 (2026-06-12)**: SCNView 의 약참조 delegate 가 dealloc 되지 않도록
    /// coordinator 가 소유하는 렌더 델리게이트. 렌더 루프(30fps)에서 체이스 follower
    /// 를 구동한다. SCNSceneRendererDelegate 는 @objc 라 NSObject 가 필요하므로
    /// Coordinator 본체와 분리(본체는 plain class 로 init 단순 유지).
    public final class ChaseRenderDelegate: NSObject, SCNSceneRendererDelegate {
        weak var owner: Coordinator?
        public func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            owner?.advanceChase(time: time)
        }
    }

    public final class Coordinator {
        let scene: SCNScene
        let cameraNode: SCNNode
        /// Heading + position 적용 wrapper. (카메라는 W4 부터 scene root 직속이고
        /// rigAnchor 는 robot 본체 + 룩타깃의 부모로만 쓰인다.)
        let rigAnchor: SCNNode
        /// IMU roll/pitch 적용 wrapper — heading 과 독립.
        let tiltWrapper: SCNNode
        /// **W4**: 카메라 LookAt 대상(scene root 직속). follower 가 lean 반영해 위치.
        private let lookTargetNode: SCNNode
        /// **W4**: 렌더 루프 델리게이트(coordinator 소유 → 약참조여도 생존).
        let renderDelegate = ChaseRenderDelegate()

        private let meshRig: MeshRig?
        private let primitiveRig: DarwinOP2Rig?
        /// **HIGH #5 fix (code review)**: pose / position / rotation 캐시 — 변화 없는
        /// frame 에서 SceneKit transform 갱신 skip. 30Hz × 20 joint write 의 대부분을
        /// 제거해 main thread cost 와 GPU upload 모두 절감.
        fileprivate var lastPose: RobotPose?
        fileprivate var lastPosition: SCNVector3?
        fileprivate var lastHeadingRad: CGFloat?
        fileprivate var lastTiltPitchRad: CGFloat?
        fileprivate var lastTiltRollRad: CGFloat?

        /// **W4 (2026-06-12)**: 체이스 follower(순수 로직) + 렌더/메인 스레드 간 보호 락.
        /// scroll(메인)과 renderer(렌더 스레드)가 모두 follower 를 만지므로 직렬화.
        private var follower = CockpitChaseFollower()
        private let followerLock = NSLock()
        private var lastUpdateTime: TimeInterval = -1

        init() {
            lookTargetNode = SCNNode()
            scene = SCNScene()
            scene.background.contents = NSColor(calibratedRed: 0.02,
                                                green: 0.04,
                                                blue: 0.07,
                                                alpha: 1.0)

            // Lighting — **W1**: PBR 전환에 맞춰 ambient 삭제 + teal IBL.
            // MeshRig/DarwinOP2Rig 이 이제 PBR 이라 lightingEnvironment 없으면 검게 죽는다.
            let key = SCNLight()
            key.type = .directional
            key.intensity = 700                        // 420 → 700 (IBL base 위 key)
            key.color = NSColor(calibratedRed: 0.95,
                                green: 0.97,
                                blue: 1.00,
                                alpha: 1.0)
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.eulerAngles = SCNVector3(-CGFloat.pi / 3,
                                              CGFloat.pi / 5,
                                              0)
            scene.rootNode.addChildNode(keyNode)

            // 절차적 IBL(teal) — ambient 대체.
            scene.lightingEnvironment.contents = ProceduralEnvironmentMap.cockpit
            scene.lightingEnvironment.intensity = 0.6

            // Grid floor — FPV cliché, helps user gauge motion.
            scene.rootNode.addChildNode(Self.makeGridFloor())

            // Rig wrappers — 노드 계층:
            //   rigAnchor (sim 위치/yaw)
            //     └─ facingAnchor (robot 정면이 +Z 로 향하게 180° flip)
            //          └─ tiltWrapper (IMU roll/pitch)
            //               └─ meshRig.root
            //
            // **방향 fix (사용자 보고)**: `MeshRig.root.transform` 의 ROS→SceneKit
            // 변환 결과 robot 의 정면이 SceneKit Z- 방향이다. 그러나 chase camera
            // 를 z=-1.55 (robot 의 -Z) 에 두면 robot 의 얼굴을 정면에서 보게 된다
            // — "stick 전진 → 화면에서 후진하는 듯" 의 원인. facingAnchor 에
            // y=180° 추가 회전하여 robot 의 정면을 +Z 로 돌려, 카메라가 robot 의
            // 등 뒤에서 정면 방향을 본다. stick 전진 → robot 이 화면 안쪽 +Z 로
            // 이동 → camera 가 child 라 같이 +Z 로 따라감 → 화면에서는 grid 가
            // 사용자 쪽으로 흘러 들어오는 자연스러운 chase camera.
            rigAnchor = SCNNode()
            let facingAnchor = SCNNode()
            facingAnchor.eulerAngles.y = .pi
            tiltWrapper = SCNNode()
            rigAnchor.addChildNode(facingAnchor)
            facingAnchor.addChildNode(tiltWrapper)
            scene.rootNode.addChildNode(rigAnchor)

            // 정직성: WalkLab 의 RobotScene3D 와 같은 rig 을 사용.
            if let mr = try? MeshRig() {
                meshRig = mr
                primitiveRig = nil
                tiltWrapper.addChildNode(mr.root)
            } else {
                meshRig = nil
                let pr = DarwinOP2Rig()
                primitiveRig = pr
                tiltWrapper.addChildNode(pr.root)
            }

            // **방법론 (Unity Cinemachine FreeLook + Unreal Spring Arm)**:
            //
            // 3인칭 chase camera 는 두 가지 invariant 가 필요하다:
            //   (1) **Position lock**: 카메라가 robot 의 child 좌표계에서 항상 같은
            //       offset (등 뒤 + 위). robot 이 yaw/이동해도 같은 위치 유지.
            //   (2) **Orientation lock**: 카메라가 항상 robot 의 가슴 (또는 head)
            //       을 본다 — `SCNLookAtConstraint` 가 매 frame rotation 을 강제로
            //       target 으로 향하게 한다. position 만 변경해도 회전이 자동 보정.
            //
            // 종전 구현은 (1) 만 있었고 (2) 는 init 시 1회 `look(at:)` 만 호출 →
            // scroll zoom 으로 position 변경 시 회전이 따라오지 않아 사용자 시야가
            // 튀었다. SCNLookAtConstraint 로 hard lock — 카메라가 robot 추적에서
            // **절대** 벗어나지 않는다.

            // **W4 (2026-06-12)**: 카메라를 rigAnchor 자식 → **scene root 직속**으로.
            // 종전엔 카메라가 rigAnchor 자식이라 robot 이동/yaw 에 즉시(0-lag) 붙어버려
            // FPV 특유의 "관성 추종"이 없었다. 이제 카메라는 독립 노드이고 렌더 델리게이트
            // (`advanceChase`)가 follower 로 위치 lerp(0.12)/heading lerp(0.08) 추종한다.
            let cam = SCNCamera()
            cam.fieldOfView = 50
            cam.zNear = 0.05
            cam.zFar = 80
            cameraNode = SCNNode()
            cameraNode.camera = cam
            // 초기 위치 = 등 뒤(heading 0). follower 초기값과 동일.
            cameraNode.simdPosition = SIMD3<Float>(CockpitChaseFollower.backOffset(
                heading: 0, distance: 1.55, height: 0.95))
            scene.rootNode.addChildNode(cameraNode)

            // **W4**: 룩타깃을 scene root 직속 노드로. follower 가 lean 반영해 위치
            // 갱신하고 LookAt constraint 는 그대로 유지(설계: constraint 유지).
            lookTargetNode.position = SCNVector3(0, 0.30, 0)
            scene.rootNode.addChildNode(lookTargetNode)

            // Hard look-at constraint — 매 frame 자동 적용.
            let lookAt = SCNLookAtConstraint(target: lookTargetNode)
            lookAt.isGimbalLockEnabled = true   // y-axis only — banking 없음
            cameraNode.constraints = [lookAt]

            // 렌더 델리게이트가 self 를 약참조로 구동.
            renderDelegate.owner = self
        }

        func applyPose(_ pose: RobotPose) {
            // **HIGH #5**: pose equality check 로 변화 없는 frame skip.
            if let last = lastPose, last == pose { return }
            meshRig?.apply(pose: pose)
            primitiveRig?.apply(pose: pose)
            lastPose = pose
        }

        /// **W4**: zoom — 메인 스레드(scroll/pinch)에서 호출. follower distance 조정.
        func zoom(by delta: Double) {
            followerLock.lock()
            follower.adjustDistance(by: delta)
            followerLock.unlock()
        }

        /// **W4**: 렌더 루프(30fps)에서 호출되는 체이스 추종 갱신.
        /// rigAnchor 의 world 위치/heading 을 읽어 follower 로 카메라 위치·룩타깃·FOV 를
        /// 매 프레임 lerp 추종한다. (rigAnchor 는 메인에서 애니메이션 없이 set 되므로
        /// model==presentation — 렌더 스레드 read 안전.)
        func advanceChase(time: TimeInterval) {
            let dt: TimeInterval = lastUpdateTime < 0 ? (1.0 / 30.0)
                : min(0.1, max(0, time - lastUpdateTime))
            lastUpdateTime = time

            let wp = rigAnchor.simdWorldPosition
            let targetPos = SIMD3<Double>(Double(wp.x), Double(wp.y), Double(wp.z))
            let heading = Double(rigAnchor.eulerAngles.y)

            followerLock.lock()
            follower.update(targetPosition: targetPos, targetHeading: heading, dt: dt)
            let camPos = follower.cameraPosition
            let look = follower.lookTarget
            let fov = follower.fov
            followerLock.unlock()

            cameraNode.simdPosition = SIMD3<Float>(Float(camPos.x), Float(camPos.y), Float(camPos.z))
            lookTargetNode.simdPosition = SIMD3<Float>(Float(look.x), Float(look.y), Float(look.z))
            cameraNode.camera?.fieldOfView = CGFloat(fov)
        }

        private static func makeGridFloor() -> SCNNode {
            let parent = SCNNode()

            // Dark base floor.
            let floor = SCNFloor()
            floor.reflectivity = 0
            let mat = SCNMaterial()
            mat.diffuse.contents = NSColor(calibratedRed: 0.04,
                                           green: 0.08,
                                           blue: 0.11,
                                           alpha: 1.0)
            mat.specular.contents = NSColor.black
            floor.firstMaterial = mat
            parent.addChildNode(SCNNode(geometry: floor))

            // **W2 (2026-06-11)**: 58-node 실린더 그리드 → 단일 셰이더 AA 그리드(teal)로
            // 교체(draw call -57, 거리 무관 일정 픽셀폭). 그리드는 월드 원점 고정 plane,
            // 로봇·카메라가 +Z 로 이동하므로 라인이 스크롤하는 FPV 모션 큐는 보존된다
            // (fade 12m 라 ±20m plane 경계는 보이지 않음). Cockpit 스펙 그리드 단일 소스.
            parent.addChildNode(
                GridFloorMaterial.makeGridNode(style: SceneEnvironmentSpec.spec(for: .cockpit).grid))
            return parent
        }
    }
}
