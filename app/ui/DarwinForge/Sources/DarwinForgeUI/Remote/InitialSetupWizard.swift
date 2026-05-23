import ForgeCore
import SwiftUI

/// 로봇 첫 만남 시 4단계 셋업 가이드.
///
/// 흐름:
///   Step 1: VNC 데스크톱 열기 (시각 접근)
///   Step 2: 로봇에서 마스터 셋업 명령 실행 (SSH + 5530 + df-inbox 영구)
///   Step 3: Mac SSH key 등록 (passwordless)
///   Step 4: DarwinForge 자동 연결
///
/// 각 단계는 자동 검증 (5초 폴링) — 사용자가 별도 "다음" 안 눌러도 자동 진행.
@MainActor
public final class InitialSetupState: ObservableObject {

    public enum StepStatus: Equatable {
        case pending      // 아직 안 함
        case inProgress   // 사용자가 액션 수행 중
        case verifying    // 자동 검증 중
        case completed    // 완료
    }

    public enum Step: Int, CaseIterable {
        case vnc = 0
        case robotSetup
        case macSSHKey
        case connect

        public var title: String {
            switch self {
            case .vnc:         return "VNC 화면 공유 열기"
            case .robotSetup:  return "로봇 마스터 셋업"
            case .macSSHKey:   return "Mac SSH key 등록"
            case .connect:     return "DarwinForge 연결"
            }
        }
        public var subtitle: String {
            switch self {
            case .vnc:         return "로봇 데스크톱 + 가상 키보드"
            case .robotSetup:  return "SSH + 5530 + df-inbox 영구 활성"
            case .macSSHKey:   return "비밀번호 없이 즉시 명령"
            case .connect:     return "5530 자동 연결"
            }
        }
        public var icon: String {
            switch self {
            case .vnc:         return "display"
            case .robotSetup:  return "wand.and.stars"
            case .macSSHKey:   return "key.fill"
            case .connect:     return "antenna.radiowaves.left.and.right"
            }
        }
    }

    @Published public private(set) var statuses: [Step: StepStatus] = [
        .vnc: .pending, .robotSetup: .pending,
        .macSSHKey: .pending, .connect: .pending
    ]
    @Published public var host: String = DFConnectionConstants.robotEthernetIP
    @Published public var username: String = "robotis"

    private var pollTask: Task<Void, Never>?

    /// 사이클 194 (cycle 190 audit P0 #2): wizard 첫 진입 시각 — completed 이벤트 의
    /// elapsed_ms 계산용. startAutoVerification 호출 시 set.
    private var wizardStartedAt: Date?
    /// 사이클 194: completed 이벤트 가 한 번만 발화 보장.
    private var completedFired: Bool = false

    public func startAutoVerification() {
        // 사이클 194: 첫 진입 시각 기록 (재진입 시 reset 안 함 — 누적 시간 정확).
        if wizardStartedAt == nil { wizardStartedAt = Date() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.verifyAll()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    public func stopAutoVerification() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func mark(_ step: Step, _ status: StepStatus) {
        // 사이클 194 (cycle 190 audit P0 #2): 모든 step status 전환 telemetry.
        // 단일 hook — 자동 verify + 수동 button 둘 다 본 method 경유 → 발화 site 통합.
        let from = statuses[step] ?? .pending
        guard from != status else { return }  // no-op transition skip.
        statuses[step] = status
        Harness.shared.record(
            .setupWizardStepChanged, level: .info, actor: .user,
            data: ["step": AnyCodable(String(describing: step)),
                   "from": AnyCodable(String(describing: from)),
                   "to": AnyCodable(String(describing: status))]
        )
        // 사이클 194: 모든 step completed 첫 전환 → wizard completed telemetry.
        if !completedFired && allDone {
            completedFired = true
            let elapsedMs = wizardStartedAt.map {
                Int(Date().timeIntervalSince($0) * 1000)
            } ?? 0
            Harness.shared.record(
                .setupWizardCompleted, level: .notice, actor: .user,
                data: ["elapsed_ms": AnyCodable(elapsedMs)]
            )
        }
    }

    public var allDone: Bool {
        Step.allCases.allSatisfy { statuses[$0] == .completed }
    }

    /// 자동 검증 — 각 단계의 외부 신호로 완료 여부 판정.
    private func verifyAll() async {
        // VNC: macOS에 /Volumes 마운트 또는 Screen Sharing 프로세스 — 정확한 검증 어려움.
        // 사용자가 한 번 "열었음" 클릭하면 완료. 자동 검증은 안 함.

        // Robot setup: TCP 5530 + SSH 22 둘 다 listen 중인지.
        let port5530 = await NetworkProbe.tcpProbe(host: host, port: 5530, timeout: 1.0)
        let port22   = await NetworkProbe.tcpProbe(host: host, port: 22,   timeout: 1.0)
        let bothOpen: Bool = {
            if case .open = port5530, case .open = port22 { return true }
            return false
        }()
        if bothOpen, statuses[.robotSetup] != .completed {
            // 사이클 194: 자동 verify path 도 mark() 경유 — telemetry 일관성.
            mark(.robotSetup, .completed)
        }

        // Mac SSH key: SSH BatchMode 즉시 응답.
        if statuses[.robotSetup] == .completed {
            let sshOK = await SSHShell.isReachable(host: host, user: username, timeout: 2.0)
            if sshOK, statuses[.macSSHKey] != .completed {
                mark(.macSSHKey, .completed)
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }
}

/// 4단계 stepper UI — InitialSetupState 와 함께 사용.
public struct InitialSetupWizardView: View {
    @EnvironmentObject var store: ConnectionStore
    @StateObject private var state = InitialSetupState()
    @State private var copyToast: String?
    @Environment(\.dfWindowWidth) private var winWidth

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                header
                ForEach(InitialSetupState.Step.allCases, id: \.self) { step in
                    stepCard(step)
                }
                if state.allDone {
                    completionCard
                }
            }
            .padding(DFSpace.md)
        }
        .glassScroll(accent: DFColor.accent)
        .background(DFColor.canvas)
        .onAppear {
            state.startAutoVerification()
            // 이미 연결된 상태면 connect 단계 완료 마킹.
            if case .connected = store.status { state.mark(.connect, .completed) }
        }
        .onChange(of: store.status) { _, new in
            if case .connected = new { state.mark(.connect, .completed) }
        }
        .onDisappear { state.stopAutoVerification() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "sparkles")
                    .foregroundStyle(DFColor.forge)
                Text("초기 셋업")
                    .font(DFFont.title)
                Spacer()
                progressBadge
            }
            Text("로봇과 처음 만나는 경우 — 4단계만 따라하면 영구 자동화 완료. 자동 검증되니 단계가 끝나면 자동으로 다음으로.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressBadge: some View {
        let done = state.statuses.values.filter { $0 == .completed }.count
        let total = InitialSetupState.Step.allCases.count
        return Text("\(done) / \(total)")
            .font(.system(size: DFFontSize.s12, weight: .bold, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(done == total ? DFColor.success.opacity(0.16) : DFColor.accent.opacity(0.16))
            .foregroundStyle(done == total ? DFColor.success : DFColor.accent)
            .clipShape(Capsule())
    }

    // MARK: - Step card

    private func stepCard(_ step: InitialSetupState.Step) -> some View {
        let status = state.statuses[step] ?? .pending
        return VStack(alignment: .leading, spacing: DFSpace.sm2) {
            HStack(spacing: DFSpace.sm2) {
                stepNumberBadge(step, status: status)
                VStack(alignment: .leading, spacing: DFSpace.micro) {
                    HStack(spacing: DFSpace.xs2) {
                        Image(systemName: step.icon)
                            .foregroundStyle(stepTint(status))
                        Text(step.title).font(DFFont.bodyEmph)
                    }
                    Text(step.subtitle)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
                Spacer()
                if status == .completed {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: DFFontSize.s18))
                        .foregroundStyle(DFColor.success)
                } else if status == .verifying {
                    ProgressView().controlSize(.small)
                }
            }
            stepActions(step)
        }
        .padding(12)
        .background(stepBackground(status))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.md)
                .stroke(stepBorder(status), lineWidth: 0.8)
        )
    }

    private func stepNumberBadge(_ step: InitialSetupState.Step, status: InitialSetupState.StepStatus) -> some View {
        ZStack {
            Circle().fill(stepTint(status).opacity(0.16)).frame(width: DFSize.iconXl, height: DFSize.iconXl)
            Text("\(step.rawValue + 1)")
                .font(.system(size: DFFontSize.s14, weight: .bold))
                .foregroundStyle(stepTint(status))
        }
    }

    private func stepTint(_ status: InitialSetupState.StepStatus) -> Color {
        switch status {
        case .completed: return DFColor.success
        case .verifying, .inProgress: return DFColor.accent
        case .pending: return DFColor.textSecondary
        }
    }
    private func stepBackground(_ status: InitialSetupState.StepStatus) -> Color {
        switch status {
        case .completed: return DFColor.success.opacity(DFOpacity.o06)
        case .verifying: return DFColor.accent.opacity(DFOpacity.o06)
        default: return DFColor.card
        }
    }
    private func stepBorder(_ status: InitialSetupState.StepStatus) -> Color {
        switch status {
        case .completed: return DFColor.success.opacity(DFOpacity.strong)
        case .verifying: return DFColor.accent.opacity(DFOpacity.strong)
        default: return DFColor.textSecondary.opacity(DFOpacity.subtle)
        }
    }

    // MARK: - Step actions

    @ViewBuilder
    private func stepActions(_ step: InitialSetupState.Step) -> some View {
        switch step {
        case .vnc:           vncActions
        case .robotSetup:    robotSetupActions
        case .macSSHKey:     macSSHKeyActions
        case .connect:       connectActions
        }
    }

    // Step 1: VNC
    private var vncActions: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            Text("로봇 데스크톱을 Mac에 띄워 가상 키보드로 명령을 입력합니다.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            // **사이클 130 (audit #23, P0)**: 수동 확인 명시 — VNC 연결 자체는 자동 검증 안 됨.
            // 종전 "VNC 데스크톱 열기" 클릭 → 즉시 .completed → 사용자가 "Mac이 VNC 연결을
            // 검증했다" 로 오해. 신규 라벨로 "수동 확인 — 화면 표시되면 클릭" 강조.
            Text("⚠️ 자동 검증 X — 화면 표시 후 사용자가 수동 확인")
                .font(DFFont.caption)
                .foregroundStyle(.orange)
                .padding(.bottom, 2)
            HStack(spacing: DFSpace.sm) {
                Button {
                    if let u = URL(string: "vnc://\(state.host):5900") {
                        NSWorkspace.shared.open(u)
                    }
                    state.mark(.vnc, .completed)
                } label: {
                    Label("VNC 열고 — 화면 표시 시 수동 확인", systemImage: "display")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(DFColor.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Text("비밀번호 후보: `darwin` / `robotis` / `111111`")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
    }

    // Step 2: Robot master setup
    private var robotSetupActions: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            Text("VNC 터미널에 아래 한 블록을 붙여넣고 Enter — SSH + 5530 + df-inbox 영구 활성.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DFSpace.sm) {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(RobotSetupCommand.masterSetup, forType: .string)
                    copyToast = "✓ VNC 터미널에 붙여넣기"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { copyToast = nil }
                    state.mark(.robotSetup, .inProgress)
                } label: {
                    Label("마스터 셋업 복사", systemImage: "doc.on.clipboard.fill")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(DFColor.forge)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                if let msg = copyToast {
                    Text(msg).font(DFFont.caption).foregroundStyle(DFColor.success)
                }
            }
            DisclosureGroup("미리보기") {
                Text(RobotSetupCommand.masterSetup)
                    .font(.system(size: DFFontSize.s9, design: .monospaced))
                    .padding(8)
                    .background(DFColor.elev2)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .textSelection(.enabled)
            }
            .font(DFFont.caption)
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "info.circle")
                    .font(.system(size: DFFontSize.s10))
                Text("실행 후 \"SSH 22 + TCP 5530\" 둘 다 열리면 이 단계 자동 ✅")
                    .font(.system(size: DFFontSize.s10))
            }
            .foregroundStyle(DFColor.textSecondary)

            // **사이클 140 (audit #22 codex follow-up)**: rollback UI wire-up.
            // cycle 131 에서 const 만 정의, UI 미연결 (codex MINOR) → 사용자가 발견 불가.
            // 본 disclosureGroup 으로 노출 — 명시 expand 시만 복사 가능 (사고 방지).
            DisclosureGroup("⚠️ 셋업 원상복구 (rollback) — 부분 실패 시") {
                Text("masterSetup 도중 단계 5 (df-inbox) 실패 등으로 partial state 발생 시\n실행. SSH/dialout 은 보존 — 다른 용도 가능성.")
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(RobotSetupCommand.masterSetupRollback, forType: .string)
                    copyToast = "✓ rollback 명령 복사 — VNC 터미널 붙여넣기"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { copyToast = nil }
                } label: {
                    Label("rollback 복사", systemImage: "arrow.uturn.backward")
                        .font(.system(size: DFFontSize.s10))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .font(DFFont.caption)
        }
    }

    // Step 3: Mac SSH key
    private var macSSHKeyActions: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            Text("Mac 터미널을 열어 아래 명령을 한 번만 실행 — 그 후 비밀번호 없이 SSH 즉시 사용.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DFSpace.sm) {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(SSHShell.keyAuthSetupCommand(host: state.host, user: state.username),
                                 forType: .string)
                    copyToast = "✓ Mac 터미널 (cmd+space → Terminal) 에 붙여넣기"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { copyToast = nil }
                } label: {
                    Label("SSH key 셋업 복사", systemImage: "key.fill")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(DFColor.success)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    NSWorkspace.shared.launchApplication("Terminal")
                } label: {
                    Label("Terminal 열기", systemImage: "terminal")
                        .font(DFFont.caption)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(DFColor.card)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: DFSpace.xs) {
                Image(systemName: "info.circle")
                    .font(.system(size: DFFontSize.s10))
                Text("ssh-copy-id 단계에서 robotis 비번 (111111) 한 번 입력. 그 후 자동 ✅")
                    .font(.system(size: DFFontSize.s10))
            }
            .foregroundStyle(DFColor.textSecondary)
        }
    }

    // Step 4: DarwinForge connect
    private var connectActions: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            Text("앞 단계 완료 후 자동 연결 시도 — 또는 즉시 연결 시도.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            HStack(spacing: DFSpace.sm) {
                Button {
                    store.connect(endpoint: .network(host: state.host, port: 5530))
                } label: {
                    Label("지금 연결", systemImage: "play.fill")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(DFColor.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state.statuses[.robotSetup] != .completed)
            }
        }
    }

    // MARK: - Completion

    private var completionCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack(spacing: DFSpace.sm) {
                Image(systemName: "sparkles.tv.fill")
                    .font(.system(size: DFFontSize.s22))
                    .foregroundStyle(DFColor.success)
                Text("🎉 셋업 완료 — 영구 자동화")
                    .font(DFFont.title)
                    .foregroundStyle(DFColor.success)
            }
            Text("이제 로봇 전원만 켜면 자동으로 DarwinForge 연결 + SSH 명령 즉시 실행 + 원격 명령 패널 사용 가능. 더 이상 셋업 작업 필요 없어요.")
                .font(DFFont.body)
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(DFSpace.md)
        .background(DFColor.success.opacity(DFOpacity.ghost))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.md)
                .stroke(DFColor.success.opacity(DFOpacity.o30), lineWidth: 0.8)
        )
    }
}
