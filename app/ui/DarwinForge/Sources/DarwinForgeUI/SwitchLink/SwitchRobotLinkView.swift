import AppKit
import SwiftUI

/// **스위치 조종석 연결 세팅** 화면 (2026-06-07, 전문가 탭).
///
/// Mac DarwinForge 의 *검증된 로봇 SSH 채널*(`RemoteShell`)을 중계자로 써서,
/// Switch 의 공개키를 로봇 `authorized_keys` 에 등록하고 Switch 조종석을 실제
/// 조종 모드(`mode=ssh`)로 전환하는 단계별 마법사. 로직은 `SwitchRobotLinkSession`,
/// 명령은 `SwitchRobotLinkCommands` 가 소유 — 이 뷰는 표시/입력만 담당한다.
public struct SwitchRobotLinkView: View {

    @StateObject private var session: SwitchRobotLinkSession
    @ObservedObject private var robotShell: RemoteShell
    /// R2 — 앱 내 스위치 에이전트 자동 배포(package→scp→install→재시작→검증).
    @StateObject private var deploy: SwitchAgentDeploySession

    @State private var copyToast: String?
    @State private var expanded: Set<String> = []
    /// Switch sudo 비밀번호(SecureField) — 배포 후 즉시 비움. 저장/로그하지 않음.
    @State private var sudoPassword: String = ""

    /// RootView 가 `remoteShell`(로봇 채널)과 Mac 이 보는 로봇 host 를 주입.
    public init(remoteShell: RemoteShell, macRobotHost: String) {
        _robotShell = ObservedObject(wrappedValue: remoteShell)
        let host = macRobotHost.isEmpty ? remoteShell.host : macRobotHost
        let linkSession = SwitchRobotLinkSession(
            macRobotHost: host,
            macRobotUser: remoteShell.username,
            robotRun: { [weak remoteShell] cmd in
                guard let remoteShell else { return nil }
                guard let ex = await remoteShell.send(cmd, timeoutSeconds: 20) else { return nil }
                if let err = ex.error { return (false, err) }
                return (true, ex.result ?? "")
            })
        _session = StateObject(wrappedValue: linkSession)
        // 배포 effect 는 호출 시점의 switchHost/User 를 라이브로 읽는다(사용자 편집 반영).
        _deploy = StateObject(wrappedValue: SwitchAgentDeploySession(
            effects: SwitchAgentDeployBundle.liveEffects(switchTarget: { [linkSession] in
                (linkSession.switchHost.trimmingCharacters(in: .whitespaces),
                 linkSession.switchUser.trimmingCharacters(in: .whitespaces))
            })))
    }

    public var body: some View {
        DFPageScaffold(
            "스위치 연결 세팅",
            subtitle: "Mac 의 로봇 연결로 Switch 공개키를 등록 — 9단계, 한 번이면 영구",
            icon: "gamecontroller.fill",
            tint: DFColor.accent,
            trailing: { robotChannelChip }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: DFSpace.md) {
                    connectionMapCard
                    targetsCard
                    if robotShell.activeChannel != .ssh { robotChannelWarning }
                    launchModesCard
                    SwitchAgentDeploymentCard(deploy: deploy, sudoPassword: $sudoPassword)
                    advancedWizardDisclosure
                    liveStateCard
                    cmdDiagnosticCard
                    stabilizeCard
                }
                .padding(DFSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .task { await robotShell.probeChannel() }
    }

    // MARK: - Header chip

    private var robotChannelChip: some View {
        let (text, icon, tint): (String, String, Color) = {
            switch robotShell.activeChannel {
            case .ssh:         return ("로봇 SSH", "bolt.fill", DFColor.success)
            case .unavailable: return ("로봇 연결 없음", "bolt.slash.fill", DFColor.warning)
            case .unknown:     return ("탐색 중", "ellipsis.circle", DFColor.textSecondary)
            }
        }()
        return Label(text, systemImage: icon)
            .font(.system(size: DFFontSize.s10, weight: .semibold))
            .padding(.horizontal, DFSpace.xs2).padding(.vertical, DFSpace.micro2 + 1)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    // MARK: - Targets (Switch + 로봇 IP 분리 표시)

    private var targetsCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            Text("연결 대상")
                .font(DFFont.sectionSmall)
            HStack(spacing: DFSpace.md) {
                labeledField("Switch 사용자", text: $session.switchUser, placeholder: "yuseok")
                    .frame(maxWidth: 160)
                labeledField("Switch IP", text: $session.switchHost, placeholder: "192.168.0.25")
                    .frame(maxWidth: 200)
            }
            HStack(spacing: DFSpace.lg) {
                infoPair("Mac 이 보는 로봇", value: "\(session.macRobotUser)@\(session.macRobotHost)")
                if let target = session.switchConfiguredRobotTarget {
                    infoPair("Switch config 로봇", value: target)
                }
            }
            if let reachable = session.reachableRobotHost {
                calloutRow(icon: "checkmark.circle.fill", tint: DFColor.success,
                           text: "Switch 가 닿는 로봇 IP: \(reachable) — 이후 단계는 이 IP 를 사용하고, agent 전환 시 config 에 저장돼요.")
            } else if !session.robotCandidateIPs.isEmpty {
                infoPair("로봇 IP 후보", value: session.robotCandidateIPs.joined(separator: ", "))
            }
            if let warn = session.robotHostMismatchWarning {
                calloutRow(icon: "info.circle.fill", tint: DFColor.info, text: warn)
            }
        }
        .padding(DFSpace.md)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(RoundedRectangle(cornerRadius: DFRadius.md)
            .stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: 0.5))
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
            Text(label).font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: DFFontSize.s11, design: .monospaced))
        }
    }

    private func infoPair(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
            Text(label).font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
            Text(value).font(.system(size: DFFontSize.s11, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var robotChannelWarning: some View {
        calloutRow(
            icon: "bolt.slash.fill", tint: DFColor.warning,
            text: "Mac 의 로봇 SSH 채널이 아직 연결되지 않았어요. ‘로봇에 공개키 등록’ 단계는 로봇 SSH 가 필요합니다 — 연결 마법사에서 먼저 로봇에 연결하세요.")
    }

    private func calloutRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: DFSpace.xs) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: DFFontSize.s11))
            Text(text).font(DFFont.caption).foregroundStyle(DFColor.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(DFSpace.sm)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - Auto run

    private var autoRunBar: some View {
        HStack(spacing: DFSpace.sm) {
            Button {
                Task { await session.runThroughStatus() }
            } label: {
                Label("여기까지 자동 실행 (연결→패치 확인)", systemImage: "play.fill")
                    .font(DFFont.caption)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.runningStep != nil)

            if session.runningStep != nil {
                ProgressView().controlSize(.small)
                Text(session.runningStep?.title ?? "").font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            Text("위험 단계(WalkLab 시작)는 자동 실행에서 제외 — 안전 확인 후 수동")
                .font(.system(size: DFFontSize.s9))
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    // MARK: - Step card

    @ViewBuilder
    private func stepCard(_ step: SwitchRobotLinkSession.StepID) -> some View {
        let outcome = session.outcome(step)
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.sm) {
                stepStatusIcon(outcome.phase, fallbackIcon: step.icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title).font(.system(size: DFFontSize.s12, weight: .semibold))
                    Text(step.detail).font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.textSecondary)
                }
                Spacer()
                runButton(step)
            }

            if step.isDangerous { safetyToggle }

            if !outcome.message.isEmpty {
                Text(outcome.message)
                    .font(DFFont.caption)
                    .foregroundStyle(phaseColor(outcome.phase))
            }

            if let fb = outcome.fallbackCommand {
                fallbackRow(fb)
            }

            if !outcome.detail.isEmpty {
                disclosureOutput(step: step, text: outcome.detail)
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(RoundedRectangle(cornerRadius: DFRadius.sm)
            .stroke(borderColor(outcome.phase), lineWidth: 0.5))
    }

    private var safetyToggle: some View {
        Toggle(isOn: $session.safetyConfirmed) {
            Label("로봇을 잡고 있고 주변이 안전함 (모터/보행 엔진이 초기화됩니다)",
                  systemImage: "hand.raised.fill")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.danger)
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, DFSpace.micro2)
    }

    @ViewBuilder
    private func runButton(_ step: SwitchRobotLinkSession.StepID) -> some View {
        let busy = session.runningStep != nil
        let needsRobotSSH = (step == .installOnRobot || step == .discoverRoute)
            && robotShell.activeChannel != .ssh
        Button {
            Task { await run(step) }
        } label: {
            if session.runningStep == step {
                ProgressView().controlSize(.small)
            } else {
                Text("실행").font(DFFont.caption)
            }
        }
        .buttonStyle(.bordered)
        .tint(step.isDangerous ? DFColor.danger : DFColor.accent)
        .disabled(busy || needsRobotSSH || (step.isDangerous && !session.safetyConfirmed))
    }

    private func run(_ step: SwitchRobotLinkSession.StepID) async {
        switch step {
        case .switchReachable: await session.runSwitchReachable()
        case .discoverRoute:   await session.runDiscoverRoute()
        case .ensureKey:       await session.runEnsureKey()
        case .readPubKey:      await session.runReadPublicKey()
        case .installOnRobot:  await session.runInstallOnRobot()
        case .probe:           await session.runProbe()
        case .status:          await session.runStatus()
        case .startWalkLab:    await session.runStartWalkLab()
        case .enableAgent:     await session.runEnableAgent()
        case .finalVerify:     await session.runFinalVerify()
        }
    }

    // MARK: - Final summary

    @ViewBuilder
    private var finalSummary: some View {
        if session.finalConfigMode != nil || session.finalAgentActive != nil {
            let done = session.finalConfigMode == "ssh" && session.finalAgentActive == true
            calloutRow(
                icon: done ? "checkmark.seal.fill" : "hourglass",
                tint: done ? DFColor.success : DFColor.warning,
                text: done
                    ? "완료 — Switch config mode=ssh, agent active. 이제 Switch 조종석이 로봇을 직접 조종합니다."
                    : "아직 완료 전 — mode=\(session.finalConfigMode ?? "?"), agent=\(session.finalAgentActive == true ? "active" : "inactive")")
        }
    }

    // MARK: - 연결 지도 (Mac↔Robot, Mac↔Switch, Switch↔Robot)

    private var connectionMapCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            Text("연결 지도").font(DFFont.sectionSmall)
            HStack(spacing: DFSpace.xs) {
                linkPill("Mac", "↔", "로봇", ok: robotShell.activeChannel == .ssh,
                         detail: robotShell.activeChannel == .ssh ? "SSH 연결됨" : "미연결")
                linkPill("Mac", "↔", "Switch", ok: switchLinkOK,
                         detail: switchLinkOK ? "SSH 연결됨" : "미확인")
                linkPill("Switch", "↔", "로봇", ok: switchRobotOK,
                         detail: switchRobotDetail)
            }
        }
        .padding(DFSpace.md)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(RoundedRectangle(cornerRadius: DFRadius.md)
            .stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: 0.5))
    }

    private var switchLinkOK: Bool { session.outcome(.switchReachable).phase == .success }
    private var switchRobotOK: Bool {
        session.outcome(.probe).phase == .success || session.apiState?.sshConnected == true
    }
    private var switchRobotDetail: String {
        if session.apiState?.sshConnected == true { return "ssh_connected" }
        if let h = session.reachableRobotHost { return "닿는 IP \(h)" }
        return "미확인"
    }

    private func linkPill(_ a: String, _ mid: String, _ b: String, ok: Bool, detail: String) -> some View {
        VStack(spacing: DFSpace.micro2) {
            HStack(spacing: DFSpace.micro2) {
                Text(a).font(.system(size: DFFontSize.s10, weight: .semibold))
                Text(mid).font(.system(size: DFFontSize.s10)).foregroundStyle(ok ? DFColor.success : DFColor.textSecondary)
                Text(b).font(.system(size: DFFontSize.s10, weight: .semibold))
            }
            HStack(spacing: 3) {
                Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: DFFontSize.s9))
                    .foregroundStyle(ok ? DFColor.success : DFColor.textSecondary)
                Text(detail).font(.system(size: DFFontSize.s8)).foregroundStyle(DFColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DFSpace.xs)
        .background((ok ? DFColor.success : DFColor.textSecondary).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - 실시간 조종 상태 (/api/state)

    private var liveStateCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack {
                Text("실시간 조종 상태").font(DFFont.sectionSmall)
                Spacer()
                Button {
                    Task { await session.refreshApiState() }
                } label: {
                    if session.isRefreshingState {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("새로고침", systemImage: "arrow.clockwise").font(DFFont.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(session.isRefreshingState)
            }
            if let s = session.apiState {
                Text(apiStateSentence(s)).font(DFFont.caption).foregroundStyle(DFColor.textPrimary)
                let cols = [GridItem(.adaptive(minimum: 92), spacing: DFSpace.xs)]
                LazyVGrid(columns: cols, alignment: .leading, spacing: DFSpace.xs) {
                    statChip("mode", s.mode ?? "—", s.mode == "ssh" ? DFColor.success : DFColor.warning)
                    statChip("ssh_connected", boolText(s.sshConnected), s.sshConnected == true ? DFColor.success : DFColor.danger)
                    statChip("armed", boolText(s.armed), s.armed == true ? DFColor.success : DFColor.textSecondary)
                    statChip("deadman", boolText(s.deadman), s.deadman == true ? DFColor.success : DFColor.textSecondary)
                    statChip("moving", boolText(s.moving), s.moving == true ? DFColor.accent : DFColor.textSecondary)
                    statChip("stride", fmt(s.stride), DFColor.info)
                    statChip("turn", fmt(s.turn), DFColor.info)
                    statChip("input", (s.inputStatus ?? "—"), DFColor.textSecondary)
                }
            } else {
                Text("‘새로고침’으로 Switch 조종석 상태를 가져옵니다 (mode·ssh_connected·armed·deadman·moving·stride·turn).")
                    .font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(DFSpace.md)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(RoundedRectangle(cornerRadius: DFRadius.md)
            .stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: 0.5))
    }

    /// **정직한 문장** — 스위치 측 flag(armed/moving)는 "명령을 보냈다"는 뜻일 뿐이라,
    /// 로봇 측 생존(`pilotLiveness`)이 확인되기 전에는 "로봇에 반영"이라고 절대 단정하지 않는다.
    private func apiStateSentence(_ s: SwitchRobotLinkCommands.ApiState) -> String {
        if s.sshConnected != true {
            return "Switch가 아직 로봇에 SSH로 연결되지 않았습니다."
        }
        // 로봇 측 사실 우선: demo 가 안 떠 있으면 스위치가 뭘 보내든 로봇은 반응하지 않는다.
        if let live = session.pilotLiveness, !live.demoRunning {
            return "Switch는 연결됐지만 로봇에서 WalkLab(demo)이 실행 중이 아닙니다 — ‘WalkLab 시작’ 단계가 필요합니다. (스위치 명령은 받는 곳이 없어 무시됩니다.)"
        }
        if s.armed != true {
            return "연결됨. 아직 조종 권한(A)이 꺼져 있어 로봇이 움직이지 않습니다."
        }
        if s.deadman != true {
            return "조종 권한 ON. ZL/ZR(deadman)을 유지하고 왼쪽 스틱으로 이동하세요."
        }
        // armed+deadman 이어도, 로봇 측 ack 신선도가 확인돼야 "실제 반영" 이라 말한다.
        if let live = session.pilotLiveness {
            if live.actuallyConsuming {
                return "로봇이 스위치 명령을 실제로 소비 중입니다 (demo=\(live.demoName), ack \(live.ackAgeSec ?? 0)s 전). stride=\(fmt(s.stride)), turn=\(fmt(s.turn))."
            }
            return "스위치는 명령을 보내지만 로봇 브로커리지가 응답하지 않습니다 (ack \(live.ackAgeSec.map { "\($0)s 전" } ?? "없음")) — demo 상태/패치 확인 필요."
        }
        return "스위치 측 준비 완료 — 로봇 실제 반영 여부는 ‘로봇 실제 반영 확인’으로 검증하세요."
    }

    private func statChip(_ k: String, _ v: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: DFFontSize.s8)).foregroundStyle(DFColor.textSecondary)
            Text(v).font(.system(size: DFFontSize.s10, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DFSpace.xs).padding(.vertical, DFSpace.micro2 + 1)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }

    private func boolText(_ b: Bool?) -> String { b == nil ? "—" : (b! ? "yes" : "no") }
    private func fmt(_ d: Double?) -> String { d.map { String(format: "%.2f", $0) } ?? "—" }

    // MARK: - 명령 파일 진단 (/tmp/df-walklab-cmd)

    /// 로봇 측 사실에 근거한 정직한 판정 — 스위치 flag 가 아니라 demo 생존 + ack 신선도.
    @ViewBuilder
    private var livenessVerdict: some View {
        if let live = session.pilotLiveness {
            if !live.demoRunning {
                calloutRow(icon: "xmark.octagon.fill", tint: DFColor.danger,
                           text: "로봇 WalkLab(demo) 미실행 — 스위치 명령을 받을 주체가 없습니다. ‘WalkLab 시작’ 단계 필요. (pilot_mode=\(live.pilotMode))")
            } else if live.actuallyConsuming {
                calloutRow(icon: "checkmark.seal.fill", tint: DFColor.success,
                           text: "로봇이 명령을 실제로 소비 중 (demo=\(live.demoName), ack \(live.ackAgeSec ?? 0)s 전). 진짜 조종 가능 상태.")
            } else {
                calloutRow(icon: "exclamationmark.triangle.fill", tint: DFColor.warning,
                           text: "demo=\(live.demoName) 실행 중이나 브로커리지 무응답 (ack \(live.ackAgeSec.map { "\($0)s 전" } ?? "없음")) — 브로커리지 패치/모드 확인.")
            }
        } else {
            Text("‘검증’으로 로봇 측 demo 생존 + ack 신선도를 직접 확인합니다 (스위치 flag 만으로는 로봇 반응을 보장하지 않음).")
                .font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
        }
    }

    private var cmdDiagnosticCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack {
                Text("로봇 실제 반영 확인").font(DFFont.sectionSmall)
                Spacer()
                Button {
                    Task { await session.refreshPilotLiveness(); await session.refreshWalkLabCmd() }
                } label: {
                    Label("검증", systemImage: "stethoscope").font(DFFont.caption)
                }
                .buttonStyle(.borderless)
                .disabled(robotShell.activeChannel != .ssh)
            }
            livenessVerdict
            if let c = session.walkLabCmd {
                let cols = [GridItem(.adaptive(minimum: 88), spacing: DFSpace.xs)]
                LazyVGrid(columns: cols, alignment: .leading, spacing: DFSpace.xs) {
                    statChip("cmd_id", String(c.cmdId.prefix(8)), DFColor.textSecondary)
                    statChip("enabled", c.enabled ? "1" : "0", c.enabled ? DFColor.success : DFColor.textSecondary)
                    statChip("stride", String(format: "%.2f", c.stride), DFColor.info)
                    statChip("turn", String(format: "%.2f", c.turn), DFColor.info)
                    statChip("period", String(format: "%.0f", c.period), DFColor.accent)
                    statChip("foot", String(format: "%.0f", c.foot), DFColor.accent)
                }
                if let ts = c.timestamp {
                    Text("갱신: \(ts)").font(.system(size: DFFontSize.s8)).foregroundStyle(DFColor.textSecondary)
                }
            } else {
                Text("‘읽기’로 로봇 /tmp/df-walklab-cmd 를 가져와 조이콘 입력 반영(stride/turn)을 확인합니다. (Mac 로봇 채널 필요)")
                    .font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(DFSpace.md)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(RoundedRectangle(cornerRadius: DFRadius.md)
            .stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: 0.5))
    }

    // MARK: - 조종 모드 선택 (2026-06-08 재설계)

    /// **모드 선택 카드** — 3개 타일(빠른 조종 / 카메라+조종 / 진단)을 1열로 배치,
    /// 사용자가 의도하는 모드 하나를 클릭하면 그 모드에 필요한 단계만 자동 실행.
    /// 9단계 wizard 는 아래쪽 「고급/단계별 디버그」 disclosure 로 숨김.
    private var launchModesCard: some View {
        let out = session.demoSuiteOutcome
        let running = session.isRunningDemoSuite
        let needsRobot = robotShell.activeChannel != .ssh
        let lastMode = session.lastLaunchMode
        return VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack(alignment: .center, spacing: DFSpace.sm) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: DFFontSize.s16, weight: .semibold))
                    .foregroundStyle(DFColor.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("조종 모드 선택")
                        .font(DFFont.sectionSmall)
                    Text("원하는 조종 방식 하나를 골라 시작하세요. 모드에 따라 필요한 단계만 자동 실행됩니다.")
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            // 모터 ON 모드(빠른 조종 / 카메라+조종)는 안전 토글이 필요 — 카드에 박아 둠.
            demoSafetyToggle

            // 데모 기동 대기 안내 — 사용자가 "안 됐다" 고 오해해서 재시도하지 않도록.
            // 실측: demo 바이너리 nohup 부팅 + 모터 초기화 + 카메라까지 합쳐 보통 15~40s.
            // 진짜 "이제 조종 가능" 신호는 로봇의 오디오 안내음 + 자세 변경.
            demoStartupNotice

            // 후면 버튼 대체 경로 안내 — DarwinForge/Switch 연결 없이도 로봇만으로
            // WalkLab 진입 가능(2026-06-08 firmware patch). 사용자가 "Mac 안 들고
            // 나갔는데 시연해야 함" 같은 상황에서 폴백.
            backPanelHint

            // 3개 모드 타일 — 가로 한 줄(좁아질 때 자동 줄바꿈은 LazyVGrid 으로).
            let cols = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: DFSpace.sm)]
            LazyVGrid(columns: cols, alignment: .leading, spacing: DFSpace.sm) {
                ForEach(SwitchRobotLinkSession.LaunchMode.allCases) { mode in
                    modeTile(mode: mode, running: running, needsRobot: needsRobot, isLast: lastMode == mode)
                }
            }

            // 진척 — 마지막으로 선택된 모드의 스테이지만 progress strip 으로.
            if let mode = lastMode {
                Divider().padding(.vertical, 2)
                progressForMode(mode: mode, outcome: out)
            } else if needsRobot {
                calloutRow(icon: "bolt.slash.fill", tint: DFColor.warning,
                           text: "Mac 의 로봇 SSH 채널이 연결돼야 어떤 모드도 시작할 수 있습니다.")
            }
        }
        .padding(DFSpace.md)
        .background(
            LinearGradient(
                colors: [DFColor.accent.opacity(0.10), DFColor.card],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(RoundedRectangle(cornerRadius: DFRadius.md)
            .stroke(DFColor.accent.opacity(DFOpacity.o25), lineWidth: 1))
    }

    /// 개별 모드 타일 — 아이콘/제목/한 줄/필요 단계 칩 + 위험 배지 + 「시작」 버튼.
    @ViewBuilder
    private func modeTile(mode: SwitchRobotLinkSession.LaunchMode,
                          running: Bool,
                          needsRobot: Bool,
                          isLast: Bool) -> some View {
        let recommended = (mode == .cameraAndControl)
        let safetyMissing = mode.movesRobot && !session.safetyConfirmed
        let canRun = !running && !needsRobot && session.runningStep == nil && !safetyMissing
        let tint: Color = recommended ? DFColor.danger : DFColor.accent
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(alignment: .top, spacing: DFSpace.xs) {
                Image(systemName: mode.icon)
                    .font(.system(size: DFFontSize.s16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DFSpace.micro2) {
                        Text(mode.title)
                            .font(.system(size: DFFontSize.s12, weight: .bold))
                        if recommended {
                            Text("권장")
                                .font(.system(size: DFFontSize.s8, weight: .bold))
                                .padding(.horizontal, DFSpace.micro2 + 2)
                                .padding(.vertical, 1)
                                .background(tint.opacity(0.18))
                                .foregroundStyle(tint)
                                .clipShape(Capsule())
                        }
                        if isLast {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: DFFontSize.s9))
                                .foregroundStyle(DFColor.success)
                        }
                    }
                    Text(mode.subtitle)
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            // 메타: 위험 배지 + 스테이지 카운트. ETA 는 본 카드 상단 안내로 일원화.
            HStack(spacing: DFSpace.xs) {
                if mode.movesRobot {
                    metaChip(icon: "exclamationmark.triangle.fill",
                             text: "모터 ON · 오디오 대기", tint: DFColor.warning)
                } else {
                    metaChip(icon: "checkmark.shield.fill",
                             text: "안전 모드", tint: DFColor.success)
                }
                metaChip(icon: "list.bullet",
                         text: "\(mode.stages.count)단계")
                Spacer(minLength: 0)
            }

            Button {
                Task { await session.runLaunch(mode) }
            } label: {
                HStack(spacing: DFSpace.micro2) {
                    if running && isLast {
                        ProgressView().controlSize(.small)
                        Text("진행 중…").font(DFFont.caption)
                    } else {
                        Image(systemName: "bolt.fill")
                        Text("시작").font(DFFont.caption)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(!canRun)

            if safetyMissing {
                Text("안전 확인 필요 — 위의 토글을 켜세요")
                    .font(.system(size: DFFontSize.s8))
                    .foregroundStyle(DFColor.danger)
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.card.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(RoundedRectangle(cornerRadius: DFRadius.sm)
            .stroke(isLast ? tint.opacity(0.5) : DFColor.textSecondary.opacity(DFOpacity.o25),
                    lineWidth: isLast ? 1 : 0.5))
    }

    @ViewBuilder
    private func metaChip(icon: String, text: String, tint: Color = DFColor.textSecondary) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: DFFontSize.s8))
            Text(text).font(.system(size: DFFontSize.s8, weight: .medium))
        }
        .padding(.horizontal, DFSpace.micro2 + 2)
        .padding(.vertical, 1)
        .background(tint.opacity(0.10))
        .foregroundStyle(tint)
        .clipShape(Capsule())
    }

    /// 선택된 모드의 활성 스테이지 progress strip + summary + 스테이지별 한 줄.
    @ViewBuilder
    private func progressForMode(mode: SwitchRobotLinkSession.LaunchMode,
                                 outcome out: SwitchRobotLinkSession.DemoSuiteOutcome) -> some View {
        let stages = mode.stages
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.micro2) {
                Image(systemName: mode.icon)
                    .font(.system(size: DFFontSize.s10))
                    .foregroundStyle(DFColor.accent)
                Text("진행: \(mode.title)")
                    .font(.system(size: DFFontSize.s10, weight: .semibold))
                Spacer(minLength: 0)
            }

            // 모드별 progress strip — 활성 스테이지만 노출.
            HStack(spacing: DFSpace.micro2) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { idx, stage in
                    let phase = out.phase(stage)
                    let chipTint: Color = {
                        switch phase {
                        case .success: return DFColor.success
                        case .failed:  return DFColor.danger
                        case .running: return DFColor.accent
                        case .idle:    return DFColor.textSecondary.opacity(0.4)
                        }
                    }()
                    HStack(spacing: 3) {
                        Image(systemName: demoStageIcon(stage))
                            .font(.system(size: DFFontSize.s9))
                        Text(stage.title)
                            .font(.system(size: DFFontSize.s9, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, DFSpace.xs)
                    .padding(.vertical, DFSpace.micro2)
                    .background(chipTint.opacity(0.14))
                    .foregroundStyle(chipTint)
                    .clipShape(Capsule())
                    if idx < stages.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: DFFontSize.s8))
                            .foregroundStyle(DFColor.textSecondary.opacity(0.5))
                    }
                }
                Spacer(minLength: 0)
            }

            if !out.summary.isEmpty {
                let allActiveGreen = stages.allSatisfy { out.phase($0) == .success }
                let anyFail = stages.contains { out.phase($0) == .failed }
                let tint: Color = allActiveGreen ? DFColor.success : (anyFail ? DFColor.danger : DFColor.warning)
                Text(out.summary)
                    .font(DFFont.caption)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 스테이지별 한 줄 메시지(이 모드가 실행한 것만).
            ForEach(stages) { stage in
                let msg = out.message(stage)
                if !msg.isEmpty {
                    HStack(alignment: .top, spacing: DFSpace.xs) {
                        stepStatusIcon(out.phase(stage), fallbackIcon: demoStageIcon(stage))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stage.title)
                                .font(.system(size: DFFontSize.s10, weight: .semibold))
                            Text(msg)
                                .font(.system(size: DFFontSize.s9))
                                .foregroundStyle(phaseColor(out.phase(stage)))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            if let fb = out.fallbackCommand {
                fallbackRow(fb)
            }
        }
    }

    /// 사용자가 "안 됐다" 고 일찍 포기/재시도하지 않도록 — 데모 기동 대기를
    /// 명확히 안내. 로봇의 *오디오 안내음 + 자세 변경* 이 진짜 "이제 조종 가능" 신호.
    private var demoStartupNotice: some View {
        HStack(alignment: .top, spacing: DFSpace.xs) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: DFFontSize.s11))
                .foregroundStyle(DFColor.info)
            VStack(alignment: .leading, spacing: 1) {
                Text("로봇 데모 기동에는 시간이 좀 걸려요")
                    .font(.system(size: DFFontSize.s10, weight: .semibold))
                    .foregroundStyle(DFColor.textPrimary)
                Text("‘시작’을 누른 뒤 로봇에서 오디오가 들리고 자세가 바뀔 때까지 기다려 주세요. 그 신호가 나야 조이콘 입력이 실제로 반영됩니다.")
                    .font(.system(size: DFFontSize.s9))
                    .foregroundStyle(DFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DFSpace.sm)
        .background(DFColor.info.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    /// **후면 버튼 대체 경로 안내** (2026-06-08) — `install-onboard.sh` 가 로봇
    /// 데모에 후면 MODE 버튼 + START 진입 경로를 추가했으므로, DarwinForge/Switch
    /// 연결 없이도 로봇 단독으로 시연 가능. UI 가 늘 보여주면 사용자가 알아 둠.
    private var backPanelHint: some View {
        HStack(alignment: .top, spacing: DFSpace.xs) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: DFFontSize.s10))
                .foregroundStyle(DFColor.textSecondary)
            Text("Mac 없이도 가능 — 로봇 후면 MODE 6회 + START 로 WalkLab 모드 진입(LED 0x07). MODE 다시 누르면 정지.")
                .font(.system(size: DFFontSize.s9))
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DFSpace.xs)
        .padding(.vertical, DFSpace.micro2 + 1)
    }

    private var demoSafetyToggle: some View {
        Toggle(isOn: $session.safetyConfirmed) {
            Label("로봇을 잡고 있고 주변이 안전함 — 모터/보행 초기화가 일어납니다",
                  systemImage: "hand.raised.fill")
                .font(DFFont.caption)
                .foregroundStyle(session.safetyConfirmed ? DFColor.textPrimary : DFColor.danger)
        }
        .toggleStyle(.checkbox)
    }

    private func demoStageIcon(_ s: SwitchRobotLinkSession.DemoSuiteStage) -> String {
        switch s {
        case .preflight:      return "checklist"
        case .startRobotDemo: return "figure.walk"
        case .enableAgent:    return "gearshape.2.fill"
        case .cameraTunnel:   return "video.fill"
        case .verify:         return "checkmark.seal.fill"
        }
    }

    // MARK: - 고급/단계별 디버그 disclosure

    /// 기존 9단계 wizard + autoRunBar + finalSummary 를 collapsible 로 묶음.
    /// 일반 사용자는 모드 타일만 보고, 전문가가 펼치면 단계별로 디버그 가능.
    @State private var advancedExpanded: Bool = false

    private var advancedWizardDisclosure: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { advancedExpanded.toggle() }
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: advancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: DFFontSize.s10))
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: DFFontSize.s11))
                        .foregroundStyle(DFColor.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("고급 / 단계별 디버그")
                            .font(.system(size: DFFontSize.s12, weight: .semibold))
                        Text("문제 해결용 — 9단계를 직접 하나씩 실행하고 출력을 확인합니다")
                            .font(.system(size: DFFontSize.s9))
                            .foregroundStyle(DFColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if advancedExpanded {
                autoRunBar
                ForEach(SwitchRobotLinkSession.StepID.allCases) { step in
                    stepCard(step)
                }
                finalSummary
            }
        }
        .padding(DFSpace.md)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(RoundedRectangle(cornerRadius: DFRadius.md)
            .stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: 0.5))
    }

    // MARK: - 안정화 설정

    private var stabilizeCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("안정 우선 설정 적용").font(DFFont.sectionSmall)
                    Text("초기 실기 테스트용 — SSH 전송 빈도를 낮춰 연결 끊김을 줄이고, 보행 속도 변화를 완만하게.")
                        .font(.system(size: DFFontSize.s9)).foregroundStyle(DFColor.textSecondary)
                }
                Spacer()
                Button {
                    Task { await session.runStabilize() }
                } label: {
                    if session.isStabilizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("적용").font(DFFont.caption)
                    }
                }
                .buttonStyle(.bordered)
                .tint(DFColor.accent)
                .disabled(session.isStabilizing || session.runningStep != nil)
            }
            let o = session.stabilizeOutcome
            if !o.message.isEmpty {
                Text(o.message).font(DFFont.caption).foregroundStyle(phaseColor(o.phase))
            }
            if let fb = o.fallbackCommand { fallbackRow(fb) }
        }
        .padding(DFSpace.md)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(RoundedRectangle(cornerRadius: DFRadius.md)
            .stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: 0.5))
    }

    // MARK: - Reusable bits

    private func stepStatusIcon(_ phase: SwitchRobotLinkSession.Phase, fallbackIcon: String) -> some View {
        let (name, tint): (String, Color) = {
            switch phase {
            case .idle:    return (fallbackIcon, DFColor.textSecondary)
            case .running: return ("arrow.triangle.2.circlepath", DFColor.accent)
            case .success: return ("checkmark.circle.fill", DFColor.success)
            case .failed:  return ("xmark.octagon.fill", DFColor.danger)
            }
        }()
        return Image(systemName: name)
            .font(.system(size: DFFontSize.s14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 22)
    }

    private func phaseColor(_ phase: SwitchRobotLinkSession.Phase) -> Color {
        switch phase {
        case .success: return DFColor.success
        case .failed:  return DFColor.danger
        case .running: return DFColor.accent
        case .idle:    return DFColor.textSecondary
        }
    }

    private func borderColor(_ phase: SwitchRobotLinkSession.Phase) -> Color {
        switch phase {
        case .success: return DFColor.success.opacity(DFOpacity.o25)
        case .failed:  return DFColor.danger.opacity(DFOpacity.o25)
        default:       return DFColor.textSecondary.opacity(DFOpacity.o25)
        }
    }

    private func fallbackRow(_ command: String) -> some View {
        HStack(spacing: DFSpace.xs) {
            Text(command)
                .font(.system(size: DFFontSize.s9, design: .monospaced))
                .foregroundStyle(DFColor.textPrimary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                copy(command)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: DFFontSize.s10))
            }
            .buttonStyle(.borderless)
            .help("터미널 명령 복사")
        }
        .padding(DFSpace.xs)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }

    @ViewBuilder
    private func disclosureOutput(step: SwitchRobotLinkSession.StepID, text: String) -> some View {
        let isOpen = expanded.contains(step.rawValue)
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
            Button {
                if isOpen { expanded.remove(step.rawValue) } else { expanded.insert(step.rawValue) }
            } label: {
                Label(isOpen ? "출력 숨기기" : "출력 보기",
                      systemImage: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: DFFontSize.s9))
                    .foregroundStyle(DFColor.textSecondary)
            }
            .buttonStyle(.borderless)
            if isOpen {
                ScrollView {
                    Text(text)
                        .font(.system(size: DFFontSize.s9, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(DFSpace.xs)
                .background(DFColor.canvas)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = copyToast {
            Text(toast)
                .font(DFFont.caption)
                .padding(.horizontal, DFSpace.md).padding(.vertical, DFSpace.xs)
                .background(DFColor.textPrimary.opacity(0.85))
                .foregroundStyle(DFColor.card)
                .clipShape(Capsule())
                .padding(.bottom, DFSpace.lg)
                .transition(.opacity)
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        withAnimation { copyToast = "복사됨" }
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withAnimation { copyToast = nil }
        }
    }
}
