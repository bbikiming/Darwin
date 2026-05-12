import ForgeCore
import SwiftUI

/// 하단 상태바 — 모드, 연결, 배터리, 평균 온도, 단축키 힌트.
public struct StatusBar: View {
    @EnvironmentObject var store: ConnectionStore
    public let telemetry: TelemetrySnapshot?
    public let onCommandPalette: () -> Void
    public let onShowDashboard: () -> Void

    public init(telemetry: TelemetrySnapshot?,
                onCommandPalette: @escaping () -> Void,
                onShowDashboard: @escaping () -> Void = {}) {
        self.telemetry = telemetry
        self.onCommandPalette = onCommandPalette
        self.onShowDashboard = onShowDashboard
    }

    public var body: some View {
        HStack(spacing: DFSpace.md) {
            // 좌측 신호등 회피 (macOS native traffic-light buttons 영역 확보).
            Color.clear.frame(width: 72, height: 1)

            connectionPill
            connectionActions
            Divider().frame(height: 16)
            batteryPill
            Divider().frame(height: 16)
            temperaturePill
            Divider().frame(height: 16)
            torquePill

            Spacer(minLength: 8)

            paletteAndVersion
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm)
        .lineLimit(1)
        .background(.regularMaterial)
        .overlay(
            Rectangle()
                .fill(DFColor.textSecondary.opacity(DFOpacity.o20))
                .frame(height: 0.5),
            alignment: .bottom    // 상단 toolbar → 하단 경계선.
        )
    }

    /// 우측 끝의 명령 팔레트 + 버전 — 좁은 화면에서 명령 팔레트 라벨 숨김.
    @ViewBuilder
    private var paletteAndVersion: some View {
        Button(action: onCommandPalette) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "command")
                Text("K")
            }
            .font(DFFont.caption.monospaced())
            .padding(.horizontal, DFSpace.xs2)
            .padding(.vertical, 2)
            .background(DFColor.elev2)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
        }
        .buttonStyle(.plain)
        .help("명령 팔레트 (⌘K)")

        Text("v\(forgeCoreVersion())")
            .font(DFFont.caption.monospaced())
            .foregroundStyle(DFColor.textSecondary)
            .lineLimit(1)
    }

    private var connectionPill: some View {
        Button(action: onShowDashboard) {
            HStack(spacing: 5) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: DFSize.indicatorSm, height: DFSize.indicatorSm)
                    .shadow(color: connectionColor.opacity(DFOpacity.dim), radius: 3)
                Text(connectionLabel)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, DFSpace.xs2)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(connectionLabel)
        .layoutPriority(1)
    }

    /// 연결됨 상태일 때만 보이는 보조 액션 — 더보기 / 해제.
    @ViewBuilder
    private var connectionActions: some View {
        if isConnected {
            HStack(spacing: DFSpace.xs) {
                Button(action: onShowDashboard) {
                    Image(systemName: "info.circle")
                        .font(.system(size: DFFontSize.s12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DFColor.accent)
                .help("연결 대시보드 (⌘I)")
                .keyboardShortcut("i", modifiers: .command)

                Button(action: { store.disconnect() }) {
                    Image(systemName: "powerplug")
                        .font(.system(size: DFFontSize.s12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DFColor.danger)
                .help("연결 해제")
            }
        }
    }

    private var batteryPill: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: batteryIcon)
                .foregroundStyle(batteryColor)
            Text(batteryText)
                .font(DFFont.caption.monospaced())
        }
    }

    private var temperaturePill: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(temperatureColor)
            Text(temperatureText)
                .font(DFFont.caption.monospaced())
        }
    }

    private var torquePill: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: torqueIcon)
                .foregroundStyle(torqueColor)
            Text(torqueText)
                .font(DFFont.caption.monospaced())
        }
    }

    // MARK: - Status helpers

    private var isConnected: Bool {
        if case .connected = store.status { return true } else { return false }
    }

    private var connectionLabel: String {
        switch store.status {
        case .disconnected:    return "오프라인"
        case .connecting(let p): return "연결 중 — \(URL(fileURLWithPath: p).lastPathComponent)"
        case .connected(let s): return shortenedControllerLabel(s.controllerLabel)
        case .error:           return "연결 오류"
        }
    }

    /// 상태바 폭 절약 — 긴 라벨은 짧게.
    /// "CM-740 (2nd gen / OP2)" → "CM-740"
    /// "Unknown (1793)" → "Unknown"
    private func shortenedControllerLabel(_ s: String) -> String {
        if let paren = s.firstIndex(of: "(") {
            let head = s[..<paren].trimmingCharacters(in: .whitespaces)
            return "연결됨 — \(head)"
        }
        return "연결됨 — \(s)"
    }

    private var connectionColor: Color {
        switch store.status {
        case .connected:    return DFColor.success
        case .connecting:   return DFColor.warning
        case .error:        return DFColor.danger
        case .disconnected: return DFColor.textSecondary.opacity(DFOpacity.dim)
        }
    }

    private var batteryText: String {
        guard let board = telemetry?.board else { return "—.— V" }
        return String(format: "%.1f V", board.voltageVolts)
    }

    private var batteryColor: Color {
        guard let v = telemetry?.board?.voltageVolts else { return DFColor.textSecondary }
        if v >= 11.1 { return DFColor.success }
        if v >= 9.5  { return DFColor.warning }
        return DFColor.danger
    }

    private var batteryIcon: String {
        guard let v = telemetry?.board?.voltageVolts else { return "battery.0percent" }
        if v >= 11.5 { return "battery.100percent" }
        if v >= 10.5 { return "battery.75percent" }
        if v >= 9.5  { return "battery.50percent" }
        if v >= 8.5  { return "battery.25percent" }
        return "battery.0percent"
    }

    private var temperatureText: String {
        guard let t = telemetry?.avgTemperature else { return "—°C" }
        return String(format: "평균 %.0f°C", t)
    }

    private var temperatureColor: Color {
        guard let t = telemetry?.avgTemperature else { return DFColor.textSecondary }
        if t >= 60 { return DFColor.danger }
        if t >= 50 { return DFColor.warning }
        return DFColor.success
    }

    private var torqueOn: Int { telemetry?.torqueOnCount ?? 0 }
    private var torqueText: String {
        if !isConnected { return "토크 —" }
        return "토크 \(torqueOn)/16"
    }
    private var torqueColor: Color {
        if !isConnected { return DFColor.textSecondary }
        return torqueOn > 0 ? DFColor.torque : DFColor.textSecondary.opacity(DFOpacity.o70)
    }
    private var torqueIcon: String {
        torqueOn > 0 ? "bolt.fill" : "bolt.slash"
    }
}
