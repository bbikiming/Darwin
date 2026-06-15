import ForgeCore
import SwiftUI

/// Studio / Teach / WalkLab / Motion / Pilot 의 공통 3D viewport.
///
/// 일관된 UX:
/// - 같은 RobotScene3D + ViewportControls (상단우측) 배치
/// - 같은 배경 gradient (canvas dim → canvas)
/// - 상단/하단 overlay slot — 각 메뉴별 page-specific badge / banner 추가용
///
/// 사용:
/// ```swift
/// Robot3DViewport(
///     pose: pose,
///     camera: camera,
///     highlight: selectedJoint
/// ) {
///     myPageMetaBadge   // 상단 좌측 overlay
/// } bottomLeading: {
///     myBanner          // 하단 좌측 overlay (optional)
/// }
/// ```
public struct Robot3DViewport<TopLeading: View, BottomLeading: View>: View {
    public let pose: RobotPose
    public let footTrace: [SIMD3<Double>]
    public let highlight: JointID?
    public let showAxes: Bool
    @ObservedObject public var camera: CameraController
    public let onMeshFallback: ((Bool) -> Void)?
    /// **W2**: 화면별 3D 환경 프리셋. 기본 `.studio`.
    public let preset: ScenePreset
    public let topLeading: () -> TopLeading
    public let bottomLeading: () -> BottomLeading

    public init(
        pose: RobotPose,
        footTrace: [SIMD3<Double>] = [],
        highlight: JointID? = nil,
        showAxes: Bool = true,
        camera: CameraController,
        onMeshFallback: ((Bool) -> Void)? = nil,
        preset: ScenePreset = .studio,
        @ViewBuilder topLeading: @escaping () -> TopLeading = { EmptyView() },
        @ViewBuilder bottomLeading: @escaping () -> BottomLeading = { EmptyView() }
    ) {
        self.pose = pose
        self.footTrace = footTrace
        self.highlight = highlight
        self.showAxes = showAxes
        self.camera = camera
        self.onMeshFallback = onMeshFallback
        self.preset = preset
        self.topLeading = topLeading
        self.bottomLeading = bottomLeading
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. 3D scene + 일관 배경.
            RobotScene3D(
                pose: pose,
                footTrace: footTrace,
                highlight: highlight,
                showAxes: showAxes,
                onMeshFallback: onMeshFallback,
                cameraController: camera,
                preset: preset
            )
            // v1.11.15 cycle 2 (2026-05-19): 3D 뷰포트는 항상 어두운 배경.
            // 회색 mesh 모델 시인성 + Apple Reality Composer / Xcode SceneKit Editor
            // 표준 패턴. 흰색 플랫 / 라이트 / 다크 모드 모두 동일 어두운 톤 유지.
            .background(
                LinearGradient(
                    colors: [DFColor.scene3DTop, DFColor.scene3DBottom],
                    startPoint: .top, endPoint: .bottom
                )
            )
            // 무채색 GUI 안에서도 어두운 톤이 흐려지지 않도록 saturation 보존.
            .dfChartAccent()

            // 2. 상단 좌측 — 페이지별 meta badge slot.
            topLeading()
                .padding(DFSpace.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // 3. 상단 우측 — 표준 viewport 컨트롤 (모든 메뉴 동일).
            ViewportControls(camera: camera)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // 4. 하단 좌측 — 페이지별 banner slot (mesh fallback, balance warning 등).
            bottomLeading()
                .padding(DFSpace.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

// MARK: - TopLeading default 편의 — 빈 view 만 필요할 때.
public extension Robot3DViewport where TopLeading == EmptyView, BottomLeading == EmptyView {
    init(
        pose: RobotPose,
        footTrace: [SIMD3<Double>] = [],
        highlight: JointID? = nil,
        showAxes: Bool = true,
        camera: CameraController,
        onMeshFallback: ((Bool) -> Void)? = nil,
        preset: ScenePreset = .studio
    ) {
        self.init(
            pose: pose, footTrace: footTrace, highlight: highlight,
            showAxes: showAxes, camera: camera, onMeshFallback: onMeshFallback,
            preset: preset,
            topLeading: { EmptyView() },
            bottomLeading: { EmptyView() }
        )
    }
}

public extension Robot3DViewport where BottomLeading == EmptyView {
    init(
        pose: RobotPose,
        footTrace: [SIMD3<Double>] = [],
        highlight: JointID? = nil,
        showAxes: Bool = true,
        camera: CameraController,
        onMeshFallback: ((Bool) -> Void)? = nil,
        preset: ScenePreset = .studio,
        @ViewBuilder topLeading: @escaping () -> TopLeading
    ) {
        self.init(
            pose: pose, footTrace: footTrace, highlight: highlight,
            showAxes: showAxes, camera: camera, onMeshFallback: onMeshFallback,
            preset: preset,
            topLeading: topLeading,
            bottomLeading: { EmptyView() }
        )
    }
}
