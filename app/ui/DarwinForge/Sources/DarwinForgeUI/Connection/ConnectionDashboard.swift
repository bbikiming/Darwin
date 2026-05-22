import ForgeCore
import SwiftUI

/// 연결 상태를 한눈에 보여주는 대시보드 — StatusBar의 "더보기" 클릭 시 띄움.
///
/// 구성:
///   - 헤더 (controllerLabel + 큰 연결 해제 버튼)
///   - 4개 카드: 보드 / 배터리 / 연결 / 통신 통계
///   - sparkline 두 개 (전압 추이 / 평균 온도)
public struct ConnectionDashboardView: View {
    @EnvironmentObject var store: ConnectionStore
    @Binding public var isPresented: Bool

    /// 1초마다 uptime/last-success 갱신용 timer.
    @State private var now: Date = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        GeometryReader { geo in
            // 윈도우보다 작은 화면에선 80%까지 축소 + 내부 ScrollView 가 자연스러운 스크롤.
            let w = min(640, geo.size.width * 0.88)
            let h = min(580, geo.size.height * 0.88)
            VStack(spacing: DFSpace.none) {
                header
                Divider()
                content
                Divider()
                footer
            }
            .frame(width: w, height: h)
            .background(DFColor.canvas)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.md)
                    .stroke(DFColor.textSecondary.opacity(DFOpacity.o18), lineWidth: DFSize.borderHairline)
            )
            .shadow(radius: 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)  // 중앙 정렬.
            .onReceive(tick) { now = $0 }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DFSpace.sm) {
            ZStack {
                Circle().fill(headerStatusColor.opacity(0.16)).frame(width: 40, height: 40)
                Image(systemName: headerIcon)
                    .font(.system(size: DFFontSize.s18, weight: .semibold))
                    .foregroundStyle(headerStatusColor)
            }
            VStack(alignment: .leading, spacing: DFSpace.micro) {
                Text(headerTitle)
                    .font(DFFont.title)
                Text(headerSubtitle)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            disconnectButton
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: DFFontSize.s18))
                    .foregroundStyle(DFColor.textSecondary)
            }
            .buttonStyle(.plain)
            .help("닫기 (ESC)")
            .keyboardShortcut(.cancelAction)
        }
        .padding(DFSpace.md)
    }

    private var disconnectButton: some View {
        Button {
            store.disconnect()
            isPresented = false
        } label: {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "powerplug.fill")
                Text("연결 해제").font(DFFont.bodyEmph)
            }
            .padding(.horizontal, DFSpace.sm3)
            .padding(.vertical, DFSpace.sm)
            .background(DFColor.danger.opacity(DFOpacity.o15))
            .foregroundStyle(DFColor.danger)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(DFColor.danger.opacity(DFOpacity.disabled), lineWidth: DFSize.borderHairline))
        }
        .buttonStyle(.plain)
        .help("로봇과의 연결을 종료합니다")
        .disabled(!isConnectedNow)
    }

    private var isConnectedNow: Bool {
        if case .connected = store.status { return true } else { return false }
    }

    private var headerTitle: String {
        if case .connected(let s) = store.status { return s.controllerLabel }
        return "연결 정보"
    }
    private var headerSubtitle: String {
        if let ep = store.activeEndpoint { return ep.detail }
        switch store.status {
        case .disconnected: return "오프라인 — 마법사로 연결하세요"
        case .connecting(let s): return "연결 중 — \(s)"
        case .error(let m): return m
        case .connected: return "—"
        }
    }
    private var headerStatusColor: Color {
        switch store.status {
        case .connected:    return DFColor.success
        case .connecting:   return DFColor.warning
        case .error:        return DFColor.danger
        case .disconnected: return DFColor.textSecondary
        }
    }
    private var headerIcon: String {
        if case .connected = store.status { return "checkmark.shield.fill" }
        if case .connecting = store.status { return "ellipsis" }
        if case .error = store.status { return "exclamationmark.shield.fill" }
        return "shield.slash.fill"
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: DFSpace.sm3) {
                topRowCards
                bottomRowCards
                sparklinesRow
                remoteToolsCard
            }
            .padding(DFSpace.md)
        }
        .glassScroll(accent: DFColor.accent)
    }

    // MARK: - 원격 도구

    /// 활성 host 추론 — TCP endpoint면 그 host, 그렇지 않으면 OP2 표준 IP.
    private var remoteHost: String {
        if let ep = store.activeEndpoint, case .network(let h, _) = ep { return h }
        return DFConnectionConstants.robotEthernetIP
    }

    /// VNC / Web / SMB 가 모두 같은 host에 동시에 떠 있는 ROBOTIS-OP2 standard 이미지를
    /// 활용 — 클릭 한 번으로 macOS 기본 앱(Screen Sharing / Safari / Finder)에 위임.
    private var remoteToolsCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "display")
                    .foregroundStyle(DFColor.forge)
                Text("원격 도구")
                    .font(DFFont.bodyEmph)
                Spacer()
                Text(remoteHost)
                    .font(.system(size: DFFontSize.s10, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
            }

            HStack(spacing: DFSpace.sm2) {
                remoteToolButton(
                    label: "VNC 데스크톱",
                    detail: "그래픽 화면 · 가상 키보드",
                    icon: "macwindow",
                    tint: DFColor.accent,
                    urlString: "vnc://\(remoteHost):5900"
                )
                remoteToolButton(
                    label: "Vision Tool",
                    detail: "카메라 · 색상 튜닝 (브라우저)",
                    icon: "camera.viewfinder",
                    tint: DFColor.success,
                    urlString: "http://\(remoteHost):8080"
                )
                remoteToolButton(
                    label: "파일 시스템",
                    detail: "SMB 공유 (Finder)",
                    icon: "folder",
                    tint: DFColor.warning,
                    urlString: "smb://\(remoteHost)"
                )
            }
        }
        .padding(DFSpace.sm3)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.md)
                .stroke(DFColor.forge.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline)
        )
    }

    private func remoteToolButton(label: String, detail: String, icon: String, tint: Color, urlString: String) -> some View {
        Button {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                HStack(spacing: DFSpace.xs2) {
                    Image(systemName: icon)
                        .font(.system(size: DFFontSize.s14, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(label).font(DFFont.bodyEmph)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(DFColor.textSecondary)
                }
                Text(detail)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(DFSpace.sm2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(DFOpacity.o06))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.xs2)
                    .stroke(tint.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline)
            )
        }
        .buttonStyle(.plain)
        .help("\(urlString) — macOS 기본 앱으로 열림")
    }

    private var topRowCards: some View {
        HStack(spacing: DFSpace.sm3) {
            boardInfoCard
            batteryCard
        }
    }

    private var bottomRowCards: some View {
        HStack(spacing: DFSpace.sm3) {
            connectionInfoCard
            communicationStatsCard
        }
    }

    // MARK: - 보드 정보 카드

    private var boardInfoCard: some View {
        DFMetricCard(title: "보드", icon: "cpu.fill", tint: DFColor.forge) {
            if case .connected(let s) = store.status {
                VStack(alignment: .leading, spacing: DFSpace.sm) {
                    metricRow(label: "컨트롤러", value: s.controllerLabel)
                    metricRow(label: "모델 번호", value: "\(s.modelNumber)")
                    metricRow(label: "펌웨어", value: "v\(s.version)")
                    if s.button != 0 {
                        metricRow(label: "버튼", value: buttonText(s.button), tint: DFColor.warning)
                    }
                }
            } else {
                emptyState(text: "연결되지 않음")
            }
        }
    }

    private func buttonText(_ b: UInt8) -> String {
        var parts: [String] = []
        if b & 0x01 != 0 { parts.append("MODE") }
        if b & 0x02 != 0 { parts.append("START") }
        return parts.isEmpty ? "—" : parts.joined(separator: " + ")
    }

    // MARK: - 배터리 카드

    private var batteryCard: some View {
        DFMetricCard(title: "배터리", icon: batteryIcon, tint: batteryColor) {
            if let v = store.lastTelemetry?.board?.voltageVolts {
                VStack(alignment: .leading, spacing: DFSpace.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: DFSpace.xs) {
                        Text(String(format: "%.1f", v))
                            .font(.system(size: DFFontSize.s28, weight: .bold, design: .rounded))
                            .foregroundStyle(batteryColor)
                        Text("V").font(DFFont.bodyEmph).foregroundStyle(DFColor.textSecondary)
                        Spacer()
                        batteryStatusChip(v)
                    }
                    voltageBar(v)
                    Text(batteryAdvice(v))
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
            } else {
                emptyState(text: "전압 데이터 없음")
            }
        }
    }

    private var batteryIcon: String {
        guard let v = store.lastTelemetry?.board?.voltageVolts else { return "battery.0percent" }
        if v >= 11.5 { return "battery.100percent" }
        if v >= 10.5 { return "battery.75percent" }
        if v >= 9.5  { return "battery.50percent" }
        if v >= 8.5  { return "battery.25percent" }
        return "battery.0percent"
    }
    private var batteryColor: Color {
        guard let v = store.lastTelemetry?.board?.voltageVolts else { return DFColor.textSecondary }
        if v >= 11.1 { return DFColor.success }
        if v >= 9.5  { return DFColor.warning }
        return DFColor.danger
    }
    private func batteryStatusChip(_ v: Double) -> some View {
        let (text, tint): (String, Color) = {
            if v >= 11.5 { return ("최상", DFColor.success) }
            if v >= 11.1 { return ("양호", DFColor.success) }
            if v >= 9.5  { return ("주의", DFColor.warning) }
            if v >= 8.5  { return ("저전압", DFColor.danger) }
            return ("위험", DFColor.danger)
        }()
        return Text(text)
            .font(.system(size: DFFontSize.s10, weight: .bold))
            .padding(.horizontal, DFSpace.xs2)
            .padding(.vertical, DFSpace.micro2)
            .background(tint.opacity(0.16))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
    private func voltageBar(_ v: Double) -> some View {
        let frac = max(0, min(1, (v - 8.0) / (12.6 - 8.0)))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: DFRadius.xs - 1)
                    .fill(DFColor.elev2)
                RoundedRectangle(cornerRadius: DFRadius.xs - 1)
                    .fill(LinearGradient(
                        colors: [batteryColor.opacity(DFOpacity.o70), batteryColor],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * frac)
            }
        }
        .frame(height: 6)
    }
    private func batteryAdvice(_ v: Double) -> String {
        if v >= 11.5 { return "정상 동작 가능" }
        if v >= 11.1 { return "충전 권장 (1시간 내)" }
        if v >= 9.5  { return "긴급 충전 — 모터 토크 저하" }
        return "즉시 충전 — 보드 셧다운 위험"
    }

    // MARK: - 연결 정보 카드

    private var connectionInfoCard: some View {
        DFMetricCard(title: "연결", icon: connectionInfoIcon, tint: DFColor.accent) {
            if let ep = store.activeEndpoint {
                VStack(alignment: .leading, spacing: DFSpace.sm) {
                    metricRow(label: "방식", value: ep.kindLabel)
                    metricRow(label: "엔드포인트", value: ep.detail, mono: true)
                    if let connectedAt = store.connectedAt {
                        metricRow(label: "연결 시간", value: formatUptime(now.timeIntervalSince(connectedAt)))
                    }
                    if let last = store.lastSuccessAt {
                        let elapsed = Int(now.timeIntervalSince(last))
                        metricRow(label: "마지막 응답",
                                  value: elapsed < 2 ? "방금" : "\(elapsed)초 전",
                                  tint: elapsed > 5 ? DFColor.warning : DFColor.success)
                    }
                    if store.isReconnecting {
                        metricRow(label: "재연결 시도",
                                  value: "\(store.reconnectAttempt)/5",
                                  tint: DFColor.warning)
                    }
                }
            } else {
                emptyState(text: "활성 endpoint 없음")
            }
        }
    }

    private var connectionInfoIcon: String {
        guard let ep = store.activeEndpoint else { return "network.slash" }
        return ep.iconSystemName
    }

    // MARK: - 통신 통계 카드

    private var communicationStatsCard: some View {
        DFMetricCard(title: "통신 통계", icon: "waveform.path.ecg", tint: DFColor.success) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                if let rtt = store.lastRoundTripMs {
                    HStack(alignment: .firstTextBaseline, spacing: DFSpace.xs) {
                        Text(String(format: "%.1f", rtt))
                            .font(.system(size: DFFontSize.s24, weight: .bold, design: .rounded))
                            .foregroundStyle(rttColor(rtt))
                        Text("ms").font(DFFont.bodyEmph).foregroundStyle(DFColor.textSecondary)
                        Spacer()
                        rttQualityChip(rtt)
                    }
                } else {
                    Text("—").font(.system(size: DFFontSize.s24)).foregroundStyle(DFColor.textSecondary)
                }
                metricRow(label: "성공", value: "\(store.successCount)회", tint: DFColor.success)
                metricRow(label: "실패", value: "\(store.failureCount)회",
                          tint: store.failureCount > 0 ? DFColor.warning : DFColor.textSecondary)
                if store.successCount + store.failureCount > 0 {
                    let total = store.successCount + store.failureCount
                    let pct = Double(store.successCount) / Double(total) * 100
                    metricRow(label: "성공률",
                              value: String(format: "%.1f%%", pct),
                              tint: pct >= 99 ? DFColor.success :
                                    pct >= 95 ? DFColor.warning : DFColor.danger)
                }
            }
        }
    }

    private func rttColor(_ ms: Double) -> Color {
        if ms < 5    { return DFColor.success }
        if ms < 50   { return DFColor.success.opacity(DFOpacity.o85) }
        if ms < 200  { return DFColor.warning }
        return DFColor.danger
    }
    private func rttQualityChip(_ ms: Double) -> some View {
        let (text, tint): (String, Color) = {
            if ms < 5    { return ("초고속", DFColor.success) }
            if ms < 50   { return ("정상",   DFColor.success) }
            if ms < 200  { return ("보통",   DFColor.warning) }
            return ("느림", DFColor.danger)
        }()
        return Text(text)
            .font(.system(size: DFFontSize.s10, weight: .bold))
            .padding(.horizontal, DFSpace.xs2)
            .padding(.vertical, DFSpace.micro2)
            .background(tint.opacity(0.16))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    // MARK: - Sparklines

    private var sparklinesRow: some View {
        HStack(spacing: DFSpace.sm3) {
            sparklineCard(
                title: "전압 추이 (60초)",
                tint: batteryColor,
                values: store.voltageHistory,
                unit: "V",
                format: "%.1f"
            )
            sparklineCard(
                title: "평균 온도 (60초)",
                tint: tempColor,
                values: store.avgTempHistory,
                unit: "°C",
                format: "%.0f"
            )
        }
    }

    private var tempColor: Color {
        guard let t = store.lastTelemetry?.avgTemperature else { return DFColor.textSecondary }
        if t >= 60 { return DFColor.danger }
        if t >= 50 { return DFColor.warning }
        return DFColor.success
    }

    private func sparklineCard(title: String, tint: Color, values: [Double], unit: String, format: String) -> some View {
        DFMetricCard(title: title, icon: "chart.xyaxis.line", tint: tint, expanded: true) {
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                if let last = values.last {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: format, last))
                            .font(.system(size: DFFontSize.s18, weight: .bold, design: .rounded))
                            .foregroundStyle(tint)
                        Text(unit).font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                        Spacer()
                        if values.count >= 2 {
                            let delta = last - (values.first ?? last)
                            let arrow = delta > 0.05 ? "arrow.up" :
                                        delta < -0.05 ? "arrow.down" : "arrow.right"
                            HStack(spacing: DFSpace.micro2) {
                                Image(systemName: arrow).font(.system(size: DFFontSize.s9))
                                Text(String(format: format, abs(delta)))
                                    .font(.system(size: DFFontSize.s10, design: .monospaced))
                            }
                            .foregroundStyle(DFColor.textSecondary)
                        }
                    }
                } else {
                    Text("샘플 없음").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                }
                MiniSparkline(values: values, tint: tint)
                    .frame(height: 38)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DFSpace.md) {
            if store.isReconnecting {
                HStack(spacing: DFSpace.xs2) {
                    ProgressView().controlSize(.small)
                    Text("자동 재연결 \(store.reconnectAttempt)/5")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.warning)
                }
            } else if isConnectedNow {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(DFColor.success)
                    Text("실시간 폴링 중")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
            } else {
                Text("연결 안 됨")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            // 사이클 138 (audit #24 codex sweep)
            Button("닫기", role: .cancel) { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(DFSpace.md)
    }

    // MARK: - 공통 헬퍼

    private func metricRow(label: String, value: String, tint: Color = DFColor.textPrimary, mono: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            Spacer()
            Text(value)
                .font(mono ? DFFont.caption.monospaced() : DFFont.bodyEmph)
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func emptyState(text: String) -> some View {
        Text(text)
            .font(DFFont.caption)
            .foregroundStyle(DFColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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

// DashboardCard 는 디자인 시스템의 DFMetricCard 로 통합됨 (Sprint A).
// 이전 로컬 구현은 제거.

/// 60 sample 시계열을 부드러운 stroke + 면 채움으로.
private struct MiniSparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2 {
                let minV = values.min() ?? 0
                let maxV = values.max() ?? 1
                let span = max(0.001, maxV - minV)
                let step = geo.size.width / CGFloat(values.count - 1)

                let strokePath = Path { p in
                    for (i, v) in values.enumerated() {
                        let x = CGFloat(i) * step
                        let y = geo.size.height * (1.0 - CGFloat((v - minV) / span))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                let fillPath = Path { p in
                    for (i, v) in values.enumerated() {
                        let x = CGFloat(i) * step
                        let y = geo.size.height * (1.0 - CGFloat((v - minV) / span))
                        if i == 0 { p.move(to: CGPoint(x: x, y: geo.size.height)); p.addLine(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    if let last = values.indices.last {
                        let x = CGFloat(last) * step
                        p.addLine(to: CGPoint(x: x, y: geo.size.height))
                        p.closeSubpath()
                    }
                }
                ZStack {
                    fillPath.fill(LinearGradient(
                        colors: [tint.opacity(DFOpacity.o30), tint.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom))
                    strokePath.stroke(tint, lineWidth: 1.5)
                }
            } else {
                RoundedRectangle(cornerRadius: DFRadius.xs - 1)
                    .fill(DFColor.elev2)
                    .overlay(
                        Text("샘플 수집 중…")
                            .font(.system(size: DFFontSize.s9))
                            .foregroundStyle(DFColor.textSecondary)
                    )
            }
        }
    }
}
