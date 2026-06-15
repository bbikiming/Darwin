import SwiftUI

/// Horizontal rotation control. Touch left → turn left; touch right → turn right.
/// Reports normalized turn rate ∈ [-1, 1]. Release = 0.
public struct DSRotationDial: View {
    let height: CGFloat
    let disabled: Bool
    let onChange: (Double) -> Void
    let onRelease: () -> Void

    @State private var dragLocation: CGFloat? = nil
    @State private var isActive = false

    public init(height: CGFloat = 80,
                disabled: Bool = false,
                onChange: @escaping (Double) -> Void,
                onRelease: @escaping () -> Void) {
        self.height = height
        self.disabled = disabled
        self.onChange = onChange
        self.onRelease = onRelease
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let half = width / 2

            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                    .fill(DS.Color.padBase)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                            .stroke(DS.Color.divider.opacity(0.5), lineWidth: DS.Stroke.regular)
                    )

                // Center line
                Rectangle()
                    .fill(DS.Color.divider)
                    .frame(width: 1, height: height * 0.5)
                    .opacity(0.5)

                // Direction symbols
                HStack {
                    Image(systemName: "arrow.turn.up.left")
                        .foregroundStyle(DS.Color.secondaryText)
                        .padding(.leading, DS.Space.l)
                    Spacer()
                    Image(systemName: "arrow.turn.up.right")
                        .foregroundStyle(DS.Color.secondaryText)
                        .padding(.trailing, DS.Space.l)
                }

                // Active region highlight
                if let loc = dragLocation {
                    let mid = loc < half ? loc / 2 : (loc + width) / 2
                    let w = abs(loc - half)
                    RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                        .fill(DS.Color.padActive)
                        .frame(width: w, height: height)
                        .position(x: mid, y: height / 2)
                        .animation(DS.Motion.quick, value: loc)
                }

                // Thumb indicator
                if isActive, let loc = dragLocation {
                    Circle()
                        .fill(DS.Color.padThumb)
                        .frame(width: 34, height: 34)
                        .position(x: loc, y: height / 2)
                        .dsShadow(DS.Shadows.pressed)
                }
            }
            .frame(width: width, height: height)
            .opacity(disabled ? 0.4 : 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !disabled else { return }
                        let clamped = min(max(0, value.location.x), width)
                        dragLocation = clamped
                        isActive = true
                        let normalized = Double((clamped - half) / half) // -1 .. 1
                        onChange(normalized)
                    }
                    .onEnded { _ in
                        dragLocation = nil
                        isActive = false
                        onRelease()
                    }
            )
            .accessibilityLabel("회전 다이얼")
            .accessibilityHint("왼쪽을 누르면 좌회전, 오른쪽을 누르면 우회전. 떼면 정지.")
        }
        .frame(height: height)
    }
}
