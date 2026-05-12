import Charts
import ForgeCore
import SwiftUI

/// 전문가 메뉴의 메인 대시보드 — 모든 텔레메트리를 한 화면에 시각화.
///
/// 카드 그리드:
///   1. 보드 정보 + 컨트롤러
///   2. 배터리 (sparkline + 게이지)
///   3. 평균 온도 (sparkline + 평균/최고)
///   4. 통신 RTT (라이브)
///   5. 관절 토크 그리드 (20 tile, ON/OFF 색)
///   6. 관절 온도 bar chart (20)
///   7. 관절 부하 bar chart (16 — 머리/발목 제외)
///   8. 관절 위치 vs 목표 (positional error)
///   9. 누적 통신 통계 (성공/실패)
public struct ExpertDashboard: View {
    @EnvironmentObject var store: ConnectionStore
    @Environment(\.dfWindowWidth) private var winWidth
    @Environment(\.dfWindowHeight) private var winHeight
    @State private var now: Date = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init() {}

    public var body: some View {
        DFPageScaffold(
            "전문가 대시보드",
            subtitle: "로봇의 모든 텔레메트리 — 보드·배터리·관절·통신을 라이브",
            icon: "wrench.and.screwdriver.fill",
            tint: DFColor.forge
        ) {
            GeometryReader { geo in
                let isNarrow = geo.size.width < 980
                let isVeryNarrow = geo.size.width < 700
                ScrollView {
                    VStack(alignment: .leading, spacing: DFSpace.md) {
                        if isConnected {
                            adaptiveRowOne(narrow: isNarrow, veryNarrow: isVeryNarrow)
                            adaptiveRowTwo(narrow: isNarrow)
                            adaptiveRowThree(narrow: isNarrow)
                            adaptiveRowFour(narrow: isNarrow)
                        } else {
                            offlineState
                        }
                    }
                    .padding(DFSpace.md)
                }
                .glassScroll(accent: DFNeon.electric)
                .onReceive(tick) { now = $0 }
            }
        }
    }

    /// 좁은 화면에서 카드를 2열로 wrap, 매우 좁으면 1열.
    @ViewBuilder
    private func adaptiveRowOne(narrow: Bool, veryNarrow: Bool) -> some View {
        if veryNarrow {
            VStack(spacing: 12) { controllerCard; batteryCard; tempCard; commCard }
        } else if narrow {
            VStack(spacing: 12) {
                HStack(spacing: 12) { controllerCard; batteryCard }
                HStack(spacing: 12) { tempCard; commCard }
            }
        } else {
            HStack(spacing: 12) { controllerCard; batteryCard; tempCard; commCard }
        }
    }

    @ViewBuilder
    private func adaptiveRowTwo(narrow: Bool) -> some View {
        if narrow {
            VStack(spacing: 12) { torqueGridCard; postureCard }
        } else {
            HStack(alignment: .top, spacing: 12) { torqueGridCard; postureCard }
        }
    }

    @ViewBuilder
    private func adaptiveRowThree(narrow: Bool) -> some View {
        if narrow {
            VStack(spacing: 12) { jointTempCard; jointLoadCard }
        } else {
            HStack(alignment: .top, spacing: 12) { jointTempCard; jointLoadCard }
        }
    }

    @ViewBuilder
    private func adaptiveRowFour(narrow: Bool) -> some View {
        if narrow {
            VStack(spacing: 12) { voltageHistoryCard; sessionInfoCard }
        } else {
            HStack(alignment: .top, spacing: 12) { voltageHistoryCard; sessionInfoCard }
        }
    }

    // MARK: - Header — DFPageScaffold 가 대체

    // MARK: - Row 1 — 4 작은 카드 (adaptiveRowOne 에서 직접 카드를 호출하므로 row 헬퍼 불필요)

    private var controllerCard: some View {
        ExpertCard(title: "보드", icon: "cpu.fill", tint: DFColor.forge) {
            if case .connected(let s) = store.status {
                VStack(alignment: .leading, spacing: 6) {
                    bigNumber(text: shortControllerName(s.controllerLabel),
                              size: 18, tint: DFColor.textPrimary)
                    metricRow(label: "모델", value: "\(s.modelNumber)", mono: true)
                    metricRow(label: "펌웨어", value: "v\(s.version)", mono: true)
                    if let ep = store.activeEndpoint {
                        metricRow(label: ep.kindLabel, value: ep.detail, mono: true)
                    }
                }
            } else {
                Text("—").foregroundStyle(DFColor.textSecondary)
            }
        }
    }

    private var batteryCard: some View {
        ExpertCard(title: "배터리", icon: "bolt.batteryblock.fill",
                   tint: batteryColor(currentVoltage)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", currentVoltage))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(batteryColor(currentVoltage))
                    Text("V").foregroundStyle(DFColor.textSecondary)
                    Spacer()
                    statusChip(batteryLabel(currentVoltage), batteryColor(currentVoltage))
                }
                Chart(voltageSeries) { s in
                    AreaMark(x: .value("t", s.idx), y: .value("V", s.value))
                        .foregroundStyle(LinearGradient(
                            colors: [batteryColor(s.value).opacity(0.5), .clear],
                            startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", s.idx), y: .value("V", s.value))
                        .foregroundStyle(batteryColor(s.value))
                }
                .chartYScale(domain: 8.0...12.6)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 38)
            }
        }
    }

    private var tempCard: some View {
        ExpertCard(title: "평균 온도", icon: "thermometer.medium",
                   tint: tempColor(currentAvgTemp)) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.0f", currentAvgTemp))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(tempColor(currentAvgTemp))
                    Text("°C").foregroundStyle(DFColor.textSecondary)
                    Spacer()
                    if let max = maxJointTemp {
                        statusChip("최고 \(Int(max))°", tempColor(max))
                    }
                }
                Chart(tempSeries) { s in
                    LineMark(x: .value("t", s.idx), y: .value("°C", s.value))
                        .foregroundStyle(tempColor(s.value))
                    RuleMark(y: .value("주의", 55))
                        .foregroundStyle(DFColor.warning.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                }
                .chartYScale(domain: 20...80)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 38)
            }
        }
    }

    private var commCard: some View {
        ExpertCard(title: "통신 RTT", icon: "waveform.path.ecg",
                   tint: rttColor(store.lastRoundTripMs ?? 0)) {
            VStack(alignment: .leading, spacing: 6) {
                if let rtt = store.lastRoundTripMs {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", rtt))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(rttColor(rtt))
                        Text("ms").foregroundStyle(DFColor.textSecondary)
                        Spacer()
                        statusChip(rttLabel(rtt), rttColor(rtt))
                    }
                }
                let total = store.successCount + store.failureCount
                let pct = total > 0 ? Double(store.successCount) / Double(total) * 100 : 100
                metricRow(label: "성공률", value: String(format: "%.1f%%", pct),
                          tint: pct >= 99 ? DFColor.success
                              : pct >= 95 ? DFColor.warning : DFColor.danger)
                metricRow(label: "성공/실패",
                          value: "\(store.successCount) / \(store.failureCount)",
                          mono: true)
            }
        }
    }

    // MARK: - Row 2 — 토크 grid + 자세 미니뷰

    private var torqueGridCard: some View {
        ExpertCard(title: "20 관절 토크", icon: "bolt.fill",
                   tint: DFColor.torque, expanded: true, height: 200) {
            let cols = 5
            VStack(spacing: 6) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: cols),
                          spacing: 4) {
                    ForEach(JointID.allCases, id: \.self) { j in
                        torqueTile(j)
                    }
                }
                HStack(spacing: 6) {
                    let on = JointID.allCases.filter { store.jointStates[$0]?.torqueEnabled == true }.count
                    Text("토크 ON \(on)/20")
                        .font(DFFont.caption.monospaced())
                        .foregroundStyle(on > 0 ? DFColor.torque : DFColor.textSecondary)
                    Spacer()
                    Text("탭하면 해당 관절 정보")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
        }
    }

    private func torqueTile(_ j: JointID) -> some View {
        let s = store.jointStates[j]
        let on = s?.torqueEnabled ?? false
        return VStack(spacing: 1) {
            Text(shortJointName(j))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(on ? .white : DFColor.textSecondary)
            Text("\(j.rawValue)")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(on ? .white.opacity(0.8) : DFColor.textSecondary.opacity(0.6))
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(on ? DFColor.torque.opacity(0.85) : DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("\(j.koreanLabel) — ID \(j.rawValue) \(on ? "ON" : "OFF")")
    }

    private var postureCard: some View {
        ExpertCard(title: "자세 — 위치 vs 목표 오차",
                   icon: "figure.stand", tint: DFColor.accent,
                   expanded: true, height: 200) {
            VStack(spacing: 4) {
                Chart(positionErrorSeries, id: \.id) { e in
                    BarMark(
                        x: .value("관절", e.label),
                        y: .value("오차°", e.errorDeg)
                    )
                    .foregroundStyle(errorColor(e.errorDeg))
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel().font(.system(size: 8))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel().font(.system(size: 7))
                    }
                }
                .frame(maxHeight: .infinity)
                Text("|present − goal| 절대 오차 (°)")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
    }

    // MARK: - Row 3 — 부하/온도 막대

    private var jointTempCard: some View {
        ExpertCard(title: "관절별 온도", icon: "thermometer.transmission",
                   tint: DFColor.warning, expanded: true, height: 220) {
            Chart(jointTempSeries, id: \.id) { e in
                BarMark(
                    x: .value("관절", e.label),
                    y: .value("°C", e.value)
                )
                .foregroundStyle(tempColor(e.value))
                RuleMark(y: .value("주의", 55))
                    .foregroundStyle(DFColor.warning.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                RuleMark(y: .value("위험", 65))
                    .foregroundStyle(DFColor.danger.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartYScale(domain: 0...80)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel().font(.system(size: 8))
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel().font(.system(size: 9))
                }
            }
        }
    }

    private var jointLoadCard: some View {
        ExpertCard(title: "관절별 부하 (load %)", icon: "scalemass.fill",
                   tint: DFColor.danger, expanded: true, height: 220) {
            Chart(jointLoadSeries, id: \.id) { e in
                BarMark(
                    x: .value("관절", e.label),
                    y: .value("%", e.value)
                )
                .foregroundStyle(loadColor(e.value))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel().font(.system(size: 8))
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel().font(.system(size: 9))
                }
            }
        }
    }

    // MARK: - Row 4 — 통신 시계열

    private var voltageHistoryCard: some View {
        ExpertCard(title: "60초 전압 추이 (자세히)",
                   icon: "chart.xyaxis.line",
                   tint: DFColor.success, expanded: true, height: 180) {
            if voltageSeries.count >= 2 {
                Chart(voltageSeries) { s in
                    AreaMark(x: .value("t", s.idx), y: .value("V", s.value))
                        .foregroundStyle(LinearGradient(
                            colors: [DFColor.success.opacity(0.4), .clear],
                            startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", s.idx), y: .value("V", s.value))
                        .foregroundStyle(DFColor.success)
                    RuleMark(y: .value("주의", 9.5))
                        .foregroundStyle(DFColor.warning.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartYScale(domain: 8.0...12.6)
                .chartYAxis {
                    AxisMarks(values: [8.5, 9.5, 10.5, 11.1, 12.0]) { _ in
                        AxisGridLine()
                        AxisValueLabel().font(.system(size: 9))
                    }
                }
                .chartXAxis(.hidden)
            } else {
                Text("샘플 수집 중…")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
    }

    private var sessionInfoCard: some View {
        ExpertCard(title: "세션 정보", icon: "clock.fill",
                   tint: DFColor.accent, expanded: true, height: 180) {
            VStack(alignment: .leading, spacing: 8) {
                if let connectedAt = store.connectedAt {
                    metricRow(label: "연결 시간",
                              value: formatUptime(now.timeIntervalSince(connectedAt)))
                }
                if let last = store.lastSuccessAt {
                    let elapsed = Int(now.timeIntervalSince(last))
                    metricRow(label: "마지막 응답",
                              value: elapsed < 2 ? "방금" : "\(elapsed)초 전",
                              tint: elapsed > 5 ? DFColor.warning : DFColor.success)
                }
                metricRow(label: "전압 샘플", value: "\(store.voltageHistory.count) / 60", mono: true)
                metricRow(label: "온도 샘플", value: "\(store.avgTempHistory.count) / 60", mono: true)
                metricRow(label: "관절 캐시", value: "\(store.jointStates.count) / 20", mono: true)
                if store.isReconnecting {
                    metricRow(label: "재연결",
                              value: "\(store.reconnectAttempt)/5",
                              tint: DFColor.warning)
                }
            }
        }
    }

    // MARK: - Offline state

    private var offlineState: some View {
        DFEmptyState(
            icon: "shield.slash.fill",
            title: "로봇과 연결되어 있지 않아요",
            message: "연결 마법사로 로봇과 연결하면 모든 텔레메트리가 라이브로 표시됩니다.",
            tint: DFColor.textSecondary
        ) {
            EmptyView()
        }
    }

    // MARK: - 데이터 시리즈

    private struct Sample: Identifiable {
        let id = UUID()
        let idx: Int
        let value: Double
    }
    private struct JointMetric: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
        let errorDeg: Double
    }

    private var voltageSeries: [Sample] {
        store.voltageHistory.enumerated().map { Sample(idx: $0.offset, value: $0.element) }
    }
    private var tempSeries: [Sample] {
        store.avgTempHistory.enumerated().map { Sample(idx: $0.offset, value: $0.element) }
    }

    private var jointTempSeries: [JointMetric] {
        JointID.allCases.map { j in
            let t = Double(store.jointStates[j]?.presentTemperature ?? 0)
            return JointMetric(label: shortJointName(j), value: t, errorDeg: 0)
        }
    }

    private var jointLoadSeries: [JointMetric] {
        JointID.allCases.map { j in
            let raw = Double(store.jointStates[j]?.presentLoad ?? 0)
            // Dynamixel load 는 0..1023, 10비트. 10번째 비트가 방향. 백분율 추정.
            let pct = min(100, raw / 10.23)
            return JointMetric(label: shortJointName(j), value: pct, errorDeg: 0)
        }
    }

    private var positionErrorSeries: [JointMetric] {
        JointID.allCases.map { j in
            let s = store.jointStates[j]
            let goal = Double(s?.goalPosition ?? 2048) - 2048.0
            let pres = Double(s?.presentPosition ?? 2048) - 2048.0
            let errDeg = abs((goal - pres) * (180.0 / 2048.0))
            return JointMetric(label: shortJointName(j), value: 0, errorDeg: errDeg)
        }
    }

    // MARK: - 색상/라벨 헬퍼

    private var isConnected: Bool {
        if case .connected = store.status { return true } else { return false }
    }
    private var currentVoltage: Double {
        store.lastTelemetry?.board?.voltageVolts ?? 0
    }
    private var currentAvgTemp: Double {
        store.lastTelemetry?.avgTemperature ?? 0
    }
    private var maxJointTemp: Double? {
        let temps = JointID.allCases.compactMap { store.jointStates[$0]?.presentTemperature }
        guard let m = temps.max() else { return nil }
        return Double(m)
    }

    private func batteryColor(_ v: Double) -> Color {
        if v >= 11.1 { return DFColor.success }
        if v >= 9.5  { return DFColor.warning }
        if v == 0    { return DFColor.textSecondary }
        return DFColor.danger
    }
    private func batteryLabel(_ v: Double) -> String {
        if v == 0    { return "—" }
        if v >= 11.5 { return "최상" }
        if v >= 11.1 { return "양호" }
        if v >= 9.5  { return "주의" }
        return "위험"
    }
    private func tempColor(_ t: Double) -> Color {
        if t == 0   { return DFColor.textSecondary }
        if t >= 65  { return DFColor.danger }
        if t >= 55  { return DFColor.warning }
        return DFColor.success
    }
    private func loadColor(_ p: Double) -> Color {
        if p >= 80 { return DFColor.danger }
        if p >= 50 { return DFColor.warning }
        return DFColor.success.opacity(0.7)
    }
    private func errorColor(_ deg: Double) -> Color {
        if deg >= 5 { return DFColor.danger }
        if deg >= 2 { return DFColor.warning }
        return DFColor.success
    }
    private func rttColor(_ ms: Double) -> Color {
        if ms == 0   { return DFColor.textSecondary }
        if ms < 10   { return DFColor.success }
        if ms < 100  { return DFColor.warning }
        return DFColor.danger
    }
    private func rttLabel(_ ms: Double) -> String {
        if ms < 5    { return "초고속" }
        if ms < 50   { return "정상" }
        if ms < 200  { return "보통" }
        return "느림"
    }

    private func shortControllerName(_ s: String) -> String {
        if let p = s.firstIndex(of: "(") { return String(s[..<p]).trimmingCharacters(in: .whitespaces) }
        return s
    }

    /// 차트 X축 라벨용 — 8자 안쪽으로 짧게.
    private func shortJointName(_ j: JointID) -> String {
        switch j {
        case .rShoulderPitch: return "RSh.P"
        case .lShoulderPitch: return "LSh.P"
        case .rShoulderRoll:  return "RSh.R"
        case .lShoulderRoll:  return "LSh.R"
        case .rElbow:         return "RElb"
        case .lElbow:         return "LElb"
        case .rHipYaw:        return "RHip.Y"
        case .lHipYaw:        return "LHip.Y"
        case .rHipRoll:       return "RHip.R"
        case .lHipRoll:       return "LHip.R"
        case .rHipPitch:      return "RHip.P"
        case .lHipPitch:      return "LHip.P"
        case .rKnee:          return "RKnee"
        case .lKnee:          return "LKnee"
        case .rAnklePitch:    return "RAnk.P"
        case .lAnklePitch:    return "LAnk.P"
        case .rAnkleRoll:     return "RAnk.R"
        case .lAnkleRoll:     return "LAnk.R"
        case .headPan:        return "HPan"
        case .headTilt:       return "HTilt"
        }
    }

    // MARK: - 공통 작은 컴포넌트

    private func metricRow(label: String, value: String, tint: Color = DFColor.textPrimary, mono: Bool = false) -> some View {
        HStack {
            Text(label).font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
            Spacer()
            Text(value)
                .font(mono ? DFFont.caption.monospaced() : DFFont.bodyEmph)
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    private func bigNumber(text: String, size: CGFloat, tint: Color) -> some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .lineLimit(1)
    }
    private func statusChip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    private func formatUptime(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total / 60) % 60
        let sec = total % 60
        if h > 0 { return "\(h)시간 \(m)분" }
        if m > 0 { return "\(m)분 \(sec)초" }
        return "\(sec)초"
    }
}

/// 카드 통일 디자인 — title + icon + content + 옵션 height.
private struct ExpertCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    var expanded: Bool = false
    var height: CGFloat = 132
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DFColor.textSecondary)
                    .textCase(.uppercase)
                Spacer()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.md)
                .stroke(DFColor.textSecondary.opacity(0.10), lineWidth: 0.5)
        )
    }
}
