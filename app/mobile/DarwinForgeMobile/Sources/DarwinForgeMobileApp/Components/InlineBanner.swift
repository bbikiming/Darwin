import SwiftUI

public struct InlineBanner: View {
    public enum Variant: Sendable {
        case info, success, warning, danger
        var background: Color {
            switch self {
            case .info:    return Color.blue.opacity(0.18)
            case .success: return Color.green.opacity(0.18)
            case .warning: return Color.orange.opacity(0.22)
            case .danger:  return Color.red.opacity(0.22)
            }
        }
        var foreground: Color {
            switch self {
            case .info:    return .blue
            case .success: return .green
            case .warning: return .orange
            case .danger:  return .red
            }
        }
        var icon: String {
            switch self {
            case .info:    return "info.circle.fill"
            case .success: return "checkmark.seal.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger:  return "exclamationmark.octagon.fill"
            }
        }
    }

    let variant: Variant
    let message: String
    let action: (label: String, handler: () -> Void)?

    public init(variant: Variant, message: String,
                action: (label: String, handler: () -> Void)? = nil) {
        self.variant = variant
        self.message = message
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: variant.icon)
                .foregroundStyle(variant.foreground)
            Text(message).font(.subheadline)
            Spacer()
            if let action {
                Button(action.label, action: action.handler)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(variant.foreground)
            }
        }
        .padding(12)
        .background(variant.background, in: RoundedRectangle(cornerRadius: 12))
    }
}
