import SwiftUI

/// 통합 「컨트롤러 연결」 시트 — 조종 시뮬(⌘9)의 두 컨트롤러 표면을 하나로 합친다.
///
/// 종전엔 (a) 상단 「컨트롤러」 버튼 → 게임패드 매핑 시트, (b) 좌측 「DJI 조종기」
/// 패널 → 「DJI 키 매핑」 시트로 **연결과 매핑이 두 곳에 흩어져** 있었다. 본 시트는
/// 둘을 한 창에 모아:
///
/// - **헤더**: 제목 + 기기 선택 세그먼트(게임패드 ↔ DJI RC) + 선택 기기의 실시간
///   연결 상태 pill (+ DJI 의 검색·Mock 데모) + 닫기(ESC).
/// - **본문**: 선택된 기기의 3-단 매핑 pane(작 할당 ↔ 다이어그램 ↔ 선택된 컨트롤)을
///   `embedded` 모드로 그대로 박아 넣는다.
///
/// # 방법론 (Steam Input · Unity RebindingOperation · PowerToys · reWASD 조사)
///
/// - **list ↔ diagram ↔ inspector 3영역** + 양방향 선택 동기화 (각 pane 이 이미 충족).
/// - **연결 상태 + 라이브 입력 + 매핑을 한 곳에** — "연결됐는지 모르겠다"를 헤더
///   pill 과 다이어그램 라이브 에코로 해소.
/// - **데이터 모델은 분리 유지** — 게임패드는 `ControllerBindingProfile`, DJI 는
///   `DJIBindingProfile`. 본 시트는 UI 통합만 담당하고 저장값을 섞지 않는다.
/// - **고정창 비파괴** — 1100×760 안에서 헤더 위·pane 아래로 나뉘고, pane 내부가
///   스크롤하므로 창이 넘치거나 잘리지 않는다.
@MainActor
public struct CockpitControllerConnectionSheet: View {

    @ObservedObject var cockpit: CockpitState
    @Binding var isPresented: Bool
    @Binding var djiProfile: DJIBindingProfile
    /// 하단 상태바 텔레메트리 소스 (로봇 연결·배터리). RootView 가 주입 → 오버레이 상속.
    @EnvironmentObject private var store: ConnectionStore

    #if canImport(IOKit)
    @ObservedObject var djiWatcher: DJIVirtualJoystickWatcher
    #endif

    /// 본연(natural) 설계 크기 — HIG Preferences large. 컨테이너 모달이 이 크기로 그린 뒤
    /// 라이브 창 크기에 맞춰 통째로 축소한다.
    /// 본연 설계 크기. **독립 윈도우**로 띄우므로 앱 메인 창 크기와 무관 — 콘텐츠가
    /// 여유 있게 들어가는 크기로 잡는다. (1200 = 280+300 컬럼 + 560 컨트롤러 + 여백.)
    public static let naturalSize = CGSize(width: 1200, height: 820)

    /// 현재 보고 있는 기기 pane.
    @State private var device: ControllerDeviceKind

    /// 각 pane 의 미저장 편집 여부 — pane 이 binding 으로 보고. 기기 전환 시 데이터
    /// 손실 경고에 사용.
    @State private var gamepadDirty = false
    @State private var djiDirty = false
    /// dirty 상태에서 전환을 시도해 확인 대기 중인 목적지 기기 (nil = 대기 없음).
    @State private var pendingDevice: ControllerDeviceKind?
    /// DJI 진단 popover 표시 여부.
    @State private var showDJIDiagnostics = false

    /// DJI 연결 관리(검색·Mock 데모·진단) — 헤더 connection cluster 가 사용.
    /// 라이브 HID→로봇 경로(`djiWatcher`)는 `PilotCockpitView` 가 소유하고, 본
    /// controller 는 시트가 열려 있는 동안의 연결 보조 역할만 한다.
    @StateObject private var djiController: CockpitDJIController

    #if canImport(IOKit)
    public init(cockpit: CockpitState,
                isPresented: Binding<Bool>,
                djiProfile: Binding<DJIBindingProfile>,
                djiWatcher: DJIVirtualJoystickWatcher) {
        self.cockpit = cockpit
        self._isPresented = isPresented
        self._djiProfile = djiProfile
        self.djiWatcher = djiWatcher
        self._device = State(initialValue: ControllerDeviceKind.autoSelect(
            djiConnected: djiWatcher.isStreaming,
            gamepadConnected: cockpit.connectedController != nil))
        self._djiController = StateObject(wrappedValue: CockpitDJIController(cockpit: cockpit))
    }
    #else
    public init(cockpit: CockpitState,
                isPresented: Binding<Bool>,
                djiProfile: Binding<DJIBindingProfile>) {
        self.cockpit = cockpit
        self._isPresented = isPresented
        self._djiProfile = djiProfile
        self._device = State(initialValue: ControllerDeviceKind.autoSelect(
            djiConnected: false,
            gamepadConnected: cockpit.connectedController != nil))
        self._djiController = StateObject(wrappedValue: CockpitDJIController(cockpit: cockpit))
    }
    #endif

    public var body: some View {
        // 본연 크기(1100×760)로만 그린다. 작은 창에 맞춘 축소(scale-to-fit)는 컨테이너
        // 모달(`ControllerConnectionModal`)이 라이브 GeometryReader 크기로 처리한다 —
        // .sheet 는 표시 시점에 창 크기를 한 번만 잡아 반응형이 불가했다.
        VStack(spacing: 0) {
            unifiedHeader
            Divider()
            activePane
            Divider()
            controllerStatusBar
        }
        // 독립 윈도우를 채우는 반응형 — 고정 frame 대신 min/max 로 창 크기를 따라간다.
        // (좌/우 컬럼 고정폭 + 중앙 가변 + 내부 스크롤이라 어떤 크기에서도 안 잘림.)
        .frame(minWidth: 980, maxWidth: .infinity,
               minHeight: 620, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // 진단은 .popover 대신 in-panel 카드로 — 상위 모달이 scaleEffect 로 축소하면
        // popover 앵커(화살표/위치)가 어긋난다. 카드는 레이아웃의 일부라 항상 정확.
        .overlay(alignment: .topTrailing) {
            #if canImport(IOKit)
            if showDJIDiagnostics, device == .djiRC {
                diagnosticsCard
                    .padding(.top, 54)
                    .padding(.trailing, 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            #endif
        }
        .onAppear {
            djiController.updateFromWatcher()
            // GameController.framework 인식 목록 1Hz 폴링 — 종전 DJI 패널과 동등.
            // 즉시 notification 을 안 쏘는 USB HID 도 진단 popover 에 반영된다.
            djiController.startDiagnosticsPolling()
        }
        .onDisappear {
            djiController.stopMockDemo()
            djiController.stopDiagnosticsPolling()
        }
        .onChange(of: device) { _, newDevice in
            // 게임패드로 전환하면 DJI Mock 데모는 정지 (잔여 입력 주입 방지).
            if newDevice != .djiRC { djiController.stopMockDemo() }
        }
        .confirmationDialog(
            "저장하지 않은 매핑 변경이 있어요",
            isPresented: Binding(get: { pendingDevice != nil },
                                 set: { if !$0 { pendingDevice = nil } }),
            titleVisibility: .visible
        ) {
            Button("변경 폐기하고 전환", role: .destructive) { commitPendingDeviceSwitch() }
            Button("취소", role: .cancel) { pendingDevice = nil }
        } message: {
            Text("\(device.label) 탭의 변경 사항이 사라집니다. 먼저 저장하려면 취소 후 ‘저장’을 누르세요.")
        }
        .accessibilityIdentifier("cockpit.controller.connection.sheet")
    }

    // MARK: - 기기 전환 (미저장 편집 보호)

    /// 세그먼트 Picker 가 쓰는 프록시 binding — dirty 면 즉시 전환하지 않고 확인을 띄운다.
    private var deviceSelection: Binding<ControllerDeviceKind> {
        Binding(
            get: { device },
            set: { requested in
                guard requested != device else { return }
                let outgoingDirty = (device == .gamepad) ? gamepadDirty : djiDirty
                if outgoingDirty {
                    pendingDevice = requested          // 확인 대기 — Picker 는 그대로 유지.
                } else {
                    device = requested
                }
            })
    }

    /// 사용자가 "변경 폐기하고 전환"을 택함 — 떠나는 pane 의 dirty 플래그를 비우고 전환.
    private func commitPendingDeviceSwitch() {
        guard let target = pendingDevice else { return }
        if device == .gamepad { gamepadDirty = false } else { djiDirty = false }
        device = target
        pendingDevice = nil
    }

    // MARK: - Bottom status bar (PRD §11) — 실제 텔레메트리만 표시 (가짜 값 없음)

    private var controllerStatusBar: some View {
        HStack(spacing: 0) {
            statusItem("연결 상태", connectionStatusText,
                       icon: "antenna.radiowaves.left.and.right", tint: connectionStatusTint)
            statusDivider
            statusItem("주행", String(format: "%+.2f m/s", cockpit.simForwardSpeedMmPerSec / 1000.0),
                       icon: "speedometer", tint: .secondary)
            statusDivider
            statusItem("회전", String(format: "%+.1f °/s", cockpit.simTurnSpeedDegPerSec),
                       icon: "arrow.triangle.2.circlepath", tint: .secondary)
            statusDivider
            statusItem("명령", cockpit.lastCommand.isStop ? "정지" : "보행",
                       icon: "command", tint: cockpit.lastCommand.isStop ? .secondary : .green)
            statusDivider
            statusItem("로봇 배터리", batteryText, icon: "battery.100", tint: .secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
    }

    private func statusItem(_ label: String, _ value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusDivider: some View { Divider().frame(height: 26) }

    private var connectionStatusText: String {
        if let n = cockpit.connectedController { return "\(n) · \(cockpit.lastSource.label)" }
        #if canImport(IOKit)
        if djiWatcher.isStreaming { return "DJI RC 연결됨" }
        #endif
        return "가상 패드"
    }
    private var connectionStatusTint: Color {
        if cockpit.connectedController != nil { return .green }
        #if canImport(IOKit)
        if djiWatcher.isStreaming { return .green }
        #endif
        return .blue
    }
    /// 로봇 보드 전압(실측). 컨트롤러 자체 배터리%는 읽지 않으므로 거짓 % 대신 실제 전압.
    private var batteryText: String {
        if let v = store.lastTelemetry?.board?.voltageVolts { return String(format: "%.1f V", v) }
        return "—"
    }

    // MARK: - Header

    private var unifiedHeader: some View {
        HStack(spacing: 16) {
            // 제목
            HStack(spacing: 8) {
                Image(systemName: device.systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("컨트롤러 연결")
                        .font(.system(size: 14, weight: .semibold))
                    Text("기기를 고르고 동작에 입력을 매핑하세요.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            // 기기 선택 세그먼트
            Picker("", selection: deviceSelection) {
                ForEach(ControllerDeviceKind.allCases) { kind in
                    Label(kind.label, systemImage: kind.systemImage).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .accessibilityIdentifier("cockpit.controller.connection.device")

            Spacer(minLength: 12)

            // 연결 상태 cluster (기기별) + 닫기
            HStack(spacing: 10) {
                connectionCluster
                closeButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var closeButton: some View {
        Button { isPresented = false } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("닫기 (ESC)")
    }

    // MARK: - Connection cluster (per device)

    @ViewBuilder
    private var connectionCluster: some View {
        switch device {
        case .gamepad:
            gamepadConnectionPill
        case .djiRC:
            djiConnectionCluster
        }
    }

    private var gamepadConnectionPill: some View {
        let name = cockpit.connectedController
        let connected = name != nil
        return statusPill(
            text: connected ? "연결됨 · \(name ?? "")" : "가상 패드 사용 중",
            systemImage: connected ? "gamecontroller.fill" : "rectangle.dashed",
            tint: connected ? .green : .secondary)
    }

    @ViewBuilder
    private var djiConnectionCluster: some View {
        #if canImport(IOKit)
        let (text, symbol, tint) = djiStatusVisual
        HStack(spacing: 8) {
            statusPill(text: text, systemImage: symbol, tint: tint)
            Button { djiController.startSearch() } label: {
                Label("검색", systemImage: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("DJI RC USB 연결을 다시 탐색합니다.")
            Button { toggleMockDemo() } label: {
                Label(isMockActive ? "Mock 중지" : "Mock",
                      systemImage: isMockActive ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("컨트롤러 없이 자동 스틱 패턴으로 입력→모션을 체감합니다.")
            Button { showDJIDiagnostics.toggle() } label: {
                Image(systemName: "stethoscope").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("인식된 컨트롤러·HID 진단")
        }
        #else
        statusPill(text: "이 빌드에서 미지원", systemImage: "exclamationmark.triangle", tint: .orange)
        #endif
    }

    #if canImport(IOKit)
    /// 인식된 컨트롤러 목록(GameController.framework) + 라이브 DJI HID 축 — 종전 DJI
    /// 패널의 진단 블록을 in-panel 카드로 복원 (popover 아님: scaleEffect 앵커 문제 회피).
    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("연결 진단").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { showDJIDiagnostics = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("닫기")
            }
            Text("인식된 컨트롤러")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if djiController.diagnostics.isEmpty {
                Text("인식된 컨트롤러가 없습니다. USB 연결을 확인하거나 ‘검색’을 누르세요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(djiController.diagnostics) { d in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.vendorName).font(.system(size: 11, weight: .medium))
                        Text("\(d.productCategory) · "
                             + (d.hasExtendedGamepad ? "Extended"
                                : (d.hasMicroGamepad ? "Micro" : "MFi 아님")))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text("DJI HID 라이브").font(.system(size: 12, weight: .semibold))
            if let r = djiWatcher.lastReport {
                Text(String(format: "X %+.2f  Y %+.2f  Z %+.2f  Rx %+.2f  Ry %+.2f",
                            r.axisX, r.axisY, r.axisZ, r.axisRx, r.axisRy))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("HID 리포트 없음 — 스틱을 움직여 확인하세요.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 16, y: 6)
    }
    #endif

    #if canImport(IOKit)
    /// DJI 연결 상태를 pill 표기(텍스트·아이콘·색)로 변환.
    private var djiStatusVisual: (String, String, Color) {
        if isMockActive {
            return ("Mock 데모", "play.circle.fill", .cyan)
        }
        if djiWatcher.isStreaming || djiWatcher.connectedName != nil {
            let name = djiWatcher.connectedName ?? "DJI RC"
            return ("연결됨 · \(name)", "antenna.radiowaves.left.and.right", .green)
        }
        if case .searching = djiController.status {
            return ("검색 중…", "dot.radiowaves.left.and.right", .orange)
        }
        return ("미연결", "antenna.radiowaves.left.and.right.slash", .secondary)
    }

    private var isMockActive: Bool {
        djiController.status == .mockActive
    }

    private func toggleMockDemo() {
        if isMockActive {
            djiController.stopMockDemo()
            djiWatcher.resumeStreaming()
        } else {
            djiWatcher.pauseStreaming()   // 실 HID 와 Mock 입력 충돌 방지.
            djiController.startMockDemo()
        }
    }
    #endif

    private func statusPill(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().stroke(tint.opacity(0.30), lineWidth: 0.5))
        .fixedSize()
    }

    // MARK: - Active pane

    @ViewBuilder
    private var activePane: some View {
        switch device {
        case .gamepad:
            CockpitControllerSettingsSheet(
                cockpit: cockpit,
                isPresented: $isPresented,
                embedded: true,
                dirty: $gamepadDirty)
        case .djiRC:
            #if canImport(IOKit)
            CockpitDJIBindingSheet(
                isPresented: $isPresented,
                profile: $djiProfile,
                watcher: djiWatcher,
                embedded: true,
                dirty: $djiDirty)
            #else
            djiUnavailablePane
            #endif
        }
    }

    #if !canImport(IOKit)
    private var djiUnavailablePane: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28)).foregroundStyle(.orange)
            Text("DJI RC 는 이 빌드에서 지원되지 않습니다.")
                .font(.system(size: 13, weight: .medium))
            Text("게임패드 탭을 사용하세요.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif
}
