import SwiftUI
import MobilePilotKit

public struct RobotDashboardView: View {
    @ObservedObject var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            summaryCard
            metricsCard
            chartsCard
        }
        .accessibilityIdentifier("robot.dashboard")
    }

    private var summaryCard: some View {
        DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Label("상태 대시보드", systemImage: "chart.line.uptrend.xyaxis")
                        .font(DS.Font.sectionTitle)
                    Spacer()
                    DSChip(modeCopy, systemImage: "iphone.gen3", tone: .neutral)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.s) {
                        DSChip(macStatus.label, systemImage: macStatus.icon,
                               tone: macStatus.tone, identifier: "robot.dashboard.mac")
                        DSChip(robotStatus.label, systemImage: robotStatus.icon,
                               tone: robotStatus.tone, identifier: "robot.dashboard.robot")
                        DSChip(armStatus.label, systemImage: armStatus.icon,
                               tone: armStatus.tone, identifier: "robot.dashboard.arm")
                    }
                }

                Divider()

                Label {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(nextStep.title)
                            .font(DS.Font.bodyEmphasis)
                        Text(nextStep.body)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                } icon: {
                    Image(systemName: nextStep.icon)
                        .foregroundStyle(nextStep.tone.foreground)
                }
            }
        }
    }

    private var metricsCard: some View {
        DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                DSSectionHeader("핵심 지표", subtitle: "값과 막대를 함께 표시해 색상에만 의존하지 않습니다.")
                MetricGauge(title: "배터리",
                            valueText: batteryText,
                            detail: "권장 범위 10.8V 이상",
                            normalized: batteryLevel,
                            tone: batteryTone,
                            systemImage: "bolt.fill")
                MetricGauge(title: "응답 지연",
                            valueText: latencyText,
                            detail: "150ms 이상이면 보행을 차단합니다.",
                            normalized: latencyRiskLevel,
                            tone: latencyTone,
                            systemImage: "timer")
                MetricGauge(title: "모터 온도",
                            valueText: temperatureText,
                            detail: "60℃ 이상은 주의가 필요합니다.",
                            normalized: temperatureLevel,
                            tone: temperatureTone,
                            systemImage: "thermometer.medium")
                MetricGauge(title: "최근 응답",
                            valueText: ackAgeText,
                            detail: "마지막 명령 응답이 오래되면 멈춤을 우선합니다.",
                            normalized: ackRiskLevel,
                            tone: ackTone,
                            systemImage: "waveform.path.ecg")
            }
        }
    }

    private var chartsCard: some View {
        DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                DSSectionHeader("최근 변화", subtitle: "연결 후 최대 48개 텔레메트리 프레임을 표시합니다.")
                ChartRow(title: "응답 지연",
                         valueText: latencyText,
                         values: state.telemetryHistory.map { Double($0.latencyMs) },
                         range: 0...300,
                         tint: DS.Color.info,
                         emptyText: "Mac Relay 연결 후 지연 그래프가 표시됩니다.")
                ChartRow(title: "배터리",
                         valueText: batteryText,
                         values: state.telemetryHistory.compactMap(\.batteryV),
                         range: 9.6...12.6,
                         tint: DS.Color.success,
                         emptyText: "로봇 전압이 수신되면 배터리 그래프가 표시됩니다.")
            }
        }
    }

    private var modeCopy: String {
        switch state.connectionMode {
        case .mockReview: return "연습 모드"
        case .realRelay: return "실제 연결"
        }
    }

    private var macStatus: DashboardStatus {
        switch state.transport {
        case .connected: return DashboardStatus("Mac 연결됨", "desktopcomputer", .success)
        case .connecting, .handshaking: return DashboardStatus("Mac 연결 중", "antenna.radiowaves.left.and.right", .info)
        case .disconnected: return DashboardStatus("Mac 끊김", "wifi.slash", .danger)
        case .idle: return DashboardStatus("Mac 대기", "desktopcomputer", .neutral)
        }
    }

    private var robotStatus: DashboardStatus {
        guard let telemetry = state.telemetry else {
            return DashboardStatus("로봇 미확인", "cpu", .neutral)
        }
        switch telemetry.robot {
        case .connected: return DashboardStatus("로봇 연결됨", "cpu.fill", .success)
        case .sim: return DashboardStatus("연습 시뮬레이션", "cube.transparent", .info)
        case .stale: return DashboardStatus("응답 지연", "clock.badge.exclamationmark", .warning)
        case .busBusy: return DashboardStatus("로봇 사용 중", "person.2.fill", .warning)
        case .disconnected: return DashboardStatus("로봇 미연결", "cpu", .neutral)
        case .estopped: return DashboardStatus("정지 상태", "octagon.fill", .danger)
        }
    }

    private var armStatus: DashboardStatus {
        switch state.pilotState {
        case .armedReady, .commandActive:
            return DashboardStatus("잠금 해제됨", "lock.open.fill", .success)
        case .arming:
            return DashboardStatus("잠금 해제 중", "lock.rotation", .info)
        case .estopped, .staleStop:
            return DashboardStatus("정지 확인", "exclamationmark.octagon.fill", .danger)
        default:
            return DashboardStatus("잠김", "lock.fill", .neutral)
        }
    }

    private var nextStep: DashboardNextStep {
        if !state.isMacReady {
            return DashboardNextStep("Mac 앱과 연결하세요",
                                     "연결 탭에서 Darwin Forge Mac 앱을 찾고 6자리 코드를 입력하세요.",
                                     "1.circle.fill", .info)
        }
        guard let telemetry = state.telemetry else {
            return DashboardNextStep("로봇 상태를 기다리는 중",
                                     "Mac과 연결됐습니다. 로봇 전원과 케이블 상태를 확인하면 상태가 갱신됩니다.",
                                     "hourglass", .neutral)
        }
        if telemetry.robot == .estopped || telemetry.safety == .estopped {
            return DashboardNextStep("정지 상태를 해제하기 전 확인",
                                     "하드웨어 정지 버튼, 전원, 주변 사람 위치를 먼저 확인하세요.",
                                     "exclamationmark.octagon.fill", .danger)
        }
        if telemetry.robot == .disconnected {
            return DashboardNextStep("로봇 전원을 확인하세요",
                                     "Mac 앱은 연결됐지만 실제 로봇 신호가 없습니다. 로봇 전원과 네트워크를 확인하세요.",
                                     "powerplug.fill", .warning)
        }
        if !state.armChecklistPassed {
            return DashboardNextStep("잠금 해제 전 확인이 남았습니다",
                                     "동작 탭에서 크래들, 물리 정지 버튼, 시야 확보를 확인하세요.",
                                     "checklist", .warning)
        }
        if !state.pilotState.isArmed {
            return DashboardNextStep("잠금 해제할 수 있습니다",
                                     "주변이 안전하면 동작 탭에서 슬라이더를 끝까지 밀어 조작을 시작하세요.",
                                     "lock.open.fill", .success)
        }
        return DashboardNextStep("조작 가능",
                                 "동작 탭의 검증된 동작과 보행 버튼을 사용할 수 있습니다.",
                                 "checkmark.circle.fill", .success)
    }

    private var batteryText: String {
        state.telemetry?.batteryV.map { String(format: "%.1f V", $0) } ?? "수신 전"
    }

    private var batteryLevel: Double {
        normalize(state.telemetry?.batteryV, in: 9.6...12.6)
    }

    private var batteryTone: DSChip.Tone {
        guard let value = state.telemetry?.batteryV else { return .neutral }
        if value < 10.5 { return .danger }
        if value < 10.8 { return .warning }
        return .success
    }

    private var latencyText: String {
        state.telemetry.map { "\($0.latencyMs) ms" } ?? "수신 전"
    }

    private var latencyRiskLevel: Double {
        normalize(Double(state.telemetry?.latencyMs ?? 0), in: 0...300)
    }

    private var latencyTone: DSChip.Tone {
        guard let value = state.telemetry?.latencyMs else { return .neutral }
        if value >= 250 { return .danger }
        if value >= 150 { return .warning }
        return .success
    }

    private var temperatureText: String {
        state.telemetry?.maxTempC.map { String(format: "%.0f ℃", $0) } ?? "수신 전"
    }

    private var temperatureLevel: Double {
        normalize(state.telemetry?.maxTempC, in: 20...80)
    }

    private var temperatureTone: DSChip.Tone {
        guard let value = state.telemetry?.maxTempC else { return .neutral }
        if value >= 70 { return .danger }
        if value >= 60 { return .warning }
        return .success
    }

    private var ackAgeText: String {
        state.telemetry?.lastAckAgeMs.map { "\($0) ms" } ?? "명령 전"
    }

    private var ackRiskLevel: Double {
        normalize(Double(state.telemetry?.lastAckAgeMs ?? 0), in: 0...500)
    }

    private var ackTone: DSChip.Tone {
        guard let value = state.telemetry?.lastAckAgeMs else { return .neutral }
        if value >= 450 { return .danger }
        if value >= 250 { return .warning }
        return .success
    }

    private func normalize(_ value: Double?, in range: ClosedRange<Double>) -> Double {
        guard let value else { return 0 }
        let span = max(0.0001, range.upperBound - range.lowerBound)
        return min(max((value - range.lowerBound) / span, 0), 1)
    }
}

private struct DashboardStatus {
    let label: String
    let icon: String
    let tone: DSChip.Tone

    init(_ label: String, _ icon: String, _ tone: DSChip.Tone) {
        self.label = label
        self.icon = icon
        self.tone = tone
    }
}

private struct DashboardNextStep {
    let title: String
    let body: String
    let icon: String
    let tone: DSChip.Tone

    init(_ title: String, _ body: String, _ icon: String, _ tone: DSChip.Tone) {
        self.title = title
        self.body = body
        self.icon = icon
        self.tone = tone
    }
}

private struct MetricGauge: View {
    let title: String
    let valueText: String
    let detail: String
    let normalized: Double
    let tone: DSChip.Tone
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: systemImage)
                    .font(DS.Font.captionEmphasis)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer()
                Text(valueText)
                    .font(DS.Font.metric)
                    .foregroundStyle(tone.foreground)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Color.elevated)
                    Capsule()
                        .fill(tone.foreground)
                        .frame(width: max(4, proxy.size.width * normalized))
                }
            }
            .frame(height: 8)
            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(valueText). \(detail)")
    }
}

private struct ChartRow: View {
    let title: String
    let valueText: String
    let values: [Double]
    let range: ClosedRange<Double>
    let tint: Color
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(DS.Font.captionEmphasis)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer()
                Text(valueText)
                    .font(DS.Font.captionEmphasis.monospacedDigit())
            }
            if values.count >= 2 {
                MiniLineChart(values: values, range: range, tint: tint)
                    .frame(height: 72)
                    .accessibilityLabel("\(title) 최근 변화 그래프")
            } else {
                Text(emptyText)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                    .background(DS.Color.elevated, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
            }
        }
    }
}

private struct MiniLineChart: View {
    let values: [Double]
    let range: ClosedRange<Double>
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let points = chartPoints(in: proxy.size)
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(DS.Color.elevated)
                Path { path in
                    for (index, point) in points.enumerated() {
                        if index == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                ForEach(points.indices, id: \.self) { index in
                    if index == points.indices.last {
                        Circle()
                            .fill(tint)
                            .frame(width: 8, height: 8)
                            .position(points[index])
                    }
                }
            }
        }
    }

    private func chartPoints(in size: CGSize) -> [CGPoint] {
        let filtered = values.filter { $0.isFinite }
        guard filtered.count >= 2 else { return [] }
        let span = max(0.0001, range.upperBound - range.lowerBound)
        let stepX = size.width / CGFloat(max(filtered.count - 1, 1))
        return filtered.enumerated().map { index, value in
            let ratio = min(max((value - range.lowerBound) / span, 0), 1)
            let x = CGFloat(index) * stepX
            let y = size.height - CGFloat(ratio) * size.height
            return CGPoint(x: x, y: y)
        }
    }
}
