import SwiftUI
import MobilePilotKit

public enum SpeedTier: String, Identifiable, CaseIterable, Sendable {
    case slow = "느림"
    case medium = "보통"
    case fast = "빠름"

    public var id: String { rawValue }

    /// Multiplier applied to walking preset baseline (xMm/yMm/aDeg).
    public var multiplier: Double {
        switch self {
        case .slow: return 1.0
        case .medium: return 1.5
        case .fast: return 2.2
        }
    }

    public var systemImage: String {
        switch self {
        case .slow: return "tortoise.fill"
        case .medium: return "figure.walk"
        case .fast: return "hare.fill"
        }
    }
}

/// Speed selector. In MVP only `slow` is enabled per the safety policy.
public struct DSSpeedSelector: View {
    @Binding var selected: SpeedTier
    let enabledTiers: Set<SpeedTier>

    public init(selected: Binding<SpeedTier>,
                enabledTiers: Set<SpeedTier> = [.slow]) {
        _selected = selected
        self.enabledTiers = enabledTiers
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(SpeedTier.allCases) { tier in
                let isEnabled = enabledTiers.contains(tier)
                let isSelected = tier == selected
                Button {
                    if isEnabled { selected = tier }
                } label: {
                    VStack(spacing: DS.Space.xs) {
                        Image(systemName: tier.systemImage)
                            .font(.system(size: 20, weight: .medium))
                        Text(tier.rawValue)
                            .font(DS.Font.captionEmphasis)
                        if !isEnabled {
                            Text("대기").font(.system(size: 9))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.s + 2)
                    .foregroundStyle(isSelected ? .white : (isEnabled ? DS.Color.primaryText : DS.Color.disabled))
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                            .fill(isSelected ? DS.Color.accent : DS.Color.elevated)
                    )
                    .opacity(isEnabled ? 1 : 0.55)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityIdentifier("pilot.speed.\(tier.rawValue)")
            }
        }
    }
}
