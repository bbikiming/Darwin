import SwiftUI

// V297-6 (PM Story S3.1): estopped 상태에서 "복구" 버튼 모드로 전환.
// Mode.estop → 빨간 긴급 정지 / Mode.recover → 녹색 복구.
public struct EmergencyStopButton: View {

    // MARK: - Mode

    public enum Mode: Equatable, Sendable {
        case estop
        case recover
    }

    // MARK: - Props

    let mode: Mode
    let onTap: () -> Void

    public init(mode: Mode = .estop, onTap: @escaping () -> Void) {
        self.mode = mode
        self.onTap = onTap
    }

    // MARK: - Body

    public var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(mode == .recover ? Color.green : Color.red)
                    .frame(width: 56, height: 56)
                    .shadow(color: (mode == .recover ? Color.green : Color.red).opacity(0.4),
                            radius: 8, y: 2)
                Image(systemName: mode == .recover
                      ? "arrow.clockwise.circle.fill"
                      : "exclamationmark.octagon.fill")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .recover ? "복구" : "긴급 정지")
        .accessibilityHint(mode == .recover
                           ? "로봇을 복구 상태로 전환합니다."
                           : "즉시 모든 동작을 정지합니다.")
        .accessibilityIdentifier(mode == .recover
                                  ? "global.recover.button"
                                  : "global.estop.button")
        .animation(DS.Motion.standard, value: mode)
    }
}
