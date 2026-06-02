import ForgeCore
import SwiftUI

// MARK: - HarnessTopStatusBar (V289-2, 2026-05-25)
//
// 비유: 비행기 PFD(Primary Flight Display)의 critical alert strip — 조종사는 화면 상단
// 고정 띠에서 비상 경보·연료·속도·자세를 항상 확인한다. 본 뷰는 그 원리를 Darwin
// Inspector 에 적용: 운영자가 어느 탭에 있든 5개 핵심 지표를 즉시 인식할 수 있다.
//
// 기술: Endsley Situation Awareness Level 1 (지각) 보장 — 색·아이콘·위치 3중
// redundant encoding. ISA-101.01-2015 §8.4 준수: 정상은 grayscale, 임계 위반만
// Okabe-Ito CVD-safe 색상 사용 (vermillion #D55E00 = 긴급, amber #E69F00 = 경고).
// 녹색 금지 — ISA-101 "녹색=동작 중" 규약 충돌 방지.
//
// 데이터 바인딩:
//   - E-Stop: `ConnectionStore.isDxlPowerOn` false + `emergencyStop()` 이력으로 감지
//   - dxlPower: `ConnectionStore.isDxlPowerOn`
//   - 배터리: `ConnectionStore.lastTelemetry?.board?.voltageVolts`
//   - 통신 지연: `ConnectionStore.lastRoundTripMs`
//   - 낙상 위험: `ConnectionStore.walkSession?.stabilityScore`
//
// 레이아웃: 48pt 고정 높이 (macOS toolbar 표준), 5 cell HStack (equalSize divider).

@MainActor
public struct HarnessTopStatusBar: View {

    @EnvironmentObject private var store: ConnectionStore

    // 낙상 위험 sparkline 용 — 마지막 30s 점수 (최대 30 sample, 1Hz 가정)
    @State private var riskHistory: [Double] = []
    // V290-B: 배터리 voltage 30s sparkline buffer
    @State private var voltageHistory: [Double] = []
    // V290-B: 통신 지연 RTT 30s sparkline buffer
    @State private var latencyHistory: [Double] = []
    @State private var timer: Timer?

    // MARK: - 임계값 상수 (ISA-101 §8.5 "threshold must be named")

    /// 배터리 위험 임계 V (amber). 로보티스 MX-28 절전: 11.1V / 3S LiPo 3.7V × 3.
    private static let voltageWarnV: Double = 11.5
    /// 배터리 긴급 임계 V (vermillion). 11.0V 이하 = 모터 토크 강하 시작.
    private static let voltageCritV: Double = 11.1
    /// 통신 지연 경고 임계 ms (amber). 10ms 초과 = 제어 루프 latency 허용치.
    private static let latencyWarnMs: Double = 10.0
    /// 통신 지연 긴급 임계 ms (vermillion). 20ms 초과 = 실시간 보행 제어 불안정.
    private static let latencyCritMs: Double = 20.0
    /// 낙상 위험 경고 임계 (amber). WalkStabilityPredictor: 30..60 = caution.
    private static let fallWarnScore: Double = 30.0
    /// 낙상 위험 긴급 임계 (vermillion). WalkStabilityPredictor: 60+ = highRisk.
    private static let fallCritScore: Double = 60.0

    // MARK: - Okabe-Ito CVD-safe 색상 토큰

    /// Okabe-Ito vermillion — 긴급/차단. #D55E00.
    private static let colorCrit = Color(red: 0.835, green: 0.369, blue: 0.0)
    /// Okabe-Ito amber — 경고/주의. #E69F00.
    private static let colorWarn = Color(red: 0.902, green: 0.624, blue: 0.0)
    /// ISA-101 정상 — grayscale dot (색 없음).
    private static let colorNorm = Color.secondary

    public init() {}

    // MARK: - Body

    public var body: some View {
        HStack(spacing: 0) {
            eStopCell
            divider
            dxlPowerCell
            divider
            batteryCell
            divider
            latencyCell
            divider
            fallRiskCell
            divider
            // **V289-5** — 설정 메뉴 (gear icon). 라이브 알림 토글 포함.
            settingsMenu
        }
        .frame(height: 48)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.primary.opacity(0.08)),
            alignment: .bottom
        )
        .onAppear {
            startTimer()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - Settings Menu (V289-5)

    /// 우측 끝 gear 아이콘 메뉴 — 라이브 알림 토스트 토글 등 설정 노출.
    private var settingsMenu: some View {
        Menu {
            Toggle(
                "라이브 알림 토스트",
                isOn: Binding(
                    get: { HarnessLiveAlerts.shared.toastEnabled },
                    set: { HarnessLiveAlerts.shared.toastEnabled = $0 }
                )
            )
            .help("임계 초과 시 macOS 알림 토스트를 표시합니다.")
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 44, height: 48)
        .accessibilityLabel("Harness 설정")
    }

    // MARK: - Cell: E-Stop

    private var eStopCell: some View {
        let active = eStopActive
        return StatusCell(
            icon: active ? "exclamationmark.triangle.fill" : "checkmark.circle",
            label: SensorLabel.eStop.shortLabel,
            value: active ? "활성" : "정상",
            dotColor: active ? Self.colorCrit : Self.colorNorm,
            valueColor: active ? Self.colorCrit : .primary
        )
        .help(SensorLabel.eStop.tooltip)
        .accessibilityLabel(active ? "\(SensorLabel.eStop.displayName) 활성" : "\(SensorLabel.eStop.displayName) 정상")
    }

    /// E-Stop 활성 여부 — dxlPower OFF + walk 세션 eStop 으로 감지.
    private var eStopActive: Bool {
        // WalkLabSession 의 emergencyStopActive 가 직접 노출되지 않으므로
        // dxlPower=OFF 를 프록시로 사용. (V283-4: eStop 발동 시 isDxlPowerOn=false)
        guard case .connected = store.status else { return false }
        return !store.isDxlPowerOn && store.bus != nil
    }

    // MARK: - Cell: dxlPower

    private var dxlPowerCell: some View {
        let on = store.isDxlPowerOn
        let connected = { if case .connected = store.status { return true }; return false }()
        let dotColor: Color
        let valueStr: String
        if !connected {
            dotColor = Self.colorNorm
            valueStr = "—"
        } else {
            dotColor = on ? Self.colorNorm : Self.colorWarn
            valueStr = on ? "ON" : "OFF"
        }
        return StatusCell(
            icon: on ? "bolt.fill" : "bolt.slash",
            label: SensorLabel.dxlPower.shortLabel,
            value: valueStr,
            dotColor: dotColor,
            valueColor: (connected && !on) ? Self.colorWarn : .primary
        )
        .help(SensorLabel.dxlPower.tooltip)
        .accessibilityLabel(connected ? "DXL 전원 \(valueStr)" : "DXL 전원 \(HarnessFormat.ConnectionStatus.disconnected.rawValue)")
    }

    // MARK: - Cell: Battery

    private var batteryCell: some View {
        let voltOpt = store.lastTelemetry?.board?.voltageVolts
        let (voltStr, minuteStr, dotColor, valColor) = batteryDisplay(voltOpt)
        // **V289-5** — accessibilityLabel: 동적 전압 + 추정 시간.
        let a11yLabel: String = {
            guard let _ = voltOpt else { return "배터리 데이터 없음" }
            let minPart = minuteStr.isEmpty ? "" : ", 추정 \(minuteStr) 남음"
            return "배터리 \(voltStr)\(minPart)"
        }()
        return BatteryCell(
            icon: batteryIcon(voltOpt),
            voltStr: voltStr,
            minuteStr: minuteStr,
            dotColor: dotColor,
            valColor: valColor,
            sparkHistory: voltageHistory
        )
        .accessibilityLabel(a11yLabel)
    }

    private func batteryDisplay(_ volt: Double?) -> (String, String, Color, Color) {
        guard let v = volt else {
            return ("—", "", Self.colorNorm, .primary)
        }
        let dotColor: Color
        let valColor: Color
        if v <= Self.voltageCritV {
            dotColor = Self.colorCrit; valColor = Self.colorCrit
        } else if v <= Self.voltageWarnV {
            dotColor = Self.colorWarn; valColor = Self.colorWarn
        } else {
            dotColor = Self.colorNorm; valColor = .primary
        }
        let voltStr = HarnessFormat.formatVoltage(v)
        // Level 3 SA: 잔여 시간 추정 (선형: 11.1V=0min ~ 12.6V=60min)
        let minutes = max(0, (v - 11.1) / (12.6 - 11.1) * 60.0)
        let minuteStr = minutes < 1 ? "<1분" : "~\(Int(minutes))분"
        return (voltStr, minuteStr, dotColor, valColor)
    }

    private func batteryIcon(_ volt: Double?) -> String {
        guard let v = volt else { return "battery.0percent" }
        switch v {
        case ...11.1: return "battery.0percent"
        case ...11.5: return "battery.25percent"
        case ...12.0: return "battery.50percent"
        case ...12.3: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }

    // MARK: - Cell: Latency

    private var latencyCell: some View {
        let ms = store.lastRoundTripMs
        let (msStr, dotColor, valColor) = latencyDisplay(ms)
        return LatencyCell(
            msStr: msStr,
            dotColor: dotColor,
            valColor: valColor,
            sparkHistory: latencyHistory
        )
        .help(SensorLabel.rtt.tooltip)
        .accessibilityLabel("통신 지연 (RTT) \(msStr)")
    }

    private func latencyDisplay(_ ms: Double?) -> (String, Color, Color) {
        guard let v = ms else { return ("—", Self.colorNorm, .primary) }
        let dotColor: Color
        let valColor: Color
        if v >= Self.latencyCritMs {
            dotColor = Self.colorCrit; valColor = Self.colorCrit
        } else if v >= Self.latencyWarnMs {
            dotColor = Self.colorWarn; valColor = Self.colorWarn
        } else {
            dotColor = Self.colorNorm; valColor = .primary
        }
        return (HarnessFormat.formatLatency(v), dotColor, valColor)
    }

    // MARK: - Cell: Fall Risk

    private var fallRiskCell: some View {
        let score = currentFallScore
        let (scoreStr, dotColor, valColor) = fallDisplay(score)
        // **V289-5** — accessibilityLabel: 동적 낙상 위험 점수.
        let a11yLabel: String = {
            guard let s = score else { return "낙상 위험 데이터 없음" }
            let level: String
            if s >= Self.fallCritScore { level = "긴급" }
            else if s >= Self.fallWarnScore { level = "경고" }
            else { level = "정상" }
            return "낙상 위험 점수 \(scoreStr), \(level)"
        }()
        return FallRiskCell(
            score: score,
            scoreStr: scoreStr,
            history: riskHistory,
            dotColor: dotColor,
            valColor: valColor
        )
        .accessibilityLabel(a11yLabel)
    }

    private var currentFallScore: Double? {
        store.walkSession?.stabilityScore.score
    }

    private func fallDisplay(_ score: Double?) -> (String, Color, Color) {
        guard let s = score else { return ("—", Self.colorNorm, .primary) }
        let dotColor: Color
        let valColor: Color
        if s >= Self.fallCritScore {
            dotColor = Self.colorCrit; valColor = Self.colorCrit
        } else if s >= Self.fallWarnScore {
            dotColor = Self.colorWarn; valColor = Self.colorWarn
        } else {
            dotColor = Self.colorNorm; valColor = .primary
        }
        return (String(format: "%.0f", s), dotColor, valColor)
    }

    // MARK: - Timer (sparkline 갱신)

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] _ in
            Task { @MainActor in
                appendFallScore()
                appendVoltage()
                appendLatency()
            }
        }
    }

    private func appendFallScore() {
        guard let s = currentFallScore else { return }
        riskHistory.append(s)
        // 최대 30 sample (30s) 유지
        if riskHistory.count > 30 {
            riskHistory = Array(riskHistory.dropFirst(riskHistory.count - 30))
        }
    }

    // V290-B: 배터리 voltage 30s rolling buffer append
    private func appendVoltage() {
        guard let v = store.lastTelemetry?.board?.voltageVolts else { return }
        voltageHistory.append(v)
        if voltageHistory.count > 30 {
            voltageHistory = Array(voltageHistory.dropFirst(voltageHistory.count - 30))
        }
    }

    // V290-B: 통신 지연 RTT 30s rolling buffer append
    private func appendLatency() {
        guard let ms = store.lastRoundTripMs else { return }
        latencyHistory.append(ms)
        if latencyHistory.count > 30 {
            latencyHistory = Array(latencyHistory.dropFirst(latencyHistory.count - 30))
        }
    }

    // MARK: - Divider

    private var divider: some View {
        Rectangle()
            .frame(width: 1)
            .foregroundStyle(Color.primary.opacity(0.08))
            .padding(.vertical, DFSpace.sm)
    }
}

// MARK: - StatusCell (generic 5-cell 기본 레이아웃)

/// 상단 상태바의 단일 셀 — dot + 아이콘 + label + value 의 표준 레이아웃.
struct StatusCell: View {
    let icon: String
    let label: String
    let value: String
    let dotColor: Color
    let valueColor: Color

    var body: some View {
        HStack(spacing: DFSpace.xs) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DFSpace.micro2) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(dotColor)
                    Text(label)
                        .font(DFFont.label)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(valueColor)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DFSpace.sm)
    }
}

// MARK: - BatteryCell (voltage + 추정 시간 2줄 + 30s sparkline)

/// 배터리 셀 — big number (voltage) + 잔여 시간 추정 (Endsley SA Level 3) + 30s sparkline.
/// V290-B: sparkHistory 는 원시 voltage 값(V). yMin=10.5, yMax=13.0 으로 정규화.
private struct BatteryCell: View {
    let icon: String
    let voltStr: String
    let minuteStr: String
    let dotColor: Color
    let valColor: Color
    var sparkHistory: [Double] = []

    /// V290-B: 정규화 범위 — 3S LiPo 실용 범위
    private static let yMin: Double = 10.5
    private static let yMax: Double = 13.0

    var body: some View {
        HStack(spacing: DFSpace.xs) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DFSpace.micro2) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(dotColor)
                    Text("배터리")
                        .font(DFFont.label)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: DFSpace.xs) {
                    Text(voltStr)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(valColor)
                    if !minuteStr.isEmpty {
                        Text(minuteStr)
                            .font(DFFont.label)
                            .foregroundStyle(.secondary)
                    }
                }
                // V290-B: 30s voltage sparkline (16pt 높이, Tufte data-ink ratio 극대화)
                if sparkHistory.count >= 2 {
                    SparklineView(
                        values: normalizedVoltage,
                        lineColor: dotColor
                    )
                    .frame(width: 40, height: 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DFSpace.sm)
    }

    /// voltage 를 0..100 범위로 정규화 (SparklineView 내부 y 범위에 맞춤)
    private var normalizedVoltage: [Double] {
        let range = Self.yMax - Self.yMin
        guard range > 0 else { return sparkHistory }
        return sparkHistory.map { v in
            ((v - Self.yMin) / range) * 100.0
        }
    }
}

// MARK: - LatencyCell (RTT + 30s sparkline)

/// 통신 지연 셀 — RTT 숫자 + 마지막 30s sparkline.
/// V290-B: sparkHistory 는 원시 ms 값. yMin=0, yMax=60 으로 정규화.
private struct LatencyCell: View {
    let msStr: String
    let dotColor: Color
    let valColor: Color
    var sparkHistory: [Double] = []

    /// V290-B: 정규화 범위 (0ms ~ 60ms 실용 범위)
    private static let yMax: Double = 60.0

    var body: some View {
        HStack(spacing: DFSpace.xs) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DFSpace.micro2) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(dotColor)
                    Text("통신 지연")
                        .font(DFFont.label)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .center, spacing: DFSpace.xs) {
                    Text(msStr)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(valColor)
                    // V290-B: 30s RTT sparkline (16pt 높이)
                    if sparkHistory.count >= 2 {
                        SparklineView(
                            values: normalizedLatency,
                            lineColor: dotColor
                        )
                        .frame(width: 40, height: 16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DFSpace.sm)
    }

    /// RTT ms 를 0..100 범위로 정규화
    private var normalizedLatency: [Double] {
        guard Self.yMax > 0 else { return sparkHistory }
        return sparkHistory.map { ms in
            min((ms / Self.yMax) * 100.0, 100.0)
        }
    }
}

// MARK: - FallRiskCell (score + 30s sparkline)

/// 낙상 위험 셀 — 점수 + 마지막 30s sparkline.
private struct FallRiskCell: View {
    let score: Double?
    let scoreStr: String
    let history: [Double]
    let dotColor: Color
    let valColor: Color

    var body: some View {
        HStack(spacing: DFSpace.xs) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DFSpace.micro2) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(dotColor)
                    Text("낙상 위험")
                        .font(DFFont.label)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .center, spacing: DFSpace.xs) {
                    Text(scoreStr)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(valColor)
                    if history.count >= 2 {
                        SparklineView(values: history, lineColor: dotColor)
                            .frame(width: 40, height: 14)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DFSpace.sm)
    }
}

// MARK: - SparklineView (30s mini chart)

/// 미니 sparkline — 마지막 N sample 을 선으로 연결. 0..100 고정 y-axis.
struct SparklineView: View {
    let values: [Double]
    let lineColor: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count >= 2 else { return }
                let w = geo.size.width
                let h = geo.size.height
                let step = w / Double(values.count - 1)
                for (i, v) in values.enumerated() {
                    let x = Double(i) * step
                    // y: 0=bottom (safe), 100=top (crit) — 뒤집기
                    let y = h - (min(max(v, 0), 100) / 100.0) * h
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(lineColor, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
    }
}
