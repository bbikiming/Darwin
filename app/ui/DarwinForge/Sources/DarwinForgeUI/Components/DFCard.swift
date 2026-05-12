import SwiftUI

/// 표준 카드 — surface.card + radius 16 + 그림자.
///
/// 근거: Apple HIG card pattern + LiquidGlassReference (본문은 솔리드).
public struct DFCard<Content: View>: View {
    private let padding: CGFloat
    private let content: () -> Content

    public init(padding: CGFloat = DFSpace.md, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.lg, style: .continuous)
                    .fill(DFColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.lg, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

/// 상태 칩 — 좌측 SF Symbol + 라벨 + tint.
///
/// 근거: KS S ISO 7010 색상 + Differentiate Without Color (색+아이콘+텍스트 3중).
public struct StatusPill: View {
    public enum Severity {
        case info, success, warning, danger

        var color: Color {
            switch self {
            case .info: return DFColor.info
            case .success: return DFColor.success
            case .warning: return DFColor.warning
            case .danger: return DFColor.danger
            }
        }
        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "exclamationmark.octagon.fill"
            }
        }
    }

    private let label: String
    private let severity: Severity

    public init(_ label: String, severity: Severity = .info) {
        self.label = label
        self.severity = severity
    }

    public var body: some View {
        Label(label, systemImage: severity.icon)
            .font(DFFont.caption.weight(.semibold))
            .foregroundStyle(severity.color)
            .padding(.horizontal, DFSpace.sm + 2)
            .padding(.vertical, DFSpace.xs)
            .background(
                Capsule()
                    .fill(severity.color.opacity(0.15))
            )
            .overlay(
                Capsule().stroke(severity.color.opacity(0.3), lineWidth: 0.5)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(severityLabel(severity)) — \(label)")
    }

    private func severityLabel(_ s: Severity) -> String {
        switch s {
        case .info: return "정보"
        case .success: return "정상"
        case .warning: return "주의"
        case .danger: return "위험"
        }
    }
}
