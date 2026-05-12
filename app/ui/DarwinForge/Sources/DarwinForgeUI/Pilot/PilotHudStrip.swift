import ForgeCore
import SwiftUI

/// HUD Strip — V·T·세션 타이머·E-Stop + (v1.1) IMU 인공수평선 + 자동복구 토글
/// (PRD §3 우측 패널 C).
///
/// HIG: ViewThatFits 로 좁아지면 wrap 됨, E-Stop 은 항상 최우선 (.layoutPriority).
public struct PilotHudStrip: View {
    @ObservedObject var store: ConnectionStore
    @ObservedObject var channel: TeleopChannel
    @ObservedObject var gate: PilotSafetyGate
    let flags: PilotFeatureFlags

    @State private var sessionStart: Date = Date()

    public init(store: ConnectionStore, channel: TeleopChannel, gate: PilotSafetyGate,
                flags: PilotFeatureFlags) {
        self.store = store
        self.channel = channel
        self.gate = gate
        self.flags = flags
    }

    public var body: some View {
        DFPanel(
            "텔레메트리",
            subtitle: hudSubtitle,
            icon: "gauge.with.dots.needle.50percent",
            tint: telemetryTint,
            trailing: {
                if gate.armed {
                    DFChip("ARM", icon: "lock.open.fill", style: .success)
                } else {
                    DFChip("DISARM", icon: "lock.fill", style: .neutral)
                }
            }
        ) {
            ViewThatFits(in: .horizontal) {
                wideRow
                wrappedGrid
            }
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .stroke(gate.flashRed ? DFColor.danger : Color.clear, lineWidth: 2)
                    .animation(PilotAnim.flashRed, value: gate.flashRed)
            )
        }
    }

    private var hudSubtitle: String {
        if case .connected = store.status {
            return "실 로봇 연결됨 — 폴링 중"
        }
        return "시뮬 모드 — 실 텔레메트리 없음"
    }

    private var telemetryTint: Color {
        if case .connected = store.status { return DFColor.success }
        return DFColor.textSecondary
    }

    // MARK: - Layouts

    private var wideRow: some View {
        HStack(spacing: DFSpace.md) {
            voltageBlock
            divider
            temperatureBlock
            divider
            sessionTimerBlock
            divider
            imuBlock
            divider
            autoRecoveryBlock
            Spacer(minLength: DFSpace.sm)
            estopButton.layoutPriority(1)
        }
    }

    private var wrappedGrid: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                voltageBlock
                temperatureBlock
                sessionTimerBlock
                imuBlock
                autoRecoveryBlock
            }
            estopButton
                .frame(maxWidth: .infinity)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(DFColor.textSecondary.opacity(0.15))
            .frame(width: 1, height: 36)
    }

    // MARK: - Blocks

    private var voltageBlock: some View {
        metricCell(label: "전압",
                   icon: "bolt.fill",
                   tint: voltageTint,
                   value: voltageString)
    }

    private var voltageString: String {
        guard let v = store.lastTelemetry?.board?.voltageVolts else { return "—" }
        return String(format: "%.1fV", v)
    }

    private var voltageTint: Color {
        guard let v = store.lastTelemetry?.board?.voltageVolts else { return DFColor.textSecondary }
        if v >= 11.1 { return DFColor.success }
        if v >= 9.5  { return DFColor.warning }
        return DFColor.danger
    }

    private var temperatureBlock: some View {
        metricCell(label: "온도",
                   icon: "thermometer.medium",
                   tint: temperatureTint,
                   value: temperatureString)
    }

    private var temperatureString: String {
        guard let t = store.lastTelemetry?.avgTemperature else { return "—" }
        return String(format: "%.0f°C", t)
    }

    private var temperatureTint: Color {
        guard let t = store.lastTelemetry?.avgTemperature else { return DFColor.textSecondary }
        if t >= 60 { return DFColor.danger }
        if t >= 50 { return DFColor.warning }
        return DFColor.success
    }

    @ViewBuilder
    private var sessionTimerBlock: some View {
        TimelineView(.periodic(from: sessionStart, by: 1)) { _ in
            let elapsed = Int(Date().timeIntervalSince(sessionStart))
            metricCell(
                label: "세션",
                icon: "timer",
                tint: DFColor.info,
                value: String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
            )
        }
    }

    private var imuBlock: some View {
        Group {
            if flags.imuTelemetry {
                metricCell(label: "IMU",
                           icon: "gyroscope",
                           tint: DFColor.info,
                           value: "0° / 0°")
            } else {
                metricCell(label: "IMU",
                           icon: "gyroscope",
                           tint: PilotColor.comingSoon,
                           value: "v1.1")
                    .comingSoon(
                        "v1.1",
                        title: "IMU 텔레메트리 (roll / pitch)",
                        why: "CmController::read_imu() 가 v1.1 에 추가",
                        when: "Sprint 16",
                        alternative: "지금: 전압·온도·세션 모니터링"
                    )
            }
        }
    }

    private var autoRecoveryBlock: some View {
        Group {
            if flags.autoRecovery {
                Toggle(isOn: .constant(false)) {
                    Label("자동복구", systemImage: "shield.fill")
                        .labelStyle(.titleAndIcon)
                        .font(DFFont.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.horizontal, DFSpace.sm)
                .padding(.vertical, DFSpace.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DFColor.elev2)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            } else {
                metricCell(label: "자동복구",
                           icon: "shield.slash.fill",
                           tint: PilotColor.comingSoon,
                           value: "v1.1")
                    .comingSoon(
                        "v1.1",
                        title: "자동 낙상 복구 (page 10/11)",
                        why: "IMU read + FallRecoveryCoordinator 가 v1.1 에 추가",
                        when: "Sprint 16",
                        alternative: "지금: ⌘⇧. E-stop 으로 모터 토크 OFF"
                    )
            }
        }
    }

    private var estopButton: some View {
        Button {
            channel.emergencyStop()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 14, weight: .bold))
                VStack(alignment: .leading, spacing: 0) {
                    Text("긴급 정지")
                        .font(DFFont.bodyEmph)
                    Text("⌘⇧.")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 120, minHeight: DFSize.estop)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.md)
                    .fill(DFColor.danger)
                    .shadow(color: DFColor.danger.opacity(0.45), radius: 8, y: 2)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(".", modifiers: [.command, .shift])
        .help("⌘⇧. — 즉시 토크 OFF + motion cancel")
        .accessibilityLabel("긴급 정지 — ⌘⇧.")
    }

    // MARK: - Metric cell

    private func metricCell(label: String, icon: String, tint: Color, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Text(value)
                    .font(DFFont.bodyEmph.monospaced())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs2)
        .frame(minHeight: 44)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }
}
