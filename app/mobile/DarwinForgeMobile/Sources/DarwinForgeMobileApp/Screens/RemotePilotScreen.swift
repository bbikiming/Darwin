import SwiftUI
import MobilePilotKit

/// 메인 조종기 화면 — 실시간 analog 조종.
///
/// 레이아웃 (portrait):
///   [Status Rail + E-Stop]
///   [Robot 상태 카드 + 속도]
///   [ARM 슬라이더 또는 ARM 완료 banner]
///   ┌──────────────────────┐
///   │   대형 이동 조이스틱   │   (XY: 전후 + 측면)
///   └──────────────────────┘
///   [회전 다이얼]
///   [헤드 컨트롤 카드]
///   [현재 명령 status banner]
public struct RemotePilotScreen: View {

    @EnvironmentObject var state: AppState
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

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.l) {
                    statusRailSection
                    freeformModeBanner
                    statePanelSection
                    armSection
                    joystickSection
                    rotationSection
                    headSection
                    feedbackSection
                }
                .padding(DS.Space.l)
            }
            .background(DS.Color.canvas)
            .navigationTitle("조종기")
            .dfInlineNavigationTitle()
            .accessibilityIdentifier("remotepilot.root")
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

    // MARK: - Sections

    private var statusRailSection: some View {
        HStack(spacing: DS.Space.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s) {
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
                }
            }
            EmergencyStopButton {
                Task { await state.performEStop() }
            }
        }
    }

    private var statePanelSection: some View {
        DSCard(padding: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                metric(label: "전압",
                       value: state.telemetry?.batteryV.map { String(format: "%.1f V", $0) } ?? "—")
                Divider().frame(height: 32)
                metric(label: "온도",
                       value: state.telemetry?.maxTempC.map { String(format: "%.0f ℃", $0) } ?? "—")
                Divider().frame(height: 32)
                metric(label: "지연",
                       value: state.telemetry.map { "\($0.latencyMs) ms" } ?? "—")
                Spacer()
                if let banner = state.recoveryBanner {
                    DSChip(banner.kind.rawValue.uppercased(),
                           tone: .danger, identifier: "remotepilot.recovery")
                }
            }
        }
    }

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
                        Task { await state.performDisarm() }
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
                                        ? "전후 + 측면. 손을 떼면 정지합니다. (연습)"
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
                DSSpeedSelector(selected: $speed, enabledTiers: [.slow])
                    .accessibilityIdentifier("remotepilot.speed")
                if !joystickEnabled {
                    Label(joystickDisabledHint, systemImage: "info.circle")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryText)
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
                        Text("자유 조종은 첫 빌드에서 실제 로봇에 전달되지 않습니다.")
                            .font(DS.Font.bodyEmphasis)
                        Text("실제 보행은 「동작」 탭의 검증된 전진, 좌회전, 우회전, 정지 버튼을 사용하세요.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
            }
            .accessibilityIdentifier("remotepilot.freeform.banner")
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
    }

    // MARK: - Handlers

    private func handleJoystickChange(_ v: DSJoystick.Vector) {
        stickActive = v
        let input = WalkFreeformInput(x: v.x, y: v.y, turn: rotationActive,
                                      speedScale: speed.multiplier)
        lastFreeform = input
        scheduleStream(input)
    }

    private func handleJoystickRelease() {
        stickActive = .zero
        let input = WalkFreeformInput(x: 0, y: 0, turn: rotationActive,
                                      speedScale: speed.multiplier)
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
        scheduleStream(input)
    }

    private func handleRotationRelease() {
        rotationActive = 0
        if stickActive.magnitude > 0.05 {
            let input = WalkFreeformInput(x: stickActive.x, y: stickActive.y, turn: 0,
                                          speedScale: speed.multiplier)
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
            return "자유 조종은 실 로봇에서 비활성 — 「동작」 탭의 버튼을 사용하세요."
        }
        return CommandPermission.reason(forWalk: state.pilotState,
                                        telemetry: state.telemetry)?.koreanCopy
            ?? "잠금 해제 후 사용 가능합니다."
    }

    private var armDisabledReason: String? {
        state.armStartDisabledReason?.koreanCopy
    }

    private var disabledHint: String {
        CommandPermission.reason(forWalk: state.pilotState,
                                 telemetry: state.telemetry)?.koreanCopy
            ?? "잠금 해제 후 사용 가능합니다."
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

    // MARK: - Subviews

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
            Text(value).font(DS.Font.metric)
        }
    }

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
