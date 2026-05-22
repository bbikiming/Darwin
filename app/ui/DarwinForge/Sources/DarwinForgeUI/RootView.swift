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
    // RemoteShell — 원격 명령 SSH/SMB 채널 (Sprint 18 환경 공유). Pilot 모드 picker
    // 등 다른 화면이 같은 인스턴스로 명령을 보내고, RemoteShellView 가 그 히스토리를
    // 보여준다.
    @StateObject private var remoteShell = RemoteShell()
    // **v1.11.12/13 (2026-05-19)** — Critic + A/B 실험 loop 전역 singleton.
    @StateObject private var claudeCritic = WalkSessionClaudeCritic()
    @StateObject private var experimentLoop = ExperimentLoopController()
    // **v1.11.14 (2026-05-19)** — WalkLabSession 전역 singleton.
    // 종전 WalkLabView 내 @StateObject — WalkDataView 의 실험 승인 흐름이 같은
    // session 인스턴스 (현재 config) 를 읽고 변경하도록 RootView 로 hoist.
    // 라이프사이클: 앱 전체. 메뉴/탭 전환 시 보존.
    @State private var walkLabSession = WalkLabSession()
    /// **v1.20.1 사이클 7-fix HIGH 1 (코덱스 검수)** — Pilot bridge production wiring.
    /// `WalkLabSession.pilotBridge` 가 `nil` 이면 trial finalize 시 pilot summary 첨부가
    /// no-op. RootView 의 onAppear 에서 bridge 인스턴스 생성 + 양방향 wiring.
    /// telloLink 는 init 시 socket 안 열림 (start() 호출 시에만). nil = 아직 onAppear 안 됨.
    @State private var pilotBridge: WalkLabRCBridge? = nil
    /// **v1.20.35 사이클 18** — Tello state listener (UDP 8890) lifecycle owner.
    /// bridge 와 listener 사이 wiring 담당. start() 시 listener bind → onState callback
    /// 이 MainActor hop 후 bridge.updateTelloState 호출.
    /// nil = bridge alloc 전 (onAppear 후 일괄 alloc).
    @State private var telloStateOwner: TelloStateListenerOwner? = nil
    // **v1.11.15 (2026-05-19)** — 테마 매니저. DarwinForgeApp 이 environmentObject 로 주입.
    @EnvironmentObject private var themeManager: DFThemeManager
    private let commander: ClaudeCommander
    /// **v1.20.1 사이클 7-fix HIGH 1** — Tello UDP 송신 채널.
    /// `start()` 호출 전까지 socket 안 열림 → 사용자가 Tello 연결 시까지 idle.
    private let telloLink: TelloLink

    @State private var section: Section = .studio
    @State private var expertTab: ExpertTab = .board
    @State private var paletteOpen: Bool = false
    @State private var paletteEntries: [CommandEntry] = CommandCatalog.standard()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var wizardOpen: Bool = false
    @State private var wizardAutoShown: Bool = false
    @State private var dashboardOpen: Bool = false
    @State private var showRecoveryConfirm: Bool = false

    public init() {
        let d = IntentDispatcher()
        _dispatcher = StateObject(wrappedValue: d)
        self.commander = ClaudeCommander()
        // **v1.20.1 사이클 7-fix HIGH 1** — Tello UDP 채널 생성 (no-op until start()).
        // init 은 socket 미생성 → cost 없음. 사용자가 Tello 연결 시 start() 발화.
        self.telloLink = TelloLink()
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
                    recoveryToastOverlay
                }
            }
            // `.balanced` — 좁은 윈도우에서도 사이드바 자동 collapse 안 함.
            // 사용자가 실수로 사이드바 토글 버튼을 눌러도 ⌘⌃S 또는 메뉴
            // "보기 → 사이드바 표시"로 복구 가능.
            .navigationSplitViewStyle(.balanced)
            // v1.11.15 (2026-05-19): 테마 인식 배경 — flat 모드 시 #FFFFFF, 그 외 light/dark.
            .background(DFColor.adaptiveCanvas(themeManager.theme))
            .toolbar { toolbarContent }
            // v1.11.15 cycle 2: 완벽 무채색 — flat 모드에서 자식 view 전체 saturation=0.
            // accent/forge/danger/success/warning/info/torque 모두 자동으로 grayscale 톤.
            // 의미는 명도 차이로 유지 (danger = 진한 회색, success = 옅은 회색 등).
            .saturation(themeManager.theme.isFlat ? 0 : 1)
            .environment(\.dfWindowWidth, geo.size.width)
            .environment(\.dfWindowHeight, geo.size.height)
        }
        // 윈도우 / fullscreen 전체 채움 명시 — WindowGroup frame max .infinity 와 결합해
        // 사용자가 윈도우를 확장하거나 ⌃⌘F 로 fullscreen 진입 시 RootView 도 화면 가득.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            dispatcher.connectionStore = store
            dispatcher.mode = store.bus != nil ? .hardware : .simulation
            store.refreshPorts()
            // **v1.11.14.3 (2026-05-19) — 진단 cold #E fix**: 종전 별도 onAppear 에서
            // setExperimentLoop 호출 — 첫 body render 전 session end 발생 시 nil race.
            // 첫 onAppear (앱 시작 직후) 에서 wiring 하여 race window 최소화. 또한
            // idempotent (같은 controller 받으면 closure overwrite, 동작 동일).
            walkLabSession.setExperimentLoop(experimentLoop)
            // **v1.20.1 사이클 7-fix HIGH 1** — Pilot bridge production wiring.
            // 일회성: 이미 생성된 경우 skip (idempotent — onAppear 가 view re-mount 시 재발화 가능).
            // 양방향: session→bridge (weak, finalize 시 snapshot) + bridge→session (weak, amplitude 적용).
            if pilotBridge == nil {
                let bridge = WalkLabRCBridge(tello: telloLink)
                bridge.session = walkLabSession
                walkLabSession.pilotBridge = bridge
                pilotBridge = bridge
            }
            // **v1.20.35 사이클 18** — Tello state listener owner alloc + start.
            // listener 의 raw UDP transport 가 bridge.updateTelloState 까지 도달하도록 wiring.
            // start() 가 silent 실패 (NSLocalNetworkUsageDescription 미허락) 시 OSLog 만 남기고
            // isActive=false 유지 → 사용자 권한 허용 후 재 start 가능 (현재는 일회성).
            if telloStateOwner == nil, let bridge = pilotBridge {
                let owner = TelloStateListenerOwner(bridge: bridge)
                owner.start()
                telloStateOwner = owner
            }
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
        // v1.12.0 telemetry — section 변경 추적 (메뉴/단축키/사이드바 모두 포착).
        .onChange(of: section) { newValue in
            Harness.shared.record(
                .uiSectionChanged, level: .info, actor: .user,
                data: ["to": AnyCodable(newValue.rawValue)]
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .dfOpenPalette)) { _ in
            paletteOpen = true
            Harness.shared.record(.uiPaletteOpened, level: .info, actor: .user)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dfAutoConnect)) { _ in
            store.autoConnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dfEmergencyStop)) { _ in
            store.emergencyStop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dfShowSidebar)) { _ in
            // ⌘⌃S 또는 메뉴 → 사이드바 강제 표시 (실수로 collapse 했을 때 복구).
            withAnimation { columnVisibility = .all }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dfOpenConnectionWizard)) { _ in
            // Pilot 카메라 패널 등에서 "연결 마법사로 가기" 요청.
            wizardOpen = true
        }
        // v1.11.15 (2026-05-19): 메뉴 / 외부 → 테마 설정.
        .onReceive(NotificationCenter.default.publisher(for: .dfSetTheme)) { note in
            if let raw = note.object as? String, let parsed = DFTheme(rawValue: raw) {
                themeManager.setTheme(parsed)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dfCycleTheme)) { _ in
            themeManager.cycle()
        }
        .environmentObject(store)
        .environmentObject(dispatcher)
        .environmentObject(remoteShell)
        .environmentObject(claudeCritic)
        .environmentObject(experimentLoop)
        // **v1.14.9 (2026-05-21) Fix #7** — @Observable 은 .environment(_:) 로 주입.
        .environment(walkLabSession)
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
        // 윈도우 폭 < 1100 일 때 보조 pill (배터리/온도/토크) 의 텍스트 hide, icon-only.
        // < 900 에선 보조 pill 자체 hide — 연결 pill 만 유지 + 우측 CTA 보장.
        ToolbarItem(placement: .principal) {
            ResponsiveToolbarRow { size in
                HStack(spacing: DFSpace.sm2) {
                    connectionToolbarPill   // 항상 표시 (핵심 상태).
                    if !size.isCompact {
                        // regular / wide — 보조 pill 모두 표시. 텍스트는 wide 에서만.
                        batteryToolbarPill
                        temperatureToolbarPill
                        torqueToolbarPill
                    }
                }
                .padding(.horizontal, DFSpace.sm)
            }
        }
        // 우측 액션 그룹 — 단일 ToolbarItem 으로 묶어 macOS 자동 배치(타이트) 회피.
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: DFSpace.sm2) {
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
                        .font(.system(size: DFFontSize.s11, weight: .semibold))
                    Text("K")
                        .font(.system(size: DFFontSize.s11, weight: .semibold, design: .monospaced))
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
                    .font(.system(size: DFFontSize.s11, weight: .bold))
                Text(label)
                    .font(.system(size: DFFontSize.s12, weight: .semibold))
            }
            .dfPillPadding()
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [tint, tint.opacity(0.82)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .clipShape(Capsule())
            .shadow(color: tint.opacity(DFOpacity.strong), radius: DFSpace.xs, y: DFSpace.micro)
        }
        .buttonStyle(.plain)
        .help("이더넷 직결 192.168.123.1:5530 으로 즉시 연결")
    }

    // MARK: - Quick connect CTA

    /// 우측 상단의 명확한 CTA — 클릭 한 번으로 이더넷 직결 192.168.123.1:5530 연결.
    /// 2026-05-17 UX 통일: "빠른 연결" / "한 번 클릭으로 연결" 혼용 → "자동 연결" 통일.
    /// 상태별 시각 강조:
    ///   - 미연결: forge 색 ⚡ "자동 연결" — 메인 CTA
    ///   - 연결중: 회전 indicator
    ///   - 연결됨: success 색 ✓ "연결 해제"
    ///   - 에러:   danger 색 ↻ 에러 메시지 표시 + 클릭 시 재시도
    @ViewBuilder
    private var quickConnectCTA: some View {
        switch store.status {
        case .disconnected:
            quickConnectButton(label: "자동 연결", icon: "bolt.fill", tint: DFColor.forge)

        case .error(let msg):
            Button {
                triggerQuickConnect()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: DFFontSize.s11, weight: .bold))
                    Text("재시도")
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                }
                .dfPillPadding()
                .foregroundStyle(.white)
                .background(DFColor.danger)
                .clipShape(Capsule())
                .shadow(color: DFColor.danger.opacity(DFOpacity.strong), radius: DFSpace.xs, y: DFSpace.micro)
            }
            .buttonStyle(.plain)
            .help("이전 시도 실패: \(msg) — 클릭 시 재시도")

        case .connecting(let label):
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).tint(.white)
                Text("연결 중 — \(label)")
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
                    .lineLimit(1)
            }
            .dfPillPadding()
            .foregroundStyle(.white)
            .background(DFColor.warning)
            .clipShape(Capsule())

        case .connected:
            Button {
                store.disconnect()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "powerplug.fill")
                        .font(.system(size: DFFontSize.s11, weight: .bold))
                    Text("연결 해제")
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                }
                .dfPillPadding()
                .foregroundStyle(DFColor.danger)
                .background(DFColor.danger.opacity(DFOpacity.subtle))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DFColor.danger.opacity(DFOpacity.strong), lineWidth: DFSize.borderHairline))
            }
            .buttonStyle(.plain)
            .help("로봇과의 연결을 종료합니다")
        }
    }

    // MARK: - Toolbar style helpers

    /// 데이터 유무에 따른 시각 강조 — 있으면 활성 색, 없으면 dim.
    /// 디자인 토큰 일원화: `DFSize.pillPaddingH/V` + `dfPill(active:tint:)` 사용.
    private func statusPill<Content: View>(
        active: Bool,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content().dfPill(active: active, tint: tint)
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
                HStack(spacing: DFSpace.xs2) {
                    Circle()
                        .fill(connectionStatusTint)
                        .frame(width: DFSize.indicatorSm, height: DFSize.indicatorSm)
                        .shadow(color: connectionStatusTint.opacity(DFOpacity.o70),
                                radius: isConnectedNow ? 3 : 0)
                    Text(toolbarConnectionLabel)
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                        .foregroundStyle(connectionStatusTint)
                        .lineLimit(1)
                    if isConnectedNow {
                        Image(systemName: "chevron.right")
                            .font(.system(size: DFFontSize.s9, weight: .semibold))
                            .foregroundStyle(connectionStatusTint.opacity(DFOpacity.dim))
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
        ResponsiveToolbarRow { size in
            let v = store.lastTelemetry?.board?.voltageVolts
            let active = v != nil
            return statusPill(active: active, tint: batteryTint) {
                HStack(spacing: DFSpace.xs2) {
                    Image(systemName: batteryIcon)
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                        .foregroundStyle(active ? batteryTint : DFColor.textSecondary.opacity(DFOpacity.o50))
                    if size.isWide {
                        if let v {
                            Text(String(format: "%.1fV", v))
                                .font(.system(size: DFFontSize.s11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(batteryTint)
                        } else {
                            Text("배터리")
                                .font(.system(size: DFFontSize.s11))
                                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                        }
                    }
                }
            }
            .help(active
                  ? (v.map { String(format: "배터리 %.1fV", $0) } ?? "배터리")
                  : "연결 후 표시 — 11.1V 이상 권장")
        }
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
        ResponsiveToolbarRow { size in
            let t = store.lastTelemetry?.avgTemperature
            let active = t != nil
            return statusPill(active: active, tint: temperatureTint) {
                HStack(spacing: DFSpace.xs2) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                        .foregroundStyle(active ? temperatureTint : DFColor.textSecondary.opacity(DFOpacity.o50))
                    if size.isWide {
                        if let t {
                            Text(String(format: "%.0f°C", t))
                                .font(.system(size: DFFontSize.s11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(temperatureTint)
                        } else {
                            Text("온도")
                                .font(.system(size: DFFontSize.s11))
                                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                        }
                    }
                }
            }
            .help(active
                  ? (t.map { String(format: "관절 평균 온도 %.0f°C", $0) } ?? "관절 평균 온도")
                  : "연결 후 표시")
        }
    }

    private var temperatureTint: Color {
        guard let t = store.lastTelemetry?.avgTemperature else { return DFColor.textSecondary }
        if t >= 60 { return DFColor.danger }
        if t >= 50 { return DFColor.warning }
        return DFColor.success
    }

    private var torqueToolbarPill: some View {
        ResponsiveToolbarRow { size in
            let on = store.lastTelemetry?.torqueOnCount ?? 0
            let active = isConnectedNow
            let tint = active && on > 0 ? DFColor.torque : DFColor.textSecondary
            return statusPill(active: active, tint: tint) {
                HStack(spacing: DFSpace.xs2) {
                    Image(systemName: active && on > 0 ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                        .foregroundStyle(active ? tint : DFColor.textSecondary.opacity(DFOpacity.o50))
                    if size.isWide {
                        if active {
                            Text("\(on)/20")
                                .font(.system(size: DFFontSize.s11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(tint)
                        } else {
                            Text("토크")
                                .font(.system(size: DFFontSize.s11))
                                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                        }
                    }
                }
            }
            .help(active ? "토크 ON 관절 \(on)/20" : "연결 후 표시")
        }
    }

    // MARK: - Sidebar
    //
    // **v1.11.15 cycle 2 (2026-05-19)** — 3구역 분리로 height 안정성 확보.
    // 종전 단일 VStack + Spacer 패턴은 메뉴/탭 + 5개 하단 버튼 + 테마 picker 합산
    // height 가 윈도우 높이 초과 시 Spacer 가 음수 → 컨텐츠가 위로 밀려 잘림 (사용자
    // 보고). 분리 후: 네비게이션만 scroll, 안전 액션은 항상 하단 고정.

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DFSpace.none) {
            // ── ① FIXED TOP — 로고 (브랜드) ────────────────────────────
            // v1.11.22.2 (사용자 요청): 헥사곤 마크 제거 → 워드마크 + tagline 만으로
            // 깔끔한 헤더. wordmarkOnly + density .standard 로 사이드바 폭 정합.
            DarwinForgeLogo(variant: .wordmarkOnly, density: .standard, showsTagline: true)
                .padding(.horizontal, DFSpace.md)
                .padding(.top, DFSpace.md)
                .padding(.bottom, DFSpace.sm)

            Divider()

            // ── ② SCROLLABLE MIDDLE — 메뉴/탭 네비게이션 ─────────────
            // 높은 윈도우에서는 자연스럽게 fill, 짧은 윈도우에서는 scroll.
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: DFSpace.none) {
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
                }
                .padding(.vertical, DFSpace.xs)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // ── ③ FIXED BOTTOM — 액션 + 테마 + 배지 ──────────────────
            VStack(alignment: .leading, spacing: DFSpace.none) {
                // 원격 도구 빠른 접근 — 연결 여부와 무관하게 항상 노출.
                remoteToolsQuickRow
                    .padding(.horizontal, DFSpace.sm)
                    .padding(.top, DFSpace.sm)
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
                            .font(.system(size: DFFontSize.s11))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, DFSpace.md)
                    .background(DFColor.elev2)
                    .foregroundStyle(DFColor.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.md)
                            .stroke(DFColor.forge.opacity(DFOpacity.o30), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DFSpace.sm)
                .padding(.bottom, 8)
                .help("연결 안내 화면 열기 — USB / 네트워크 / 자동 검색")

                // 로봇 복구 — E-stop 이후 액추에이터 재활성 + 기본 자세로 매우 천천히 이동.
                recoveryButton

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

                // v1.11.15 (2026-05-19) cycle 2: 컴팩트 테마 picker — 라벨 제거.
                // 사이드바 height 절약 — icon 3개 + 짧은 텍스트 ("자동/흰색/다크") 행.
                DFThemePicker(layout: .horizontal, showsLabel: false)
                    .padding(.horizontal, DFSpace.sm)
                    .padding(.bottom, DFSpace.xs2)

                // Forge core badge
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "cube.box")
                        .font(.system(size: DFFontSize.s10))
                    Text("forge-core \(forgeCoreVersion())")
                        .font(DFFont.caption.monospaced())
                }
                .foregroundStyle(DFColor.textSecondary)
                .padding(.horizontal, DFSpace.md)
                .padding(.bottom, DFSpace.sm)
            }
        }
    }

    // MARK: - 로봇 복구 버튼 (사이드바)

    /// E-stop 후 액추에이터 복구 — 녹색 버튼.
    /// 활성 조건: bus 연결됨 + 진행 중 아님. 클릭 시 confirm alert → recoverFromEStop().
    private var recoveryButton: some View {
        let busAvailable = store.bus != nil
        let inProgress = store.isRecovering
        let enabled = busAvailable && !inProgress

        return Button {
            // 확인 다이얼로그 — cradle 거치 안내.
            showRecoveryConfirm = true
        } label: {
            HStack(spacing: DFSpace.sm) {
                Group {
                    if inProgress {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise.heart.fill")
                            .font(.system(size: DFFontSize.s14, weight: .semibold))
                    }
                }
                .frame(width: DFSize.iconSm2, height: DFSize.iconSm2)
                Text(inProgress ? "복구 중…" : "로봇 복구")
                    .font(DFFont.bodyEmph)
                Spacer()
                if !inProgress && busAvailable {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(.white.opacity(DFOpacity.o85))
                } else if !busAvailable {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(.white.opacity(DFOpacity.o70))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, DFSpace.md)
            .background(
                LinearGradient(
                    colors: enabled
                        ? [DFColor.success, DFColor.success.opacity(DFOpacity.o85)]
                        : [DFColor.success.opacity(DFOpacity.o45), DFColor.success.opacity(DFOpacity.o30)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
            .shadow(color: DFColor.success.opacity(enabled ? 0.35 : 0.0), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(busAvailable
              ? "긴급 정지 후 액추에이터 토크 ON + walkReady 자세로 매우 천천히 이동 (정비 스탠드 거치 필수)"
              : "연결 후 사용 가능 — 먼저 연결 마법사로 연결하세요")
        .padding(.horizontal, DFSpace.sm)
        .padding(.bottom, 8)
        .alert("로봇 복구",
               isPresented: $showRecoveryConfirm) {
            Button("취소", role: .cancel) {}
            Button("정비 스탠드 거치됨 — 복구 시작") {
                // 사용자가 명시적으로 거치를 확인한 행위 → cradleConfirmed: true.
                Task { await store.recoverFromEStop(cradleConfirmed: true) }
            }
        } message: {
            Text("긴급 정지 이후 모든 관절에 토크를 다시 켜고 walkReady 자세 (ROBOTIS 공식 deep squat — 검증된 균형 자세) 로 매우 천천히 이동합니다.\n\n⚠️ 정비 스탠드 거치 필수 — 복구 중 다리 자세가 변경되며 거치 없이 진행하면 fall 위험.\n\n• 안전 검증 우회 (부하/전압 거부 없이 실행)\n• moving_speed = 80 + 5 초 정착")
        }
    }

    /// 복구 결과 토스트 — 4 초 후 자동 dismiss. 상단 중앙.
    @ViewBuilder
    private var recoveryToastOverlay: some View {
        if let msg = store.lastRecoveryResult, let outcome = store.lastRecoveryOutcome {
            VStack {
                HStack(spacing: DFSpace.sm) {
                    Image(systemName: recoveryToastIcon(outcome))
                        .foregroundStyle(recoveryToastTint(outcome))
                    Text(msg)
                        .font(DFFont.bodyEmph)
                        .foregroundStyle(DFColor.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.md)
                        .stroke(recoveryToastTint(outcome).opacity(DFOpacity.o45), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(DFOpacity.o15), radius: 8, y: 2)
                .padding(.top, 56)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: msg)
        }
    }

    private func recoveryToastIcon(_ o: ConnectionStore.RecoveryOutcome) -> String {
        switch o {
        case .success:      return "checkmark.circle.fill"
        case .failure:      return "exclamationmark.triangle.fill"
        case .notConnected: return "wifi.slash"
        }
    }

    private func recoveryToastTint(_ o: ConnectionStore.RecoveryOutcome) -> Color {
        switch o {
        case .success:      return DFColor.success
        case .failure:      return DFColor.danger
        case .notConnected: return DFColor.warning
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
        return VStack(alignment: .leading, spacing: DFSpace.xs) {
            Text("원격 도구")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            HStack(spacing: DFSpace.xs2) {
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
                .font(.system(size: DFFontSize.s13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: DFSize.buttonHMedium - DFSpace.micro2)
                .background(tint.opacity(DFOpacity.o10))
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.xs2)
                        .stroke(tint.opacity(DFOpacity.o25), lineWidth: DFSize.borderHairline)
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
                    ? DFColor.accent.opacity(DFOpacity.subtle) : Color.clear
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
        case .walk:     WalkDiagnosticsView()
        case .walkData: WalkDataView()
        case .strategy: StrategyView()
        case .harness:  HarnessInspectorView()
        }
    }

    // MARK: - Command palette overlay

    private var paletteOverlay: some View {
        ZStack {
            Color.black.opacity(DFOpacity.strong)
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
        case .disconnected: return DFColor.textSecondary.opacity(DFOpacity.dim)
        }
    }

    // MARK: - Wizard overlay

    private var wizardOverlay: some View {
        ZStack {
            Color.black.opacity(DFOpacity.disabled)
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
            Color.black.opacity(DFOpacity.disabled)
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
    case board, joints, motion, walk, walkData, strategy, harness
    var id: String { rawValue }

    var label: String {
        switch self {
        case .board:    return "보드 상태"
        case .joints:   return "관절 제어"
        case .motion:   return "동작 라이브러리"
        case .walk:     return "보행 진단"
        case .walkData: return "보행 데이터"
        case .strategy: return "전략 FSM"
        case .harness:  return "텔레메트리"
        }
    }
    var icon: String {
        switch self {
        case .board:    return "cpu"
        case .joints:   return "slider.horizontal.3"
        case .motion:   return "play.rectangle.on.rectangle"
        case .walk:     return "waveform.path.ecg"
        case .walkData: return "chart.line.uptrend.xyaxis"
        case .strategy: return "brain.head.profile"
        case .harness:  return "tray.and.arrow.down"
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
    public static let dfShowSidebar   = Notification.Name("DarwinForge.ShowSidebar")
    /// 다른 화면에서 연결 마법사 띄우기 — Pilot 카메라 패널 "연결 마법사로 가기" 등.
    public static let dfOpenConnectionWizard = Notification.Name("DarwinForge.OpenConnectionWizard")

    /// 티칭 모드 → Studio 로 자세 전달. object 는 RobotPose.
    public static let dfTransferPoseToStudio = Notification.Name("DarwinForge.TransferPoseToStudio")
    /// Studio → MotionStudio 로 자세 전달. object 는 RobotPose.
    public static let dfTransferPoseToMotion = Notification.Name("DarwinForge.TransferPoseToMotion")

    /// **2026-05-16**: WalkLab fall prevention 모니터링 dashboard 토글.
    /// 메뉴바 "보기 → Fall Prevention 모니터링" (⌘⇧M) → WalkLabView 가 listen.
    public static let dfToggleMonitoring = Notification.Name("DarwinForge.ToggleMonitoring")
}
