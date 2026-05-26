import SwiftUI
import MobilePilotKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ConnectScreen
//
// 공항 체크인 4단계 비유 (V292-A):
//   1) Mac 발견  — 카운터에 가서 항공사(Mac DarwinForge)를 찾는다
//   2) 핸드셰이크 — 여권(6자리 OTP 코드)을 제시해 신원 확인
//   3) 안전 점검  — 수하물 X-ray(ARM 전 체크리스트) 통과
//   4) ARM 준비  — 탑승구 입장(로봇 준비 완료)
//
// Hick's Law 적용: 진입 선택지를 1개(Hero CTA)로 줄이고 보조 방법은 sheet에 숨겼다.
// Nielsen #9: 페어링 실패 이유를 inline banner로 즉시 표시.
// Fitts's Law: Hero CTA는 56pt 풀-너비 thumb-zone 버튼.
// Sub-view 정의: ConnectSubViews.swift (ConnectPhase, ConnectStepBar,
//   DiscoveredMacCard, OTPPairingSection, TroubleshootExpander,
//   PairingDiagnosis, ManualEntrySheet, DevMenuSheet)

public struct ConnectScreen: View {

    @EnvironmentObject var state: AppState

    // MARK: IA Flow State
    @State private var phase: ConnectPhase = .discovery
    @State private var showManualSheet: Bool = false
    @State private var showDevMenu: Bool = false

    // MARK: Discovery state
    @State private var showTroubleshoot: Bool = false

    // MARK: Pairing state
    @State private var selectedTarget: RelayDiscoveryResult?
    @State private var otpDigits: [String] = Array(repeating: "", count: 6)
    @State private var activeOTPField: Int = 0
    @State private var pairingError: PairingDiagnosis?

    // MARK: Permission state
    @State private var showPermissionPriming: Bool = false
    @State private var permissionDenied: Bool = false

    // MARK: Camera QR scanner state (V292-cam)
    @State private var showCameraScanner: Bool = false
    @State private var cameraPermissionDenied: Bool = false

    // MARK: Dev menu tap counter (hidden 10-tap unlock)
    @State private var devTapCount: Int = 0

    public init() {}

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                DS.Color.canvas.ignoresSafeArea()
                VStack(spacing: 0) {
                    // N of 4 step bar at the top
                    ConnectStepBar(phase: phase)
                        .padding(.horizontal, DS.Space.l)
                        .padding(.top, DS.Space.m)
                        .padding(.bottom, DS.Space.s)

                    Divider()
                        .foregroundStyle(DS.Color.divider)

                    ScrollView {
                        VStack(spacing: DS.Space.xl) {
                            phaseContent
                        }
                        .padding(DS.Space.l)
                        .padding(.bottom, DS.Space.xxl)
                    }
                }
            }
            .navigationTitle("연결")
            .dfInlineNavigationTitle()
            .accessibilityIdentifier("connect.root")
            .onAppear {
                if state.connectionMode == .realRelay {
                    state.startDiscovery()
                }
                if state.discoveryTimedOut { showTroubleshoot = true }
            }
            .onDisappear { state.stopDiscovery() }
            .onChange(of: state.pairedEndpoint) { _, endpoint in
                if endpoint != nil {
                    withAnimation(DS.Motion.standard) { phase = .safety }
                    state.beginSafetyGate()
                }
            }
            .onChange(of: state.lastError) { _, error in
                if let error {
                    pairingError = PairingDiagnosis.diagnose(error)
                } else {
                    pairingError = nil
                }
            }
            .onChange(of: state.discovered) { _, results in
                if !results.isEmpty && phase == .discovery {
                    withAnimation(DS.Motion.standard) { phase = .pairing }
                }
            }
            .onChange(of: state.discoveryTimedOut) { _, timedOut in
                if timedOut { showTroubleshoot = true }
            }
            .sheet(isPresented: $showManualSheet) {
                ManualEntrySheet(onConnect: { endpoint in
                    showManualSheet = false
                    Task { await state.connect(to: endpoint) }
                })
            }
            // V292-cam: 카메라 QR 스캐너 sheet
            #if canImport(AVFoundation) && canImport(UIKit)
            .sheet(isPresented: $showCameraScanner) {
                NavigationStack {
                    CameraQRScannerView(
                        onScan: { raw in handleScannedQR(raw) },
                        onError: { _ in
                            showCameraScanner = false
                            showManualSheet = true   // 카메라 실패 → manual fallback
                        })
                    .ignoresSafeArea()
                    .navigationTitle("QR 스캔")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("취소") { showCameraScanner = false }
                        }
                    }
                }
                .accessibilityIdentifier("connect.camera.scanner")
            }
            #endif
            .alert("카메라 권한이 거부됐어요",
                   isPresented: $cameraPermissionDenied) {
                Button("설정 열기") {
                    #if canImport(UIKit)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    #endif
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("설정 → DarwinForge Pilot → 카메라 를 켜면 QR 스캔이 가능합니다. 또는 'IP 직접 입력' 으로 연결할 수 있어요.")
            }
            #if DEBUG
            .sheet(isPresented: $showDevMenu) {
                DevMenuSheet()
            }
            #endif
        }
    }

    // MARK: - Phase routing

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .discovery:
            discoveryPhaseView
        case .pairing:
            pairingPhaseView
        case .safety:
            safetyPhaseView
        case .arm:
            armReadyPhaseView
        }
    }

    // MARK: - Phase 1: Discovery

    private var discoveryPhaseView: some View {
        VStack(spacing: DS.Space.xl) {
            if state.pairedEndpoint != nil {
                connectedStatusCard
            }

            // Hero area
            VStack(spacing: DS.Space.m) {
                Image(systemName: "desktopcomputer.and.iphone")
                    .font(.system(size: 52))
                    .foregroundStyle(DS.Color.brand)
                    .accessibilityHidden(true)

                Text("iPhone과 Mac을 연결하세요")
                    .font(DS.Font.screenTitle)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text("Mac에서 DarwinForge를 열고\nMobile Pilot Relay를 켜두면 자동으로 찾습니다.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .multilineTextAlignment(.center)
            }

            // Hero CTA — Fitts's Law: 56pt 풀너비
            if permissionDenied {
                permissionDeniedCard
            } else if showPermissionPriming {
                permissionPrimingCard
            } else {
                DSButton("Mac 찾기",
                         systemImage: "magnifyingglass",
                         style: .primary,
                         size: .large,
                         fullWidth: true) {
                    handleFindMacTapped()
                }
                .frame(minHeight: DS.Hit.estop)
                .accessibilityLabel("Mac 찾기")
                .accessibilityHint("같은 Wi-Fi에서 DarwinForge Mac 앱을 자동으로 검색합니다")
                .accessibilityIdentifier("connect.hero.findMac")
            }

            // 발견 중 상태 + 타임아웃 트러블슈트
            if state.connectionMode == .realRelay {
                discoveryStatusSection
            }

            otherMethodsButton
            devUnlockLabel
        }
    }

    // MARK: - Phase 2: Pairing

    private var pairingPhaseView: some View {
        VStack(spacing: DS.Space.xl) {
            if let error = pairingError {
                pairingErrorBanner(error)
            }

            VStack(spacing: DS.Space.s) {
                DSSectionHeader("발견된 Mac")
                ForEach(state.discovered) { result in
                    DiscoveredMacCard(result: result,
                                      isSelected: selectedTarget?.id == result.id) {
                        withAnimation(DS.Motion.quick) {
                            selectedTarget = result
                            otpDigits = Array(repeating: "", count: 6)
                            activeOTPField = 0
                        }
                    }
                    .accessibilityIdentifier("connect.card.\(result.id)")
                }
            }

            if let target = selectedTarget {
                OTPPairingSection(
                    target: target,
                    digits: $otpDigits,
                    activeField: $activeOTPField,
                    onConnect: {
                        let code = otpDigits.joined()
                        Task {
                            await state.connect(to: RelayEndpoint(
                                host: target.host,
                                port: target.port,
                                pairingCode: code))
                        }
                    },
                    onCancel: {
                        withAnimation(DS.Motion.quick) { selectedTarget = nil }
                    }
                )
            }

            HStack {
                Button {
                    withAnimation(DS.Motion.standard) {
                        phase = .discovery
                        state.startDiscovery()
                    }
                } label: {
                    Label("다시 찾기", systemImage: "arrow.clockwise")
                        .font(DS.Font.button)
                }
                .foregroundStyle(DS.Color.accent)
                .accessibilityIdentifier("connect.retry")

                Spacer()
                otherMethodsButton
            }
        }
    }

    // MARK: - Phase 3: Safety
    // V292-B: 페어링 성공 후 Safety Brief → Preflight → E-Stop Drill 3 게이트 강제 진행.
    // 게이트 완료 후 .arm phase 로 자동 전환.

    @State private var showSafetyBrief: Bool = false
    @State private var showPreflightChecklist: Bool = false
    @State private var showEStopDrill: Bool = false

    private var safetyPhaseView: some View {
        VStack(spacing: DS.Space.xl) {
            connectedStatusCard

            DSCard(tone: state.isMacReady ? .success : .standard) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Label(state.isMacReady ? "Mac 연결 완료" : "Mac 상태 확인 중",
                          systemImage: state.isMacReady ? "checkmark.seal.fill" : "hourglass")
                        .font(DS.Font.sectionTitle)
                        .foregroundStyle(state.isMacReady ? DS.Color.success : DS.Color.warning)
                    Text(state.isMacReady
                         ? "상태 데이터까지 수신했습니다. ARM 전 안전 3단계 점검을 진행하세요."
                         : "Mac과 연결을 확인했습니다. 첫 상태 데이터를 받으면 안전 점검을 시작할 수 있습니다.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }

            // Safety gate progress indicator
            safetyGateProgressView

            DSButton(state.isMacReady ? "안전 점검 시작" : "Mac 상태 확인 중",
                     systemImage: "shield.checkered",
                     style: .primary,
                     size: .large,
                     fullWidth: true) {
                guard state.isMacReady else { return }
                showSafetyBrief = true
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                #endif
            }
            .disabled(!state.isMacReady)
            .frame(minHeight: DS.Hit.estop)
            .accessibilityIdentifier("connect.toArm")

            Button {
                Task { await state.disconnect() }
                withAnimation(DS.Motion.standard) { phase = .discovery }
            } label: {
                Text("연결 해제")
                    .font(DS.Font.button)
                    .foregroundStyle(DS.Color.danger)
            }
            .accessibilityIdentifier("connect.disconnect")
        }
        .sheet(isPresented: $showSafetyBrief) {
            SafetyBriefModal {
                showSafetyBrief = false
                state.completeSafetyBrief()
                showPreflightChecklist = true
            }
        }
        .sheet(isPresented: $showPreflightChecklist) {
            PreflightChecklistView(telemetry: state.telemetry) {
                showPreflightChecklist = false
                state.completePreflightChecklist()
                if state.safetyGateState == .drill {
                    showEStopDrill = true
                } else {
                    withAnimation(DS.Motion.standard) { phase = .arm }
                }
            }
        }
        .sheet(isPresented: $showEStopDrill) {
            EStopDrillView {
                showEStopDrill = false
                state.completeEStopDrill()
                withAnimation(DS.Motion.standard) { phase = .arm }
            }
        }
        .onChange(of: state.safetyGateState) { _, gateState in
            if gateState == .ready {
                withAnimation(DS.Motion.standard) { phase = .arm }
            }
        }
    }

    private var safetyGateProgressView: some View {
        let steps: [(String, String, SafetyGateState)] = [
            ("shield.fill", "안전 브리핑", .brief),
            ("checklist", "사전 점검", .preflight),
            ("hand.raised.fill", "E-Stop 확인", .drill)
        ]
        return HStack(spacing: DS.Space.xs) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                let (icon, label, gateStep) = step
                let isPassed = isGatePassed(gateStep)
                VStack(spacing: DS.Space.xxs) {
                    Image(systemName: isPassed ? "checkmark.circle.fill" : icon)
                        .font(.title3)
                        .foregroundStyle(isPassed ? DS.Color.success : DS.Color.secondaryText)
                    Text(label)
                        .font(.system(size: 9, weight: isPassed ? .semibold : .regular))
                        .foregroundStyle(isPassed ? DS.Color.success : DS.Color.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(isPassed ? DS.Color.success : DS.Color.divider)
                        .frame(height: DS.Stroke.regular)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("안전 점검 진행 상황")
    }

    private func isGatePassed(_ gate: SafetyGateState) -> Bool {
        switch gate {
        case .brief:
            return state.safetyGateState == .preflight ||
                   state.safetyGateState == .drill ||
                   state.safetyGateState == .ready
        case .preflight:
            return state.safetyGateState == .drill ||
                   state.safetyGateState == .ready
        case .drill:
            return state.safetyGateState == .ready
        default:
            return false
        }
    }

    // MARK: - Phase 4: ARM ready

    private var armReadyPhaseView: some View {
        VStack(spacing: DS.Space.xl) {
            connectedStatusCard

            DSCard(tone: .accent) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Label("ARM 준비", systemImage: "figure.stand")
                        .font(DS.Font.sectionTitle)
                        .foregroundStyle(DS.Color.brand)
                    Text("동작 탭으로 이동해 안전 체크리스트를 완료하면 로봇을 움직일 수 있습니다.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }

            VStack(spacing: DS.Space.xs) {
                statusRow(title: "Mac 앱", value: macStatusText,
                          icon: "desktopcomputer", tone: state.isMacReady ? .success : .neutral)
                statusRow(title: "로봇", value: robotStatusText,
                          icon: "cpu", tone: robotStatusTone)
                if let endpoint = state.pairedEndpoint {
                    statusRow(title: "연결 대상",
                              value: "\(endpoint.host):\(endpoint.port)",
                              icon: "network", tone: .info)
                }
            }
        }
    }

    // MARK: - Shared sub-views

    private var connectedStatusCard: some View {
        DSCard(tone: .standard) {
            VStack(spacing: DS.Space.xs) {
                statusRow(title: "Mac 앱", value: macStatusText,
                          icon: "desktopcomputer", tone: state.isMacReady ? .success : .neutral)
                if let endpoint = state.pairedEndpoint {
                    Divider()
                    statusRow(title: "연결 대상",
                              value: "\(endpoint.host):\(endpoint.port)",
                              icon: "network", tone: .info)
                }
                // iOS-C2 fix (truth-gap report, 2026-05-25): 실 sessionId / 마지막
                // telemetry 경과 노출 — 사용자/개발자가 iOS↔Mac 양쪽 session 일치를
                // 직접 비교할 수 있어야 한다.
                if let sid = state.currentSessionId {
                    Divider()
                    statusRow(title: "Session",
                              value: "...\(String(sid.suffix(8)))",
                              icon: "key.fill", tone: .accent)
                        .accessibilityIdentifier("connect.session.id")
                }
                if let ageMs = state.lastTelemetryAgeMs {
                    Divider()
                    let ageLabel: String = ageMs < 2000 ? "\(ageMs)ms" : "\(ageMs/1000)s"
                    let tone: DSChip.Tone = ageMs < 2000 ? .success : .warning
                    statusRow(title: "Telemetry",
                              value: "\(ageLabel) 전",
                              icon: "antenna.radiowaves.left.and.right", tone: tone)
                        .accessibilityIdentifier("connect.telemetry.age")
                }
            }
        }
    }

    private func statusRow(title: String, value: String,
                           icon: String, tone: DSChip.Tone) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(DS.Font.body)
            Spacer()
            Text(value)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(tone.foreground)
        }
    }

    // MARK: - Discovery status section

    @ViewBuilder
    private var discoveryStatusSection: some View {
        if state.discovered.isEmpty && !state.discoveryTimedOut {
            DSCard(tone: .standard) {
                HStack(spacing: DS.Space.m) {
                    ProgressView()
                        .accessibilityLabel("탐색 중")
                    Text("같은 Wi-Fi에서 Mac 앱을 찾는 중입니다...")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
        } else if state.discoveryTimedOut && state.discovered.isEmpty {
            // 30초 타임아웃 → 자동 펼침
            TroubleshootExpander(isExpanded: $showTroubleshoot,
                                 autoExpand: true,
                                 onRetry: {
                state.startDiscovery()
                showTroubleshoot = false
            })
        }
    }

    private var otherMethodsButton: some View {
        // V292-cam (2026-05-25): Menu 로 변경 — 카메라 QR 스캔 / IP 직접 입력
        // 두 보조 경로 노출. Hick's Law: 보조 옵션은 클릭 후 2개로만 노출.
        Menu {
            Button {
                requestCameraThenScan()
            } label: {
                Label("QR 코드로 카메라 스캔", systemImage: "qrcode.viewfinder")
            }
            Button {
                showManualSheet = true
            } label: {
                Label("IP 직접 입력 / JSON 붙여넣기", systemImage: "keyboard")
            }
        } label: {
            Text("다른 방법으로 연결")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .underline()
        }
        .accessibilityLabel("다른 방법으로 연결")
        .accessibilityHint("QR 카메라 스캔 또는 IP 직접 입력 방법을 선택합니다")
        .accessibilityIdentifier("connect.otherMethods")
    }

    // MARK: - Camera QR helpers (V292-cam)

    /// 카메라 권한을 확인하고 스캐너 sheet 를 띄운다. Apple AVFoundation
    /// 권장 패턴: notDetermined 이면 requestAccess, denied 이면 Settings 안내.
    private func requestCameraThenScan() {
        #if canImport(AVFoundation) && canImport(UIKit)
        Task { @MainActor in
            switch CameraPermission.current {
            case .authorized:
                showCameraScanner = true
            case .notDetermined:
                let granted = await CameraPermission.request()
                if granted {
                    showCameraScanner = true
                } else {
                    cameraPermissionDenied = true
                }
            case .denied, .restricted:
                cameraPermissionDenied = true
            }
        }
        #else
        // simulator / 비 iOS — manual fallback 로 전환.
        showManualSheet = true
        #endif
    }

    /// QR 페이로드 처리 — JSON 파싱 시도 후 endpoint 로 연결.
    private func handleScannedQR(_ raw: String) {
        showCameraScanner = false
        do {
            let payload = try QRPairingDecoder.decode(raw)
            Task {
                await state.connect(to: RelayEndpoint(host: payload.host,
                                                     port: payload.port,
                                                     pairingCode: payload.pairingCode))
            }
        } catch {
            // QR 페이로드가 JSON 형식이 아니면 manual sheet 에 텍스트 채워 fallback.
            showManualSheet = true
        }
    }

    // MARK: - Permission priming (V292-2)

    private var permissionPrimingCard: some View {
        DSCard(tone: .accent) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Label("로컬 네트워크 권한 필요", systemImage: "wifi.circle.fill")
                    .font(DS.Font.sectionTitle)
                    .foregroundStyle(DS.Color.brand)
                Text("DarwinForge가 같은 Wi-Fi의 Mac 앱을 찾으려면 로컬 네트워크 접근이 필요합니다. 다음 화면에서 '허용'을 탭하세요.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)

                DSButton("계속 — 권한 요청",
                         systemImage: "checkmark.shield",
                         style: .primary,
                         fullWidth: true) {
                    showPermissionPriming = false
                    state.startDiscovery()
                }
                .accessibilityIdentifier("connect.permission.allow")

                Button("나중에") {
                    showPermissionPriming = false
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var permissionDeniedCard: some View {
        DSCard(tone: .danger) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Label("권한이 거부됨", systemImage: "wifi.slash")
                    .font(DS.Font.sectionTitle)
                    .foregroundStyle(DS.Color.danger)
                Text("설정에서 로컬 네트워크 권한을 허용해야 Mac을 자동으로 찾을 수 있습니다.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)

                DSButton("Settings 열기",
                         systemImage: "arrow.up.right.square",
                         style: .danger,
                         fullWidth: true) {
                    ConnectSubViewHelpers.openAppSettings()
                }
                .accessibilityIdentifier("connect.settings.open")
            }
        }
    }

    // MARK: - Pairing error banner (V292-6)

    private func pairingErrorBanner(_ diagnosis: PairingDiagnosis) -> some View {
        InlineBanner(variant: .danger,
                     message: diagnosis.localizedMessage,
                     action: diagnosis.actionLabel.map { label in
            (label: label, handler: {
                diagnosis.performAction(openSettings: ConnectSubViewHelpers.openAppSettings)
            })
        })
        .accessibilityIdentifier("connect.error.banner")
    }

    // MARK: - Dev unlock (hidden 10-tap)

    private var devUnlockLabel: some View {
        Button {
            devTapCount += 1
            if devTapCount >= 10 {
                devTapCount = 0
                #if DEBUG
                showDevMenu = true
                #endif
            }
        } label: {
            Text("DarwinForge Mobile")
                .font(.system(size: 11))
                .foregroundStyle(DS.Color.tertiaryText)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("버전 정보")
        .accessibilityHint("개발자 메뉴를 여는 숨겨진 버튼")
    }

    // MARK: - Actions

    private func handleFindMacTapped() {
        // V292-fix (2026-05-25): Mac 찾기 = (1) realRelay 모드 보장 → (2) 권한
        // priming 후 시스템 dialog → (3) Bonjour 시작. 종전 무반응 원인:
        // 기본 mockReview 모드라 `BonjourRelayBrowser` 대신 빈 `FixedRelayBrowser`
        // 가 yield 돼 발견 결과 없음.
        //
        // Apple TN3179: 첫 NWBrowser.start() 시점에 시스템이 자동 로컬 네트워크
        // 권한 다이얼로그를 띄운다. priming 카드는 사용자가 그 다이얼로그를
        // 예상하도록 1회 안내.
        Task {
            if state.connectionMode != .realRelay {
                await state.setConnectionMode(.realRelay)
            }
            await MainActor.run {
                if !UserDefaults.standard.bool(forKey: "connect.permissionPrimingShown") {
                    UserDefaults.standard.set(true, forKey: "connect.permissionPrimingShown")
                    withAnimation(DS.Motion.standard) { showPermissionPriming = true }
                    return
                }
                state.startDiscovery()
            }
        }
    }

    // MARK: - Computed helpers

    private var macStatusText: String {
        switch state.transport {
        case .connected: return state.telemetry == nil ? "상태 확인 중" : "연결됨"
        case .connecting, .handshaking: return "연결 중"
        case .disconnected: return "끊김"
        case .idle: return "대기"
        }
    }

    private var robotStatusText: String {
        guard let telemetry = state.telemetry else { return "수신 전" }
        switch telemetry.robot {
        case .connected: return "연결됨"
        case .sim: return "연습 중"
        case .stale: return "응답 지연"
        case .busBusy: return "사용 중"
        case .disconnected: return "미연결"
        case .estopped: return "정지 상태"
        }
    }

    private var robotStatusTone: DSChip.Tone {
        guard let telemetry = state.telemetry else { return .neutral }
        switch telemetry.robot {
        case .connected: return .success
        case .sim: return .info
        case .stale, .busBusy: return .warning
        case .disconnected: return .neutral
        case .estopped: return .danger
        }
    }
}
