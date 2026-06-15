import Charts
import ForgeCore
import SwiftUI

// MARK: - HarnessSensorTileGrid
//
// **V289-3** — Few 2006 "Information Dashboard Design" 기반 L2 Primary Tile Grid (2×3).
//
// 비유: 비행기 앞 유리 HUD — 핵심 6개 지표를 한 눈에 파악.
// 기술: 2×3 LazyVGrid + Swift Charts sparkline. Okabe-Ito 색상 (이상치만).
//       Data-ink ratio 극대화 (Tufte 1990) — 축/grid/legend 제거.
//
// 데이터 소스:
//   - IMU:          ConnectionStore.lastImuRaw (roll/pitch)
//   - Gait phase:   WalkLabSession.current + isWalkActive
//   - Active intent: liveEvents 에서 claude.intent_dispatched 종류 최신값
//   - Servo health: liveEvents 에서 servo 관련 온도 임계 카운트 (mock — "—")
//   - CPU/온도:      macOS host (보류 — "—")
//   - 통신 품질:     ConnectionStore.lastRoundTripMs

// MARK: - Okabe-Ito Palette (색맹 안전, ISA-101)

private enum OkabeIto {
    static let vermillion = Color(red: 0.835, green: 0.369, blue: 0.000)   // #D55E00
    static let amber      = Color(red: 0.902, green: 0.624, blue: 0.000)   // #E69F00
    static let bluishGreen = Color(red: 0.000, green: 0.620, blue: 0.451)  // #009E73
}

// MARK: - Tile view model

private struct ImuSample: Identifiable {
    let id: Int
    let rollDeg: Double
    let pitchDeg: Double
}

// MARK: - Root grid

/// 2×3 LazyVGrid with 6 sensor tiles.
/// Reads live data from ConnectionStore + WalkLabSession via @Environment.
public struct HarnessSensorTileGrid: View {
    @EnvironmentObject private var store: ConnectionStore
    @Environment(WalkLabSession.self) private var session: WalkLabSession

    // IMU 30-sample sparkline buffer (1 sample = 1 poll tick ≈ 1 Hz)
    let imuBuffer: [TelemetryEvent]
    // All live events for intent extraction
    let liveEvents: [TelemetryEvent]

    public init(imuBuffer: [TelemetryEvent] = [], liveEvents: [TelemetryEvent] = []) {
        self.imuBuffer = imuBuffer
        self.liveEvents = liveEvents
    }

    private let columns = [
        GridItem(.flexible(), spacing: DFSpace.sm),
        GridItem(.flexible(), spacing: DFSpace.sm),
        GridItem(.flexible(), spacing: DFSpace.sm)
    ]

    public var body: some View {
        LazyVGrid(columns: columns, spacing: DFSpace.sm) {
            // **V289-5** — 각 tile 에 accessibilityLabel 추가 (WCAG 2.2).
            ImuTile(imuRaw: store.lastImuRaw, buffer: imuSamples)
                .accessibilityLabel(imuAccessibilityLabel)
            GaitPhaseTile(preset: session.current, isActive: session.isWalkActive)
                .accessibilityLabel(gaitAccessibilityLabel)
            ActiveIntentTile(event: lastIntentEvent)
                .accessibilityLabel(intentAccessibilityLabel)
            ServoHealthTile(snap: store.lastTelemetry)
                .accessibilityLabel(servoAccessibilityLabel)
            // **V291-5** — Mobile Pilot tile (CPU mock 대체).
            MobilePilotTile(liveEvents: liveEvents)
                .accessibilityLabel(mobilePilotAccessibilityLabel)
            CommQualityTile(rttMs: store.lastRoundTripMs, lossPercent: packetLossPercent)
                .accessibilityLabel(commAccessibilityLabel)
        }
        .padding(.horizontal, DFSpace.sm)
    }

    // MARK: - Accessibility label derivation (V289-5)

    private var imuAccessibilityLabel: String {
        guard let raw = store.lastImuRaw else { return "IMU 자세 — 데이터 없음" }
        let rollStr = HarnessFormat.formatAngle(raw.rollDeg)
        let pitchStr = HarnessFormat.formatAngle(raw.pitchDeg)
        let rollStatus = abs(raw.rollDeg) > 25 ? "이상" : "정상"
        return "IMU 자세 — Roll \(rollStr), Pitch \(pitchStr), \(rollStatus)"
    }

    private var gaitAccessibilityLabel: String {
        let phase: String
        switch session.current {
        case .idle:       phase = "Idle"
        case .march:      phase = "이중 지지 단계"
        case .slowWalk:   phase = "단일 지지 좌"
        case .normalWalk: phase = "단일 지지 우"
        case .fastWalk:   phase = "단일 지지 우 고속"
        case .jog:        phase = "조깅"
        case .turnLeft:   phase = "좌회전"
        case .turnRight:  phase = "우회전"
        }
        let activeStr = session.isWalkActive ? "보행 중" : "정지"
        return "보행 단계 — \(phase), \(activeStr)"
    }

    private var intentAccessibilityLabel: String {
        guard let ev = lastIntentEvent,
              let tool = ev.d.raw["tool"]?.value as? String else {
            return "활성 명령 — 없음"
        }
        return "활성 명령 — \(tool)"
    }

    private var servoAccessibilityLabel: String {
        guard let joints = store.lastTelemetry?.joints, !joints.isEmpty else {
            return "서보 건강 — 데이터 없음"
        }
        let abnormal = joints.values.filter { $0.presentTemperature >= 75 }.count
        let normal = 20 - abnormal
        return "서보 건강 — 20개 중 \(normal)개 정상"
    }

    private var commAccessibilityLabel: String {
        let rttStr = store.lastRoundTripMs.map { HarnessFormat.formatLatency($0) } ?? "—"
        let lossStr = packetLossPercent.map { HarnessFormat.formatPacketLoss($0) } ?? "—"
        return "통신 품질 — RTT \(rttStr), 손실 \(lossStr)"
    }

    private var mobilePilotAccessibilityLabel: String {
        let hasPaired = liveEvents.last { $0.k == .mobilePilotPairingSuccess } != nil
        let deviceName = liveEvents.last { $0.k == .mobilePilotPairingSuccess }
            .flatMap { $0.d.raw["deviceName"]?.value as? String } ?? "—"
        if hasPaired {
            return "Mobile Pilot — 연결됨, 기기: \(deviceName)"
        }
        return "Mobile Pilot — 대기 중"
    }

    // MARK: - Derived values

    private var imuSamples: [ImuSample] {
        // Use last 30 imu-kind events from buffer
        let imuEvents = imuBuffer
            .filter { $0.k.namespace == "imu" }
            .suffix(30)
        return imuEvents.enumerated().map { idx, ev in
            let roll = (ev.d.raw["roll_deg"]?.value as? Double) ?? 0
            let pitch = (ev.d.raw["pitch_deg"]?.value as? Double) ?? 0
            return ImuSample(id: idx, rollDeg: roll, pitchDeg: pitch)
        }
    }

    private var lastIntentEvent: TelemetryEvent? {
        liveEvents.last { $0.k == .claudeIntentDispatched }
    }

    // Packet loss: fraction of bus.read_fail among recent 30 events
    private var packetLossPercent: Double? {
        let recent = liveEvents.suffix(30)
        guard !recent.isEmpty else { return nil }
        let failures = recent.filter { $0.k == .busReadFail }.count
        return Double(failures) / Double(recent.count) * 100
    }
}

// MARK: - Tile 1: IMU

private struct ImuTile: View {
    let imuRaw: ImuRaw?
    let buffer: [ImuSample]

    var body: some View {
        TileCard(label: "IMU 자세 (관성 측정)") {
            if let raw = imuRaw {
                VStack(alignment: .leading, spacing: DFSpace.xs2) {
                    HStack(alignment: .firstTextBaseline, spacing: DFSpace.xs) {
                        bigNumber(HarnessFormat.formatAngle(raw.rollDeg), color: rollColor)
                        Text("Roll (좌우 기울기)").font(DFFont.label).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: DFSpace.xs) {
                        bigNumber(HarnessFormat.formatAngle(raw.pitchDeg), color: pitchColor)
                        Text("Pitch (앞뒤 기울기)").font(DFFont.label).foregroundStyle(.secondary)
                    }
                    if !buffer.isEmpty {
                        sparkline
                    }
                }
            } else {
                Text(HarnessFormat.EmptyState.noSensorData)
                    .font(DFFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var rollColor: Color {
        guard let r = imuRaw else { return .secondary }
        return abs(r.rollDeg) > 25 ? OkabeIto.vermillion : .primary
    }

    private var pitchColor: Color {
        guard let p = imuRaw else { return .secondary }
        return abs(p.pitchDeg) > 25 ? OkabeIto.vermillion : .primary
    }

    private var sparkline: some View {
        Chart {
            ForEach(buffer) { s in
                LineMark(
                    x: .value("t", s.id),
                    y: .value("roll", s.rollDeg),
                    series: .value("ch", "R")
                )
                .foregroundStyle(OkabeIto.bluishGreen)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                LineMark(
                    x: .value("t", s.id),
                    y: .value("pitch", s.pitchDeg),
                    series: .value("ch", "P")
                )
                .foregroundStyle(OkabeIto.amber)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 32)
    }

    private func bigNumber(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
    }
}

// MARK: - Tile 2: Gait Phase

private struct GaitPhaseTile: View {
    let preset: WalkLabPreset
    let isActive: Bool

    var body: some View {
        TileCard(label: "보행 단계") {
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                Text(phaseLabel)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(phaseColor)
                    .padding(.horizontal, DFSpace.xs)
                    .padding(.vertical, DFSpace.micro)
                    .background(phaseColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text(isActive ? "보행 중" : "정지")
                    .font(DFFont.label)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var phaseLabel: String {
        switch preset {
        case .idle:       return "Idle"
        case .march:      return "DSP"
        case .slowWalk:   return "SSP-L"
        case .normalWalk: return "SSP-R"
        case .fastWalk:   return "SSP-R"
        case .jog:        return "SSP-R"
        case .turnLeft:   return "SSP-L"
        case .turnRight:  return "SSP-R"
        }
    }

    private var phaseColor: Color {
        guard isActive else { return .secondary }
        switch preset {
        case .idle:       return .secondary
        case .march:      return OkabeIto.bluishGreen
        default:          return OkabeIto.amber
        }
    }
}

// MARK: - Tile 3: Active Intent

private struct ActiveIntentTile: View {
    let event: TelemetryEvent?

    var body: some View {
        TileCard(label: "활성 명령") {
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                Text(toolLabel)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(ageLabel)
                    .font(DFFont.label)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var toolLabel: String {
        guard let ev = event,
              let tool = ev.d.raw["tool"]?.value as? String else {
            return "—"
        }
        return tool
    }

    private var ageLabel: String {
        guard let ev = event else { return "—" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: ev.tw) else { return "—" }
        let dt = Date().timeIntervalSince(d)
        if dt < 60 { return String(format: "%.1f초 전", dt) }
        return String(format: "%.0f분 전", dt / 60)
    }
}

// MARK: - Tile 4: Servo Health

private struct ServoHealthTile: View {
    let snap: TelemetrySnapshot?

    private static let warnThreshold: UInt8 = 75
    private static let critThreshold: UInt8 = 90
    private static let totalServos = 20

    var body: some View {
        TileCard(label: "서보 건강") {
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(normalLabel)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(normalColor)
                    Text("/ \(Self.totalServos) 정상")
                        .font(DFFont.label)
                        .foregroundStyle(.secondary)
                }
                ForEach(hotChips, id: \.0) { name, temp in
                    Text("\(name) \(HarnessFormat.formatTemp(Double(temp)))")
                        .font(DFFont.label)
                        .foregroundStyle(OkabeIto.vermillion)
                        .padding(.horizontal, DFSpace.xs)
                        .padding(.vertical, DFSpace.micro2)
                        .background(OkabeIto.vermillion.opacity(0.10),
                                    in: Capsule())
                }
                // V290-B: 서보 온도 분포 mini bar chart (40pt 높이)
                // Tufte data-ink ratio: 축/grid/legend 모두 hidden
                // ISA-101: 정상 grayscale, warn(75+) amber, crit(90+) vermillion
                if !tempBars.isEmpty {
                    Chart {
                        ForEach(tempBars, id: \.id) { bar in
                            BarMark(
                                x: .value("ID", bar.id),
                                y: .value("Temp", bar.temp)
                            )
                            .foregroundStyle(bar.color)
                        }
                        // 임계선: warn 75°C (amber)
                        RuleMark(y: .value("warn", 75))
                            .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
                            .foregroundStyle(OkabeIto.amber.opacity(0.7))
                        // 임계선: crit 90°C (vermillion)
                        RuleMark(y: .value("crit", 90))
                            .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
                            .foregroundStyle(OkabeIto.vermillion.opacity(0.7))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartLegend(.hidden)
                    .chartYScale(domain: 0...100)
                    .frame(height: 40)
                }
            }
        }
    }

    // MARK: - Bar chart data model

    private struct TempBar {
        let id: Int       // 1-based servo index (x-axis)
        let temp: Double  // 온도 °C (y-axis)
        let color: Color
    }

    /// 모든 joint 를 ID 순으로 정렬해 bar chart 데이터 생성.
    private var tempBars: [TempBar] {
        guard let joints = snap?.joints, !joints.isEmpty else { return [] }
        return joints
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .enumerated()
            .map { idx, pair in
                let temp = Double(pair.value.presentTemperature)
                let color: Color
                if temp >= Double(Self.critThreshold) {
                    color = OkabeIto.vermillion
                } else if temp >= Double(Self.warnThreshold) {
                    color = OkabeIto.amber
                } else {
                    color = Color.secondary.opacity(0.5)
                }
                return TempBar(id: idx + 1, temp: temp, color: color)
            }
    }

    // MARK: - Existing helpers (unchanged)

    private var normalLabel: String {
        guard let joints = snap?.joints, !joints.isEmpty else { return "—" }
        let abnormal = joints.values.filter {
            $0.presentTemperature >= Self.warnThreshold
        }.count
        return "\(Self.totalServos - abnormal)"
    }

    private var normalColor: Color {
        guard let joints = snap?.joints, !joints.isEmpty else { return .secondary }
        let crit = joints.values.filter {
            $0.presentTemperature >= Self.critThreshold
        }
        if !crit.isEmpty { return OkabeIto.vermillion }
        let warn = joints.values.filter {
            $0.presentTemperature >= Self.warnThreshold
        }
        // **V289-7 critic MAJOR-1 fix** — ISA-101 §8.4 위반 회피.
        // 녹색은 "동작 중" 의미로 예약 (정상≠색). 정상 servo health 는 grayscale.
        return warn.isEmpty ? Color.primary : OkabeIto.amber
    }

    private var hotChips: [(String, UInt8)] {
        guard let joints = snap?.joints else { return [] }
        return joints
            .filter { $0.value.presentTemperature >= Self.warnThreshold }
            .sorted { $0.value.presentTemperature > $1.value.presentTemperature }
            .prefix(2)
            .map { (KoreanUX.JointName.from(rawId: Int($0.key.rawValue)), $0.value.presentTemperature) }
    }
}

// MARK: - Tile 5: Mobile Pilot Status (V291-5, CPU mock 대체)

/// Mobile Pilot 릴레이 상태 tile.
/// liveEvents 에서 mobile_pilot.* 이벤트를 필터링해 현재 상태를 표시.
///
/// ISA-101: grayscale (꺼짐) / amber (대기) / vermillion (거부/watchdog)
private struct MobilePilotTile: View {
    let liveEvents: [TelemetryEvent]

    var body: some View {
        TileCard(label: "Mobile Pilot") {
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                HStack(spacing: DFSpace.xs) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusLabel)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(statusColor)
                }
                if let name = activeDeviceName {
                    Text(name)
                        .font(DFFont.label)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let cmd = lastCommandLabel {
                    Text(cmd)
                        .font(DFFont.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if recentPairingAttempts > 0 {
                    Text("페어링 시도 \(recentPairingAttempts)회")
                        .font(DFFont.label)
                        .foregroundStyle(recentPairingAttempts >= 3 ? OkabeIto.vermillion : OkabeIto.amber)
                }
            }
        }
    }

    // MARK: - Derived state from liveEvents

    private var lastPairingSuccessEvent: TelemetryEvent? {
        liveEvents.last { $0.k == .mobilePilotPairingSuccess }
    }

    private var lastDisconnectedEvent: TelemetryEvent? {
        liveEvents.last { $0.k == .mobilePilotDisconnected || $0.k == .mobilePilotWatchdogStop }
    }

    /// pairing_success 이후 disconnect 가 없으면 연결됨.
    private var isConnected: Bool {
        guard let pairEv = lastPairingSuccessEvent else { return false }
        if let discEv = lastDisconnectedEvent {
            return pairEv.i > discEv.i   // seq 비교: pairing 이 disconnect 보다 최신
        }
        return true
    }

    private var activeDeviceName: String? {
        guard isConnected, let ev = lastPairingSuccessEvent else { return nil }
        return ev.d.raw["deviceName"]?.value as? String
    }

    private var statusLabel: String {
        if isConnected { return "연결됨" }
        if liveEvents.contains(where: { $0.k == .mobilePilotPairingSuccess }) { return "대기" }
        return "꺼짐"
    }

    private var statusColor: Color {
        if isConnected { return OkabeIto.bluishGreen }
        if liveEvents.contains(where: { $0.k == .mobilePilotWatchdogStop }) { return OkabeIto.vermillion }
        if liveEvents.contains(where: { $0.k == .mobilePilotPairingRejected }) { return OkabeIto.amber }
        return .secondary
    }

    private var lastCommandLabel: String? {
        let commandEvents = liveEvents.filter {
            $0.k == .mobilePilotCommandAccepted || $0.k == .mobilePilotCommandRejected
        }
        guard let ev = commandEvents.last else { return nil }
        let type = ev.d.raw["commandType"]?.value as? String ?? "?"
        let verb = ev.k == .mobilePilotCommandAccepted ? "✓" : "✗"
        return "\(verb) \(type)"
    }

    /// 최근 5분 내 pairing 이벤트 횟수 (success + rejected 합산).
    private var recentPairingAttempts: Int {
        let cutoff = Date().addingTimeInterval(-300)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return liveEvents.filter { ev in
            guard ev.k == .mobilePilotPairingSuccess || ev.k == .mobilePilotPairingRejected,
                  let d = isoFormatter.date(from: ev.tw) else { return false }
            return d > cutoff
        }.count
    }
}

// MARK: - Tile 6: Comm Quality

private struct CommQualityTile: View {
    let rttMs: Double?
    let lossPercent: Double?

    var body: some View {
        TileCard(label: "통신 품질") {
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(rttMs.map { HarnessFormat.formatLatency($0) } ?? "—")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(rttColor)
                    Text("RTT (왕복 지연)")
                        .font(DFFont.label)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(lossPercent.map { HarnessFormat.formatPacketLoss($0) } ?? "—")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(lossColor)
                    Text("손실")
                        .font(DFFont.label)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var rttColor: Color {
        guard let ms = rttMs else { return .secondary }
        if ms > 100 { return OkabeIto.vermillion }
        if ms > 50  { return OkabeIto.amber }
        return .primary
    }

    private var lossColor: Color {
        guard let pct = lossPercent else { return .secondary }
        if pct > 5 { return OkabeIto.vermillion }
        if pct > 1 { return OkabeIto.amber }
        return .secondary
    }
}

// MARK: - TileCard container

private struct TileCard<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text(label)
                .font(DFFont.label)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(DFSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.card, in: RoundedRectangle(cornerRadius: 8))
    }
}
