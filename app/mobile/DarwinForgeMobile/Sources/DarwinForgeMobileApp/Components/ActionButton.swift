import SwiftUI
import MobilePilotKit

public struct ActionButton: View {
    let title: String
    let systemImage: String
    let risk: MotionRisk
    let disabled: Bool
    let disabledReason: String?
    let running: Bool
    let onTap: () -> Void
    let accessibilityID: String

    public init(title: String,
                systemImage: String,
                risk: MotionRisk,
                disabled: Bool,
                disabledReason: String?,
                running: Bool,
                accessibilityID: String,
                onTap: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.risk = risk
        self.disabled = disabled
        self.disabledReason = disabledReason
        self.running = running
        self.accessibilityID = accessibilityID
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.title3)
                    if running {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Spacer()
                        riskBadge
                    }
                }
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if let reason = disabledReason, disabled {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.dfSecondaryBackground, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityHint(disabled ? (disabledReason ?? "") : "")
    }

    private var riskBadge: some View {
        Group {
            switch risk {
            case .safe:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            case .caution:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .highRisk:
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .imageScale(.small)
    }
}
