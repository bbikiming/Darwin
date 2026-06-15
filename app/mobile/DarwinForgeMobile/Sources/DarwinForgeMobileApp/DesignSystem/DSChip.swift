import SwiftUI

/// Universal chip — replaces ad-hoc StatusChip across screens.
public struct DSChip: View {
    public enum Tone {
        case neutral, info, success, warning, danger, accent

        var foreground: Color {
            switch self {
            case .neutral: return DS.Color.secondaryText
            case .info:    return DS.Color.info
            case .success: return DS.Color.success
            case .warning: return DS.Color.warning
            case .danger:  return DS.Color.danger
            case .accent:  return DS.Color.brand
            }
        }
        var background: Color {
            switch self {
            case .neutral: return DS.Color.elevated
            case .info:    return DS.Color.info.opacity(0.16)
            case .success: return DS.Color.success.opacity(0.16)
            case .warning: return DS.Color.warning.opacity(0.18)
            case .danger:  return DS.Color.danger.opacity(0.18)
            case .accent:  return DS.Color.brandSoft
            }
        }
    }

    let label: String
    let value: String?
    let systemImage: String?
    let tone: Tone
    let identifier: String?

    public init(_ label: String,
                value: String? = nil,
                systemImage: String? = nil,
                tone: Tone = .neutral,
                identifier: String? = nil) {
        self.label = label
        self.value = value
        self.systemImage = systemImage
        self.tone = tone
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(label)
                .font(DS.Font.chipLabel)
            if let value {
                Text(value)
                    .font(DS.Font.chipLabel.monospacedDigit())
                    .foregroundStyle(tone.foreground)
            }
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs + 2)
        .background(tone.background, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + (value.map { " " + $0 } ?? ""))
        .accessibilityIdentifier(identifier ?? label)
    }
}

/// Pill button — circle-ish capsule for toolbar-style toggle.
public struct DSPillButton: View {
    let systemImage: String
    let label: String?
    let tone: DSChip.Tone
    let action: () -> Void

    public init(systemImage: String,
                label: String? = nil,
                tone: DSChip.Tone = .neutral,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.tone = tone
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: systemImage)
                if let label {
                    Text(label).font(DS.Font.chipLabel)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .foregroundStyle(tone.foreground)
            .background(tone.background, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
