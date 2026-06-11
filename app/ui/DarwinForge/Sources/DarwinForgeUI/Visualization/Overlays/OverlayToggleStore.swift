import SwiftUI

/// **W3 (2026-06-12)** — 오버레이 표시 토글 경량 store.
///
/// preset 기본값에서 시작하고, 사용자가 `ViewportControls` 팝오버에서 켜고 끈다.
/// 화면이 `@StateObject` 로 1개 보유 → `RobotScene3D(overlays:)` 에 전달.
public final class OverlayToggleStore: ObservableObject {
    @Published public var overlays: RobotOverlaySet

    public init(preset: ScenePreset) {
        overlays = RobotOverlaySet.defaults(for: preset)
    }

    public func binding(for overlay: RobotOverlaySet) -> Binding<Bool> {
        Binding(
            get: { self.overlays.contains(overlay) },
            set: { isOn in
                if isOn { self.overlays.insert(overlay) } else { self.overlays.remove(overlay) }
            }
        )
    }
}

/// 오버레이 토글 팝오버 버튼 — `ViewportControls` 에 합류.
struct OverlayToggleControl: View {
    @ObservedObject var store: OverlayToggleStore
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "square.3.layers.3d")
                Text("오버레이")
            }
            .font(DFFont.caption.bold())
            .foregroundStyle(DFColor.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("로봇공학 오버레이 표시/숨김")
        .popover(isPresented: $showPopover, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                Text("오버레이")
                    .font(DFFont.caption.bold())
                    .foregroundStyle(DFColor.textSecondary)
                ForEach(RobotOverlaySet.toggleable, id: \.label) { item in
                    Toggle(item.label, isOn: store.binding(for: item.overlay))
                        .toggleStyle(.checkbox)
                        .font(DFFont.caption)
                }
            }
            .padding(DFSpace.md)
            .frame(width: 200)
        }
    }
}
