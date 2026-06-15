import AppKit
import SwiftUI

/// **ROG Ally FPV 조종 — 가이드·런처 화면** (전문가 탭).
///
/// ROG Ally(Windows 11 핸드헬드)를 들고 로봇 1인칭(FPV) 영상을 보며 조종하는 데모를
/// *시작하도록 가이드·점검·트리거* 한다. 화면 앱(darwin-fpv)은 ROG Ally 에서 돌고(W2),
/// 이 Mac 화면은 연결을 안내하고 Mac→Ally SSH 점검을 트리거하며 단일 세션 가드를 건다.
/// 기존 Nintendo Switch 조종석 연결은 하단 "대체 컨트롤러" 시트로 흡수했다.
///
/// 로직/명령은 `AllyFpvLauncherSession` + `AllyFpvCommands` 가 소유 — 이 뷰는 표시/입력만.
public struct AllyFpvLauncherView: View {

    @StateObject private var session: AllyFpvLauncherSession
    @ObservedObject private var robotShell: RemoteShell
    @ObservedObject private var store: ConnectionStore
    private let macRobotHost: String

    @State private var copyToast: String?
    @State private var showSwitchSheet = false
    @State private var expandedDetail: Set<String> = []

    public init(remoteShell: RemoteShell, macRobotHost: String, store: ConnectionStore) {
        _robotShell = ObservedObject(wrappedValue: remoteShell)
        _store = ObservedObject(wrappedValue: store)
        self.macRobotHost = macRobotHost
        _session = StateObject(wrappedValue: AllyFpvLauncherSession(store: store))
    }

    /// 로봇이 Mac 에 연결돼 있는가 — store 를 직접 보아 실시간 판정(단일 세션 가드).
    private var robotConnected: Bool {
        if case .connected = store.status { return true }
        return false
    }

    public var body: some View {
        DFPageScaffold(
            "ROG Ally FPV 조종",
            subtitle: "ROG Ally 를 들고 로봇 1인칭 영상을 보며 조종 — 연결부터 출격까지 안내",
            icon: "video.fill",
            tint: DFColor.accent,
            trailing: { headerChip }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: DFSpace.md) {
                    overviewCard
                    singleSessionGuardCard
                    networkTopologyCard
                    prepStepsCard
                    allyCheckCard
                    launchCard
                    advancedAlternateControllerDisclosure
                }
                .padding(DFSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .sheet(isPresented: $showSwitchSheet) {
            SwitchRobotLinkView(remoteShell: robotShell, macRobotHost: macRobotHost)
                .frame(minWidth: 760, minHeight: 620)
        }
        .onAppear { session.refreshRobotConnection() }
    }

    // MARK: - Header chip

    private var headerChip: some View {
        let reach = session.outcome(.reachable).phase
        let (text, style): (String, DFChip.Style) = {
            switch reach {
            case .success: return ("ROG Ally 연결됨", .success)
            case .failed:  return ("ROG Ally 미연결", .warning)
            default:       return ("ROG Ally", .neutral)
            }
        }()
        return DFChip(text, icon: "gamecontroller.fill", style: style)
    }

    // MARK: - 1. 개요

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            sectionHeader("이 데모는?", icon: "scope", tint: DFColor.accent)
            Text("ROG Ally 핸드헬드 화면에 로봇 카메라 영상을 띄우고, 패드로 로봇을 1인칭 시점으로 조종합니다. "
                 + "DARwIn FPV(darwin-fpv) 앱이 ROG Ally 에서 영상·조종을 모두 담당하고, 이 화면은 그 데모를 "
                 + "시작하도록 연결·점검을 안내합니다.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DFSpace.md) {
                prepBullet(icon: "gamecontroller.fill", text: "ROG Ally + 패드")
                prepBullet(icon: "cable.connector", text: "USB-C LAN")
                prepBullet(icon: "figure.walk", text: "DARwIn-OP2")
            }
        }
        .modifier(CardBox(tint: DFColor.accent, soft: true))
    }

    private func prepBullet(icon: String, text: String) -> some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: icon).font(.system(size: DFFontSize.s11)).foregroundStyle(DFColor.accent)
            Text(text).font(.system(size: DFFontSize.s10, weight: .semibold)).foregroundStyle(DFColor.textPrimary)
        }
    }

    // MARK: - 2. 단일 세션 안전 가드

    private var singleSessionGuardCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            sectionHeader("로봇은 한 번에 한 기기", icon: "person.badge.shield.checkmark", tint: DFColor.warning)
            Text("ROG Ally 가 로봇을 조종하는 동안 Mac DarwinForge 는 로봇 연결을 끊어야 합니다. "
                 + "Mac 의 폴러가 연결을 유지하면 ROG Ally 의 조종 채널이 즉시 끊깁니다(단일 세션 규칙).")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if robotConnected {
                calloutRow(icon: "bolt.fill", tint: DFColor.warning,
                           text: "현재 Mac 이 로봇에 연결돼 있어요. ROG Ally 에 넘기려면 먼저 연결을 끊으세요.")
                DFButton(.danger, size: .small, action: {
                    session.disconnectRobotForAlly()
                }) { Label("Mac 로봇 연결 끊기", systemImage: "bolt.slash.fill") }
            } else {
                calloutRow(icon: "checkmark.circle.fill", tint: DFColor.success,
                           text: session.didDisconnectRobot
                                 ? "Mac 로봇 연결을 끊었어요 — ROG Ally 가 단독으로 조종할 수 있습니다."
                                 : "Mac 로봇 연결 없음 — ROG Ally 가 단독으로 조종할 수 있습니다.")
            }
        }
        .modifier(CardBox(tint: DFColor.warning, soft: false))
    }

    // MARK: - 3. 네트워크 토폴로지

    private var networkTopologyCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            sectionHeader("연결 경로", icon: "network", tint: DFColor.info)
            Picker("", selection: $session.prefer) {
                ForEach(AllyFpvCommands.NetPath.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            calloutRow(icon: "bolt.horizontal.fill", tint: DFColor.info,
                       text: "유선 USB-C LAN(\(AllyFpvCommands.robotWiredHost))이 무선(\(AllyFpvCommands.robotWirelessHost))보다 "
                           + "~166× 빠릅니다 — 데모는 유선을 권장합니다.")
        }
        .modifier(CardBox(tint: DFColor.info, soft: true))
    }

    // MARK: - 4. 준비 단계 가이드

    private var prepStepsCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            sectionHeader("준비 단계 (ROG Ally 에서)", icon: "list.number", tint: DFColor.forge)
            prepStep(1, "ROG Ally 부트스트랩 — 1회",
                     "관리자 PowerShell 에서 도구 설치 + OpenSSH 서버 + 리포 클론.",
                     cmd: "irm https://raw.githubusercontent.com/bbikiming/Darwin/main/app/ally/scripts/ally-bootstrap.ps1 -OutFile bootstrap.ps1; Set-ExecutionPolicy -Scope Process Bypass; .\\bootstrap.ps1")
            prepStep(2, "로봇 SSH 키 등록 (RSA only)",
                     "ROG Ally 에서 RSA 키를 만들고 로봇 authorized_keys 에 등록합니다(로봇 OpenSSH 5.9 = RSA).",
                     cmd: "ssh-keygen -t rsa -b 2048 -f $HOME\\.ssh\\id_rsa_darwin -N '\"\"'; type $HOME\\.ssh\\id_rsa_darwin.pub | ssh robotis@\(session.prefer.robotHost) \"cat >> ~/.ssh/authorized_keys\"")
            prepStep(3, "ROG Ally ↔ 로봇 물리 연결",
                     "USB-C LAN 어댑터로 로봇과 직결(\(AllyFpvCommands.robotWiredHost), 권장) 하거나 같은 공유기 무선.",
                     cmd: nil)
            prepStep(4, "FPV 앱 실행",
                     "아래 ‘FPV 데모 시작’ 으로 ROG Ally 에서 darwin-fpv 를 띄웁니다(준비 시).",
                     cmd: nil)
        }
        .modifier(CardBox(tint: DFColor.forge, soft: true))
    }

    private func prepStep(_ n: Int, _ title: String, _ detail: String, cmd: String?) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            HStack(alignment: .top, spacing: DFSpace.xs) {
                Text("\(n)")
                    .font(.system(size: DFFontSize.s11, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(DFColor.forge.opacity(0.18))
                    .foregroundStyle(DFColor.forge)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: DFFontSize.s12, weight: .semibold))
                        .foregroundStyle(DFColor.textPrimary)
                    Text(detail).font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let cmd { copyRow(cmd) }
        }
    }

    private func copyRow(_ command: String) -> some View {
        HStack(alignment: .top, spacing: DFSpace.xs) {
            Text(command)
                .font(.system(size: DFFontSize.s9, design: .monospaced))
                .foregroundStyle(DFColor.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { copy(command) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: DFFontSize.s10))
            }
            .buttonStyle(.borderless)
            .help("복사")
        }
        .padding(DFSpace.xs)
        .background(DFColor.canvas)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }

    // MARK: - 5. Ally 점검 (Mac → ROG Ally SSH)

    private var allyCheckCard: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            sectionHeader("ROG Ally 점검 (Mac 에서)", icon: "checkmark.seal", tint: DFColor.accent)
            HStack(spacing: DFSpace.sm) {
                labeledField("ROG Ally IP", text: $session.allyHost, placeholder: "192.168.0.x")
                    .frame(maxWidth: 180)
                labeledField("Ally 계정", text: $session.allyUser, placeholder: "Windows 계정명")
                    .frame(maxWidth: 160)
            }
            labeledField("Ally→로봇 키 경로 (ally-cli)", text: $session.robotIdentityOnAlly,
                         placeholder: AllyFpvCommands.defaultRobotIdentityOnAlly)
            if !session.inputsReady {
                calloutRow(icon: "info.circle.fill", tint: DFColor.info,
                           text: "ROG Ally 의 IP 와 Windows 계정을 입력하면 점검을 실행할 수 있어요. "
                               + "(Mac ~/.ssh/config 의 Host ally 도 사용 가능)")
            }
            ForEach([AllyFpvLauncherSession.CheckId.reachable, .w0Smoke, .cliProbe, .fpvReady]) { id in
                checkRow(id)
            }
        }
        .modifier(CardBox(tint: DFColor.accent, soft: false))
    }

    private func checkRow(_ id: AllyFpvLauncherSession.CheckId) -> some View {
        let out = session.outcome(id)
        let running = session.runningCheck == id
        return VStack(alignment: .leading, spacing: DFSpace.xs2) {
            HStack(spacing: DFSpace.xs) {
                Image(systemName: phaseIcon(out.phase))
                    .foregroundStyle(phaseTint(out.phase))
                    .font(.system(size: DFFontSize.s12))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(id.title).font(.system(size: DFFontSize.s11, weight: .semibold))
                        .foregroundStyle(DFColor.textPrimary)
                    if !out.message.isEmpty {
                        Text(out.message).font(.system(size: DFFontSize.s9))
                            .foregroundStyle(phaseTint(out.phase))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if running {
                    DFProgressDots(tint: DFColor.accent)
                } else {
                    DFButton(.secondary, size: .small, action: {
                        Task { await session.runCheck(id) }
                    }) { Text("실행") }
                    .disabled(session.runningCheck != nil)
                }
            }
            if !out.detail.isEmpty { detailDisclosure(key: id.rawValue, text: out.detail) }
        }
        .padding(DFSpace.xs)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    // MARK: - 6. 데모 실행

    private var launchCard: some View {
        let out = session.launchOutcome
        let canLaunch = session.fpvReady && session.inputsReady && !robotConnected
        return VStack(alignment: .leading, spacing: DFSpace.sm) {
            sectionHeader("FPV 데모 시작 (ROG Ally)", icon: "play.tv.fill", tint: DFColor.danger)
            if robotConnected {
                calloutRow(icon: "exclamationmark.triangle.fill", tint: DFColor.warning,
                           text: "먼저 위에서 ‘Mac 로봇 연결 끊기’ 로 ROG Ally 에 소유권을 넘기세요.")
            }
            if session.fpvReady {
                DFButton(.danger, size: .medium, action: {
                    Task { await session.launchFpv() }
                }) { Label("FPV 데모 시작", systemImage: "play.fill") }
                .disabled(!canLaunch)
            } else {
                calloutRow(icon: "hammer.fill", tint: DFColor.info,
                           text: "darwin-fpv(W2) 앱이 아직 ROG Ally 에 빌드되지 않았어요. 위 ‘FPV 앱 준비 상태’ 점검으로 "
                               + "확인하고, 준비 전에는 아래 연결 게이트로 조종 채널을 실연할 수 있습니다.")
                DFButton(.secondary, size: .small, action: {
                    Task { await session.runCheck(.cliConnect) }
                }) { Label("연결 게이트 실연 (ally-cli connect)", systemImage: "bolt.badge.checkmark") }
                .disabled(robotConnected || !session.inputsReady || session.runningCheck != nil)
                let cc = session.outcome(.cliConnect)
                if cc.phase != .idle { checkResultLine(cc) }
            }
            if out.phase != .idle { checkResultLine(out) }
        }
        .modifier(CardBox(tint: DFColor.danger, soft: false))
    }

    private func checkResultLine(_ out: AllyFpvLauncherSession.CheckOutcome) -> some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: phaseIcon(out.phase)).foregroundStyle(phaseTint(out.phase))
                .font(.system(size: DFFontSize.s11))
            Text(out.message).font(.system(size: DFFontSize.s10)).foregroundStyle(phaseTint(out.phase))
            if out.phase == .running { DFProgressDots(tint: DFColor.accent) }
        }
    }

    // MARK: - 7. 대체 컨트롤러 (스위치 흡수)

    private var advancedAlternateControllerDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                Text("Nintendo Switch(Switchroot Ubuntu)를 컨트롤러로 쓰는 기존 연결 방식입니다. "
                     + "ROG Ally 와 달리 Mac 이 로봇 SSH 채널을 중계해 Switch 공개키를 등록하므로, "
                     + "이때는 Mac 로봇 연결이 필요합니다.")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                DFButton(.secondary, size: .small, action: {
                    showSwitchSheet = true
                }) { Label("스위치 연결 세팅 열기", systemImage: "gamecontroller") }
            }
            .padding(.top, DFSpace.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("대체 컨트롤러 — Nintendo Switch 조종석", systemImage: "rectangle.2.swap")
                .font(DFFont.sectionSmall)
                .foregroundStyle(DFColor.textPrimary)
        }
        .modifier(CardBox(tint: DFColor.textSecondary, soft: true))
    }

    // MARK: - 공통 헬퍼

    private func sectionHeader(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: icon).font(.system(size: DFFontSize.s14, weight: .semibold)).foregroundStyle(tint)
            Text(title).font(DFFont.sectionSmall).foregroundStyle(DFColor.textPrimary)
            Spacer(minLength: 0)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
            Text(label).font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: DFFontSize.s11, design: .monospaced))
        }
    }

    private func calloutRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: DFSpace.xs) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: DFFontSize.s11))
            Text(text).font(DFFont.caption).foregroundStyle(DFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DFSpace.sm)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    @ViewBuilder
    private func detailDisclosure(key: String, text: String) -> some View {
        let isOpen = expandedDetail.contains(key)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if isOpen { expandedDetail.remove(key) } else { expandedDetail.insert(key) }
            } label: {
                Label(isOpen ? "출력 숨기기" : "출력 보기",
                      systemImage: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: DFFontSize.s9)).foregroundStyle(DFColor.textSecondary)
            }
            .buttonStyle(.borderless)
            if isOpen {
                ScrollView {
                    Text(text).font(.system(size: DFFontSize.s9, design: .monospaced))
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

    private func phaseIcon(_ p: AllyFpvLauncherSession.Phase) -> String {
        switch p {
        case .idle:    return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failed:  return "xmark.octagon.fill"
        }
    }

    private func phaseTint(_ p: AllyFpvLauncherSession.Phase) -> Color {
        switch p {
        case .idle:    return DFColor.textSecondary
        case .running: return DFColor.accent
        case .success: return DFColor.success
        case .failed:  return DFColor.danger
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

/// 카드 박스 스타일 — 배경/보더 통일(소프트 그라데이션 옵션).
private struct CardBox: ViewModifier {
    let tint: Color
    let soft: Bool
    func body(content: Content) -> some View {
        content
            .padding(DFSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                soft
                    ? AnyView(LinearGradient(colors: [tint.opacity(0.08), DFColor.card],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyView(DFColor.card)
            )
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
            .overlay(RoundedRectangle(cornerRadius: DFRadius.md)
                .stroke(tint.opacity(DFOpacity.o25), lineWidth: 0.5))
    }
}
