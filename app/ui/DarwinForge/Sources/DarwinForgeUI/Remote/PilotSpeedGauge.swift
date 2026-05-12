import ForgeCore
import SwiftUI

/// 보행 속도 게이지 + WalkPhase 세그먼트 바 (sim only).
/// D-pad sim 입력에 반응.
public struct PilotSpeedGauge: View {
    @ObservedObject var channel: TeleopChannel

    private var walkSpeed: Double {
        if case .walk(let x, let y, _) = channel.currentCmd {
            return min(1.0, sqrt(x * x + y * y) / 0.06)
        }
        return 0.0
    }

    private var isStopped: Bool {
        if case .stop = channel.currentCmd { return true }
        if case .walk(let x, let y, let a) = channel.currentCmd {
            return x == 0 && y == 0 && a == 0
        }
        return true
    }

    public init(channel: TeleopChannel) {
        self.channel = channel
    }

    public var body: some View {
        VStack(spacing: 6) {
            // 속도 아치형 게이지
            ZStack {
                ArcShape(startAngle: 210, endAngle: 330)
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 4, lineCap: .round))

                ArcShape(startAngle: 210, endAngle: 210 + 120 * walkSpeed)
                    .stroke(
                        isStopped ? Color.white.opacity(0.2) : PilotColor.armed,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .animation(.easeInOut(duration: 0.2), value: walkSpeed)

                VStack(spacing: 1) {
                    Text(String(format: "%.0f%%", walkSpeed * 100))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(isStopped ? .white.opacity(0.4) : .white)
                    Text("속도")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(width: 80, height: 60)

            // WalkPhase 세그먼트 바 (시각 미리보기)
            phaseBar
        }
    }

    private var phaseBar: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { phase in
                RoundedRectangle(cornerRadius: 2)
                    .fill(phaseColor(phase))
                    .frame(height: 4)
                    .overlay(
                        Text("P\(phase)")
                            .font(.system(size: 7))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .frame(height: 14)
    }

    private func phaseColor(_ phase: Int) -> Color {
        guard !isStopped else { return Color.white.opacity(0.08) }
        return phase < 2 ? PilotColor.armed.opacity(0.5) : PilotColor.armed.opacity(0.25)
    }
}

// MARK: - Arc shape helper

private struct ArcShape: Shape {
    var startAngle: Double
    var endAngle: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2 - 2,
            startAngle: .degrees(startAngle),
            endAngle: .degrees(endAngle),
            clockwise: false
        )
        return p
    }
}
