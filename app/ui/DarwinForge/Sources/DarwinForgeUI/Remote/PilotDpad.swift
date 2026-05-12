import ForgeCore
import SwiftUI

/// D-pad 방향 명령 (v1.0 sim only — 실 모터 송출 없음).
enum DpadDirection: String, CaseIterable {
    case forward, backward, left, right
    case turnLeft, turnRight, stop
}

/// D-pad — 7존 (↑↓←→ + ↶↷ + ◉ 정지).
/// v1.0: WalkEngine sim만. 실 모터 송출 경로 없음 (BLOCKER C3).
/// PRD: "flags.dpadRealMotor=false 이면 실 모터 송출 코드 경로 자체가 빠짐"
public struct PilotDpad: View {
    @ObservedObject var channel: TeleopChannel
    let flags: PilotFeatureFlags

    @State private var pressed: DpadDirection? = nil

    public init(channel: TeleopChannel, flags: PilotFeatureFlags = .default) {
        self.channel = channel
        self.flags = flags
    }

    public var body: some View {
        VStack(spacing: 4) {
            // v2 배지 — 인라인 (overlay 아님)
            HStack {
                Text("D-PAD")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
                Spacer()
                Text("v2 활성 — 실 보행 IK 후")
                    .font(.system(size: 9))
                    .foregroundStyle(PilotColor.caution.opacity(0.7))
            }
            .padding(.horizontal, 4)

            // D-pad layout
            VStack(spacing: 3) {
                dpadRow([nil, .forward, nil], keys: [nil, "W", nil])
                dpadRow([.turnLeft, .stop, .turnRight], keys: ["Q", "Space", "E"])
                dpadRow([.left, .backward, .right], keys: ["A", "S", "D"])
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func dpadRow(_ directions: [DpadDirection?], keys: [String?]) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                if let dir = directions[i] {
                    dpadButton(dir: dir, key: keys[i])
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
        }
    }

    private func dpadButton(dir: DpadDirection, key: String?) -> some View {
        let isPressed = pressed == dir
        return Button {
            sendCommand(dir)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isPressed ? PilotColor.dpadPressed : PilotColor.dpadButton)
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
                VStack(spacing: 1) {
                    Image(systemName: dirIcon(dir))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    if let k = key {
                        Text(k)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.30))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.92 : 1.0)
        .animation(PilotAnim.buttonPress, value: isPressed)
    }

    private func sendCommand(_ dir: DpadDirection) {
        pressed = dir
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            pressed = nil
        }
        // v1.0 sim only — 절대 실 모터 송출 없음 (BLOCKER C3).
        guard !flags.dpadRealMotor else { return }
        let cmd: TeleopCommandSwift
        switch dir {
        case .forward:   cmd = .walk(x: 0.04, y: 0, a: 0)
        case .backward:  cmd = .walk(x: -0.04, y: 0, a: 0)
        case .left:      cmd = .walk(x: 0, y: 0.03, a: 0)
        case .right:     cmd = .walk(x: 0, y: -0.03, a: 0)
        case .turnLeft:  cmd = .walk(x: 0, y: 0, a: 0.3)
        case .turnRight: cmd = .walk(x: 0, y: 0, a: -0.3)
        case .stop:      cmd = .stop
        }
        channel.currentCmd = cmd
    }

    private func dirIcon(_ dir: DpadDirection) -> String {
        switch dir {
        case .forward:   return "arrow.up"
        case .backward:  return "arrow.down"
        case .left:      return "arrow.left"
        case .right:     return "arrow.right"
        case .turnLeft:  return "arrow.counterclockwise"
        case .turnRight: return "arrow.clockwise"
        case .stop:      return "stop.circle.fill"
        }
    }
}
