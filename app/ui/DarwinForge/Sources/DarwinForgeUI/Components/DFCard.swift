import SwiftUI

/// 표준 카드 — Sprint A 이후 deprecated. `DFPanel` 또는 `DFPanel(variant: .modal)` 사용 권장.
///
/// 기존 호출 측 호환을 위해 본 구조체는 유지하되, 내부 구현을 단순화하고
/// 새 코드는 `DFPanel` 을 직접 쓰도록 안내한다.
@available(*, deprecated, message: "Use DFPanel(variant: .modal) for shadowed cards, or DFPanel for standard cards.")
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
                    .stroke(Color.primary.opacity(DFOpacity.o06), lineWidth: DFSize.borderHairline)
            )
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

/// 상태 칩 — `DFStatusPill` 의 legacy alias.
///
/// 기존 호출 측 호환을 위해 유지. 신규 코드는 `DFStatusPill` 사용.
@available(*, deprecated, renamed: "DFStatusPill")
public struct StatusPill: View {
    public enum Severity {
        case info, success, warning, danger

        var dfSeverity: DFStatusPill.Severity {
            switch self {
            case .info: return .info
            case .success: return .success
            case .warning: return .warning
            case .danger: return .danger
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
        DFStatusPill(label, severity: severity.dfSeverity)
    }
}
