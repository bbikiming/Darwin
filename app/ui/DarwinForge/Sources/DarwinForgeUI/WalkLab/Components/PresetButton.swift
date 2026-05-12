import SwiftUI

/// Walk Lab 의 큰 보행 프리셋 버튼. SF Symbol + 한국어 라벨 + 안전 등급 배지.
struct PresetButton: View {
    let preset: WalkLabPreset
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DFSpace.sm3) {
                Image(systemName: preset.icon)
                    .font(.system(size: DFFontSize.s18, weight: .semibold))
                    .frame(width: DFSize.iconLg, height: DFSize.iconLg)
                    .foregroundStyle(preset.safety.tintColor)
                VStack(alignment: .leading, spacing: DFSpace.micro2) {
                    Text(preset.label)
                        .font(.system(size: DFFontSize.s14, weight: .medium))
                    if preset.safety != .safe {
                        Text(preset.safety.labelKo)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(preset.safety.tintColor.opacity(DFOpacity.o18))
                            .foregroundStyle(preset.safety.tintColor)
                            .clipShape(Capsule())
                    }
                }
                Spacer()
                if preset.maxDurationSec > 0 {
                    Text("\(preset.maxDurationSec)s")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if isActive {
                    Image(systemName: "circle.fill")
                        .font(.system(size: DFFontSize.s8))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, DFSpace.sm3)
            .padding(.vertical, DFSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.sm, style: .continuous)
                    .fill(isActive
                          ? preset.safety.tintColor.opacity(DFOpacity.subtle)
                          : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.sm, style: .continuous)
                    .stroke(preset.safety == .safe
                            ? Color.clear
                            : preset.safety.tintColor.opacity(DFOpacity.disabled),
                            lineWidth: preset.safety == .safe ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.45)
        .help(preset.warning ?? "")
    }
}
