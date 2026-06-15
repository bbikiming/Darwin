import SwiftUI
import MobilePilotKit

/// **메인 조종기 화면 — Cockpit HUD 모드**.
///
/// # 레이아웃 (portrait)
///
/// ```
/// ┌──────────────────────────────────────┐
/// │ [Status Rail · E-Stop]                │
/// │ [Cockpit Telemetry Grid 11필드]      │
/// │ [Attitude Indicator | Position Map]   │   ← cockpit HUD 좌우 split
/// │ [Speed Gauge       | Command Readout]│
/// │ [Freeform Banner (필요시)]            │
/// │ [ARM 슬라이더 / 잠금 해제 카드]       │
/// │ [대형 이동 조이스틱]                  │
/// │ [회전 다이얼]                         │
/// │ [모션 빠른 액션 · walkReady/sit/...] │
/// │ [헤드 컨트롤 카드]                    │
/// │ [현재 명령 status banner]             │
/// └──────────────────────────────────────┘
/// ```
///
/// # Cockpit 연동 (Mac 9번 메뉴 ⌘9 와 시각적 등가)
///
/// 본 화면은 Mac `PilotCockpitView` 의 instrument suite 를 iOS 에서 재현한다. 조이스틱
/// 입력은 `CockpitSimulator` 로 동시에 흘려 sim 위치/속도/거리/trail 을 30Hz 로 적분
/// 한다. 사용자가 보는 게이지 숫자 (mm/s) 는 Mac Cockpit 의 CockpitSpeedGauge 와 동일한
/// ROBOTIS Walking 공식 `forward_speed_mmps = strideMm × 2000 / periodMs` 으로 계산.
///
/// Mac 측 텔레메트리 (`TelemetryStatePayload` 11 필드 — robot/safety/dxlPower/battery/temp/
/// latency/ackAge/uiState…) 는 `CockpitTelemetryGrid` 가 모두 카드로 시각화. 종전 화면이
/// battery/temp/latency 3 개만 보여주던 갭을 해소한다.
public struct RemotePilotScreen: View {

    @EnvironmentObject var state: AppState
    @StateObject private var simulator = CockpitSimulator()
    @State private var showArmChecklist = false
    @State private var speed: SpeedTier = .slow
    @State private var headEnabled = false
    @State private var headPan: Double = 0
    @State private var headTilt: Double = 0
    @State private var headTracking = false
    @State private var streamTask: Task<Void, Never>? = nil
    @State private var lastFreeform: WalkFreeformInput = .zero
    @State private var rotationActive: Double = 0
    @State private var stickActive: DSJoystick.Vector = .zero
    @State private var simEnabled: Bool = true

    /// External controller adapter — owned by the screen so its lifecycle
    /// matches the screen's appearance. Bridges into `state` via the
    /// `RemoteControlBridge` protocol so the same `streamWalk` / `releaseWalk`
    /// path that the on-screen joystick uses also receives controller input.
    @StateObject private var controllerAdapter = ExternalControllerAdapter(
        bridge: nil,
        source: GameControllerSource())

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.l) {
                    statusRailSection
                    freeformModeBanner
                    autoRecoveryBanner
                    robotLinkBanner
                    cockpitTelemetrySection
                    cockpitHUDSection
                    cockpitGaugeSection
                    armSection
                    joystickSection
                    rotationSection
                    motionQuickSection
                    headSection
                    ballTrackSection
                    feedbackSection
                }
                .padding(DS.Space.l)
            }
            .background(DS.Color.canvas)
            .navigationTitle("조종기")
            .dfInlineNavigationTitle()
            .accessibilityIdentifier("remotepilot.root")
            .task {
                // Wire the bridge once and start polling. The adapter does
                // nothing until a controller actually connects, so it's safe
                // to leave running for the screen's lifetime.
                if controllerAdapter.bridge == nil {
                    controllerAdapter.bridge = state
                    controllerAdapter.start()
                }
                simulator.start()
                simulator.setSpeedScale(speed.multiplier)
            }
            .onDisappear {
                stopStream()
                controllerAdapter.stop()
                simulator.stop()
                Task { await state.releaseWalk() }
            }
            .onChange(of: speed) { _, newValue in
                controllerAdapter.setSpeedScale(newValue.multiplier)
                simulator.setSpeedScale(newValue.multiplier)
            }
            .onChange(of: simEnabled) { _, newValue in
                simulator.simulationEnabled = newValue
            }
            .sheet(isPresented: $showArmChecklist) {
                NavigationStack {
                    ArmChecklistContent(state: state)
                        .navigationTitle("잠금 해제 전 확인")
                        .dfInlineNavigationTitle()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("닫기") { showArmChecklist = false }
                            }
                        }
                }
                .accessibilityIdentifier("remotepilot.arm.checklist.sheet")
                .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Status / banner

    private var statusRailSection: some View {
        HStack(spacing: DS.Space.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s) {
                    if state.isReconnecting {
                        DSChip("재연결 중 \(state.autoReconnectAttempt)회",
                               tone: .warning,
                               identifier: "remotepilot.status.reconnecting")
                    }
                    DSChip(state.statusRail.macLabel,
                           tone: macTone, identifier: "remotepilot.status.mac")
                    DSChip(state.statusRail.robotLabel,
                           tone: robotTone, identifier: "remotepilot.status.robot")
                    DSChip(state.statusRail.armLabel,
                           tone: armTone, identifier: "remotepilot.status.arm")
                    DSChip("지연",
                           value: state.statusRail.latencyLabel,
                           tone: state.statusRail.latencyWarning ? .warning : .neutral,
                           identifier: "remotepilot.status.latency")
                    if let name = controllerAdapter.connectedControllerName {
                        DSChip(name,
                               tone: .accent,
                               identifier: "remotepilot.status.controller")
                    }
                }
            }
            EmergencyStopButton {
                Task {
                    simulator.release()
                    await state.performEStop()
                }
            }
        }
    }

    @ViewBuilder
    private var freeformModeBanner: some View {
        if !state.freeformWalkSupported {
            DSCard(tone: .danger, padding: DS.Space.m) {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(DS.Color.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("이 Mac 앱은 아직 자유 조종을 지원하지 않습니다.")
                            .font(DS.Font.bodyEmphasis)
                        Text("Mac 앱을 최신 빌드로 업데이트하거나 「동작」 탭의 전진, 좌회전, 우회전, 정지 버튼을 사용하세요.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
            }
            .accessibilityIdentifier("remotepilot.freeform.banner")
        }
    }

    /// 자동 낙하 복구 배너 — `cockpit.telemetry` 의 autoRecoveryPhase 가 활성일 때만.
    /// 로봇이 넘어졌거나 일어나는 중임을 사용자에게 즉시 알리고, 그동안 조종이 잠긴다는
    /// 맥락을 준다(Mac 측이 자동 복구 중 조종을 차단하므로).
    @ViewBuilder
    private var autoRecoveryBanner: some View {
        if let attitude = state.robotAttitude, attitude.isRecovering {
            DSCard(tone: .danger, padding: DS.Space.m) {
                HStack(alignment: .center, spacing: DS.Space.s) {
                    Image(systemName: "figure.fall")
                        .foregroundStyle(DS.Color.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(autoRecoveryLabel(attitude))
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.danger)
                        Text("자동 일어나기 중에는 조종이 일시 정지됩니다.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .accessibilityIdentifier("remotepilot.autorecovery.banner")
        }
    }

    private func autoRecoveryLabel(_ a: RobotAttitudePayload) -> String {
        let dir: String
        switch a.fallDirection {
        case "forward": dir = "앞으로 "
        case "backward": dir = "뒤로 "
        default: dir = ""
        }
        switch a.autoRecoveryPhase {
        case "fallen": return "\(dir)넘어짐 감지"
        case "settling": return "안정화 대기 중"
        case "gettingUp": return "\(dir)일어나는 중…"
        case "failed": return "일어나기 실패 — 점검 필요"
        default: return "자동 복구 중"
        }
    }

    /// 로봇 회선(②구간) 저하 배너 — Mac↔로봇 SSH 무선이 느리거나 stale 일 때.
    ///
    /// **왜 중요한가**: 모바일 상단의 "지연 Nms"(latencyMs)는 ①구간(iPhone↔Mac)만
    /// 반영해, SSH 무선으로 실제 로봇까지 0.7~2.5초 걸려도 화면엔 빠르게 보였다. 본
    /// 배너가 ②구간의 진실을 알려 사용자가 "유선 전환" 같은 조치를 하도록 한다.
    @ViewBuilder
    private var robotLinkBanner: some View {
        if let link = state.robotLink, link.isDegraded {
            DSCard(tone: .danger, padding: DS.Space.m) {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Image(systemName: link.isWireless ? "wifi.exclamationmark" : "exclamationmark.triangle.fill")
                        .foregroundStyle(DS.Color.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("로봇 회선이 느립니다 — 조종 반응이 지연될 수 있어요")
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.danger)
                        Text(robotLinkAdvice(link))
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                    Spacer()
                }
            }
            .accessibilityIdentifier("remotepilot.robotlink.banner")
        }
    }

    private func robotLinkAdvice(_ link: RobotLinkPayload) -> String {
        var bits: [String] = []
        if let rtt = link.robotLinkRttMs { bits.append("왕복 \(rtt)ms") }
        if let hz = link.telemetryHz { bits.append(String(format: "수신 %.1fHz", hz)) }
        let detail = bits.isEmpty ? "" : "(\(bits.joined(separator: ", "))) "
        if link.onboardStale == true {
            return "\(detail)로봇 응답이 끊겼습니다. Mac 앱에서 유선 연결을 확인하세요."
        }
        if link.isWireless {
            return "\(detail)Mac 앱에서 로봇을 유선(이더넷)으로 연결하면 훨씬 빨라집니다."
        }
        return "\(detail)잠시 후 회복되지 않으면 Mac 앱 연결을 확인하세요."
    }

    // MARK: - Cockpit HUD sections (NEW)

    /// 텔레메트리 그리드 — Mac → iOS 의 `TelemetryStatePayload` 11 필드를 모두 시각화.
    private var cockpitTelemetrySection: some View {
        CockpitTelemetryGrid(
            telemetry: state.telemetry,
            history: latencyHistory,
            macConnected: macIsConnected,
            pilotStateLabel: pilotStateKorean,
            robotLink: state.robotLink
        )
    }

    /// Cockpit HUD 1행 — 헤딩 컴퍼스 + 위치 미니맵 좌우 split.
    private var cockpitHUDSection: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            CockpitAttitudeIndicator(
                headingDeg: simulator.simHeadingDeg,
                isWalking: !simulator.isStopped,
                isArmed: state.pilotState.isArmed,
                stickMagnitude: stickActive.magnitude,
                rollDeg: state.robotAttitude?.rollDeg,
                pitchDeg: state.robotAttitude?.pitchDeg)
            CockpitMinimap(
                positionMM: simulator.simPositionMM,
                headingDeg: simulator.simHeadingDeg,
                trail: simulator.pathTrail,
                totalDistanceMm: simulator.totalDistanceMm,
                isSim: true)
        }
    }

    /// Cockpit HUD 2행 — 속도 게이지 + 명령 readout 좌우 split.
    private var cockpitGaugeSection: some View {
        VStack(spacing: DS.Space.s) {
            CockpitSpeedGauge(
                forwardMmPerSec: simulator.forwardSpeedMmPerSec,
                lateralMmPerSec: simulator.lateralSpeedMmPerSec,
                turnDegPerSec: simulator.turnSpeedDegPerSec,
                peakForwardMmPerSec: simulator.peakForwardSpeedMmPerSec,
                forwardNorm: simulator.forwardSpeedNorm,
                lateralNorm: simulator.lateralSpeedNorm,
                turnNorm: simulator.turnSpeedNorm)
            CockpitCommandReadout(
                strideMm: simulator.commandedStrideMm,
                sideMm: simulator.commandedSideMm,
                turnDeg: simulator.commandedTurnDeg,
                periodMs: simulator.periodMs,
                speedScale: simulator.speedScale,
                isActiveDispatch: state.pendingCommandLabel != nil
                                  || streamTask != nil,
                source: controllerAdapter.connectedControllerName ?? "조이스틱")
            simulationToggle
        }
    }

    /// 시뮬레이션 ON/OFF 토글 (Mac Cockpit 의 시뮬 토글과 동일).
    private var simulationToggle: some View {
        HStack {
            Toggle(isOn: $simEnabled) {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                        .foregroundStyle(simEnabled ? DS.Color.warning : DS.Color.tertiaryText)
                    Text("위치 시뮬")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DS.Color.warning)
            Spacer()
            if simEnabled {
                Text("미니맵·헤딩·거리 적분 활성")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.Color.tertiaryText)
            }
            Button {
                simulator.resetVisuals()
            } label: {
                Label("초기화", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, DS.Space.s)
    }

    // MARK: - Arm / joystick / rotation (기존 유지)

    @ViewBuilder
    private var armSection: some View {
        if state.pilotState.isArmed {
            DSCard(tone: .success, padding: DS.Space.m) {
                HStack {
                    Label("잠금 해제됨 — 조종 가능", systemImage: "lock.open.fill")
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.success)
                    Spacer()
                    DSButton("잠금",
                             systemImage: "lock.fill",
                             style: .secondary, size: .small) {
                        Task {
                            simulator.release()
                            await state.performDisarm()
                        }
                    }
                    .accessibilityIdentifier("remotepilot.disarm")
                }
            }
        } else {
            DSCard(padding: DS.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(armDisabledReason ?? "잠금 해제하여 조종 시작")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                    ArmSlider(isArmed: .constant(false),
                              disabled: armDisabledReason != nil,
                              label: "잠금 해제하려면 끝까지 밀기",
                              onArm: {
                                  guard state.armChecklistPassed else {
                                      showArmChecklist = true
                                      return
                                  }
                                  Task { await state.performArm() }
                              },
                              onDisarm: { })
                    if !state.armChecklistPassed {
                        DSButton("잠금 해제 전 확인",
                                 systemImage: "checklist",
                                 style: .secondary, size: .small) {
                            showArmChecklist = true
                        }
                        .accessibilityIdentifier("remotepilot.arm.checklist.open")
                    }
                }
            }
        }
    }

    private var joystickSection: some View {
        DSCard(padding: DS.Space.l) {
            VStack(spacing: DS.Space.m) {
                HStack {
                    DSSectionHeader("이동",
                                    subtitle: state.freeformWalkSupported
                                        ? "방향과 기울기만큼 속도가 바뀝니다. 손을 떼면 정지합니다."
                                        : "자유 조종은 실 로봇에서 비활성")
                    Spacer()
                    DSChip(stickMovementLabel(),
                           tone: stickActive.magnitude > 0.1 ? .accent : .neutral,
                           identifier: "remotepilot.move.value")
                }
                HStack {
                    Spacer()
                    DSJoystick(
                        size: 220,
                        label: "이동 조이스틱",
                        disabled: !joystickEnabled,
                        onChange: handleJoystickChange,
                        onRelease: handleJoystickRelease)
                    .accessibilityIdentifier("remotepilot.move.joystick")
                    Spacer()
                }
                DSSpeedSelector(selected: $speed,
                                enabledTiers: state.speedScaleSupported
                                    ? Set(SpeedTier.allCases)
                                    : [.slow])
                    .accessibilityIdentifier("remotepilot.speed")
                if !state.speedScaleSupported {
                    Label("현재 Mac 앱은 느림만 지원합니다. 업데이트 후 보통과 빠름을 사용할 수 있어요.",
                          systemImage: "speedometer")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                if !joystickEnabled {
                    Label(joystickDisabledHint, systemImage: "info.circle")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
        }
    }

    private var rotationSection: some View {
        DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    DSSectionHeader("회전", subtitle: nil)
                    Spacer()
                    DSChip("\(Int(rotationActive * 10))°/step",
                           tone: abs(rotationActive) > 0.1 ? .accent : .neutral,
                           identifier: "remotepilot.turn.value")
                }
                DSRotationDial(height: 70,
                               disabled: !joystickEnabled,
                               onChange: handleRotationChange,
                               onRelease: handleRotationRelease)
                .accessibilityIdentifier("remotepilot.turn.dial")
                if !joystickEnabled {
                    Label(joystickDisabledHint, systemImage: "info.circle")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
        }
    }

    // MARK: - 볼 트래킹 (2026-06-02)

    /// 로봇 온보드 자동 헤드 추적 on/off. 조종기 X 버튼과 동일 상태(state.ballTrackingActive)
    /// 를 공유 — 화면 토글이든 버튼이든 결과가 일치한다. Mac 미지원이면 비활성.
    private var ballTrackSection: some View {
        DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    DSSectionHeader("볼 트래킹", subtitle: "로봇이 공을 따라 머리 이동")
                    Spacer()
                    DSChip(state.ballTrackingActive ? "ON" : "OFF",
                           tone: state.ballTrackingActive ? .accent : .neutral,
                           identifier: "remotepilot.balltrack.value")
                }
                Button {
                    Task { await state.toggleBallTracking() }
                } label: {
                    Label(state.ballTrackingActive ? "볼 트래킹 끄기" : "볼 트래킹 켜기",
                          systemImage: state.ballTrackingActive ? "eye.fill" : "eye")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.isMacReady || !state.ballTrackingSupported)
                .accessibilityIdentifier("remotepilot.balltrack.toggle")
                Text("조종기 X 버튼으로도 토글됩니다.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
    }

    // MARK: - Motion quick actions (NEW)

    /// 자주 쓰는 모션 빠른 진입 — walkReady/basic/sit/greeting. ARM 후만 활성.
    private var motionQuickSection: some View {
        DSCard(padding: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    DSSectionHeader("모션", subtitle: "안전 자세 빠른 진입")
                    Spacer()
                    if let label = state.pendingCommandLabel {
                        DSChip(label,
                               tone: .accent,
                               identifier: "remotepilot.motion.pending")
                    }
                }
                let labels = ["walkReady", "basicPosture", "sit", "greeting"]
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.s) {
                        ForEach(labels, id: \.self) { motion in
                            motionButton(label: motion)
                        }
                    }
                }
                if !motionEnabled {
                    Label("잠금 해제 후 사용 가능", systemImage: "info.circle")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
        }
    }

    private func motionButton(label: String) -> some View {
        let entry = SafeMotionCatalog.entry(forLabel: label)
        let korean = entry?.koreanName ?? label
        return Button {
            Task { await state.performMotion(label: label) }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: iconFor(motion: label))
                    .font(.title3)
                Text(korean)
                    .font(.system(size: 11, weight: .semibold))
                if let slot = entry?.slot {
                    Text("slot \(slot)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(DS.Color.tertiaryText)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .frame(minWidth: 84)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .fill(DS.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.s)
                    .stroke(DS.Color.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!motionEnabled)
        .opacity(motionEnabled ? 1 : 0.4)
        .accessibilityIdentifier("remotepilot.motion.\(label)")
    }

    private func iconFor(motion: String) -> String {
        switch motion {
        case "walkReady": return "figure.walk"
        case "basicPosture": return "figure.stand"
        case "sit": return "chair"
        case "greeting": return "hand.wave"
        default: return "figure.walk"
        }
    }

    private var motionEnabled: Bool {
        state.pilotState.isArmed && state.isMacReady
    }

    // MARK: - Head section

    private var headSection: some View {
        DSCard(padding: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                DSHeadControl(enabled: $headEnabled,
                              panDeg: $headPan,
                              tiltDeg: $headTilt,
                              trackingAvailable: false,
                              trackingEnabled: $headTracking,
                              disabled: !state.isMacReady || !state.headControlSupported,
                              onChange: { en, pan, tilt, tr in
                                  Task {
                                      await state.sendHead(enabled: en, panDeg: pan,
                                                           tiltDeg: tilt, tracking: tr)
                                  }
                              })
                if !state.headControlSupported {
                    Label("머리 방향 조절은 첫 빌드에서 연습 모드 미리보기만 지원합니다.",
                          systemImage: "info.circle")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .accessibilityIdentifier("remotepilot.head.unsupported")
                }
            }
        }
    }

    // MARK: - Feedback section

    @ViewBuilder
    private var feedbackSection: some View {
        if let label = state.pendingCommandLabel {
            DSCard(tone: .accent, padding: DS.Space.m) {
                Label("실행 중: \(label)", systemImage: "waveform")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.brand)
            }
        }
        if let receipt = state.lastReceipt {
            DSCard(padding: DS.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("최근 명령").font(DS.Font.captionEmphasis)
                        .foregroundStyle(DS.Color.secondaryText)
                    Text(receipt.commandId).font(DS.Font.caption.monospaced())
                    Text(receiptDescription(receipt)).font(DS.Font.caption)
                }
            }
        }
        if let banner = state.recoveryBanner {
            DSCard(tone: .danger, padding: DS.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(banner.kind.rawValue.uppercased(),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.danger)
                    Text(banner.message)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                    DSButton("확인", style: .secondary, size: .small) {
                        state.acknowledgeRecovery()
                    }
                }
            }
        }
    }

    // MARK: - Handlers (joystick / rotation)

    private func handleJoystickChange(_ v: DSJoystick.Vector) {
        stickActive = v
        let input = WalkFreeformInput(x: v.x, y: v.y, turn: rotationActive,
                                      speedScale: speed.multiplier)
        lastFreeform = input
        simulator.apply(input: input)
        scheduleStream(input)
    }

    private func handleJoystickRelease() {
        stickActive = .zero
        let input = WalkFreeformInput(x: 0, y: 0, turn: rotationActive,
                                      speedScale: speed.multiplier)
        simulator.apply(input: input)
        if abs(rotationActive) > 0.05 {
            scheduleStream(input)
        } else {
            stopStream()
            Task { await state.releaseWalk() }
        }
    }

    private func handleRotationChange(_ v: Double) {
        rotationActive = v
        let input = WalkFreeformInput(x: stickActive.x, y: stickActive.y, turn: v,
                                      speedScale: speed.multiplier)
        simulator.apply(input: input)
        scheduleStream(input)
    }

    private func handleRotationRelease() {
        rotationActive = 0
        let input = WalkFreeformInput(x: stickActive.x, y: stickActive.y, turn: 0,
                                      speedScale: speed.multiplier)
        simulator.apply(input: input)
        if stickActive.magnitude > 0.05 {
            scheduleStream(input)
        } else {
            stopStream()
            Task { await state.releaseWalk() }
        }
    }

    /// Throttle to ~10Hz to align with Mac watchdog's 5Hz robot dispatch.
    private func scheduleStream(_ input: WalkFreeformInput) {
        lastFreeform = input
        if streamTask == nil {
            streamTask = Task { @MainActor in
                while !Task.isCancelled {
                    let snapshot = lastFreeform
                    await state.streamWalk(snapshot)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if !snapshot.isMoving && !lastFreeform.isMoving { break }
                }
                streamTask = nil
            }
        }
    }

    private func stopStream() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Derived

    private var controlsEnabled: Bool {
        state.pilotState.isArmed && state.isMacReady
    }

    /// Joystick is enabled only when the state machine allows control AND
    /// freeform walking is actually supported in the current mode (Mock).
    private var joystickEnabled: Bool {
        controlsEnabled && state.freeformWalkSupported
    }

    private var joystickDisabledHint: String {
        if !state.freeformWalkSupported {
            return "Mac 앱 업데이트 후 자유 조종을 사용할 수 있어요."
        }
        return CommandPermission.reason(forWalk: state.pilotState,
                                        telemetry: state.telemetry)?.koreanCopy
            ?? "잠금 해제 후 사용 가능합니다."
    }

    private var armDisabledReason: String? {
        state.armStartDisabledReason?.koreanCopy
    }

    /// PilotState → 한국어 라벨 (텔레메트리 그리드 표시용).
    private var pilotStateKorean: String {
        switch state.pilotState {
        case .notPaired: return "미페어링"
        case .pairing: return "페어링 중"
        case .pairedNoMac: return "Mac 대기"
        case .macConnectedNoRobot: return "Mac만 연결"
        case .robotConnectedLocked: return "로봇 연결"
        case .arming: return "ARM 중"
        case .armedReady: return "준비 완료"
        case .commandActive: return "명령 중"
        case .staleStop: return "STALE"
        case .estopped: return "E-STOP"
        }
    }

    /// Transport.connected (associated value 무시) 매칭.
    private var macIsConnected: Bool {
        if case .connected = state.transport { return true }
        return false
    }

    /// CockpitTelemetryGrid 용 latency sparkline 입력.
    private var latencyHistory: [CockpitTelemetryGrid.LatencySample] {
        state.telemetryHistory.suffix(24).map {
            CockpitTelemetryGrid.LatencySample(latencyMs: $0.latencyMs)
        }
    }

    private func stickMovementLabel() -> String {
        guard stickActive.magnitude > 0.1 else { return "정지" }
        var parts: [String] = []
        if stickActive.y < -0.15 { parts.append("전진") }
        if stickActive.y > 0.15 { parts.append("후진") }
        if stickActive.x < -0.15 { parts.append("좌") }
        if stickActive.x > 0.15 { parts.append("우") }
        return parts.joined(separator: "·")
    }

    private func receiptDescription(_ r: CommandReceipt) -> String {
        switch r.outcome {
        case .accepted: return "접수"
        case .acked(let ms): return "응답 \(ms)ms"
        case .rejected(let reason, _): return "거부 \(reason.rawValue)"
        case .failed(let reason, _): return "실패 \(reason.rawValue)"
        }
    }

    // MARK: - Tones (status rail)

    private var macTone: DSChip.Tone {
        switch state.transport {
        case .connected: return .success
        case .connecting, .handshaking, .idle: return .info
        case .disconnected: return .danger
        }
    }
    private var robotTone: DSChip.Tone {
        guard let t = state.telemetry else { return .neutral }
        switch t.robot {
        case .connected: return .success
        case .sim: return .neutral
        case .stale, .busBusy: return .warning
        case .disconnected: return .neutral
        case .estopped: return .danger
        }
    }
    private var armTone: DSChip.Tone {
        switch state.pilotState {
        case .armedReady, .commandActive: return .success
        case .arming: return .info
        case .estopped, .staleStop: return .danger
        default: return .neutral
        }
    }
}

// MARK: - ARM checklist content (shared with Pilot screen)

struct ArmChecklistContent: View {
    @ObservedObject var state: AppState
    var body: some View {
        Form {
            Section("필수 확인") {
                Toggle("로봇이 크래들에 있거나 안전줄로 고정되어 있어요", isOn: $state.cradleConfirmed)
                    .accessibilityIdentifier("remotepilot.arm.checklist.cradle")
                // P1-4 fix: real toggles.
                Toggle("물리 긴급 정지 버튼에 손이 닿아요",
                       isOn: $state.physicalEStopConfirmed)
                    .accessibilityIdentifier("remotepilot.arm.checklist.estop")
                Toggle("로봇을 직접 보고 있어요",
                       isOn: $state.lineOfSightConfirmed)
                    .accessibilityIdentifier("remotepilot.arm.checklist.lineofsight")
            }
            Section("주의") {
                Label("잠금 해제 후 실제 로봇이 움직일 수 있습니다.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Color.warning)
                Label("응답 지연이 크면 보행이 자동 차단됩니다.",
                      systemImage: "info.circle.fill")
                    .foregroundStyle(DS.Color.info)
                Label("첫 빌드는 느린 속도만 활성화되어 있습니다.",
                      systemImage: "tortoise.fill")
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
    }
}
