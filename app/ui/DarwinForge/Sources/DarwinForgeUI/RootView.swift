import ForgeCore
import SwiftUI

/// DarwinForge 앱 메인 컨테이너.
///
/// 5개 메인 섹션:
/// - **Studio** (기본) — 3D viewer + 자세 인스펙터 + 텔레메트리
/// - **Motion** — RoboPlus 스타일 페이지/스텝 타임라인 에디터
/// - **Walk Lab** — Webots 스타일 발 trail 시각화
/// - **Conversation** — 자연어 인터페이스 (Claude)
/// - **Expert** — 5탭 전문가 콘솔 (Board/Joints/Motion/Walk/Strategy)
///
/// 단축키: ⌘1..5 섹션 전환, ⌘K 명령 팔레트, ⌘⇧. 비상 정지.
public struct RootView: View {
    @StateObject private var store = ConnectionStore()
    @StateObject private var dispatcher: IntentDispatcher
    private let commander: ClaudeCommander

    @State private var section: Section = .studio
    @State private var expertTab: ExpertTab = .board
    @State private var paletteOpen: Bool = false
    @State private var paletteEntries: [CommandEntry] = CommandCatalog.standard()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var wizardOpen: Bool = false
    @State private var wizardAutoShown: Bool = false
    @State private var dashboardOpen: Bool = false

    public init() {
        let d = IntentDispatcher()
        _dispatcher = StateObject(wrappedValue: d)
        self.commander = ClaudeCommander()
    }

    /// Status bar 높이 — sidebar 끝에 보정용 빈 공간을 둘 때 사용.
    public var body: some View {
        // SwiftUI native NavigationSplitView + .toolbar API + 반응형 (v5):
        //   - macOS unified toolbar 가 신호등 + sidebar toggle + status items 자동 배치
        //   - 사이드바 width 가 윈도우 폭에 따라 동적
        //   - .navigationSplitViewStyle(.automatic) — 좁아지면 시스템이 자동 collapse
        //   - 윈도우 폭/높이를 environment 로 전파 → 자식 view 들이 반응형 분기.
        GeometryReader { geo in
            let w = geo.size.width
            let sidebarIdeal: CGFloat = w < 1100 ? 190 : (w < 1400 ? 215 : 240)
            let sidebarMin: CGFloat = w < 1024 ? 170 : 190
            let sidebarMax: CGFloat = w < 1100 ? 220 : 260

            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(min: sidebarMin,
                                                    ideal: sidebarIdeal,
                                                    max: sidebarMax)
            } detail: {
                ZStack {
                    detail

                    if paletteOpen {
                        paletteOverlay
                    }
                    if wizardOpen {
                        wizardOverlay
                    }
                    if dashboardOpen {
                        dashboardOverlay
                    }
                }
            }
            .navigationSplitViewStyle(.automatic)
            .background(DFColor.canvas)
            .toolbar { toolbarContent }
            .environment(\.dfWindowWidth, geo.size.width)
            .environment(\.dfWindowHeight, geo.size.height)
        }
        .onAppear {
            dispatcher.connectionStore = store
            dispatcher.mode = store.bus != nil ? .hardware : .simulation
            store.refreshPorts()
            // 첫 실행 자동 연결/자동 마법사는 제거됨 — 사용자가 직접
            // 우측 상단 "Auto Connect" 버튼 또는 마법사를 눌러서 연결.
        }
        .onReceive(store.$bus) { bus in
            dispatcher.mode = bus != nil ? .hardware : .simulation
        }
        // P0-G: macOS Menu (DarwinForgeApp.commands) → RootView 액션 분배.
        .onReceive(NotificationCenter.default.publisher(for: .dfSwitchSection)) { note in
            if let raw = note.object as? String, let s = Section(id: raw) {
                section = s
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dfOpenPalette)) { _ in
            paletteOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .dfAutoConnect)) { _ in
            store.autoConnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dfEmergencyStop)) { _ in
            store.emergencyStop()
        }
        .environmentObject(store)
        .environmentObject(dispatcher)
        // 글로벌 단축키 (메뉴와 같은 단축키 — 메뉴 enabled 일 때 메뉴가 우선 처리)
        .background(globalShortcuts)
    }

    // MARK: - Toolbar (macOS unified)

    /// macOS native unified toolbar — 신호등 + sidebar toggle + status pill 들.
    /// 모든 pill 을 ToolbarItem(.principal) 한 자리에 명시 HStack 으로 묶어 → 간격 정확히 통제 +
    /// macOS Button 의 자동 chrome (이중 테두리) 방지.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 좌측 상태 pill 그룹 — 단일 ToolbarItem 으로 묶어 spacing/padding 정확 통제.
        // 디자인 ref: Apple HIG 8pt 그리드 + Linear 미묘 보더 (design-system-references.md §1·§Apple).
        ToolbarItem(placement: .principal) {
            HStack(spacing: 10) {
                connectionToolbarPill
                batteryToolbarPill
                temperatureToolbarPill
                torqueToolbarPill
            }
            .padding(.horizontal, DFSpace.sm)   // toolbar 경계와 첫/마지막 pill 사이 호흡.
        }
        // 우측 액션 그룹 — 단일 ToolbarItem 으로 묶어 macOS 자동 배치(타이트) 회피.
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 10) {
                quickConnectCTA
                paletteShortcutPill
            }
            .padding(.trailing, DFSpace.xs)
        }
    }

    /// ⌘K 팔레트 단축키 — 상태 pill 들과 동일 chrome 으로 통일.
    private var paletteShortcutPill: some View {
        Button {
            paletteOpen = true
        } label: {
            statusPill(active: false, tint: DFColor.accent) {
                HStack(spacing: 3) {
                    Image(systemName: "command")
                        .font(.system(size: 11, weight: .semibold))
                    Text("K")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(DFColor.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .help("명령 팔레트 (⌘K)")
    }

    /// CTA 액션 — Task로 감싸 메인 스레드 block 회피. connect()의 boardSnapshot 동기 호출이
    /// 메인 스레드에서 ~1초 block되면 UI freeze로 "동작 안 함"으로 인식됨.
    private func triggerQuickConnect() {
        Task { @MainActor in
            // 즉시 status .connecting 으로 전환 (사용자 피드백).
            store.status = .connecting("192.168.123.1:5530")
            // 짧은 yield 후 실제 connect — UI 가 .connecting 상태로 한 번 그려진 후 진행.
            try? await Task.sleep(nanoseconds: 50_000_000)
            store.connect(endpoint: .network(host: "192.168.123.1", port: 5530))
        }
    }

    private func quickConnectButton(label: String, icon: String, tint: Color) -> some View {
        Button {
            triggerQuickConnect()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [tint, tint.opacity(0.82)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .clipShape(Capsule())
            .shadow(color: tint.opacity(0.35), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .help("이더넷 직결 192.168.123.1:5530 으로 즉시 연결")
    }

    // MARK: - Quick connect CTA

    /// 우측 상단의 명확한 CTA — 클릭 한 번으로 이더넷 직결 192.168.123.1:5530 연결.
    /// 상태별 시각 강조:
    ///   - 미연결: forge 색 ⚡ "빠른 연결" — 메인 CTA
    ///   - 연결중: 회전 indicator
    ///   - 연결됨: success 색 ✓ "연결 해제"
    ///   - 에러:   danger 색 ↻ 에러 메시지 표시 + 클릭 시 재시도
    @ViewBuilder
    private var quickConnectCTA: some View {
        switch store.status {
        case .disconnected:
            quickConnectButton(label: "빠른 연결", icon: "bolt.fill", tint: DFColor.forge)

        case .error(let msg):
            Button {
                triggerQuickConnect()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                    Text("재시도")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(DFColor.danger)
                .clipShape(Capsule())
                .shadow(color: DFColor.danger.opacity(0.35), radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .help("이전 시도 실패: \(msg) — 클릭 시 재시도")

        case .connecting(let label):
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).tint(.white)
                Text("연결 중 — \(label)")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(.white)
            .background(DFColor.warning)
            .clipShape(Capsule())

        case .connected:
            Button {
                store.disconnect()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "powerplug.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("연결 해제")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(DFColor.danger)
                .background(DFColor.danger.opacity(0.12))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DFColor.danger.opacity(0.35), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("로봇과의 연결을 종료합니다")
        }
    }

    // MARK: - Toolbar style helpers

    /// 데이터 유무에 따른 시각 강조 — 있으면 활성 색, 없으면 dim.
    /// 디자인 ref: Apple HIG 8pt 그리드 + Linear 미묘 보더 (테두리 12% 알파).
    private func statusPill<Content: View>(
        active: Bool,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 12)   // breathing room: 좌우 내부 패딩 (10→12).
            .padding(.vertical, 6)      // 세로 내부 패딩 (5→6) — 컨텐츠 높이 ~24pt.
            .background(active ? tint.opacity(0.14) : DFColor.textSecondary.opacity(0.06))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    active ? tint.opacity(0.35) : DFColor.textSecondary.opacity(0.18),
                    lineWidth: 0.5
                )
            )
    }

    private var isConnectedNow: Bool {
        if case .connected = store.status { return true } else { return false }
    }

    // MARK: - Connection pill

    /// 연결 상태 — 클릭 시 대시보드 (⌘I).
    private var connectionToolbarPill: some View {
        Button {
            dashboardOpen = true
        } label: {
            statusPill(active: isConnectedNow, tint: connectionStatusTint) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionStatusTint)
                        .frame(width: 8, height: 8)
                        .shadow(color: connectionStatusTint.opacity(0.7),
                                radius: isConnectedNow ? 3 : 0)
                    Text(toolbarConnectionLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(connectionStatusTint)
                        .lineLimit(1)
                    if isConnectedNow {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(connectionStatusTint.opacity(0.6))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .help("연결 정보 — 클릭으로 상세 (⌘I)")
        .keyboardShortcut("i", modifiers: .command)
    }

    private var toolbarConnectionLabel: String {
        switch store.status {
        case .disconnected:    return "오프라인"
        case .connecting:      return "연결 중…"
        case .connected(let s):
            if let p = s.controllerLabel.firstIndex(of: "(") {
                return "연결됨 — " + String(s.controllerLabel[..<p]).trimmingCharacters(in: .whitespaces)
            }
            return "연결됨 — \(s.controllerLabel)"
        case .error:           return "연결 오류"
        }
    }

    // MARK: - Battery / Temp / Torque pills

    private var batteryToolbarPill: some View {
        let v = store.lastTelemetry?.board?.voltageVolts
        let active = v != nil
        return statusPill(active: active, tint: batteryTint) {
            HStack(spacing: 5) {
                Image(systemName: batteryIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? batteryTint : DFColor.textSecondary.opacity(0.5))
                if let v {
                    Text(String(format: "%.1fV", v))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(batteryTint)
                } else {
                    Text("배터리")
                        .font(.system(size: 11))
                        .foregroundStyle(DFColor.textSecondary.opacity(0.6))
                }
            }
        }
        .help(active ? "배터리 전압" : "연결 후 표시 — 11.1V 이상 권장")
    }

    private var batteryTint: Color {
        guard let v = store.lastTelemetry?.board?.voltageVolts else { return DFColor.textSecondary }
        if v >= 11.1 { return DFColor.success }
        if v >= 9.5  { return DFColor.warning }
        return DFColor.danger
    }

    private var batteryIcon: String {
        guard let v = store.lastTelemetry?.board?.voltageVolts else { return "battery.0percent" }
        if v >= 11.5 { return "battery.100percent" }
        if v >= 10.5 { return "battery.75percent" }
        if v >= 9.5  { return "battery.50percent" }
        if v >= 8.5  { return "battery.25percent" }
        return "battery.0percent"
    }

    private var temperatureToolbarPill: some View {
        let t = store.lastTelemetry?.avgTemperature
        let active = t != nil
        return statusPill(active: active, tint: temperatureTint) {
            HStack(spacing: 5) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? temperatureTint : DFColor.textSecondary.opacity(0.5))
                if let t {
                    Text(String(format: "%.0f°C", t))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(temperatureTint)
                } else {
                    Text("온도")
                        .font(.system(size: 11))
                        .foregroundStyle(DFColor.textSecondary.opacity(0.6))
                }
            }
        }
        .help(active ? "관절 평균 온도" : "연결 후 표시")
    }

    private var temperatureTint: Color {
        guard let t = store.lastTelemetry?.avgTemperature else { return DFColor.textSecondary }
        if t >= 60 { return DFColor.danger }
        if t >= 50 { return DFColor.warning }
        return DFColor.success
    }

    private var torqueToolbarPill: some View {
        let on = store.lastTelemetry?.torqueOnCount ?? 0
        let active = isConnectedNow
        let tint = active && on > 0 ? DFColor.torque : DFColor.textSecondary
        return statusPill(active: active, tint: tint) {
            HStack(spacing: 5) {
                Image(systemName: active && on > 0 ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? tint : DFColor.textSecondary.opacity(0.5))
                if active {
                    Text("\(on)/20")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint)
                } else {
                    Text("토크")
                        .font(.system(size: 11))
                        .foregroundStyle(DFColor.textSecondary.opacity(0.6))
                }
            }
        }
        .help(active ? "토크 ON 관절 수 / 20" : "연결 후 표시")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            DarwinForgeLogo(variant: .full, density: .standard, showsTagline: true)
                .padding(.horizontal, DFSpace.md)
                .padding(.top, DFSpace.md)
                .padding(.bottom, DFSpace.sm)

            Divider()

            ForEach(Section.allCases, id: \.self) { s in
                sidebarRow(section: s)
            }

            Divider()
                .padding(.vertical, DFSpace.xs)

            Text("전문가 콘솔")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .padding(.horizontal, DFSpace.md)
                .padding(.top, DFSpace.xs)
                .padding(.bottom, 2)

            ForEach(ExpertTab.allCases) { tab in
                expertTabRow(tab)
            }

            Spacer()

            // 원격 도구 빠른 접근 — 연결 여부와 무관하게 항상 노출.
            // 사용자가 연결 전에도 VNC/Vision Tool/SMB 로 접근해 셋업 가능.
            remoteToolsQuickRow
                .padding(.horizontal, DFSpace.sm)
                .padding(.bottom, 8)

            // 연결 마법사 — 첫 진입과 도움 요청 시 launch.
            Button {
                wizardOpen = true
            } label: {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("연결 마법사").font(DFFont.bodyEmph)
                    Spacer()
                    Image(systemName: connectionStatusIcon)
                        .foregroundStyle(connectionStatusTint)
                        .font(.system(size: 11))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, DFSpace.md)
                .background(DFColor.elev2)
                .foregroundStyle(DFColor.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.md)
                        .stroke(DFColor.forge.opacity(0.30), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DFSpace.sm)
            .padding(.bottom, 8)
            .help("연결 안내 화면 열기 — USB / 네트워크 / 자동 검색")

            // E-Stop big button
            Button {
                store.emergencyStop()
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.octagon.fill")
                    Text("긴급 정지").font(DFFont.bodyEmph)
                    Spacer()
                    Text("⌘⇧.")
                        .font(DFFont.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, DFSpace.md)
                .background(DFColor.danger)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .padding(.horizontal, DFSpace.sm)
            .padding(.bottom, DFSpace.sm)

            // Forge core badge
            HStack(spacing: 4) {
                Image(systemName: "cube.box")
                    .font(.system(size: 10))
                Text("forge-core \(forgeCoreVersion())")
                    .font(DFFont.caption.monospaced())
            }
            .foregroundStyle(DFColor.textSecondary)
            .padding(.horizontal, DFSpace.md)
            .padding(.bottom, DFSpace.sm)

        }
    }

    /// 사이드바 빠른 접근 — VNC / Vision Tool / 파일 시스템 세 아이콘.
    /// 활성 endpoint의 host로 자동 URL 생성, macOS 기본 앱에 위임.
    private var remoteToolsQuickRow: some View {
        let host: String = {
            if let ep = store.activeEndpoint, case .network(let h, _) = ep { return h }
            if let ep = store.lastSuccessfulEndpoint, case .network(let h, _) = ep { return h }
            return "192.168.123.1"
        }()
        return VStack(alignment: .leading, spacing: 4) {
            Text("원격 도구")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            HStack(spacing: 6) {
                remoteIconButton(icon: "macwindow", tint: DFColor.accent,
                                 help: "VNC 데스크톱 열기",
                                 url: "vnc://\(host):5900")
                remoteIconButton(icon: "camera.viewfinder", tint: DFColor.success,
                                 help: "Vision Tool (브라우저)",
                                 url: "http://\(host):8080")
                remoteIconButton(icon: "folder", tint: DFColor.warning,
                                 help: "SMB 파일 시스템",
                                 url: "smb://\(host)")
            }
        }
    }

    private func remoteIconButton(icon: String, tint: Color, help: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(tint.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(tint.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("\(help) (\(url))")
    }

    private func sidebarRow(section target: Section) -> some View {
        Button { section = target } label: {
            HStack {
                Image(systemName: target.icon)
                    .frame(width: 22)
                    .foregroundStyle(section == target ? target.tint : DFColor.textSecondary)
                Text(target.label)
                    .font(section == target ? DFFont.bodyEmph : DFFont.body)
                Spacer()
                Text(target.shortcut)
                    .font(DFFont.caption.monospaced())
                    .foregroundStyle(DFColor.textSecondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, DFSpace.md)
            .background(section == target ? target.tint.opacity(0.14) : Color.clear)
            .foregroundStyle(section == target ? DFColor.textPrimary : DFColor.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm, style: .continuous))
            .padding(.horizontal, DFSpace.sm)
        }
        .buttonStyle(.plain)
    }

    private func expertTabRow(_ tab: ExpertTab) -> some View {
        Button {
            section = .expert
            expertTab = tab
        } label: {
            HStack {
                Image(systemName: tab.icon).frame(width: 22)
                Text(tab.label)
                    .font(DFFont.body)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, DFSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (section == .expert && expertTab == tab)
                    ? DFColor.accent.opacity(0.12) : Color.clear
            )
            .foregroundStyle(
                (section == .expert && expertTab == tab) ? DFColor.accent : DFColor.textPrimary
            )
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm, style: .continuous))
            .padding(.horizontal, DFSpace.sm)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .studio:
            StudioView()
        case .teach:
            TeachModeView()
        case .motion:
            MotionStudioView()
        case .walk:
            WalkLabView()
        case .conversation:
            ConversationView(commander: commander, dispatcher: dispatcher)
        case .pilot:
            RemotePilotView()
        case .remote:
            RemoteShellView()
        case .expert:
            expertDetail
        }
    }

    @ViewBuilder
    private var expertDetail: some View {
        switch expertTab {
        case .board:    ExpertDashboard()
        case .joints:   JointControlView()
        case .motion:   MotionLibraryView()
        case .walk:     WalkLabView()
        case .strategy: StrategyView()
        }
    }

    // MARK: - Command palette overlay

    private var paletteOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .onTapGesture { paletteOpen = false }
            CommandPalette(
                isPresented: $paletteOpen,
                entries: paletteEntries,
                onRun: { entry in
                    Task { await dispatch(entry.action) }
                }
            )
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }

    // MARK: - Sidebar connection status helpers

    private var connectionStatusIcon: String {
        switch store.status {
        case .connected:    return "checkmark.circle.fill"
        case .connecting:   return "arrow.triangle.2.circlepath"
        case .error:        return "exclamationmark.triangle.fill"
        case .disconnected: return "circle"
        }
    }

    private var connectionStatusTint: Color {
        switch store.status {
        case .connected:    return DFColor.success
        case .connecting:   return DFColor.warning
        case .error:        return DFColor.danger
        case .disconnected: return DFColor.textSecondary.opacity(0.6)
        }
    }

    // MARK: - Wizard overlay

    private var wizardOverlay: some View {
        ZStack {
            Color.black.opacity(0.40)
                .onTapGesture { wizardOpen = false }
            ConnectionWizardView(isPresented: $wizardOpen)
                .environmentObject(store)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    // MARK: - Dashboard overlay

    private var dashboardOverlay: some View {
        ZStack {
            Color.black.opacity(0.40)
                .onTapGesture { dashboardOpen = false }
            ConnectionDashboardView(isPresented: $dashboardOpen)
                .environmentObject(store)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    private func dispatch(_ action: CommandAction) async {
        switch action {
        case .connect:           store.autoConnect()
        case .disconnect:        store.disconnect()
        case .scanJoints:
            if let bus = store.bus {
                _ = try? bus.scan(lo: 1, hi: 20)
            }
        case .wakeUp:
            if let bus = store.bus {
                for j in JointID.allCases { try? bus.setTorque(j, enable: true) }
            }
        case .sleep:
            try? store.bus?.emergencyStop()
        case .emergencyStop:
            store.emergencyStop()
        case .switchSection(let id):
            if let s = Section(id: id) { section = s }
        case .switchExpertTab(let id):
            if let t = ExpertTab(rawValue: id) {
                section = .expert
                expertTab = t
            }
        case .applyPose, .mirrorPose, .resetPose,
             .fillFromTelemetry, .saveCurrentPoseAsKeyframe:
            // Studio가 자체 메모리에 자세를 보유하므로 NotificationCenter로 fan-out.
            NotificationCenter.default.post(
                name: .dfStudioCommand,
                object: action
            )
        case .importMotion:
            section = .motion
        case .playSelectedPage, .stopPlayback:
            section = .motion
            NotificationCenter.default.post(
                name: .dfMotionCommand,
                object: action
            )
        }
    }

    // MARK: - Global shortcuts

    private var globalShortcuts: some View {
        ZStack {
            Button("Open palette") { paletteOpen = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("Section 1") { section = .studio }
                .keyboardShortcut("1", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("Section 2") { section = .teach }
                .keyboardShortcut("2", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("Section 3") { section = .motion }
                .keyboardShortcut("3", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("Section 4") { section = .walk }
                .keyboardShortcut("4", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("Section 5") { section = .conversation }
                .keyboardShortcut("5", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("Section 6") { section = .remote }
                .keyboardShortcut("6", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("Section 7") { section = .expert }
                .keyboardShortcut("7", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("Section 8") { section = .pilot }
                .keyboardShortcut("8", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)
            Button("Auto Connect") { store.autoConnect() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .opacity(0).frame(width: 0, height: 0)
        }
    }
}

// MARK: - Sections

private enum Section: String, CaseIterable, Hashable {
    case studio, teach, motion, walk, conversation, remote, expert, pilot

    init?(id: String) {
        self.init(rawValue: id)
    }

    var label: String {
        switch self {
        case .studio:        return "스튜디오"
        case .teach:         return "티칭 모드"
        case .motion:        return "모션 스튜디오"
        case .walk:          return "워크 랩"
        case .conversation:  return "대화"
        case .pilot:         return "원격 조종"
        case .remote:        return "원격 명령"
        case .expert:        return "전문가"
        }
    }

    var icon: String {
        switch self {
        case .studio:        return "rectangle.3.group.fill"
        case .teach:         return "hand.point.up.braille.fill"
        case .motion:        return "play.rectangle.on.rectangle"
        case .walk:          return "figure.walk"
        case .conversation:  return "bubble.left.and.bubble.right.fill"
        case .pilot:         return "gamecontroller.fill"
        case .remote:        return "terminal.fill"
        case .expert:        return "wrench.and.screwdriver"
        }
    }

    var shortcut: String {
        switch self {
        case .studio:        return "⌘1"
        case .teach:         return "⌘2"
        case .motion:        return "⌘3"
        case .walk:          return "⌘4"
        case .conversation:  return "⌘5"
        case .remote:        return "⌘6"
        case .expert:        return "⌘7"
        case .pilot:         return "⌘8"
        }
    }

    var tint: Color {
        switch self {
        case .studio:        return DFColor.forge
        case .teach:         return DFColor.info
        case .motion:        return DFColor.accent
        case .walk:          return DFColor.success
        case .conversation:  return DFColor.info
        case .pilot:         return DFColor.accent
        case .remote:        return DFColor.warning
        case .expert:        return DFColor.textSecondary
        }
    }
}

private enum ExpertTab: String, CaseIterable, Identifiable, Hashable {
    case board, joints, motion, walk, strategy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .board:    return "보드 상태"
        case .joints:   return "관절 제어"
        case .motion:   return "동작 라이브러리"
        case .walk:     return "보행 시뮬"
        case .strategy: return "전략 FSM"
        }
    }
    var icon: String {
        switch self {
        case .board:    return "cpu"
        case .joints:   return "slider.horizontal.3"
        case .motion:   return "play.rectangle.on.rectangle"
        case .walk:     return "figure.walk"
        case .strategy: return "brain.head.profile"
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// CommandPalette → Studio/Motion fan-out
    public static let dfStudioCommand = Notification.Name("DarwinForge.StudioCommand")
    public static let dfMotionCommand = Notification.Name("DarwinForge.MotionCommand")

    /// P0-G: macOS Menu (DarwinForgeApp) → RootView fan-out.
    /// 메뉴는 SwiftUI App scope에 있고 RootView는 Window 안에 있어 NotificationCenter로 느슨 결합.
    public static let dfSwitchSection = Notification.Name("DarwinForge.SwitchSection")
    public static let dfOpenPalette   = Notification.Name("DarwinForge.OpenPalette")
    public static let dfAutoConnect   = Notification.Name("DarwinForge.AutoConnect")
    public static let dfEmergencyStop = Notification.Name("DarwinForge.EmergencyStop")

    /// 티칭 모드 → Studio 로 자세 전달. object 는 RobotPose.
    public static let dfTransferPoseToStudio = Notification.Name("DarwinForge.TransferPoseToStudio")
    /// Studio → MotionStudio 로 자세 전달. object 는 RobotPose.
    public static let dfTransferPoseToMotion = Notification.Name("DarwinForge.TransferPoseToMotion")
}
