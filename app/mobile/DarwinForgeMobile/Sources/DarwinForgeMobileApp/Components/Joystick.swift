import SwiftUI

/// Analog joystick. Reports normalized (x, y) ∈ [-1, 1].
///
/// Behavior:
/// - Touch down → thumb springs toward finger; emits `onChange(x, y)` at ~60Hz
/// - Touch release → thumb returns to center; emits `onChange(0, 0)` once
/// - Disabled → grayed out, no gesture
///
/// Axes:
///   x = +1: 오른쪽 (측면 이동 우)
///   x = -1: 왼쪽 (측면 이동 좌)
///   y = -1: 위 (전진)
///   y = +1: 아래 (후진)
public struct DSJoystick: View {

    public struct Vector: Equatable {
        public let x: Double
        public let y: Double
        public static let zero = Vector(x: 0, y: 0)
        public var magnitude: Double { sqrt(x*x + y*y) }
    }

    let size: CGFloat
    let label: String?
    let disabled: Bool
    let allowVerticalOnly: Bool
    let onChange: (Vector) -> Void
    let onRelease: () -> Void

    @State private var offset: CGSize = .zero
    @State private var isActive: Bool = false

    public init(size: CGFloat = 200,
                label: String? = nil,
                disabled: Bool = false,
                allowVerticalOnly: Bool = false,
                onChange: @escaping (Vector) -> Void,
                onRelease: @escaping () -> Void) {
        self.size = size
        self.label = label
        self.disabled = disabled
        self.allowVerticalOnly = allowVerticalOnly
        self.onChange = onChange
        self.onRelease = onRelease
    }

    public var body: some View {
        let thumbSize: CGFloat = size * 0.36
        let maxOffset: CGFloat = (size - thumbSize) / 2 - 4

        ZStack {
            // Outer ring with subtle grid hint
            Circle()
                .fill(DS.Color.padBase)
                .overlay(
                    Circle().stroke(DS.Color.divider.opacity(0.6), lineWidth: DS.Stroke.regular)
                )

            // Cardinal direction hints
            DirectionHints(disabled: disabled, allowVerticalOnly: allowVerticalOnly)
                .padding(DS.Space.s)

            // Inner active circle (highlight when held)
            Circle()
                .fill(isActive ? DS.Color.padActive : Color.clear)
                .frame(width: size * 0.7, height: size * 0.7)
                .animation(DS.Motion.quick, value: isActive)

            // Thumb
            Circle()
                .fill(DS.Color.padThumb)
                .frame(width: thumbSize, height: thumbSize)
                .overlay(
                    Image(systemName: isActive ? "dot.circle.fill" : "circle.fill")
                        .foregroundStyle(.white.opacity(0.95))
                        .imageScale(.small)
                )
                .offset(offset)
                .dsShadow(isActive ? DS.Shadows.pressed : DS.Shadows.card)
                .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.7),
                           value: offset)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .opacity(disabled ? 0.4 : 1)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !disabled else { return }
                    isActive = true
                    let raw = CGSize(
                        width: value.translation.width,
                        height: value.translation.height
                    )
                    let constrained = constrain(raw, max: maxOffset)
                    offset = constrained
                    let normX = Double(constrained.width / maxOffset)
                    let normY = Double(constrained.height / maxOffset)
                    let snapped = Vector(
                        x: allowVerticalOnly ? 0 : normX,
                        y: normY)
                    onChange(snapped)
                }
                .onEnded { _ in
                    offset = .zero
                    isActive = false
                    onRelease()
                }
        )
        .accessibilityLabel(label ?? "조종 조이스틱")
        .accessibilityHint("누르고 있는 동안만 활성, 떼면 정지합니다")
        .accessibilityAddTraits(.isButton)
    }

    private func constrain(_ s: CGSize, max: CGFloat) -> CGSize {
        let length = sqrt(s.width * s.width + s.height * s.height)
        if length <= max { return s }
        let scale = max / length
        return CGSize(width: s.width * scale, height: s.height * scale)
    }
}

private struct DirectionHints: View {
    let disabled: Bool
    let allowVerticalOnly: Bool
    var body: some View {
        let color = DS.Color.secondaryText.opacity(disabled ? 0.3 : 0.55)
        return ZStack {
            VStack {
                Image(systemName: "chevron.up").imageScale(.small)
                    .foregroundStyle(color)
                Spacer()
                Image(systemName: "chevron.down").imageScale(.small)
                    .foregroundStyle(color)
            }
            if !allowVerticalOnly {
                HStack {
                    Image(systemName: "chevron.left").imageScale(.small)
                        .foregroundStyle(color)
                    Spacer()
                    Image(systemName: "chevron.right").imageScale(.small)
                        .foregroundStyle(color)
                }
            }
        }
    }
}
