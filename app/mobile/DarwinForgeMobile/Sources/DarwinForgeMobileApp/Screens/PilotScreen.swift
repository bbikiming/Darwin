import SwiftUI
import MobilePilotKit

public struct PilotScreen: View {

    @EnvironmentObject var state: AppState
    @State private var mode: PilotMode = .actions
    @State private var showArmChecklist = false

    public init() {}

    enum PilotMode: String, CaseIterable, Identifiable {
        case actions = "동작"
        case walk    = "보행"
        case status  = "상태"
        var id: String { rawValue }
        var accessibilityID: String {
            switch self {
            case .actions: return "pilot.segment.actions"
            case .walk:    return "pilot.segment.walk"
            case .status:  return "pilot.segment.state"
            }
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                StatusRailView(model: state.statusRail,
                               onEStop: { Task { await state.performEStop() } })
                    .padding(.horizontal)

                if let banner = state.recoveryBanner {
                    InlineBanner(variant: .danger, message: banner.message,
                                 action: ("확인", { state.acknowledgeRecovery() }))
                        .padding(.horizontal)
                }

                RobotStatePanel(telemetry: state.telemetry)
                    .padding(.horizontal)

                ArmSection(state: state, showChecklist: $showArmChecklist)
                    .padding(.horizontal)

                Picker("모드", selection: $mode) {
                    ForEach(PilotMode.allCases) { m in
                        Text(m.rawValue).tag(m).accessibilityIdentifier(m.accessibilityID)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: mode) { _, newValue in
                    if newValue != .walk, state.activeWalkPreset != nil {
                        Task { await state.stopWalk(reason: .tabSwitch) }
                    }
                }

                ScrollView {
                    switch mode {
                    case .actions: ActionGrid(state: state)
                    case .walk:    WalkSection(state: state)
                    case .status:  StateSection(state: state)
                    }
                }
                .padding(.horizontal)

                if let label = state.pendingCommandLabel {
                    InlineBanner(variant: .info, message: "실행 중: \(label)")
                        .padding(.horizontal)
                }
            }
            .padding(.top, 8)
            .navigationTitle("로봇 동작")
            .dfInlineNavigationTitle()
            .background(Color.dfBackground)
            .accessibilityIdentifier("pilot.root")
            .sheet(isPresented: $showArmChecklist) {
                ArmChecklistSheet(state: state, isPresented: $showArmChecklist)
            }
        }
    }
}

// MARK: - Sub-views

struct RobotStatePanel: View {
    let telemetry: TelemetryStatePayload?
    var body: some View {
        HStack(spacing: 16) {
            Label {
                Text(endpointCopy)
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
            } icon: {
                Image(systemName: "cpu")
            }
            Spacer()
            if let v = telemetry?.batteryV {
                Label("\(String(format: "%.1f", v))V", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            if let t = telemetry?.maxTempC {
                Label("\(String(format: "%.0f", t))℃", systemImage: "thermometer")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .padding(12)
        .background(Color.dfSecondaryBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private var endpointCopy: String {
        guard let telemetry else { return "상태 수신 전" }
        if telemetry.robot == .sim { return "연습 시뮬레이션" }
        return telemetry.endpoint ?? "로봇 미연결"
    }
}

private struct ArmSection: View {
    @ObservedObject var state: AppState
    @Binding var showChecklist: Bool

    var body: some View {
        let armedBinding = Binding(
            get: { state.pilotState.isArmed },
            set: { _ in /* slider drives via callbacks */ }
        )
        VStack(spacing: 8) {
            ArmSlider(isArmed: armedBinding,
                      disabled: disabledReason != nil,
                      label: "잠금 해제하려면 끝까지 밀기",
                      onArm: {
                          guard state.armChecklistPassed else {
                              showChecklist = true
                              return
                          }
                          Task { await state.performArm() }
                      },
                      onDisarm: { Task { await state.performDisarm() } })
            if let reason = disabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !state.armChecklistPassed {
                Button("잠금 해제 전 확인하기") { showChecklist = true }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("pilot.arm.checklist.open")
            }
        }
    }

    private var disabledReason: String? {
        state.armStartDisabledReason?.koreanCopy
    }
}

private struct ArmChecklistSheet: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("필수 확인") {
                    Toggle("로봇이 크래들에 있거나 안전줄로 고정되어 있어요", isOn: $state.cradleConfirmed)
                        .accessibilityIdentifier("pilot.arm.checklist.cradle")
                    // P1-4 fix: real toggles (was disabled constant true).
                    Toggle("물리 긴급 정지 버튼에 손이 닿아요",
                           isOn: $state.physicalEStopConfirmed)
                        .accessibilityIdentifier("pilot.arm.checklist.estop")
                    Toggle("나 또는 관찰자가 로봇을 직접 보고 있어요",
                           isOn: $state.lineOfSightConfirmed)
                        .accessibilityIdentifier("pilot.arm.checklist.lineofsight")
                }
                Section("주의") {
                    Label("잠금 해제 후 실제 로봇이 움직일 수 있습니다.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Label("응답이 지연되면 보행 조작은 자동으로 차단됩니다.",
                          systemImage: "info.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            .navigationTitle("잠금 해제 전 확인")
            .dfInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { isPresented = false }
                }
            }
        }
        .accessibilityIdentifier("pilot.arm.checklist.sheet")
        .presentationDetents([.medium, .large])
    }
}

private struct ActionGrid: View {
    @ObservedObject var state: AppState

    private let entries: [(label: String, korean: String, systemImage: String, risk: MotionRisk)] = [
        ("walkReady",    "보행 자세", "figure.stand", .safe),
        ("basicPosture", "기본 자세", "figure.stand.line.dotted.figure.stand", .safe),
        ("sit",          "앉기",      "figure.seated.side", .caution),
        ("greeting",     "인사",      "hand.wave.fill", .safe)
        // P0-4: `bow` removed — slot 41 is `talk2` long-chain, not bow.
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(entries, id: \.label) { entry in
                ActionButton(title: entry.korean,
                             systemImage: entry.systemImage,
                             risk: entry.risk,
                             disabled: actionDisabled,
                             disabledReason: actionDisabledReason,
                             running: state.pendingCommandLabel == entry.korean,
                             accessibilityID: "pilot.action.\(entry.label.lowercased())") {
                    Task { await state.performMotion(label: entry.label) }
                }
            }
            ActionButton(title: "정지",
                         systemImage: "stop.circle.fill",
                         risk: .safe,
                         disabled: false,
                         disabledReason: nil,
                         running: false,
                         accessibilityID: "pilot.action.stop") {
                Task { await state.stopWalk(reason: .user) }
            }
        }
        .padding(.vertical, 4)
    }

    private var actionDisabled: Bool { actionDisabledReason != nil }
    private var actionDisabledReason: String? {
        CommandPermission.reason(forSafeAction: state.pilotState,
                                 telemetry: state.telemetry)?.koreanCopy
    }
}

private struct WalkSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("속도")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("속도", selection: .constant(0)) {
                    Text("느림").tag(0)
                    Text("보통").tag(1)
                    Text("빠름").tag(2)
                }
                .pickerStyle(.segmented)
                .disabled(true)
                .frame(maxWidth: 240)
            }
            WalkPad(
                disabled: walkDisabled,
                onPressBegan: { preset in
                    Task { await state.startWalk(preset) }
                },
                onReleased: {
                    Task { await state.stopWalk(reason: .deadmanRelease) }
                }
            )
            if let reason = walkDisabledReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var walkDisabled: Bool { walkDisabledReason != nil }
    private var walkDisabledReason: String? {
        CommandPermission.reason(forWalk: state.pilotState,
                                 telemetry: state.telemetry)?.koreanCopy
    }
}

private struct StateSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RobotDashboardView(state: state)
            if let receipt = state.lastReceipt {
                DSCard(padding: DS.Space.m) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("최근 명령").font(.subheadline.weight(.semibold))
                        row("명령 ID", value: receipt.commandId)
                        row("결과", value: receiptDescription(receipt))
                    }
                }
            }
        }
    }

    private func receiptDescription(_ r: CommandReceipt) -> String {
        switch r.outcome {
        case .accepted: return "접수"
        case .acked(let ms): return "응답 \(ms)ms"
        case .rejected(let reason, _): return "거부 \(reason.rawValue)"
        case .failed(let reason, _): return "실패 \(reason.rawValue)"
        }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }
}
