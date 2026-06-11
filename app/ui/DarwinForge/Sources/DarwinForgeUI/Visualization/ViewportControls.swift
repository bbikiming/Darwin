import SwiftUI

/// 3D viewport 의 카메라 제어 UI — Studio / TeachMode / WalkLab / MotionStudio 모두 공통.
///
/// 구성:
///   - 우측 상단: ViewCube + [🏠 기본 시점]
///   - (옵션) 좌측 상단: 미니 도움말
///   - 모든 메뉴에서 동일 위치 / 동일 디자인 → 사용자 일관성.
public struct ViewportControls: View {
    @ObservedObject public var camera: CameraController

    public init(camera: CameraController) {
        self.camera = camera
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: DFSpace.xs2) {
            ViewCubeWidget(controller: camera)
                .frame(width: 96, height: 96)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: 0.5)
                )

            Button {
                camera.reset()
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "house.fill")
                    Text("기본 시점")
                }
                .font(DFFont.caption.bold())
                .foregroundStyle(DFColor.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("기본 시점으로 즉시 복귀")

            // 조명·머티리얼 튜닝 — 공유 컴포넌트(버튼 + 패널).
            SceneTuningControl()
        }
        .padding(DFSpace.md)
    }
}
