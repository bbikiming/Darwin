import SwiftUI

public struct ArmSlider: View {

    @Binding public var isArmed: Bool
    public var disabled: Bool
    public var label: String
    public var onArm: () -> Void
    public var onDisarm: () -> Void

    @GestureState private var dragOffset: CGFloat = 0
    @State private var committed = false

    public init(isArmed: Binding<Bool>, disabled: Bool, label: String,
                onArm: @escaping () -> Void, onDisarm: @escaping () -> Void) {
        _isArmed = isArmed
        self.disabled = disabled
        self.label = label
        self.onArm = onArm
        self.onDisarm = onDisarm
    }

    public var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let thumb: CGFloat = 56
            let maxOffset = max(0, totalWidth - thumb - 8)
            let offset = isArmed ? maxOffset : min(maxOffset, max(0, dragOffset))
            let progress = maxOffset > 0 ? offset / maxOffset : 0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.dfSecondaryBackground)
                RoundedRectangle(cornerRadius: 22)
                    .fill(isArmed ? Color.green.opacity(0.35) : Color.blue.opacity(0.18 * Double(progress)))
                HStack {
                    ZStack {
                        Circle()
                            .fill(isArmed ? Color.green : Color.blue)
                            .frame(width: thumb, height: thumb)
                        Image(systemName: isArmed ? "lock.open.fill" : "lock.fill")
                            .foregroundStyle(.white)
                            .font(.system(size: 22, weight: .bold))
                    }
                    .offset(x: 4 + offset)
                    Spacer()
                }
                Text(displayText(progress: progress))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 8)
            }
            .frame(height: 64)
            .opacity(disabled ? 0.5 : 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        guard !disabled, !isArmed else { return }
                        state = max(0, min(maxOffset, value.translation.width))
                    }
                    .onEnded { value in
                        guard !disabled else { return }
                        let drag = max(0, min(maxOffset, value.translation.width))
                        if !isArmed && drag >= maxOffset * 0.85 {
                            committed = true
                            isArmed = true
                            onArm()
                        } else if isArmed && drag < -maxOffset * 0.2 {
                            isArmed = false
                            onDisarm()
                        }
                    }
            )
            .accessibilityIdentifier("pilot.arm.slider")
            .accessibilityLabel("로봇 잠금 해제")
            .accessibilityValue(isArmed ? "잠금 해제됨" : "잠김")
            .accessibilityHint("오른쪽으로 끝까지 밀어 잠금을 해제합니다.")
        }
        .frame(height: 64)
    }

    private func displayText(progress: CGFloat) -> String {
        if isArmed { return "잠금 해제됨" }
        if disabled { return label }
        if progress > 0.85 { return "잠금 해제 중..." }
        if progress > 0.1 { return "계속 미세요" }
        return label
    }
}
