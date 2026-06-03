import SwiftUI

/// 범용 컨트롤러 세팅 시트 (M4 코어) — 게임패드 없이 **가상 컨트롤러**로 키매핑/주입
/// 체감. 가상 패드 입력이 `CockpitControllerDriver` 를 통해 동일 `CockpitState` 에
/// 30Hz 주입되어 뒤편 cockpit 로봇이 실시간 반응한다.
///
/// 레이아웃: 헤더(프리셋·연결·conflict) / 좌 바인딩 목록 / 중앙 가상 패드 / 우 라이브 테스트.
/// press-to-bind·곡선 에디터·캘리브레이션은 후속(M4 확장) 범위.
@MainActor
public struct CockpitControllerSettingsSheet: View {
    @ObservedObject var cockpit: CockpitState
    @Binding var isPresented: Bool

    @StateObject private var source = VirtualControllerSource()
    @State private var driver: CockpitControllerDriver?
    @State private var preset: Preset = .xbox

    /// 기본 프리셋 선택.
    enum Preset: String, CaseIterable, Identifiable {
        case xbox, dualSense, empty
        var id: String { rawValue }
        var label: String {
            switch self {
            case .xbox:      return "Xbox / RG G01"
            case .dualSense: return "DualSense"
            case .empty:     return "비어 있음"
            }
        }
        var profile: ControllerBindingProfile {
            switch self {
            case .xbox:      return .xbox
            case .dualSense: return .dualSense
            case .empty:     return .empty
            }
        }
    }

    private var profile: ControllerBindingProfile { preset.profile }

    public init(cockpit: CockpitState, isPresented: Binding<Bool>) {
        self.cockpit = cockpit
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.1))
            HStack(alignment: .top, spacing: 14) {
                bindingList.frame(width: 240)
                Divider().overlay(Color.white.opacity(0.08))
                VStack(spacing: 12) {
                    VirtualControllerPad(source: source)
                        .background(RoundedRectangle(cornerRadius: 12).fill(CockpitColors.panelSolid))
                    injectionReadout
                }
                ControllerLiveTestPanel(source: source, profile: profile)
                    .frame(width: 300)
            }
            .padding(14)
        }
        .frame(width: 1040, height: 660)
        .background(CockpitColors.backdrop)
        .onAppear(perform: startDriver)
        .onDisappear(perform: stopDriver)
        .onChange(of: preset) { _, _ in driver?.profile = profile }
    }

    // MARK: - 헤더

    private var header: some View {
        HStack(spacing: 16) {
            Label("컨트롤러 세팅", systemImage: "gamecontroller.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            Picker("프리셋", selection: $preset) {
                ForEach(Preset.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            conflictBadge

            Spacer()

            Text("가상 컨트롤러 · 게임패드 없이 데모")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))

            Button("닫기") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var conflictBadge: some View {
        let conflicts = profile.conflicts()
        return Group {
            if conflicts.isEmpty {
                Label("충돌 없음", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(CockpitColors.live)
            } else {
                Label("\(conflicts.count) 충돌", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(CockpitColors.warn)
                    .help(conflictSummary(conflicts))
            }
        }
        .font(.system(size: 11, weight: .medium))
    }

    private func conflictSummary(_ conflicts: [ControllerBindingConflict]) -> String {
        conflicts.map { c in
            switch c {
            case .duplicateInput(let b, let acts):
                return "중복 입력 \(b.displayLabel): \(acts.map(\.label).joined(separator: ", "))"
            case .safetyCriticalUnbound(let a):
                return "안전 미할당: \(a.label)"
            }
        }.joined(separator: "\n")
    }

    // MARK: - 바인딩 목록

    private var bindingList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(CockpitAction.Group.allCases, id: \.self) { group in
                    let actions = CockpitAction.allCases.filter { $0.group == group }
                    if !actions.isEmpty {
                        Text(group.rawValue.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))
                        ForEach(actions, id: \.self) { bindingRow($0) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func bindingRow(_ action: CockpitAction) -> some View {
        let binding = profile.bindings[action] ?? .unbound
        let isUnboundSafety = action.isSafetyCritical && binding.isUnbound
        return HStack {
            Text(action.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(binding.displayLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(isUnboundSafety ? CockpitColors.danger : CockpitColors.cyan)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))
    }

    // MARK: - 주입 확인 (뒤편 cockpit 반응 증거)

    private var injectionReadout: some View {
        HStack(spacing: 16) {
            metric("주입 L-스틱", String(format: "%+.2f, %+.2f", cockpit.leftStick.x, cockpit.leftStick.y))
            metric("회전", String(format: "%+.2f", cockpit.rightStick.x))
            metric("명령", commandText)
            metric("소스", cockpit.lastSource.label)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    private var commandText: String {
        let c = cockpit.lastCommand
        if c.isStop { return "정지" }
        return String(format: "보행 %.0f/%.0f/%.0f", c.strideMm, c.sideMm, c.turnDeg)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(CockpitColors.live)
        }
    }

    // MARK: - 드라이버 lifecycle

    private func startDriver() {
        let d = CockpitControllerDriver(state: cockpit, source: source, profile: profile)
        d.start()
        driver = d
    }

    private func stopDriver() {
        driver?.stop()
        driver = nil
        source.resetAll()
        cockpit.release()
    }
}
