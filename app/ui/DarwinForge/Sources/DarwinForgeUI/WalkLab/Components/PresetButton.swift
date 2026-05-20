import SwiftUI

/// Walk Lab 의 큰 보행 프리셋 버튼. SF Symbol + 한국어 라벨 + 안전 등급 배지.
///
/// **v1.11.24 (2026-05-20) audit P0-2/P0-3 — 차단 사유 표면화**:
/// - `blockingReason` 가 nil 이 아니면 비활성 + 사유 inline 표시. 사용자가 click 전에
///   "왜 이 버튼이 작동 안 되는지" 알 수 있어 audit §1 mixed-preset 혼란을 차단.
/// - `onUnblock` 가 있으면 inline action 으로 차단 해소 (예: 자세 보정 ON 한 번에).
struct PresetButton: View {
    let preset: WalkLabPreset
    let isActive: Bool
    let isEnabled: Bool
    /// nil = 차단 사유 없음. 값이 있으면 버튼은 비활성 + 사유 inline 표시.
    let blockingReason: String?
    /// 차단 사유 해소 액션 (예: "자세 보정 켜기"). nil 이면 unblock 버튼 미표시.
    let onUnblock: (() -> Void)?
    let action: () -> Void

    init(preset: WalkLabPreset,
         isActive: Bool,
         isEnabled: Bool,
         blockingReason: String? = nil,
         onUnblock: (() -> Void)? = nil,
         action: @escaping () -> Void) {
        self.preset = preset
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.blockingReason = blockingReason
        self.onUnblock = onUnblock
        self.action = action
    }

    /// 차단 사유가 있으면 effective enable=false.
    private var isEffectivelyEnabled: Bool { isEnabled && blockingReason == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
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
            .disabled(!isEffectivelyEnabled)
            .opacity(isEffectivelyEnabled ? 1.0 : 0.45)
            .help(blockingReason ?? (preset.warning ?? ""))

            if let reason = blockingReason {
                blockingHint(reason: reason)
            }
        }
        .accessibilityLabel(Text(preset.label))
        .accessibilityHint(Text(blockingReason ?? preset.warning ?? ""))
        .accessibilityAddTraits(isEffectivelyEnabled ? [] : .isStaticText)
    }

    /// 비활성 사유 inline hint — 사용자가 왜 클릭 안 되는지 즉시 알 수 있게.
    @ViewBuilder
    private func blockingHint(reason: String) -> some View {
        HStack(spacing: DFSpace.micro2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(DFColor.warning)
            Text(reason)
                .font(.caption2)
                .foregroundStyle(DFColor.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DFSpace.micro)
            if let onUnblock = onUnblock {
                Button(action: onUnblock) {
                    Text("해소")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(DFColor.warning.opacity(DFOpacity.o18))
                        .foregroundStyle(DFColor.warning)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DFSpace.sm3)
        .padding(.vertical, DFSpace.micro)
    }
}
