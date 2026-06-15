import SwiftUI

/// Standard surface for grouped content. Consistent radius/shadow/padding
/// across every screen.
public struct DSCard<Content: View>: View {
    public enum Tone {
        case standard, elevated, accent, danger, success
    }

    private let tone: Tone
    private let padding: CGFloat
    private let content: Content

    public init(tone: Tone = .standard,
                padding: CGFloat = DS.Space.l,
                @ViewBuilder content: () -> Content) {
        self.tone = tone
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
            .dsShadow(tone == .elevated ? DS.Shadows.elevated : DS.Shadows.card)
    }

    private var background: some View {
        let fill: Color
        switch tone {
        case .standard:  fill = DS.Color.surface
        case .elevated:  fill = DS.Color.elevated
        case .accent:    fill = DS.Color.brandSoft
        case .danger:    fill = DS.Color.danger.opacity(0.10)
        case .success:   fill = DS.Color.success.opacity(0.10)
        }
        return RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
            .fill(fill)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
            .stroke(borderColor, lineWidth: DS.Stroke.hairline)
    }

    private var borderColor: Color {
        switch tone {
        case .standard, .elevated: return DS.Color.divider.opacity(0.45)
        case .accent:  return DS.Color.brand.opacity(0.30)
        case .danger:  return DS.Color.danger.opacity(0.35)
        case .success: return DS.Color.success.opacity(0.35)
        }
    }
}

/// Section header — small uppercase label above a card group.
public struct DSSectionHeader: View {
    let title: String
    let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(title)
                .font(DS.Font.sectionTitle)
                .foregroundStyle(DS.Color.primaryText)
            if let subtitle {
                Text(subtitle)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.xs)
    }
}
