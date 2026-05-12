import SwiftUI

/// Pilot 모드 토글 — Manual / Ball-Follow (PRD §3 좌측 패널 2).
///
/// HIG: SwiftUI 네이티브 `Picker(.segmented)` 사용. macOS 표준 시각.
/// v1.0: Manual 만 활성. Ball-Follow 는 disabled + comingSoon overlay.
public enum PilotMode: String, Sendable, CaseIterable, Identifiable {
    case manual
    case ballFollow

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .manual:     return "수동"
        case .ballFollow: return "공 자동 추적"
        }
    }
    public var icon: String {
        switch self {
        case .manual:     return "gamecontroller"
        case .ballFollow: return "target"
        }
    }
}

public struct PilotModePicker: View {
    @Binding var mode: PilotMode
    let flags: PilotFeatureFlags

    public init(mode: Binding<PilotMode>, flags: PilotFeatureFlags) {
        self._mode = mode
        self.flags = flags
    }

    public var body: some View {
        DFPanel(
            "조작 모드",
            subtitle: flags.ballFollow ? "수동 / 공 자동 추적 선택" : "v1.0: 수동만 활성",
            icon: "switch.2",
            tint: DFColor.info
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                Picker("모드", selection: $mode) {
                    Label(PilotMode.manual.label, systemImage: PilotMode.manual.icon)
                        .tag(PilotMode.manual)
                    Label(PilotMode.ballFollow.label, systemImage: PilotMode.ballFollow.icon)
                        .tag(PilotMode.ballFollow)
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .labelsHidden()
                .disabled(!flags.ballFollow && mode != .manual)
                .onChange(of: mode) { _, newMode in
                    // Ball-Follow 비활성 빌드에서 사용자가 그쪽 segment 를 눌러도 manual 로 되돌림.
                    if newMode == .ballFollow && !flags.ballFollow {
                        mode = .manual
                    }
                }

                if !flags.ballFollow {
                    HStack(spacing: DFSpace.xs2) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(PilotColor.comingSoon)
                        Text("공 자동 추적은 v1.1 (head 추적) → v1.5 (walk 자동) 에 활성")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, DFSpace.sm)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DFRadius.sm)
                            .fill(PilotColor.comingSoon.opacity(DFOpacity.o10))
                    )
                }
            }
        }
    }
}
