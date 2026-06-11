import ForgeCore
import Metal
import SceneKit
import SwiftUI

/// SceneKit 기반 16-DOF 휴머노이드 실시간 뷰어 — ROBOTIS-OP2 비주얼 모사.
///
/// Webots `robotis-op2` proto의 mesh를 직접 import하지 않고 SceneKit primitives
/// (SCNBox/SCNSphere/SCNCylinder/SCNCapsule)로 외형을 재현. 모든 관절에는 회전
/// 노드 + MX-28T 모터 그룹 + 본 메시가 묶여 있다.
///
/// **W0 (2026-06-11)**: scene 그래프 소유 로직은 `RobotSceneCoordinator`,
/// 무대(조명/바닥/그리드/축)는 `SceneStage`, 프리미티브 rig 은 `DarwinOP2Rig.swift`
/// 로 분리. 본 파일은 NSViewRepresentable 결선 + 헤드리스 렌더 extension 만 보유.
public struct RobotScene3D: NSViewRepresentable {
    /// **W0**: 종전 중첩 `Coordinator` 클래스를 `RobotSceneCoordinator` 로 승격.
    /// 소스 호환을 위한 typealias — `RobotScene3D.Coordinator` 참조 보존.
    public typealias Coordinator = RobotSceneCoordinator

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
        // **v1.14.8 (2026-05-21) perf #4**: 60fps → 30fps.
        // 종전: 60fps continuous render. WalkLab 진입 시 SCNView 가 main thread
        //       에서 60Hz 로 frame 합성 → main actor saturation 의 절반 차지.
        // 신규: 30fps. 워크/포즈 변화가 빠르지 않아 인지적 차이 거의 없음.
        //       updateNSView 도 SwiftUI body 갱신 (10Hz tick) 따라 호출됨.
        view.preferredFramesPerSecond = 30
        view.pointOfView = context.coordinator.cameraNode
        view.applyCamera()                         // orbit state → 카메라 적용
        context.coordinator.applyPose(pose)
        context.coordinator.applyFootTrace(footTrace)
        context.coordinator.applyHighlight(highlight)
        context.coordinator.applyAxesVisible(showAxes)
        context.coordinator.applyImuTilt(rollDeg: imuRollDeg, pitchDeg: imuPitchDeg)
        context.coordinator.applyTuning()
        // ViewCube/Home 버튼이 카메라를 조작할 수 있도록 controller에 view 등록.
        if let controller = cameraController {
            Task { @MainActor in controller.view = view }
        }
        // P0-F: makeNSView 한 번 호출 시 fallback 여부를 호출자에게 통지.
        if let cb = onMeshFallback {
            let active = context.coordinator.usingMeshFallback
            Task { @MainActor in cb(active) }
        }
        return view
    }

    public func updateNSView(_ nsView: InteractiveSceneView, context: Context) {
        context.coordinator.applyPose(pose)
        context.coordinator.applyFootTrace(footTrace)
        context.coordinator.applyHighlight(highlight)
        context.coordinator.applyAxesVisible(showAxes)
        context.coordinator.applyImuTilt(rollDeg: imuRollDeg, pitchDeg: imuPitchDeg)
        context.coordinator.applyTuning()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
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
