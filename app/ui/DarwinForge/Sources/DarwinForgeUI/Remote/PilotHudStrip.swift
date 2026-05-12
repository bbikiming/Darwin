import ForgeCore
import SwiftUI

/// HUD strip — 상단 상태 바.
/// v1.0 활성: V·T·세션 타이머·E-Stop.
/// v1.1 비활성: IMU 인공수평선·자동복구 토글.
public struct PilotHudStrip: View {
    @ObservedObject var channel: TeleopChannel
    @ObservedObject var gate: PilotSafetyGate
    @EnvironmentObject var store: ConnectionStore

    @State private var sessionStart = Date()
    @State private var elapsed: Int = 0
    @State private var timer: Timer? = nil

    public init(channel: TeleopChannel, gate: PilotSafetyGate) {
        self.channel = channel
        self.gate = gate
    }

    public var body: some View {
        HStack(spacing: 10) {
            voltageIndicator
            tempIndicator

            Label(formatElapsed(elapsed), systemImage: "timer")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            Spacer()

            imuHorizonWidget
            autoRecoveryToggle
            eStopButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.5))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(Color.white.opacity(0.10)),
            alignment: .bottom
        )
        .onAppear {
            sessionStart = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                elapsed = Int(Date().timeIntervalSince(sessionStart))
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    // MARK: - Subviews

    private var voltageIndicator: some View {
        let v = store.lastTelemetry?.board?.voltageVolts ?? 0
        let color: Color = v > 11.0 ? .green : (v > 9.5 ? .yellow : .red)
        return Label(String(format: "%.1fV", v > 0 ? v : 0), systemImage: "battery.100")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(v > 0 ? color : .white.opacity(0.30))
    }

    private var tempIndicator: some View {
        let t = store.lastTelemetry?.joints.values.compactMap { $0.presentTemperature }.max().map { Double($0) } ?? 0
        let color: Color = t < 50 ? .green : (t < 65 ? .yellow : .red)
        return Label("\(Int(t))°C", systemImage: "thermometer")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(t > 0 ? color : .white.opacity(0.30))
    }

    private var imuHorizonWidget: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(0.06))
            .frame(width: 40, height: 20)
            .overlay(
                Text("IMU")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.3))
            )
            .comingSoon(
                stage: "v1.1",
                title: "IMU 인공수평선",
                why: "CmController::read_imu() + ComplementaryFilter 구현이 필요합니다.",
                when: "Sprint 16 (v1.1)",
                alternative: nil
            )
    }

    private var autoRecoveryToggle: some View {
        Toggle("자동복구", isOn: .constant(false))
            .toggleStyle(.switch)
            .labelsHidden()
            .scaleEffect(0.75)
            .comingSoon(
                stage: "v1.1",
                title: "자동 낙상 복구",
                why: "IMU 텔레메트리와 연동이 필요합니다.",
                when: "Sprint 16 (v1.1)",
                alternative: "수동으로 Action Bar의 앞/뒤 일어서기 버튼을 누르세요"
            )
    }

    private var eStopButton: some View {
        Button {
            Task { @MainActor in
                await channel.emergencyStop()
                gate.triggerEstopFlash()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .black))
                Text("E-STOP")
                    .font(.system(size: 12, weight: .black))
            }
            .foregroundStyle(.white)
            .frame(width: 90, height: 32)
            .background(PilotColor.estop)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: PilotColor.estop.opacity(0.6), radius: 6)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(".", modifiers: [.command, .shift])
        .help("비상 정지 (⌘⇧.) — 즉시 모든 모터 토크 OFF")
    }

    private func formatElapsed(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}
