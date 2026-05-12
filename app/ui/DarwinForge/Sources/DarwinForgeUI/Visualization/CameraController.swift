import AppKit
import SceneKit
import SwiftUI

/// SwiftUI 측에서 `InteractiveSceneView`의 카메라를 조작하는 브리지.
///
/// 사용 패턴:
/// ```swift
/// @StateObject var camera = CameraController()
/// RobotScene3D(controller: camera, ...)
/// Button("앞") { camera.goToFace(.front) }
/// ```
@MainActor
public final class CameraController: ObservableObject {
    /// `RobotScene3D.makeNSView`가 생성한 view를 여기에 등록.
    public weak var view: InteractiveSceneView?

    public init() {}

    public func goToFace(_ face: CameraFace) {
        view?.goToFace(face)
    }

    public func reset() {
        view?.resetCamera()
    }
}

// MARK: - ViewCubeOverlay

/// 3D 툴 표준 ViewCube 위젯 — 6 face 프리셋 + 기본 view + (시각적) cube hint.
///
/// - 우상단 작은 카드.
/// - 7개 버튼 (앞 / 뒤 / 좌 / 우 / 위 / 아래 / 기본).
/// - 클릭 시 `controller.goToFace(...)` → InteractiveSceneView smoothing이 부드럽게 전환.
///
/// 진짜 회전 cube SCN 위젯은 phase 2 — 첫 단계는 명시적 face 버튼 + 큐브 아이콘.
public struct ViewCubeOverlay: View {
    @ObservedObject public var controller: CameraController

    public init(controller: CameraController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: DFSpace.xs) {
            // 큐브 hint — 클릭하면 기본 view (3D 툴의 ViewCube home 동작과 일치).
            Button {
                controller.goToFace(.isometric)
            } label: {
                ZStack {
                    Image(systemName: "cube.fill")
                        .font(.system(size: DFFontSize.s22, weight: .regular))
                        .foregroundStyle(DFColor.accent)
                    Image(systemName: "house.fill")
                        .font(.system(size: DFFontSize.s9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(DFColor.forge))
                        .offset(x: 12, y: 12)
                }
                .padding(8)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("기본 시점으로 돌아가기")

            // Cross layout: top, mid (left center right), bottom
            VStack(spacing: DFSpace.micro2) {
                faceButton(.top)
                HStack(spacing: DFSpace.micro2) {
                    faceButton(.left)
                    faceButton(.front)
                    faceButton(.right)
                    faceButton(.back)
                }
                faceButton(.bottom)
            }
            .padding(6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DFColor.textSecondary.opacity(DFOpacity.o18), lineWidth: 0.5)
            )
        }
    }

    private func faceButton(_ face: CameraFace) -> some View {
        Button {
            controller.goToFace(face)
        } label: {
            VStack(spacing: DFSpace.micro) {
                Image(systemName: face.icon)
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
                Text(face.label)
                    .font(.system(size: DFFontSize.s9, weight: .medium))
            }
            .foregroundStyle(DFColor.textPrimary)
            .frame(width: 38, height: 32)
            .background(DFColor.card)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(face.label) 시점으로 이동")
    }
}
