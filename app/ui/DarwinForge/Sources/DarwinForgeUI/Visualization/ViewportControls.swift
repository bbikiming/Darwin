import SwiftUI

/// 3D viewport 의 카메라 제어 UI — Studio / TeachMode / WalkLab / MotionStudio 모두 공통.
///
/// 구성:
///   - 우측 상단: ViewCube + [🏠 기본 시점]
///   - (옵션) 좌측 상단: 미니 도움말
///   - 모든 메뉴에서 동일 위치 / 동일 디자인 → 사용자 일관성.
public struct ViewportControls: View {
    @ObservedObject public var camera: CameraController
    /// **W4 (2026-06-12)**: DOF 시네마틱 토글 노출 여부. Studio/Motion 만 `true`.
    public let showCinematic: Bool
    /// **W3**: 비-nil 이면 로봇공학 오버레이 토글 팝오버를 노출. nil 이면 종전과 동일.
    public let overlayStore: OverlayToggleStore?

    public init(camera: CameraController,
                showCinematic: Bool = false,
                overlayStore: OverlayToggleStore? = nil) {
        self.camera = camera
        self.showCinematic = showCinematic
        self.overlayStore = overlayStore
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

            // **W4** 턴테이블 토글 — 모든 화면 공통. 기본 off(idle CPU 계약).
            toggleChip(icon: "arrow.triangle.2.circlepath",
                       label: "턴테이블",
                       isOn: camera.turntableEnabled,
                       help: "모델을 천천히 자동 회전 (켜진 동안만 연속 렌더)") {
                camera.turntableEnabled.toggle()
            }

            // **W4** 시네마틱(DOF) 토글 — Studio/Motion 만. 스냅샷 렌더러엔 미적용.
            if showCinematic {
                toggleChip(icon: "camera.aperture",
                           label: "시네마틱",
                           isOn: camera.cinematicEnabled,
                           help: "피사계 심도(DOF) — 초점 밖이 부드럽게 흐려짐") {
                    camera.cinematicEnabled.toggle()
                }
            }

            // 조명·머티리얼 튜닝 — 공유 컴포넌트(버튼 + 패널).
            SceneTuningControl()

            // **W3**: 로봇공학 오버레이 토글(주입된 화면만).
            if let store = overlayStore {
                OverlayToggleControl(store: store)
            }
        }
        .padding(DFSpace.md)
    }

    private func toggleChip(icon: String, label: String, isOn: Bool,
                            help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: icon)
                Text(label)
            }
            .font(DFFont.caption.bold())
            .foregroundStyle(isOn ? DFColor.accent : DFColor.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isOn ? DFColor.accent.opacity(DFOpacity.o60) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
