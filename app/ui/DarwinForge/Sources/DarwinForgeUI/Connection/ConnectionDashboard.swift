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

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

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
            harness.record(.connectDisconnect, level: .info, actor: .user)
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
                if isConnectedNow {
                    telemetryModeBanner
                    liveStatusHero
                }
                topRowCards
                bottomRowCards
                sparklinesRow
                remoteToolsCard
            }
            .padding(DFSpace.md)
        }
        .glassScroll(accent: DFColor.accent)
    }

    // MARK: - 텔레메트리 경로/엔진 배지 + 안전게이트 배너 (W5)

    /// 현재 텔레메트리 경로(LAN vs 온보드SSH)와 안전게이트 온/오프라인을 한 줄로.
    ///
    /// **정직성**: 온보드(SSH) 모드는 로봇이 IMU/전압만 업링크하므로(관절/온도 없음)
    /// "초록불=실시간"을 오해시키지 않도록 경로를 명시하고, 신선 샘플이 끊기면
    /// (`.onboardStale`) 호박색으로 강등한다. 안전게이트는 `mode.isLive` 일 때만 온라인.
    private var telemetryModeBanner: some View {
        let mode = store.telemetryMode
        return HStack(spacing: DFSpace.sm) {
            // 경로/엔진 배지.
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: mode.iconSystemName)
                    .font(.system(size: DFFontSize.s12, weight: .semibold))
                Text(mode.pathLabel)
                    .font(.system(size: DFFontSize.s12, weight: .bold))
            }
            .foregroundStyle(mode.tint)
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, DFSpace.xs2)
            .background(mode.tint.opacity(DFOpacity.o15))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(mode.tint.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline))

            // **활성 경로 정직성 (2026-06-02)**: 지금 붙어 있는 경로가 유선(케이블)인지 무선(WiFi)
            // 인지 + host 를 명시. "무선이라 믿었는데 실은 유선" 혼동을 제거(랜선 뽑으면 끊김).
            // host 가 없으면(USB 시리얼/미연결) 칩을 숨긴다 — 유선/무선 개념이 없음.
            if mode != .offline, !store.activeConnectionHost.trimmingCharacters(in: .whitespaces).isEmpty {
                linkKindChip
            }

            Spacer()

            // 안전게이트 — **정직성 fix**: Mac 게이트 실제 동작 여부 기준(온보드는 로봇 자율).
            let banner = mode.safetyBanner
            let bannerColor: Color = {
                switch banner.level {
                case .ok:      return DFColor.success
                case .caution: return DFColor.warning
                case .danger:  return DFColor.danger
                }
            }()
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: banner.level == .ok ? "checkmark.shield.fill"
                      : (banner.level == .caution ? "shield.lefthalf.filled" : "shield.slash.fill"))
                    .font(.system(size: DFFontSize.s12, weight: .semibold))
                Text(banner.text)
                    .font(.system(size: DFFontSize.s12, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(bannerColor)
            .padding(.horizontal, DFSpace.sm)
            .padding(.vertical, DFSpace.xs2)
            .background(bannerColor.opacity(DFOpacity.o15))
            .clipShape(Capsule())
        }
        .help(mode.hasThermal
              ? "LAN 경로 — Mac 이 전압·IMU·관절·온도 전체 비상게이트 모니터링."
              : "온보드(SSH) — Mac 비상게이트(전압·기울기·열)는 미작동(bus 없음). "
              + "낙상 시 일어나기·정지는 로봇 demo 가 자율 처리.")
    }

    /// **활성 유선/무선 + host 칩** — 케이블 의존 여부를 한눈에. 유선은 "랜선 뽑으면 끊김"
    /// 경고 톤, 무선은 success 톤. host 가 비면 노출 안 함(`mode != .offline` 가드는 호출부).
    private var linkKindChip: some View {
        let host = store.activeConnectionHost.trimmingCharacters(in: .whitespaces)
        let link = ConnectionLinkKind.classify(host: host)
        return HStack(spacing: DFSpace.xs2) {
            Image(systemName: link.icon)
                .font(.system(size: DFFontSize.s12, weight: .semibold))
            Text(host.isEmpty ? link.label : "\(link.label) · \(host)")
                .font(.system(size: DFFontSize.s12, weight: .bold))
                .lineLimit(1)
            if link.requiresCable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: DFFontSize.s10, weight: .bold))
            }
        }
        .foregroundStyle(link.tint)
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs2)
        .background(link.tint.opacity(DFOpacity.o15))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(link.tint.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline))
        .help(link.cableHint)
        .accessibilityIdentifier("dashboard.linkKind")
    }

    // MARK: - 실시간 연결 상태 히어로

    /// 연결 유지 시간을 큰 실시간 시계(HH:MM:SS)로 + 데이터 신선도를 한눈에.
    /// `now` 1초 tick 으로 매초 갱신 → "실시간" 체감. 연결 상태에서만 노출.
    ///
    /// 표시 데이터는 모두 실측: `store.connectedAt`(연결 성공 시각),
    /// `store.lastSuccessAt`(마지막 성공 board read 시각). 가공/추정 없음.
    private var liveStatusHero: some View {
        let uptime = store.connectedAt.map { now.timeIntervalSince($0) } ?? 0
        return HStack(alignment: .top, spacing: DFSpace.md) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                HStack(spacing: DFSpace.xs2) {
                    livePulseDot
                    Text("실시간 연결 유지 시간")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
                Text(formatUptimeClock(uptime))
                    .font(.system(size: DFFontSize.s32, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(DFColor.textPrimary)
                    .contentTransition(.numericText())
                if let at = store.connectedAt {
                    Text("\(at.formatted(date: .omitted, time: .standard)) 연결 시작")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
            Spacer()
            freshnessBadge
        }
        .padding(DFSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DFColor.success.opacity(DFOpacity.o06))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.md)
                .stroke(DFColor.success.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline)
        )
    }

    /// 살아있는 폴링을 알리는 맥동 점 (SF Symbols pulse).
    private var livePulseDot: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: DFFontSize.s8))
            .foregroundStyle(DFColor.success)
            .symbolEffect(.pulse, options: .repeating)
    }

    /// 데이터 신선도 — 마지막 성공 read 로부터 경과로 "실시간성" 을 색으로 표현.
    ///
    /// **정직성(W5)**: `telemetryMode` 가 라이브가 아니거나 온보드 지연이면 경과시간이
    /// 짧더라도 초록을 띄우지 않는다(stale-green 금지). 오프라인/지연은 회색/호박색.
    private var freshnessBadge: some View {
        let mode = store.telemetryMode
        return VStack(alignment: .trailing, spacing: DFSpace.xs) {
            Text("데이터 신선도")
                .font(.system(size: DFFontSize.s10))
                .foregroundStyle(DFColor.textSecondary)
            if !mode.isLive {
                // 오프라인/지연 — 마지막 성공값이 있어도 "실시간"으로 표시 금지.
                Text(mode == .onboardStale ? "온보드 지연" : "라이브 아님")
                    .font(.system(size: DFFontSize.s16, weight: .bold, design: .rounded))
                    .foregroundStyle(mode == .onboardStale ? DFColor.warning : DFColor.textSecondary)
            } else if let last = store.lastSuccessAt {
                let elapsed = now.timeIntervalSince(last)
                let (txt, tint): (String, Color) =
                    elapsed < 1.5 ? ("실시간", DFColor.success)
                    : elapsed < 5  ? ("\(Int(elapsed))초 전", DFColor.success)
                    : ("\(Int(elapsed))초 지연", DFColor.warning)
                Text(txt)
                    .font(.system(size: DFFontSize.s16, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            } else {
                Text("대기 중")
                    .font(.system(size: DFFontSize.s16, weight: .bold, design: .rounded))
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
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
                    urlString: "vnc://\(remoteHost):5900",
                    buttonKey: "remote_vnc"
                )
                remoteToolButton(
                    label: "Vision Tool",
                    detail: "카메라 · 색상 튜닝 (브라우저)",
                    icon: "camera.viewfinder",
                    tint: DFColor.success,
                    urlString: "http://\(remoteHost):8080",
                    buttonKey: "remote_vision"
                )
                remoteToolButton(
                    label: "파일 시스템",
                    detail: "SMB 공유 (Finder)",
                    icon: "folder",
                    tint: DFColor.warning,
                    urlString: "smb://\(remoteHost)",
                    buttonKey: "remote_smb"
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

    private func remoteToolButton(label: String, detail: String, icon: String, tint: Color, urlString: String, buttonKey: String) -> some View {
        Button {
            harness.record(
                .uiButtonTapped, level: .info, actor: .user,
                data: ["button": AnyCodable(buttonKey),
                       "url_hash": AnyCodable(Harness.shortHash(urlString))]
            )
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
                    metricRow(label: "추정 잔량", value: "약 \(batteryPercent(v))%", tint: batteryColor)
                    Text(batteryAdvice(v))
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
                // staleness 탈색 — 라이브가 아니거나 온보드 지연이면 마지막 전압을
                // fresh-green 으로 표시하지 않도록 채도를 낮춰 "보존된 값" 임을 알린다.
                .saturation(store.telemetryMode.shouldDesaturate ? 0 : 1)
                .opacity(store.telemetryMode.shouldDesaturate ? DFOpacity.o70 : 1)
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
    /// 추정 잔량 % — voltageBar 와 동일한 8.0~12.6V 선형 매핑.
    /// 3S LiPo 의 전압-SoC 곡선은 비선형이므로 정밀 SoC 가 아닌 **추정치** ("약 N%").
    private func batteryPercent(_ v: Double) -> Int {
        let frac = (v - 8.0) / (12.6 - 8.0)
        return Int((max(0, min(1, frac)) * 100).rounded())
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
                    // 연결 유지 시간·신선도는 상단 히어로에서 실시간 표시 — 중복 제거.
                    // 대신 실측 수신 관절 수(폴링 중인 관절)를 노출.
                    if let joints = store.lastTelemetry?.joints, !joints.isEmpty {
                        metricRow(label: "관절 수신", value: "\(joints.count)개")
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
                format: "%.0f",
                footnote: tempFootnote
            )
        }
    }

    /// 온도 스파크라인 보조 라인 — 실측 최고 관절 온도 + 토크 ON 관절 수.
    /// `hottestJoint`/`torqueOnCount` 는 폴링된 관절 집합 기준 실측값.
    ///
    /// **정직성(W5, 계약 §F-6)**: 온보드(SSH) 모드는 관절 온도가 없어 L4 열 게이트가
    /// 오프라인이다. 빈 값을 침묵하지 말고 "열 오프라인"으로 명시한다.
    private var tempFootnote: String? {
        if !store.telemetryMode.hasThermal && store.telemetryMode != .offline {
            return "열 오프라인 — 온보드 경로엔 관절 온도 없음"
        }
        guard let snap = store.lastTelemetry, !snap.joints.isEmpty else { return nil }
        var parts: [String] = []
        if let hot = snap.hottestJoint {
            parts.append("최고 \(Int(hot.1.presentTemperature))°C")
        }
        parts.append("토크 \(snap.torqueOnCount)/\(snap.joints.count)")
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var tempColor: Color {
        guard let t = store.lastTelemetry?.avgTemperature else { return DFColor.textSecondary }
        if t >= 60 { return DFColor.danger }
        if t >= 50 { return DFColor.warning }
        return DFColor.success
    }

    private func sparklineCard(title: String, tint: Color, values: [Double], unit: String, format: String, footnote: String? = nil) -> some View {
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
                // 60초 창의 최저/최고 범위 + (옵션) 실측 보조 정보.
                if values.count >= 2 || footnote != nil {
                    HStack(spacing: DFSpace.xs2) {
                        if values.count >= 2, let lo = values.min(), let hi = values.max() {
                            Text("최저 \(String(format: format, lo)) · 최고 \(String(format: format, hi)) \(unit)")
                                .font(.system(size: DFFontSize.s9, design: .monospaced))
                                .foregroundStyle(DFColor.textSecondary)
                        }
                        Spacer()
                        if let footnote {
                            Text(footnote)
                                .font(.system(size: DFFontSize.s9))
                                .foregroundStyle(DFColor.textSecondary)
                        }
                    }
                }
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
                        .font(DFIcon.micro)
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

    /// 연결 유지 시간을 매초 갱신되는 HH:MM:SS 시계로 — 실시간 체감.
    private func formatUptimeClock(_ s: TimeInterval) -> String {
        let total = max(0, Int(s))
        let h = total / 3600
        let m = (total / 60) % 60
        let sec = total % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
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
