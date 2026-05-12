import SwiftUI

/// Walk Lab 의 큰 보행 프리셋 버튼. SF Symbol + 한국어 라벨 + 안전 등급 배지.
struct PresetButton: View {
    let preset: WalkLabPreset
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: preset.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(preset.safety.tintColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.label)
                        .font(.system(size: 14, weight: .medium))
                    if preset.safety != .safe {
                        Text(preset.safety.labelKo)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(preset.safety.tintColor.opacity(0.18))
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
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive
                          ? preset.safety.tintColor.opacity(0.12)
                          : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(preset.safety == .safe
                            ? Color.clear
                            : preset.safety.tintColor.opacity(0.4),
                            lineWidth: preset.safety == .safe ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.45)
        .help(preset.warning ?? "")
    }
}
