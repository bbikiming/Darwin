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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: DFSpace.sm)], spacing: DFSpace.sm) {
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
            .fill(DFColor.textSecondary.opacity(DFOpacity.o15))
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
                // Phase D3 (Sprint 18) — 실 IMU 값. fc_bus_read_imu 가 1Hz 폴링.
                // Codex 권고 (잔여 2/4): stale 표시 + "정적 tilt" 명시.
                metricCell(label: imuLabel,
                           icon: imuIcon,
                           tint: imuTint,
                           value: imuValueText)
                    .help(imuTooltip)
            } else {
                metricCell(label: "IMU",
                           icon: "gyroscope",
                           tint: PilotColor.comingSoon,
                           value: "OFF")
                    .comingSoon(
                        "v1.5+",
                        title: "IMU 텔레메트리 (roll / pitch)",
                        why: "사용자가 feature picker 에서 'IMU + 자동복구' 활성화 필요",
                        when: "Sprint 18",
                        alternative: "지금: 전압·온도·세션 모니터링"
                    )
            }
        }
    }

    /// IMU 라벨 — Phase E 부터 filter 적용 여부 명시.
    private var imuLabel: String {
        if store.isImuUnavailable { return "IMU 불가" }
        if store.isImuStale { return "IMU 오래됨" }
        // 5Hz polling × CF filter 가 settling 했으면 "필터링" 표시. 아직 sample 부족하면 "정적".
        return store.imuFilter.sampleCount >= 3 ? "IMU (5Hz CF)" : "IMU (정적)"
    }

    private var imuIcon: String {
        if store.isImuUnavailable { return "exclamationmark.triangle.fill" }
        if store.isImuStale { return "clock.badge.exclamationmark" }
        return "gyroscope"
    }

    /// IMU 값 표시 — filter 가 충분히 settling 했으면 filtered 값, 아니면 accel-only 정적.
    private var imuValueText: String {
        if store.isImuUnavailable { return "—" }
        if store.imuFilter.sampleCount >= 3 {
            // CF filter 적용 후 — 정적보다 약간 안정적.
            return String(format: "R%+.0f° P%+.0f°",
                          store.imuFilter.rollDeg, store.imuFilter.pitchDeg)
        }
        // settling 전 — accel-only fallback.
        guard let imu = store.lastTelemetry?.imu else { return "—" }
        return String(format: "R%+.0f° P%+.0f°", imu.rollDeg, imu.pitchDeg)
    }

    /// roll/pitch 가 ±30° 초과면 danger, ±15° 초과면 warning. stale/unavailable 면 별도 색.
    private var imuTint: Color {
        if store.isImuUnavailable { return DFColor.danger }
        if store.isImuStale { return DFColor.warning }
        let (roll, pitch): (Double, Double) = {
            if store.imuFilter.sampleCount >= 3 {
                return (store.imuFilter.rollDeg, store.imuFilter.pitchDeg)
            }
            return (store.lastTelemetry?.imu?.rollDeg ?? 0,
                    store.lastTelemetry?.imu?.pitchDeg ?? 0)
        }()
        let m = max(abs(roll), abs(pitch))
        if m >= 30 { return DFColor.danger }
        if m >= 15 { return DFColor.warning }
        return DFColor.info
    }

    /// IMU 툴팁 — 필터 상태 + 정적 추정의 한계 + 마지막 통신 시각.
    private var imuTooltip: String {
        var parts: [String] = []
        if store.imuFilter.sampleCount >= 3 {
            parts.append("Mac complementary filter (5Hz, tau=0.5s, alpha≈0.71)")
            parts.append("정적 tilt 보다 약간 안정. 진짜 동적 추적은 v1.6 robot-side loop 필요.")
        } else {
            parts.append("정적 tilt 추정 (accelerometer-only)")
            parts.append("Filter 가 아직 settling 중 (\(store.imuFilter.sampleCount) sample)")
        }
        if let at = store.lastImuSuccessAt {
            let elapsed = Int(Date().timeIntervalSince(at))
            parts.append("마지막 IMU 통신: \(elapsed)초 전")
        }
        if let err = store.lastImuError, store.isImuStale || store.isImuUnavailable {
            parts.append("최근 오류: \(err)")
        }
        if store.isImuUnavailable {
            parts.append("→ CM 보드 IMU register 응답 없음. CM-740 펌웨어 또는 USB·전원 확인.")
        }
        return parts.joined(separator: "\n")
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
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: DFFontSize.s14, weight: .bold))
                VStack(alignment: .leading, spacing: DFSpace.none) {
                    Text("긴급 정지")
                        .font(DFFont.bodyEmph)
                    Text("⌘⇧.")
                        .font(.system(size: DFFontSize.s9, design: .monospaced))
                        .foregroundStyle(.white.opacity(DFOpacity.o85))
                }
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 120, minHeight: DFSize.estop)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.md)
                    .fill(DFColor.danger)
                    .shadow(color: DFColor.danger.opacity(DFOpacity.o45), radius: 8, y: 2)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(".", modifiers: [.command, .shift])
        .help("⌘⇧. — 즉시 토크 OFF + motion cancel")
        .accessibilityLabel("긴급 정지 — ⌘⇧.")
    }

    // MARK: - Metric cell

    private func metricCell(label: String, icon: String, tint: Color, value: String) -> some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: DFFontSize.s14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: DFSpace.none) {
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
