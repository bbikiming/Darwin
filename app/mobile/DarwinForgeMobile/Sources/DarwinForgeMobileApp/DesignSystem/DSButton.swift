import SwiftUI

public struct DSButton: View {
    public enum Style {
        case primary
        case secondary
        case ghost
        case danger
        case success
    }

    public enum Size {
        case small, regular, large
    }

    let label: String
    let systemImage: String?
    let style: Style
    let size: Size
    let fullWidth: Bool
    let action: () -> Void
    let disabled: Bool

    public init(_ label: String,
                systemImage: String? = nil,
                style: Style = .primary,
                size: Size = .regular,
                fullWidth: Bool = false,
                disabled: Bool = false,
                action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.style = style
        self.size = size
        self.fullWidth = fullWidth
        self.disabled = disabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(label)
                    .font(DS.Font.button)
            }
            .padding(.vertical, verticalPad)
            .padding(.horizontal, horizontalPad)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.m,
                                                          style: .continuous))
        }
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .buttonStyle(.plain)
    }

    private var verticalPad: CGFloat {
        switch size { case .small: return 8; case .regular: return 12; case .large: return 16 }
    }
    private var horizontalPad: CGFloat {
        switch size { case .small: return 12; case .regular: return 16; case .large: return 20 }
    }

    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .secondary: return DS.Color.primaryText
        case .ghost: return DS.Color.accent
        case .danger: return .white
        case .success: return .white
        }
    }
    private var background: Color {
        switch style {
        case .primary: return DS.Color.accent
        case .secondary: return DS.Color.elevated
        case .ghost: return .clear
        case .danger: return DS.Color.danger
        case .success: return DS.Color.success
        }
    }
}

/// Segmented selector with consistent DS styling.
public struct DSSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String, disabled: Bool)]
    @Binding var selection: Value

    public init(_ options: [(value: Value, label: String, disabled: Bool)],
                selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(options.indices, id: \.self) { idx in
                let opt = options[idx]
                let isSelected = opt.value == selection
                Button {
                    if !opt.disabled { selection = opt.value }
                } label: {
                    Text(opt.label)
                        .font(DS.Font.button)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.s)
                        .foregroundStyle(isSelected ? .white : (opt.disabled ? DS.Color.disabled : DS.Color.primaryText))
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                                .fill(isSelected ? DS.Color.accent : DS.Color.elevated)
                        )
                        .opacity(opt.disabled ? 0.55 : 1)
                }
                .buttonStyle(.plain)
                .disabled(opt.disabled)
            }
        }
        .padding(DS.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(DS.Color.surface)
        )
    }
}
