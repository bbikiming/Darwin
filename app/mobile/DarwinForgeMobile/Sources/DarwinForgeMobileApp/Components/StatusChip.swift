import SwiftUI

public struct StatusChip: View {
    public enum Variant: Sendable {
        case connected, searching, warning, danger, neutral

        var background: Color {
            switch self {
            case .connected: return Color.green.opacity(0.18)
            case .searching: return Color.blue.opacity(0.18)
            case .warning:   return Color.orange.opacity(0.20)
            case .danger:    return Color.red.opacity(0.22)
            case .neutral:   return Color.gray.opacity(0.18)
            }
        }
        var foreground: Color {
            switch self {
            case .connected: return .green
            case .searching: return .blue
            case .warning:   return .orange
            case .danger:    return .red
            case .neutral:   return .secondary
            }
        }
        var icon: String {
            switch self {
            case .connected: return "checkmark.circle.fill"
            case .searching: return "antenna.radiowaves.left.and.right"
            case .warning:   return "exclamationmark.triangle.fill"
            case .danger:    return "exclamationmark.octagon.fill"
            case .neutral:   return "circle.slash"
            }
        }
    }

    let label: String
    let variant: Variant
    let value: String?
    let accessibilityID: String?

    public init(label: String, variant: Variant, value: String? = nil,
                accessibilityID: String? = nil) {
        self.label = label
        self.variant = variant
        self.value = value
        self.accessibilityID = accessibilityID
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: variant.icon)
                .imageScale(.small)
            Text(label)
                .font(.subheadline.weight(.semibold))
            if let value {
                Text(value)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(variant.foreground)
            }
        }
        .foregroundStyle(variant.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(variant.background, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + (value.map { " " + $0 } ?? ""))
        .accessibilityIdentifier(accessibilityID ?? label)
    }
}
