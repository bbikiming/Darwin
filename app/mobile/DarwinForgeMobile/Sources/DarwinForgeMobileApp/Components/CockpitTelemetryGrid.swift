import SwiftUI
import MobilePilotKit

/// **풍부한 텔레메트리 그리드** — TelemetryStatePayload 의 11 개 필드를 모두 카드로 표시.
///
/// # 표시 필드 (각 카드)
///
/// 행 1 (연결/상태):
///   - Mac 연결 (MacConnectionState)
///   - Robot 연결 (RobotConnectionState + endpoint)
///   - Safety 상태 (SafetyState)
///   - Pilot UI 상태 (PilotUIState)
///
/// 행 2 (하드웨어):
///   - 배터리 전압 (V) + low banner
///   - 최대 모터 온도 (℃) + hot banner
///   - DXL Power (on/off)
///   - ARM 상태
///
/// 행 3 (성능):
///   - 통신 지연 (ms)
///   - 마지막 ACK age (ms)
///   - Mini sparkline (지연 추세) — telemetryHistory 가 있으면
///
/// Mac Cockpit 의 status block + attitude indicator + DJI panel 의 정보를 한 곳에 압축.
/// 한국어 라벨, 상태별 색상 (success/warning/danger).
public struct CockpitTelemetryGrid: View {

    public let telemetry: TelemetryStatePayload?
    public let history: [LatencySample]
    public let macConnected: Bool
    public let pilotStateLabel: String

    public struct LatencySample: Identifiable {
        public let id: UUID
        public let latencyMs: Int

        public init(id: UUID = UUID(), latencyMs: Int) {
            self.id = id
            self.latencyMs = latencyMs
        }
    }

    public init(telemetry: TelemetryStatePayload?,
                history: [LatencySample] = [],
                macConnected: Bool,
                pilotStateLabel: String) {
        self.telemetry = telemetry
        self.history = history
        self.macConnected = macConnected
        self.pilotStateLabel = pilotStateLabel
    }

    public var body: some View {
        DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                header
                connectivityRow
                hardwareRow
                performanceRow
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Label("텔레메트리", systemImage: "antenna.radiowaves.left.and.right")
                .font(DS.Font.captionEmphasis)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer()
            Text(telemetry == nil ? "대기 중" : "수신 중")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    (telemetry == nil ? DS.Color.tertiaryText : DS.Color.success).opacity(0.18),
                    in: Capsule())
                .foregroundStyle(telemetry == nil ? DS.Color.tertiaryText : DS.Color.success)
        }
    }

    private var connectivityRow: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            cell(label: "Mac",
                 value: macStatusText,
                 tint: macStatusTint,
                 icon: "macbook")
            cell(label: "Robot",
                 value: robotStatusText,
                 tint: robotStatusTint,
                 icon: "figure.walk")
            cell(label: "Safety",
                 value: safetyText,
                 tint: safetyTint,
                 icon: "shield.lefthalf.filled")
            cell(label: "조종",
                 value: pilotStateLabel,
                 tint: DS.Color.info,
                 icon: "gamecontroller")
        }
    }

    private var hardwareRow: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            cell(label: "전압",
                 value: batteryText,
                 tint: batteryTint,
                 icon: "battery.100")
            cell(label: "온도",
                 value: tempText,
                 tint: tempTint,
                 icon: "thermometer.medium")
            cell(label: "DXL 전원",
                 value: dxlText,
                 tint: dxlTint,
                 icon: "bolt.fill")
            cell(label: "잠금 해제",
                 value: armedText,
                 tint: armedTint,
                 icon: "lock.open.fill")
        }
    }

    private var performanceRow: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            cell(label: "지연",
                 value: latencyText,
                 tint: latencyTint,
                 icon: "clock.fill")
            cell(label: "ACK age",
                 value: ackAgeText,
                 tint: ackAgeTint,
                 icon: "checkmark.seal")
            if !history.isEmpty {
                latencySparkline
            } else {
                Spacer()
            }
        }
    }

    // MARK: - Cell

    private func cell(label: String, value: String, tint: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Color.tertiaryText)
            }
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.xs))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.xs)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Sparkline (지연 추세)

    private var latencySparkline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("지연 추세")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DS.Color.tertiaryText)
            Canvas { ctx, size in
                drawSparkline(ctx: ctx, size: size)
            }
            .frame(width: 80, height: 30)
        }
        .padding(.vertical, 4)
    }

    private func drawSparkline(ctx: GraphicsContext, size: CGSize) {
        guard history.count >= 2 else { return }
        let maxV = max(history.map { Double($0.latencyMs) }.max() ?? 1, 1)
        let stepX = size.width / CGFloat(max(history.count - 1, 1))
        var path = Path()
        for (i, sample) in history.enumerated() {
            let x = CGFloat(i) * stepX
            let y = size.height - (CGFloat(sample.latencyMs) / CGFloat(maxV)) * size.height
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(path, with: .color(DS.Color.brand), lineWidth: 1.2)
    }

    // MARK: - Field text/tint derivations

    private var macStatusText: String {
        guard let t = telemetry else {
            return macConnected ? "연결" : "—"
        }
        switch t.mac {
        case .connected: return "연결"
        case .searching: return "탐색"
        case .lost: return "끊김"
        }
    }
    private var macStatusTint: Color {
        guard let t = telemetry else { return macConnected ? DS.Color.success : DS.Color.tertiaryText }
        switch t.mac {
        case .connected: return DS.Color.success
        case .searching: return DS.Color.info
        case .lost: return DS.Color.danger
        }
    }

    private var robotStatusText: String {
        guard let t = telemetry else { return "—" }
        switch t.robot {
        case .connected: return "연결"
        case .sim: return "SIM"
        case .stale: return "stale"
        case .busBusy: return "BUS busy"
        case .disconnected: return "끊김"
        case .estopped: return "E-STOP"
        }
    }
    private var robotStatusTint: Color {
        guard let t = telemetry else { return DS.Color.tertiaryText }
        switch t.robot {
        case .connected: return DS.Color.success
        case .sim: return DS.Color.info
        case .stale, .busBusy: return DS.Color.warning
        case .disconnected: return DS.Color.tertiaryText
        case .estopped: return DS.Color.danger
        }
    }

    private var safetyText: String {
        guard let t = telemetry else { return "—" }
        switch t.safety {
        case .ready: return "준비"
        case .arming: return "ARM 중"
        case .degraded: return "저하"
        case .estopped: return "E-STOP"
        }
    }
    private var safetyTint: Color {
        guard let t = telemetry else { return DS.Color.tertiaryText }
        switch t.safety {
        case .ready: return DS.Color.success
        case .arming: return DS.Color.info
        case .degraded: return DS.Color.warning
        case .estopped: return DS.Color.danger
        }
    }

    private var batteryText: String {
        guard let v = telemetry?.batteryV else { return "—" }
        return String(format: "%.1f V", v)
    }
    private var batteryTint: Color {
        guard let v = telemetry?.batteryV else { return DS.Color.tertiaryText }
        if v < 10.5 { return DS.Color.danger }
        if v < 11.0 { return DS.Color.warning }
        return DS.Color.success
    }

    private var tempText: String {
        guard let v = telemetry?.maxTempC else { return "—" }
        return String(format: "%.0f℃", v)
    }
    private var tempTint: Color {
        guard let v = telemetry?.maxTempC else { return DS.Color.tertiaryText }
        if v > 70 { return DS.Color.danger }
        if v > 60 { return DS.Color.warning }
        return DS.Color.success
    }

    private var dxlText: String {
        guard let t = telemetry else { return "—" }
        return t.dxlPower ? "ON" : "OFF"
    }
    private var dxlTint: Color {
        guard let t = telemetry else { return DS.Color.tertiaryText }
        return t.dxlPower ? DS.Color.success : DS.Color.warning
    }

    private var armedText: String {
        guard let t = telemetry else { return "—" }
        return t.armed ? "해제됨" : "잠금"
    }
    private var armedTint: Color {
        guard let t = telemetry else { return DS.Color.tertiaryText }
        return t.armed ? DS.Color.success : DS.Color.tertiaryText
    }

    private var latencyText: String {
        guard let t = telemetry else { return "—" }
        return "\(t.latencyMs) ms"
    }
    private var latencyTint: Color {
        guard let t = telemetry else { return DS.Color.tertiaryText }
        if t.latencyMs > 200 { return DS.Color.danger }
        if t.latencyMs > 80 { return DS.Color.warning }
        return DS.Color.success
    }

    private var ackAgeText: String {
        guard let ms = telemetry?.lastAckAgeMs else { return "—" }
        return "\(ms) ms"
    }
    private var ackAgeTint: Color {
        guard let ms = telemetry?.lastAckAgeMs else { return DS.Color.tertiaryText }
        if ms > 1000 { return DS.Color.danger }
        if ms > 400 { return DS.Color.warning }
        return DS.Color.success
    }
}
