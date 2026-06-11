import SwiftUI

/// 뷰포트 오버레이 — 조명·머티리얼 라이브 튜닝 슬라이더.
///
/// `ViewportControls`(우상단 카메라 칩)의 토글로 노출. `SceneTuning.shared` 에 바인딩하며
/// 변경은 `RobotSceneCoordinator` 의 Combine 구독을 통해 모든 활성 3D 씬에 즉시 반영된다.
struct SceneTuningPanel: View {
    @ObservedObject private var tuning = SceneTuning.shared
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: DFSpace.md) {
                    group("조명") {
                        row("Key 강도", $tuning.keyIntensity, 0...1200, "%.0f")
                        row("Rim 강도", $tuning.rimIntensity, 0...600, "%.0f")
                        row("IBL 강도", $tuning.iblIntensity, 0...2.0)
                        row("그림자 부드러움", $tuning.shadowRadius, 0...20, "%.1f")
                    }
                    group("머티리얼") {
                        row("흰 쉘 거칠기", $tuning.whiteShellRoughness, 0...1.0)
                        row("알루미늄 metalness", $tuning.aluminumMetalness, 0...1.0)
                        row("알루미늄 거칠기", $tuning.aluminumRoughness, 0...1.0)
                        row("전완 밝기", $tuning.servoBlackBrightness, 0...0.8)
                        row("머리 밝기", $tuning.helmetBrightness, 0...0.8)
                        row("머리 거칠기", $tuning.helmetRoughness, 0...1.0)
                    }
                    group("바닥") {
                        row("바닥 밝기", $tuning.floorBrightness, 0...0.5)
                        row("바닥 거칠기", $tuning.floorRoughness, 0...1.0)
                    }
                }
                .padding(.trailing, DFSpace.xs)
            }
            .frame(maxHeight: 380)
        }
        .padding(DFSpace.md)
        .frame(width: 280)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    // MARK: - 구성요소

    private var header: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: "slider.horizontal.3")
            Text("조명·머티리얼")
                .font(DFFont.caption.bold())
            Spacer()
            Button {
                tuning.resetToDefaults()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.plain)
            .help("기본값으로 복원")
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("닫기")
        }
        .foregroundStyle(DFColor.textPrimary)
        .font(DFFont.caption)
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text(title)
                .font(DFFont.caption.bold())
                .foregroundStyle(DFColor.textSecondary)
            content()
        }
    }

    private func row(_ label: String,
                     _ value: Binding<Double>,
                     _ range: ClosedRange<Double>,
                     _ fmt: String = "%.2f") -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textPrimary)
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(DFColor.textSecondary)
            }
            Slider(value: value, in: range)
                .controlSize(.mini)
        }
    }
}
