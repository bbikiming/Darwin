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
        case .medium: return 1.25
        case .fast: return 1.5
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

/// Speed selector. The Mac relay clamps accepted walking speed to 0.5...1.5.
public struct DSSpeedSelector: View {
    @Binding var selected: SpeedTier
    let enabledTiers: Set<SpeedTier>
    let unavailableLabel: String

    public init(selected: Binding<SpeedTier>,
                enabledTiers: Set<SpeedTier> = [.slow],
                unavailableLabel: String = "Mac 미지원") {
        _selected = selected
        self.enabledTiers = enabledTiers
        self.unavailableLabel = unavailableLabel
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
                            Text(unavailableLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
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
