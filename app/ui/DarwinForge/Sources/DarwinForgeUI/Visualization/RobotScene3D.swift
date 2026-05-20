import ForgeCore
import Metal
import SceneKit
import SwiftUI

/// SceneKit 기반 16-DOF 휴머노이드 실시간 뷰어 — ROBOTIS-OP2 비주얼 모사.
///
/// Webots `robotis-op2` proto의 mesh를 직접 import하지 않고 SceneKit primitives
/// (SCNBox/SCNSphere/SCNCylinder/SCNCapsule)로 외형을 재현. 모든 관절에는 회전
/// 노드 + MX-28T 모터 그룹 + 본 메시가 묶여 있다.
public struct RobotScene3D: NSViewRepresentable {
    public let pose: RobotPose
    public let footTrace: [SIMD3<Double>]
    public let highlight: JointID?
    public let showAxes: Bool
    /// P0-F: STL mesh fallback 신호용. 코디네이터가 활성 시 banner 띄우도록 호출자가 구독.
    public let onMeshFallback: ((Bool) -> Void)?
    /// SwiftUI 측에서 ViewCube 등으로 카메라를 조작할 때 사용. nil이면 자체 인터랙션만.
    public let cameraController: CameraController?
    /// **v1.11.18 (2026-05-19)** — IMU 기반 base orientation tilt.
    /// 실시간 imuRollDeg/imuPitchDeg 가 robot 전체 root 노드의 eulerAngles 에 적용.
    /// 사용자 워크랩 진입 시 robot 의 실제 기울기 시각화 (sim/real 무관).
    /// default 0 — 종전 호출처는 변경 X.
    public let imuRollDeg: Double
    public let imuPitchDeg: Double

    public init(pose: RobotPose,
                footTrace: [SIMD3<Double>] = [],
                highlight: JointID? = nil,
                showAxes: Bool = true,
                onMeshFallback: ((Bool) -> Void)? = nil,
                cameraController: CameraController? = nil,
                imuRollDeg: Double = 0,
                imuPitchDeg: Double = 0) {
        self.pose = pose
        self.footTrace = footTrace
        self.highlight = highlight
        self.showAxes = showAxes
        self.onMeshFallback = onMeshFallback
        self.cameraController = cameraController
        self.imuRollDeg = imuRollDeg
        self.imuPitchDeg = imuPitchDeg
    }

    public func makeNSView(context: Context) -> InteractiveSceneView {
        let view = InteractiveSceneView(frame: .zero)
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.pointOfView = context.coordinator.cameraNode
        view.applyCamera()                         // orbit state → 카메라 적용
        context.coordinator.applyPose(pose)
        context.coordinator.applyFootTrace(footTrace)
        context.coordinator.applyHighlight(highlight)
        context.coordinator.applyAxesVisible(showAxes)
        context.coordinator.applyImuTilt(rollDeg: imuRollDeg, pitchDeg: imuPitchDeg)
        // ViewCube/Home 버튼이 카메라를 조작할 수 있도록 controller에 view 등록.
        if let controller = cameraController {
            DispatchQueue.main.async { controller.view = view }
        }
        // P0-F: makeNSView 한 번 호출 시 fallback 여부를 호출자에게 통지.
        if let cb = onMeshFallback {
            let active = context.coordinator.usingMeshFallback
            DispatchQueue.main.async { cb(active) }
        }
        return view
    }

    public func updateNSView(_ nsView: InteractiveSceneView, context: Context) {
        context.coordinator.applyPose(pose)
        context.coordinator.applyFootTrace(footTrace)
        context.coordinator.applyHighlight(highlight)
        context.coordinator.applyAxesVisible(showAxes)
        context.coordinator.applyImuTilt(rollDeg: imuRollDeg, pitchDeg: imuPitchDeg)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    public final class Coordinator {
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

        public init() {
            scene = SCNScene()
            scene.background.contents = NSColor.clear

            // ── Lighting (3-point) — burn-out 방지를 위해 강도 대폭 낮춤.
            let key = SCNLight()
            key.type = .directional
            key.intensity = 240                                   // 420 → 240
            key.castsShadow = true
            key.shadowRadius = 4
            key.shadowSampleCount = 12
            key.shadowMode = .deferred
            key.color = NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.95, alpha: 1.0)
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.position = SCNVector3(0.6, 2.3, -2.0)
            keyNode.look(at: SCNVector3(0, 0.30, 0))
            scene.rootNode.addChildNode(keyNode)

            let fill = SCNLight()
            fill.type = .directional
            fill.intensity = 130                                   // 200 → 130
            fill.color = NSColor(calibratedRed: 0.86, green: 0.92, blue: 1.00, alpha: 1.0)
            let fillNode = SCNNode()
            fillNode.light = fill
            fillNode.position = SCNVector3(-1.5, 1.4, 0.5)
            fillNode.look(at: SCNVector3(0, 0.30, 0))
            scene.rootNode.addChildNode(fillNode)

            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 200                                // 280 → 200
            let aNode = SCNNode()
            aNode.light = ambient
            scene.rootNode.addChildNode(aNode)

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

            // ── 그라운드 — 반사 없애 흰 robot의 후광 burn-out 차단.
            let ground = SCNFloor()
            ground.reflectivity = 0
            let gMat = SCNMaterial()
            gMat.diffuse.contents = NSColor(white: 0.10, alpha: 1.0)
            gMat.specular.contents = NSColor.black
            gMat.lightingModel = .blinn
            ground.firstMaterial = gMat
            scene.rootNode.addChildNode(SCNNode(geometry: ground))
            scene.rootNode.addChildNode(Self.makeGrid())

            axesNode = Self.makeAxes()
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

        // MARK: helpers

        private static func makeGrid() -> SCNNode {
            let group = SCNNode()
            let half = 0.85
            let step = 0.10
            let mat = SCNMaterial()
            mat.diffuse.contents = NSColor(white: 0.18, alpha: 1.0)
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

        private static func makeAxes() -> SCNNode {
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
}

// MARK: - Headless rendering (for visual self-tests)

public extension RobotScene3D {
    /// 헤드리스 SCNRenderer로 한 프레임 렌더 → NSImage.
    /// 자체 검증(스크린샷 비교) 또는 docs/preview용.
    @MainActor
    static func renderImage(pose: RobotPose,
                            size: CGSize = CGSize(width: 1024, height: 768),
                            highlight: JointID? = nil,
                            cameraOverride: SCNVector3? = nil) -> NSImage? {
        let coord = Coordinator()
        coord.applyPose(pose)
        coord.applyHighlightPublic(highlight)

        if let cam = cameraOverride {
            coord.cameraNode.position = cam
            coord.cameraNode.look(at: SCNVector3(0, 0.27, 0))
        }

        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = coord.scene
        renderer.pointOfView = coord.cameraNode
        return renderer.snapshot(atTime: 0,
                                 with: size,
                                 antialiasingMode: .multisampling4X)
    }

    /// 헤드리스 PNG 저장. 성공 시 true.
    @MainActor
    @discardableResult
    static func writePNG(pose: RobotPose,
                         to url: URL,
                         size: CGSize = CGSize(width: 1024, height: 768),
                         highlight: JointID? = nil,
                         cameraOverride: SCNVector3? = nil) -> Bool {
        guard let img = renderImage(pose: pose, size: size,
                                    highlight: highlight,
                                    cameraOverride: cameraOverride),
              let tiff = img.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? png.write(to: url)) != nil
    }
}

// MARK: - DarwinOP2Rig

/// ROBOTIS-OP2 (DARwIn-OP 2세대) 형상 본 트리.
final class DarwinOP2Rig {
    let root: SCNNode
    private var joints: [JointID: SCNNode] = [:]
    private var highlightMeshes: [JointID: [SCNNode]] = [:]
    private var originalEmissions: [ObjectIdentifier: NSColor] = [:]

    // ────────────────────────────────────────────────────────────────────────
    // 컬러 팔레트 (Webots OP2 스크린샷 기반)
    // ────────────────────────────────────────────────────────────────────────

    static let bodyShell    = NSColor(calibratedRed: 0.78, green: 0.78, blue: 0.80, alpha: 1.0)  // 본체 회색
    static let bodyShellHi  = NSColor(calibratedRed: 0.86, green: 0.86, blue: 0.88, alpha: 1.0)  // 밝은 면
    static let helmetDark   = NSColor(calibratedRed: 0.18, green: 0.19, blue: 0.21, alpha: 1.0)  // 헬멧
    static let motorBlack   = NSColor(calibratedWhite: 0.13, alpha: 1.0)
    static let motorCap     = NSColor(calibratedWhite: 0.83, alpha: 1.0)
    static let detailDark   = NSColor(calibratedWhite: 0.20, alpha: 1.0)
    static let footBlack    = NSColor(calibratedWhite: 0.09, alpha: 1.0)
    static let solWhite     = NSColor(calibratedWhite: 0.88, alpha: 1.0)
    static let eyePurple    = NSColor(calibratedRed: 0.42, green: 0.36, blue: 1.00, alpha: 1.0)
    static let eyePupil     = NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.10, alpha: 1.0)
    static let ledGreen     = NSColor(calibratedRed: 0.30, green: 0.95, blue: 0.42, alpha: 1.0)
    static let darwinRed    = NSColor(calibratedRed: 0.86, green: 0.14, blue: 0.10, alpha: 1.0)

    // ────────────────────────────────────────────────────────────────────────
    // 치수 (실제 ROBOTIS-OP2: 키 454.5 mm, 단위 m)
    // ────────────────────────────────────────────────────────────────────────

    static let pelvisHeight: CGFloat = 0.358

    // 머리
    static let helmetW: CGFloat = 0.094
    static let helmetH: CGFloat = 0.084
    static let helmetD: CGFloat = 0.092
    static let eyeRadius: CGFloat = 0.012

    // 가슴
    static let chestW: CGFloat = 0.124
    static let chestH: CGFloat = 0.122
    static let chestD: CGFloat = 0.084

    // 어깨/골반 anchor offsets
    static let shoulderOffX: CGFloat = 0.073
    static let shoulderOffY: CGFloat = 0.054
    static let hipOffX: CGFloat = 0.044
    static let hipOffY: CGFloat = -0.022

    // 팔 — Webots OP2처럼 stocky 비율
    static let upperArmLen: CGFloat = 0.072
    static let upperArmDia: CGFloat = 0.042
    static let forearmLen:  CGFloat = 0.140
    static let forearmDia:  CGFloat = 0.038

    // 다리 — 본 길이 +20%, 굵기 +25%
    static let thighLen: CGFloat = 0.110
    static let thighDia: CGFloat = 0.056
    static let shinLen:  CGFloat = 0.110
    static let shinDia:  CGFloat = 0.052

    // 발
    static let footW: CGFloat = 0.078
    static let footH: CGFloat = 0.028
    static let footD: CGFloat = 0.118
    static let footChamfer: CGFloat = 0.014

    init() {
        root = SCNNode()
        root.position = SCNVector3(0, Self.pelvisHeight, 0)
        buildBody()
    }

    // MARK: - Pose

    func apply(pose: RobotPose) {
        for j in JointID.allCases {
            guard let node = joints[j] else { continue }
            let rad = pose.radians(j)
            let robotAxis = j.rotationAxis
            let sceneAxis: SCNVector3
            if robotAxis == SIMD3(0, 1, 0) {
                sceneAxis = SCNVector3(1, 0, 0)        // pitch → SceneKit X
            } else if robotAxis == SIMD3(1, 0, 0) {
                sceneAxis = SCNVector3(0, 0, 1)        // roll → SceneKit Z
            } else {
                sceneAxis = SCNVector3(0, 1, 0)        // yaw → SceneKit Y
            }
            let isLeft = !j.rawValue.isOnRightHalf
            let sign: CGFloat = (isLeft && j.mirrorSignFlip) ? -1 : 1
            node.rotation = SCNVector4(sceneAxis.x, sceneAxis.y, sceneAxis.z,
                                       CGFloat(rad) * sign)
        }
    }

    func highlight(_ joint: JointID?) {
        for (_, meshes) in highlightMeshes {
            for m in meshes {
                let key = ObjectIdentifier(m)
                m.geometry?.firstMaterial?.emission.contents =
                    originalEmissions[key] ?? NSColor.black
            }
        }
        guard let j = joint, let meshes = highlightMeshes[j] else { return }
        for m in meshes {
            m.geometry?.firstMaterial?.emission.contents =
                NSColor.systemOrange.withAlphaComponent(0.55)
        }
    }

    // MARK: - Build

    private func buildBody() {
        // ── 골반: 검은 라운드 박스 (모터 어셈블리)
        let pelvis = makeBox(w: 0.090, h: 0.038, d: 0.062,
                             color: Self.motorBlack, chamfer: 0.008)
        pelvis.position = SCNVector3(0, 0, 0)
        root.addChildNode(pelvis)

        // 골반 위 흰색 마운트 (척추 베이스)
        let spineMount = makeBox(w: 0.072, h: 0.022, d: 0.052,
                                  color: Self.bodyShell, chamfer: 0.005)
        spineMount.position = SCNVector3(0, 0.030, 0)
        root.addChildNode(spineMount)

        // ── 가슴 어셈블리
        let chestRoot = SCNNode()
        chestRoot.position = SCNVector3(0, Self.chestH / 2 + 0.045, 0)
        root.addChildNode(chestRoot)

        // 검은 inner spine (가슴판 뒤)
        let innerSpine = makeBox(w: Self.chestW * 0.62,
                                  h: Self.chestH * 0.92,
                                  d: Self.chestD * 0.86,
                                  color: Self.detailDark, chamfer: 0.004)
        chestRoot.addChildNode(innerSpine)

        // 흰 가슴판 (앞면)
        let chestPlate = makeBox(w: Self.chestW,
                                  h: Self.chestH * 0.86,
                                  d: 0.020,
                                  color: Self.bodyShell, chamfer: 0.012)
        chestPlate.position = SCNVector3(0, -0.005, Self.chestD / 2 + 0.001)
        chestRoot.addChildNode(chestPlate)

        // 가슴 가운데 흰 layered 패널 (V-line 대신 매끈한 디테일)
        let centerPanel = makeBox(w: Self.chestW * 0.46,
                                   h: Self.chestH * 0.50,
                                   d: 0.006,
                                   color: Self.bodyShellHi, chamfer: 0.006)
        centerPanel.position = SCNVector3(0, 0.005, Self.chestD / 2 + 0.011)
        chestRoot.addChildNode(centerPanel)

        // 작은 다윈 로고 (빨강 LED)
        let logo = SCNSphere(radius: 0.0055)
        let logoMat = SCNMaterial()
        logoMat.diffuse.contents = Self.darwinRed
        logoMat.emission.contents = Self.darwinRed
        logoMat.lightingModel = .constant
        logo.firstMaterial = logoMat
        let logoNode = SCNNode(geometry: logo)
        logoNode.position = SCNVector3(0, -0.020, Self.chestD / 2 + 0.013)
        chestRoot.addChildNode(logoNode)

        // 가슴 측면 어깨 마운트 — 더 라운드한 회색 캡슐 형태.
        let shoulderMountR = makeBox(w: 0.038, h: 0.066, d: Self.chestD * 0.86,
                                      color: Self.bodyShellHi, chamfer: 0.018)
        shoulderMountR.position = SCNVector3(Self.chestW / 2 + 0.016,
                                              Self.chestH / 2 - 0.038, 0)
        chestRoot.addChildNode(shoulderMountR)

        let shoulderMountL = makeBox(w: 0.038, h: 0.066, d: Self.chestD * 0.86,
                                      color: Self.bodyShellHi, chamfer: 0.018)
        shoulderMountL.position = SCNVector3(-(Self.chestW / 2 + 0.016),
                                              Self.chestH / 2 - 0.038, 0)
        chestRoot.addChildNode(shoulderMountL)

        // 등판 (뒤 박스)
        let backPanel = makeBox(w: Self.chestW * 0.96,
                                 h: Self.chestH * 0.82,
                                 d: 0.018,
                                 color: Self.bodyShell, chamfer: 0.010)
        backPanel.position = SCNVector3(0, -0.005, -Self.chestD / 2 - 0.001)
        chestRoot.addChildNode(backPanel)

        // ── 머리 (목 → headPan → headTilt → 헬멧)
        let neckBase = SCNNode()
        neckBase.position = SCNVector3(0, Self.chestH / 2 + 0.002, -0.005)
        chestRoot.addChildNode(neckBase)

        // 짧고 두꺼운 목.
        let neckCyl = SCNCylinder(radius: 0.016, height: 0.014)
        neckCyl.firstMaterial = darkMat()
        let neckCylNode = SCNNode(geometry: neckCyl)
        neckCylNode.position = SCNVector3(0, 0.007, 0)
        neckBase.addChildNode(neckCylNode)

        let headPanNode = SCNNode()
        headPanNode.position = SCNVector3(0, 0.014, 0)
        neckBase.addChildNode(headPanNode)
        joints[.headPan] = headPanNode

        let headTiltNode = SCNNode()
        headTiltNode.position = SCNVector3(0, 0.005, 0)
        headPanNode.addChildNode(headTiltNode)
        joints[.headTilt] = headTiltNode

        buildHelmet(into: headTiltNode)

        // ── 어깨/팔
        buildArm(side: .right, attach: chestRoot,
                 anchor: SCNVector3( Self.chestW / 2 + 0.030,
                                     Self.chestH / 2 - 0.038, 0))
        buildArm(side: .left, attach: chestRoot,
                 anchor: SCNVector3(-(Self.chestW / 2 + 0.030),
                                      Self.chestH / 2 - 0.038, 0))

        // ── 다리
        buildLeg(side: .right, attach: pelvis,
                 anchor: SCNVector3( Self.hipOffX, Self.hipOffY, 0))
        buildLeg(side: .left, attach: pelvis,
                 anchor: SCNVector3(-Self.hipOffX, Self.hipOffY, 0))
    }

    // MARK: - Head (헬멧 + 큰 보라 눈 + 정수리 LED)

    private func buildHelmet(into parent: SCNNode) {
        // 메인 헬멧 — chamfer 큰 박스. 머리 중심을 (0, helmetH/2, 0)으로.
        let helmet = makeBox(w: Self.helmetW,
                              h: Self.helmetH,
                              d: Self.helmetD,
                              color: Self.helmetDark,
                              chamfer: 0.022)
        helmet.position = SCNVector3(0, Self.helmetH / 2, 0)
        parent.addChildNode(helmet)
        registerHighlight(.headPan, [helmet])
        registerHighlight(.headTilt, [helmet])

        // 정수리 흰 panel (cap) — 헬멧 윗면에 딱 붙임.
        let capH: CGFloat = 0.012
        let cap = makeBox(w: Self.helmetW * 0.62, h: capH, d: Self.helmetD * 0.66,
                          color: Self.bodyShell, chamfer: 0.006)
        cap.position = SCNVector3(0, Self.helmetH + capH / 2 - 0.002, 0)
        parent.addChildNode(cap)

        // 정수리 녹색 LED
        let ledGeom = SCNSphere(radius: 0.0048)
        let ledMat = SCNMaterial()
        ledMat.diffuse.contents = Self.ledGreen
        ledMat.emission.contents = Self.ledGreen
        ledMat.lightingModel = .constant
        ledGeom.firstMaterial = ledMat
        let ledNode = SCNNode(geometry: ledGeom)
        ledNode.position = SCNVector3(0, Self.helmetH + capH + 0.001, 0.014)
        parent.addChildNode(ledNode)

        // 헬멧 측면 흰 ridge (귀 부분)
        let ridgeL = makeBox(w: 0.005, h: 0.034, d: 0.046,
                              color: Self.bodyShell, chamfer: 0.002)
        ridgeL.position = SCNVector3(-Self.helmetW / 2 - 0.001, Self.helmetH * 0.55, 0)
        parent.addChildNode(ridgeL)
        let ridgeR = makeBox(w: 0.005, h: 0.034, d: 0.046,
                              color: Self.bodyShell, chamfer: 0.002)
        ridgeR.position = SCNVector3(Self.helmetW / 2 + 0.001, Self.helmetH * 0.55, 0)
        parent.addChildNode(ridgeR)

        // 큰 보라 LED 눈 (헬멧 정면).
        let eyeY = Self.helmetH * 0.52
        addEye(into: parent, x: -0.020, y: eyeY, z: Self.helmetD / 2 + 0.003)
        addEye(into: parent, x:  0.020, y: eyeY, z: Self.helmetD / 2 + 0.003)

        // 이마 카메라 (눈 사이 위)
        let cam = SCNCylinder(radius: 0.005, height: 0.005)
        let camMat = SCNMaterial()
        camMat.diffuse.contents = Self.eyePupil
        camMat.specular.contents = NSColor.white.withAlphaComponent(0.7)
        camMat.shininess = 80
        cam.firstMaterial = camMat
        let camNode = SCNNode(geometry: cam)
        camNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        camNode.position = SCNVector3(0, eyeY + 0.024, Self.helmetD / 2 + 0.005)
        parent.addChildNode(camNode)

        // 입 — 가로 검은 grill
        let mouth = makeBox(w: 0.022, h: 0.004, d: 0.002,
                             color: Self.eyePupil, chamfer: 0.001)
        mouth.position = SCNVector3(0, eyeY - 0.024, Self.helmetD / 2 + 0.004)
        parent.addChildNode(mouth)

        // 턱 (헬멧 아래쪽 검은 라인 - 더 매끈)
        let chin = makeBox(w: Self.helmetW * 0.72, h: 0.008, d: Self.helmetD * 0.84,
                            color: Self.detailDark, chamfer: 0.003)
        chin.position = SCNVector3(0, 0.004, 0)
        parent.addChildNode(chin)
    }

    private func addEye(into parent: SCNNode, x: CGFloat, y: CGFloat, z: CGFloat) {
        // 외부 보라 LED 디스크 (앞으로 살짝 튀어나옴)
        let outer = SCNCylinder(radius: Self.eyeRadius, height: 0.005)
        let outerMat = SCNMaterial()
        outerMat.diffuse.contents = Self.eyePurple
        outerMat.emission.contents = Self.eyePurple.withAlphaComponent(0.85)
        outerMat.specular.contents = NSColor.white.withAlphaComponent(0.5)
        outerMat.shininess = 30
        outerMat.lightingModel = .blinn
        outer.firstMaterial = outerMat
        let outerNode = SCNNode(geometry: outer)
        outerNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        outerNode.position = SCNVector3(x, y, z)
        parent.addChildNode(outerNode)

        // 검은 동공 (가운데)
        let pupil = SCNSphere(radius: 0.005)
        let pupilMat = SCNMaterial()
        pupilMat.diffuse.contents = Self.eyePupil
        pupilMat.specular.contents = NSColor.white.withAlphaComponent(0.9)
        pupilMat.shininess = 90
        pupil.firstMaterial = pupilMat
        let pupilNode = SCNNode(geometry: pupil)
        pupilNode.position = SCNVector3(x, y, z + 0.0035)
        parent.addChildNode(pupilNode)
    }

    // MARK: - Arm

    private enum Side { case right, left
        var sign: CGFloat { self == .right ? 1 : -1 }
    }

    private func buildArm(side: Side, attach: SCNNode, anchor: SCNVector3) {
        // shoulder pitch (앞뒤 회전) — 큰 둥근 모터
        let pitchAnchor = SCNNode()
        pitchAnchor.position = anchor
        attach.addChildNode(pitchAnchor)
        let pitchKey: JointID = (side == .right) ? .rShoulderPitch : .lShoulderPitch
        joints[pitchKey] = pitchAnchor

        let pitchMotor = makeMotor(.large, axis: .x)
        pitchAnchor.addChildNode(pitchMotor)
        registerHighlight(pitchKey, motorMeshes(in: pitchMotor))

        // shoulder roll (옆벌리기) — 직각 결합 모터
        let rollAnchor = SCNNode()
        rollAnchor.position = SCNVector3(side.sign * 0.026, -0.008, 0)
        pitchAnchor.addChildNode(rollAnchor)
        let rollKey: JointID = (side == .right) ? .rShoulderRoll : .lShoulderRoll
        joints[rollKey] = rollAnchor

        let rollMotor = makeMotor(.medium, axis: .y)
        rollAnchor.addChildNode(rollMotor)
        registerHighlight(rollKey, motorMeshes(in: rollMotor))

        // 위팔 (라운드 박스)
        let upper = makeBox(w: Self.upperArmDia,
                             h: Self.upperArmLen,
                             d: Self.upperArmDia * 0.90,
                             color: Self.bodyShell, chamfer: Self.upperArmDia * 0.18)
        upper.position = SCNVector3(0, -Self.upperArmLen / 2 - 0.024, 0)
        rollAnchor.addChildNode(upper)
        registerHighlight(rollKey, [upper])
        registerHighlight(pitchKey, [upper])

        // 팔꿈치 모터
        let elbowAnchor = SCNNode()
        elbowAnchor.position = SCNVector3(0, -Self.upperArmLen - 0.026, 0)
        rollAnchor.addChildNode(elbowAnchor)
        let elbowKey: JointID = (side == .right) ? .rElbow : .lElbow
        joints[elbowKey] = elbowAnchor

        let elbowMotor = makeMotor(.medium, axis: .x)
        elbowAnchor.addChildNode(elbowMotor)
        registerHighlight(elbowKey, motorMeshes(in: elbowMotor))

        // 아래팔 (라운드 박스, 어두운 회색)
        let fore = makeBox(w: Self.forearmDia,
                            h: Self.forearmLen,
                            d: Self.forearmDia * 0.90,
                            color: Self.detailDark, chamfer: Self.forearmDia * 0.20)
        fore.position = SCNVector3(0, -Self.forearmLen / 2 - 0.024, 0)
        elbowAnchor.addChildNode(fore)
        registerHighlight(elbowKey, [fore])

        // 그리퍼 (손 — 두 핑거 모양 박스)
        let palm = makeBox(w: 0.026, h: 0.024, d: 0.020,
                            color: Self.bodyShell, chamfer: 0.004)
        palm.position = SCNVector3(0, -Self.forearmLen - 0.030, 0)
        elbowAnchor.addChildNode(palm)

        let fingerL = makeBox(w: 0.008, h: 0.026, d: 0.010,
                               color: Self.helmetDark, chamfer: 0.002)
        fingerL.position = SCNVector3(-0.008, -Self.forearmLen - 0.052, 0.005)
        elbowAnchor.addChildNode(fingerL)
        let fingerR = makeBox(w: 0.008, h: 0.026, d: 0.010,
                               color: Self.helmetDark, chamfer: 0.002)
        fingerR.position = SCNVector3(0.008, -Self.forearmLen - 0.052, 0.005)
        elbowAnchor.addChildNode(fingerR)
    }

    // MARK: - Leg

    private func buildLeg(side: Side, attach: SCNNode, anchor: SCNVector3) {
        // hip yaw (Y축)
        let yawAnchor = SCNNode()
        yawAnchor.position = anchor
        attach.addChildNode(yawAnchor)
        let yawKey: JointID = (side == .right) ? .rHipYaw : .lHipYaw
        joints[yawKey] = yawAnchor

        let yawMotor = makeMotor(.medium, axis: .y)
        yawAnchor.addChildNode(yawMotor)
        registerHighlight(yawKey, motorMeshes(in: yawMotor))

        // hip roll
        let rollAnchor = SCNNode()
        rollAnchor.position = SCNVector3(0, -0.020, 0)
        yawAnchor.addChildNode(rollAnchor)
        let rollKey: JointID = (side == .right) ? .rHipRoll : .lHipRoll
        joints[rollKey] = rollAnchor

        let rollMotor = makeMotor(.medium, axis: .z)
        rollAnchor.addChildNode(rollMotor)
        registerHighlight(rollKey, motorMeshes(in: rollMotor))

        // hip pitch
        let pitchAnchor = SCNNode()
        pitchAnchor.position = SCNVector3(side.sign * 0.013, -0.015, 0)
        rollAnchor.addChildNode(pitchAnchor)
        let pitchKey: JointID = (side == .right) ? .rHipPitch : .lHipPitch
        joints[pitchKey] = pitchAnchor

        let pitchMotor = makeMotor(.large, axis: .x)
        pitchAnchor.addChildNode(pitchMotor)
        registerHighlight(pitchKey, motorMeshes(in: pitchMotor))

        // 허벅지 (라운드 박스, 흰)
        let thigh = makeBox(w: Self.thighDia,
                             h: Self.thighLen,
                             d: Self.thighDia * 0.92,
                             color: Self.bodyShell, chamfer: Self.thighDia * 0.18)
        thigh.position = SCNVector3(0, -Self.thighLen / 2 - 0.028, 0)
        pitchAnchor.addChildNode(thigh)
        registerHighlight(yawKey, [thigh])
        registerHighlight(rollKey, [thigh])
        registerHighlight(pitchKey, [thigh])

        // 허벅지 측면 검은 ridge (디테일)
        let thighRidge = makeBox(w: Self.thighDia * 0.30,
                                  h: Self.thighLen * 0.84,
                                  d: 0.004,
                                  color: Self.detailDark, chamfer: 0.001)
        thighRidge.position = SCNVector3(0, -Self.thighLen / 2 - 0.028,
                                          Self.thighDia * 0.48)
        pitchAnchor.addChildNode(thighRidge)

        // 무릎
        let kneeAnchor = SCNNode()
        kneeAnchor.position = SCNVector3(0, -Self.thighLen - 0.028, 0)
        pitchAnchor.addChildNode(kneeAnchor)
        let kneeKey: JointID = (side == .right) ? .rKnee : .lKnee
        joints[kneeKey] = kneeAnchor

        let kneeMotor = makeMotor(.large, axis: .x)
        kneeAnchor.addChildNode(kneeMotor)
        registerHighlight(kneeKey, motorMeshes(in: kneeMotor))

        // 정강이 (라운드 박스, 흰)
        let shin = makeBox(w: Self.shinDia,
                            h: Self.shinLen,
                            d: Self.shinDia * 0.92,
                            color: Self.bodyShell, chamfer: Self.shinDia * 0.18)
        shin.position = SCNVector3(0, -Self.shinLen / 2 - 0.026, 0)
        kneeAnchor.addChildNode(shin)
        registerHighlight(kneeKey, [shin])

        // 정강이 앞쪽 검은 ridge
        let shinRidge = makeBox(w: Self.shinDia * 0.34,
                                 h: Self.shinLen * 0.82,
                                 d: 0.004,
                                 color: Self.detailDark, chamfer: 0.001)
        shinRidge.position = SCNVector3(0, -Self.shinLen / 2 - 0.026,
                                         Self.shinDia * 0.48)
        kneeAnchor.addChildNode(shinRidge)

        // 발목 결합부 (회색 라운드 box)
        let ankle = makeBox(w: 0.058, h: 0.034, d: 0.064,
                             color: Self.detailDark, chamfer: 0.008)
        ankle.position = SCNVector3(0, -Self.shinLen - 0.046, 0.006)
        kneeAnchor.addChildNode(ankle)

        // 신발 (검은 부츠)
        let foot = makeBox(w: Self.footW, h: Self.footH, d: Self.footD,
                            color: Self.footBlack, chamfer: Self.footChamfer)
        foot.position = SCNVector3(0, -Self.shinLen - 0.072, 0.022)
        kneeAnchor.addChildNode(foot)

        // 신발 흰 밑창
        let sole = makeBox(w: Self.footW + 0.002,
                            h: 0.006,
                            d: Self.footD + 0.002,
                            color: Self.solWhite, chamfer: 0.003)
        sole.position = SCNVector3(0, -Self.shinLen - 0.090, 0.022)
        kneeAnchor.addChildNode(sole)

        // 신발 앞쪽 흰 ridge (장식)
        let toeRidge = makeBox(w: Self.footW * 0.62, h: 0.007, d: 0.016,
                                color: Self.solWhite, chamfer: 0.002)
        toeRidge.position = SCNVector3(0, -Self.shinLen - 0.082,
                                        0.022 + Self.footD / 2 - 0.014)
        kneeAnchor.addChildNode(toeRidge)
    }

    // MARK: - Building blocks

    /// MX-28T 모터 모형: 둥근 검은 박스 + 양쪽 흰 디스크.
    /// `axis`는 회전축 방향을 나타내며, 캡 두 개가 그 축 양 끝에 자리한다.
    private enum MotorSize { case small, medium, large }
    private enum MotorAxis { case x, y, z }

    private func makeMotor(_ size: MotorSize, axis: MotorAxis) -> SCNNode {
        let group = SCNNode()
        let dims: (w: CGFloat, h: CGFloat, d: CGFloat, capR: CGFloat, capH: CGFloat)
        switch size {
        case .small:  dims = (0.022, 0.030, 0.022, 0.010, 0.0025)
        case .medium: dims = (0.030, 0.040, 0.030, 0.013, 0.0030)
        case .large:  dims = (0.034, 0.046, 0.034, 0.015, 0.0035)
        }

        // 본체: chamfer 큰 검은 박스
        let body = makeBox(w: dims.w, h: dims.h, d: dims.d,
                            color: Self.motorBlack, chamfer: 0.005)
        group.addChildNode(body)

        // 두 캡 (양쪽). axis에 따라 위치 + 회전.
        let cap1 = makeMotorCap(radius: dims.capR, height: dims.capH)
        let cap2 = makeMotorCap(radius: dims.capR, height: dims.capH)
        switch axis {
        case .x:
            cap1.position = SCNVector3(-dims.w / 2 - dims.capH / 2, 0, 0)
            cap1.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
            cap2.position = SCNVector3(dims.w / 2 + dims.capH / 2, 0, 0)
            cap2.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
        case .y:
            cap1.position = SCNVector3(0, -dims.h / 2 - dims.capH / 2, 0)
            cap2.position = SCNVector3(0, dims.h / 2 + dims.capH / 2, 0)
        case .z:
            cap1.position = SCNVector3(0, 0, -dims.d / 2 - dims.capH / 2)
            cap1.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
            cap2.position = SCNVector3(0, 0, dims.d / 2 + dims.capH / 2)
            cap2.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        }
        group.addChildNode(cap1)
        group.addChildNode(cap2)
        return group
    }

    private func makeMotorCap(radius: CGFloat, height: CGFloat) -> SCNNode {
        let outer = SCNCylinder(radius: radius, height: height)
        outer.firstMaterial = lightCapMat()
        let outerNode = SCNNode(geometry: outer)

        // 가운데 작은 검은 축 표시
        let axle = SCNCylinder(radius: radius * 0.35, height: height + 0.001)
        let aMat = SCNMaterial()
        aMat.diffuse.contents = Self.detailDark
        aMat.specular.contents = NSColor.white.withAlphaComponent(0.4)
        aMat.shininess = 30
        axle.firstMaterial = aMat
        let axleNode = SCNNode(geometry: axle)
        outerNode.addChildNode(axleNode)
        return outerNode
    }

    private func motorMeshes(in motorGroup: SCNNode) -> [SCNNode] {
        // body + 두 캡(외부 cylinder만 — axle은 항상 같은 색).
        var out: [SCNNode] = []
        for child in motorGroup.childNodes {
            out.append(child)
        }
        return out
    }

    /// 캡슐 본 — 위/아래가 라운드된 길쭉한 형태.
    private func makeCapsule(diameter: CGFloat, height: CGFloat, color: NSColor) -> SCNNode {
        let cap = SCNCapsule(capRadius: diameter / 2, height: height)
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.specular.contents = NSColor.white.withAlphaComponent(0.20)
        m.shininess = 18
        m.lightingModel = .blinn
        cap.firstMaterial = m
        return SCNNode(geometry: cap)
    }

    private func makeBox(w: CGFloat, h: CGFloat, d: CGFloat,
                         color: NSColor, chamfer: CGFloat) -> SCNNode {
        let box = SCNBox(width: w, height: h, length: d, chamferRadius: chamfer)
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.specular.contents = NSColor.white.withAlphaComponent(0.22)
        m.shininess = 16
        m.lightingModel = .blinn
        box.firstMaterial = m
        return SCNNode(geometry: box)
    }

    private func darkMat() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = Self.detailDark
        m.specular.contents = NSColor.white.withAlphaComponent(0.22)
        m.shininess = 16
        return m
    }

    private func lightCapMat() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = Self.motorCap
        m.specular.contents = NSColor.white.withAlphaComponent(0.35)
        m.shininess = 22
        m.lightingModel = .blinn
        return m
    }

    private func registerHighlight(_ joint: JointID, _ meshes: [SCNNode]) {
        var existing = highlightMeshes[joint] ?? []
        existing.append(contentsOf: meshes)
        highlightMeshes[joint] = existing
        for m in meshes {
            let key = ObjectIdentifier(m)
            if originalEmissions[key] == nil {
                let cur = m.geometry?.firstMaterial?.emission.contents as? NSColor
                originalEmissions[key] = cur ?? NSColor.black
            }
        }
    }
}

// MARK: - JointID side helper

private extension UInt8 {
    var isOnRightHalf: Bool {
        switch self {
        case 1, 3, 5, 11, 13, 15, 17, 19, 20: return true
        default: return false
        }
    }
}
