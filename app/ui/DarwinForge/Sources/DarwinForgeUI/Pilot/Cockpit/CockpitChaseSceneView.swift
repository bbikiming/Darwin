import AppKit
import ForgeCore
import SceneKit
import SwiftUI

/// SCNView subclass that intercepts scroll-wheel / trackpad events to drive
/// chase-camera zoom. The chase camera is a child of the robot's rig anchor,
/// so we only mutate its local `position` along the Z axis (camera-to-robot
/// distance). Roll/yaw/pitch follow the anchor automatically.
public final class CockpitChaseSCNView: SCNView {
    /// Camera node — child of `rigAnchor` in Coordinator.
    public weak var cameraNode: SCNNode?

    /// Distance limits — robot is ~0.45 m tall, so 0.6 m min keeps the robot
    /// fully framed without clipping into the mesh, and 4.0 m max keeps the
    /// scene readable even on small windows.
    public var minDistance: CGFloat = 0.6
    public var maxDistance: CGFloat = 4.0

    /// 고정된 chase camera 높이 (m). zoom 시 변하지 않아 robot 등 뒤 시점 안정.
    private let chaseHeight: CGFloat = 0.95
    /// 고정 look-at target (robot 의 가슴 높이).
    private let chaseTarget = SCNVector3(0, 0.30, 0)

    public override func scrollWheel(with event: NSEvent) {
        guard let cam = cameraNode else { return super.scrollWheel(with: event) }

        // **방법론 (Apple HIG + SceneKit best practice)**:
        //   - 트랙패드: hasPreciseScrollingDeltas == true, deltaY 가 작고 정밀.
        //   - 마우스 휠: hasPreciseScrollingDeltas == false, deltaY 가 큰 step.
        // 두 input 의 scale 을 분리해 양쪽 모두 매끄럽게 zoom.
        let raw = event.scrollingDeltaY
        let delta: CGFloat = event.hasPreciseScrollingDeltas
            ? -raw * 0.008
            : -raw * 0.06
        // 한 frame 의 변화량을 ±0.4m 로 limit — 트랙패드 inertial flick 으로 카메라가
        // 한순간에 튀어 chase 가 부자연스러워지는 현상 차단.
        let clampedDelta = max(-0.4, min(0.4, delta))

        var pos = cam.position
        let newZ = (CGFloat(pos.z) - clampedDelta)
            .clamped(to: -maxDistance ... -minDistance)
        // **카메라 등 뒤 고정 invariant**: x/y 는 절대 변경하지 않아 chase camera 가
        // 항상 robot 의 등 뒤 정중앙 + 동일 높이에 위치. zoom 은 distance (z) 만
        // 변경. rotation 은 SCNLookAtConstraint 가 매 frame 자동 보정하므로 별도
        // `look(at:)` 호출 불필요 — constraint 가 hard lock 을 보장.
        pos.x = 0
        pos.y = chaseHeight
        pos.z = newZ
        cam.position = pos
    }

    /// Trackpad pinch zoom — 두 손가락 magnify 도 zoom 으로 라우팅.
    public override func magnify(with event: NSEvent) {
        guard let cam = cameraNode else { return super.magnify(with: event) }
        // event.magnification: pinch in = positive, pinch out = negative.
        // pinch in = zoom in (가까이) → z 증가 (덜 negative).
        let delta = CGFloat(event.magnification) * 0.8
        var pos = cam.position
        let newZ = (CGFloat(pos.z) + delta)
            .clamped(to: -maxDistance ... -minDistance)
        pos.x = 0
        pos.y = chaseHeight
        pos.z = newZ
        cam.position = pos
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
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
        view.cameraNode = context.coordinator.cameraNode
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 30
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.pointOfView = context.coordinator.cameraNode
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

    public final class Coordinator {
        let scene: SCNScene
        let cameraNode: SCNNode
        /// Heading + position 적용 wrapper. 카메라가 자식으로 붙어 chase camera.
        let rigAnchor: SCNNode
        /// IMU roll/pitch 적용 wrapper — heading 과 독립.
        let tiltWrapper: SCNNode

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

        init() {
            scene = SCNScene()
            scene.background.contents = NSColor(calibratedRed: 0.02,
                                                green: 0.04,
                                                blue: 0.07,
                                                alpha: 1.0)

            // Lighting — moody FPV grid look but enough to read the robot mesh.
            let key = SCNLight()
            key.type = .directional
            key.intensity = 420
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

            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 240
            ambient.color = NSColor(calibratedRed: 0.75,
                                    green: 0.82,
                                    blue: 0.95,
                                    alpha: 1.0)
            scene.rootNode.addChildNode({
                let n = SCNNode(); n.light = ambient; return n
            }())

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

            let cam = SCNCamera()
            cam.fieldOfView = 50
            cam.zNear = 0.05
            cam.zFar = 80
            cameraNode = SCNNode()
            cameraNode.camera = cam
            cameraNode.position = SCNVector3(0, 0.95, -1.55)
            rigAnchor.addChildNode(cameraNode)

            // Chase target — robot 의 가슴 위치 (rigAnchor 좌표계).
            let chestTarget = SCNNode()
            chestTarget.position = SCNVector3(0, 0.30, 0)
            rigAnchor.addChildNode(chestTarget)

            // Hard look-at constraint — 매 frame 자동 적용.
            let lookAt = SCNLookAtConstraint(target: chestTarget)
            lookAt.isGimbalLockEnabled = true   // y-axis only — banking 없음
            cameraNode.constraints = [lookAt]
        }

        func applyPose(_ pose: RobotPose) {
            // **HIGH #5**: pose equality check 로 변화 없는 frame skip.
            if let last = lastPose, last == pose { return }
            meshRig?.apply(pose: pose)
            primitiveRig?.apply(pose: pose)
            lastPose = pose
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

            // Grid lines.
            let half = 14
            let step: Float = 0.5
            for i in -half...half {
                let v = Float(i) * step
                let mat = SCNMaterial()
                mat.diffuse.contents = NSColor(calibratedRed: 0.20,
                                               green: 0.70,
                                               blue: 0.55,
                                               alpha: i.isMultiple(of: 2) ? 0.45 : 0.18)
                mat.emission.contents = mat.diffuse.contents
                mat.lightingModel = .constant

                let xLine = SCNCylinder(radius: 0.003,
                                        height: CGFloat(step * Float(half * 2)))
                xLine.firstMaterial = mat
                let xn = SCNNode(geometry: xLine)
                xn.position = SCNVector3(v, 0.002, 0)
                xn.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
                parent.addChildNode(xn)

                let zLine = SCNCylinder(radius: 0.003,
                                        height: CGFloat(step * Float(half * 2)))
                zLine.firstMaterial = mat
                let zn = SCNNode(geometry: zLine)
                zn.position = SCNVector3(0, 0.002, v)
                zn.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
                parent.addChildNode(zn)
            }
            return parent
        }
    }
}
