import SwiftUI

/// macOS virtual joystick — mouse drag → normalised (x, y) ∈ [-1, +1].
///
/// Mirror of the iOS `DSJoystick` component so users on either platform see
/// the same control surface. The thumb springs back to centre on release and
/// emits a single `onRelease()` callback the panel uses to flip the bridge
/// into a `stop` intent.
///
/// # Axes (matches `WalkFreeformInput` / `TelloRCMapper` convention)
///
/// - `x = +1` — 우측 (lateral right)
/// - `x = -1` — 좌측 (lateral left)
/// - `y = -1` — 위 (전진, forward)
/// - `y = +1` — 아래 (후진, backward)
///
/// The DSJoystick convention is preserved so the same panel-level mapping
/// works whether the user grabs the on-screen pad or pushes a real game
/// controller stick.
public struct MacJoystickPad: View {

    public struct Vector: Equatable {
        public let x: Double
        public let y: Double
        public static let zero = Vector(x: 0, y: 0)
        public var magnitude: Double { sqrt(x * x + y * y) }
    }

    let size: CGFloat
    let disabled: Bool
    let onChange: (Vector) -> Void
    let onRelease: () -> Void

    @State private var offset: CGSize = .zero
    @State private var isActive: Bool = false

    public init(size: CGFloat = 160,
                disabled: Bool = false,
                onChange: @escaping (Vector) -> Void,
                onRelease: @escaping () -> Void) {
        self.size = size
        self.disabled = disabled
        self.onChange = onChange
        self.onRelease = onRelease
    }

    public var body: some View {
        let thumbSize: CGFloat = size * 0.32
        let maxOffset: CGFloat = (size - thumbSize) / 2 - 4

        ZStack {
            Circle()
                .fill(Color.gray.opacity(0.18))
                .overlay(
                    Circle().stroke(Color.gray.opacity(0.5), lineWidth: 1)
                )
            DirectionHints(disabled: disabled)
                .padding(8)
            Circle()
                .fill(isActive ? Color.accentColor.opacity(0.35) : Color.clear)
                .frame(width: size * 0.7, height: size * 0.7)
                .animation(.easeOut(duration: 0.12), value: isActive)
            Circle()
                .fill(Color.accentColor)
                .frame(width: thumbSize, height: thumbSize)
                .overlay(
                    Image(systemName: isActive
                          ? "dot.circle.fill"
                          : "circle.fill")
                        .foregroundStyle(.white.opacity(0.92))
                        .imageScale(.small)
                )
                .offset(offset)
                .shadow(radius: isActive ? 6 : 3)
                .animation(.interactiveSpring(response: 0.18,
                                              dampingFraction: 0.7),
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
                    let raw = CGSize(width: value.translation.width,
                                     height: value.translation.height)
                    let constrained = constrain(raw, max: maxOffset)
                    offset = constrained
                    onChange(Vector(
                        x: Double(constrained.width / maxOffset),
                        y: Double(constrained.height / maxOffset)))
                }
                .onEnded { _ in
                    offset = .zero
                    isActive = false
                    onRelease()
                }
        )
        .accessibilityLabel("가상 조이스틱")
        .accessibilityHint("드래그하는 동안 활성, 떼면 정지합니다")
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
    var body: some View {
        let color = Color.secondary.opacity(disabled ? 0.3 : 0.55)
        return ZStack {
            VStack {
                Image(systemName: "chevron.up").imageScale(.small).foregroundStyle(color)
                Spacer()
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(color)
            }
            HStack {
                Image(systemName: "chevron.left").imageScale(.small).foregroundStyle(color)
                Spacer()
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(color)
            }
        }
    }
}
