import SwiftUI

public struct EmergencyStopButton: View {

    let onTap: () -> Void

    public init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 56, height: 56)
                    .shadow(color: .red.opacity(0.4), radius: 8, y: 2)
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("긴급 정지")
        .accessibilityHint("즉시 모든 동작을 정지합니다.")
        .accessibilityIdentifier("global.estop.button")
    }
}
