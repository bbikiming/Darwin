import ForgeCore
import SwiftUI

// MARK: - Models

/// 연결 경로 — 사용자가 처음 선택.
public enum WizardPath: String, CaseIterable, Identifiable {
    case usb, network, bonjour
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .usb:     return "USB 케이블"
        case .network: return "네트워크 (수동)"
        case .bonjour: return "자동 검색"
        }
    }

    public var subtitle: String {
        switch self {
        case .usb:     return "Mac과 로봇을 USB로 직접 연결"
        case .network: return "IP 주소를 알고 있는 경우"
        case .bonjour: return "같은 네트워크의 로봇을 자동으로 찾기"
        }
    }

    public var icon: String {
        switch self {
        case .usb:     return "cable.connector"
        case .network: return "network"
        case .bonjour: return "antenna.radiowaves.left.and.right"
        }
    }

    public var tint: Color {
        switch self {
        case .usb:     return DFColor.accent
        case .network: return DFColor.success
        case .bonjour: return DFColor.forge
        }
    }

    public var recommendation: String {
        switch self {
        case .usb:     return "가장 안정적, 첫 연결 권장"
        case .network: return "와이파이·이더넷 모두 가능"
        case .bonjour: return "IP 입력 없이 한 번 클릭"
        }
    }
}

public enum StepStatus: Equatable {
    case pending
    case inProgress
    case success
    case failed(String)

    public var isTerminal: Bool {
        switch self { case .success, .failed: return true; default: return false }
    }
}

public struct WizardStep: Identifiable, Equatable {
    public let id: String
    public let number: Int
    public let title: String
    public let detail: String
    public let icon: String
    public var status: StepStatus

    public init(id: String, number: Int, title: String, detail: String, icon: String,
                status: StepStatus = .pending) {
        self.id = id
        self.number = number
        self.title = title
        self.detail = detail
        self.icon = icon
        self.status = status
    }
}

// MARK: - Wizard View

public struct ConnectionWizardView: View {
    @EnvironmentObject var store: ConnectionStore
    @StateObject private var bonjour = BonjourBrowser()
    @StateObject private var oneClick = OneClickConnect()
    @Binding public var isPresented: Bool

    @State private var selectedPath: WizardPath?
    @State private var steps: [WizardStep] = []
    @State private var manualHost: String = ""
    @State private var manualPort: String = "5530"
    /// false = OneClick 화면 (기본), true = 기존 수동 경로 (USB/Network/Bonjour 카드).
    @State private var isAdvanced: Bool = false
    /// 셋업 블록 복사 토스트 트리거.
    @State private var copyConfirm: String? = nil

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        GeometryReader { geo in
            let w = min(660, geo.size.width * 0.92)
            let h = min(660, geo.size.height * 0.92)
            VStack(spacing: DFSpace.none) {
                header
                Divider()
                content
                    .frame(minHeight: min(420, max(200, h - 220)))
                Divider()
                footer
            }
            .frame(width: w, height: h)
            .background(DFColor.canvas)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.md)
                    .stroke(DFColor.textSecondary.opacity(DFOpacity.o18), lineWidth: DFSize.borderHairline)
            )
            .shadow(radius: 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                oneClick.bind(store: store, bonjour: bonjour)
                if !isAdvanced && selectedPath == nil {
                    // 마지막 성공 endpoint 가 있으면 마법사 진입 즉시 자동 연결 시도.
                    if store.lastSuccessfulEndpoint != nil, store.bus == nil {
                        oneClick.runOneClick()
                    } else {
                        oneClick.runDiagnosticsOnly()
                    }
                }
            }
            .onChange(of: store.status) { _, new in
                if case .connected = new {
                    markCurrentStep(.success)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        isPresented = false
                    }
                } else if case .error(let m) = new {
                    markCurrentStep(.failed(m))
                }
            }
            .onDisappear { bonjour.stop(); oneClick.cancel() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: DFFontSize.s20, weight: .semibold))
                .foregroundStyle(DFColor.forge)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("연결 마법사")
                    .font(DFFont.title)
                Text(headerSubtitle)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: DFFontSize.s18))
                    .foregroundStyle(DFColor.textSecondary)
            }
            .buttonStyle(.plain)
            .help("닫기 (ESC)")
            .keyboardShortcut(.cancelAction)
        }
        .padding(DFSpace.md)
    }

    private var headerSubtitle: String {
        if let p = selectedPath { return "\(p.title) 경로 — 안내에 따라 진행해 주세요" }
        if isAdvanced { return "수동 경로 — USB / 네트워크 / Bonjour 중 선택" }
        return "Mac이 자동으로 검색·연결합니다 — 한 번 클릭만 하세요"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let path = selectedPath {
            stepListView(path: path)
        } else if isAdvanced {
            pathPicker
        } else {
            oneClickHero
        }
    }

    // MARK: - One-click hero

    /// 마법사 진입 직후 보이는 메인 화면 — 큰 자동 연결 버튼 + 라이브 진단 + (실패 시) 통합 셋업 블록.
    private var oneClickHero: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                heroBadge
                heroPrimaryAction
                liveDiagnosticsSection
                manualProbeSection
                if case .allFailed = oneClick.phase {
                    unifiedSetupSection
                }
                advancedToggleRow
            }
            .padding(DFSpace.md)
        }
        .glassScroll(accent: DFColor.accent)
    }

    /// 사용자가 직접 IP/호스트 입력해서 ping + 포트 검사 — 자동 진단이 못 잡는 IP를 점검할 때.
    private var manualProbeSection: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(DFColor.accent)
                Text("직접 점검")
                    .font(DFFont.bodyEmph)
                Text("(IP나 호스트명을 직접 입력해 ping + 포트 5530 검사)")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }

            HStack(spacing: DFSpace.xs2) {
                TextField("",
                          text: $manualHost,
                          prompt: Text("예: 192.168.123.1, op2.local, 192.168.0.33"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runManualProbe() }

                Button {
                    runManualProbe()
                } label: {
                    HStack(spacing: DFSpace.xs) {
                        if oneClick.isManualProbing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "stethoscope")
                        }
                        Text("Ping + 포트 검사").font(DFFont.caption)
                    }
                    .padding(.horizontal, DFSpace.sm2)
                    .padding(.vertical, DFSpace.xs2)
                    .background(DFColor.accent.opacity(DFOpacity.o18))
                    .foregroundStyle(DFColor.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || oneClick.isManualProbing)
            }

            // 결과
            if let r = oneClick.manualResult {
                manualResultCard(r)
            }

            // 빠른 입력 프리셋.
            HStack(spacing: DFSpace.xs2) {
                Text("빠른 입력:").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                ForEach(quickPresets(), id: \.self) { ip in
                    Button {
                        manualHost = ip
                        runManualProbe()
                    } label: {
                        Text(ip)
                            .font(.system(size: DFFontSize.s10, design: .monospaced))
                            .padding(.horizontal, DFSpace.xs2)
                            .padding(.vertical, DFSpace.micro2)
                            .background(DFColor.card)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle), lineWidth: DFSize.borderHairline)
        )
    }

    private func manualResultCard(_ r: OneClickConnect.ManualProbeResult) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            HStack(spacing: DFSpace.xs2) {
                Text(r.host)
                    .font(.system(size: DFFontSize.s12, weight: .semibold, design: .monospaced))
                pingChip(r.ping)
                portChip(r.port)
                Spacer()
                if r.canConnect {
                    Button {
                        store.connect(endpoint: .network(host: r.host, port: 5530))
                    } label: {
                        Text("이 호스트로 연결")
                            .font(DFFont.caption)
                            .padding(.horizontal, DFSpace.sm)
                            .padding(.vertical, DFSpace.xs)
                            .background(DFColor.success.opacity(DFOpacity.o18))
                            .foregroundStyle(DFColor.success)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(r.summary)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DFSpace.sm)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
    }

    private func runManualProbe() {
        let h = manualHost.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        oneClick.manualProbe(host: h)
    }

    /// Mac이 보이는 인접 .1 후보 + OP2 표준을 빠른 버튼으로.
    private func quickPresets() -> [String] {
        var set: [String] = ["192.168.123.1"]
        for h in NetworkProbe.likelyRobotCandidates() where !set.contains(h) {
            set.append(h)
        }
        return Array(set.prefix(4))
    }

    private var heroBadge: some View {
        HStack(spacing: DFSpace.sm) {
            ZStack {
                Circle().fill(DFColor.forge.opacity(DFOpacity.subtle)).frame(width: 56, height: 56)
                Image(systemName: "bolt.fill")
                    .font(.system(size: DFFontSize.s26, weight: .bold))
                    .foregroundStyle(DFColor.forge)
            }
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                Text("자동 연결")
                    .font(DFFont.title)
                Text("Mac이 USB·이더넷·LAN·mDNS를 동시에 검색해 가장 빠른 경로로 자동 연결합니다.")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = store.lastSuccessfulEndpoint {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: "memorychip.fill")
                            .font(.system(size: DFFontSize.s9))
                            .foregroundStyle(DFColor.success)
                        Text("기억된 마지막: \(last.detail)")
                            .font(.system(size: DFFontSize.s10, design: .monospaced))
                            .foregroundStyle(DFColor.success)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var heroPrimaryAction: some View {
        let isConnecting: Bool = {
            if case .connecting = oneClick.phase { return true }
            return false
        }()
        let isScanning: Bool = oneClick.phase == .scanning
        Button {
            oneClick.runOneClick()
        } label: {
            HStack(spacing: DFSpace.sm) {
                if isConnecting || isScanning {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: DFFontSize.s14, weight: .bold))
                }
                Text(heroButtonTitle)
                    .font(.system(size: DFFontSize.s16, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.md)
                    .fill(LinearGradient(
                        colors: [DFColor.forge, DFColor.forge.opacity(0.78)],
                        startPoint: .leading, endPoint: .trailing))
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(isConnecting || isScanning)
    }

    private var heroButtonTitle: String {
        switch oneClick.phase {
        case .idle, .allFailed, .failed: return "🚀  자동 연결 시작"
        case .scanning:                  return "주변 검색 중…"
        case .connecting(let label):     return "연결 중 — \(label)"
        case .connected:                 return "✅ 연결됨"
        }
    }

    private var liveDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack {
                Text("📡 진단")
                    .font(DFFont.bodyEmph)
                Spacer()
                if let at = oneClick.lastDiagnosticAt {
                    Text("최근 \(Self.relativeTime(at))")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
                Button {
                    oneClick.runDiagnosticsOnly()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: DFFontSize.s11))
                }
                .buttonStyle(.plain)
                .help("다시 진단")
            }
            ForEach(oneClick.candidates) { c in
                candidateRow(c)
            }
        }
    }

    private func candidateRow(_ c: OneClickConnect.CandidateState) -> some View {
        HStack(alignment: .top, spacing: DFSpace.sm2) {
            stageIcon(c.stage)
                .frame(width: DFSize.iconMd, height: DFSize.iconMd)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                HStack(spacing: DFSpace.xs2) {
                    Text(c.label).font(DFFont.bodyEmph)
                    kindChip(c.kind)
                    if c.kind != .usb {
                        pingPortChips(c)
                    }
                }
                Text(stageDescription(c))
                    .font(DFFont.caption)
                    .foregroundStyle(stageColor(c.stage))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(spacing: DFSpace.xs) {
                if case .readyToConnect = c.stage, let ep = c.endpoint {
                    Button {
                        store.connect(endpoint: ep)
                    } label: {
                        Text("이걸로 연결")
                            .font(DFFont.caption)
                            .padding(.horizontal, DFSpace.sm)
                            .padding(.vertical, DFSpace.xs)
                            .background(DFColor.success.opacity(0.16))
                            .foregroundStyle(DFColor.success)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if let host = c.host, c.kind != .usb {
                    Button {
                        manualHost = host
                        oneClick.manualProbe(host: host)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "stethoscope")
                                .font(.system(size: DFFontSize.s9))
                            Text("재진단").font(.system(size: DFFontSize.s10))
                        }
                        .padding(.horizontal, DFSpace.xs2)
                        .padding(.vertical, DFSpace.micro2 + 1)
                        .background(DFColor.card)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(DFColor.textSecondary.opacity(DFOpacity.o20), lineWidth: DFSize.borderHairline))
                    }
                    .buttonStyle(.plain)
                    .help("이 호스트만 다시 ping + 포트 검사")
                }
            }
        }
        .padding(DFSpace.sm)
        .background(stageBackground(c.stage))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(stageBorder(c.stage), lineWidth: DFSize.borderHairline)
        )
    }

    /// Ping + Port 5530 결과를 짧은 칩 두 개로 표시. 사용자가 한눈에 어디 막혔는지 인지.
    private func pingPortChips(_ c: OneClickConnect.CandidateState) -> some View {
        HStack(spacing: DFSpace.xs) {
            pingChip(c.ping)
            portChip(c.port)
        }
    }

    private func pingChip(_ ping: OneClickConnect.CandidateState.PingChip) -> some View {
        let (text, tint, sym): (String, Color, String) = {
            switch ping {
            case .unknown:        return ("ping ?",        DFColor.textSecondary, "questionmark")
            case .probing:        return ("ping…",         DFColor.accent,        "ellipsis")
            case .ok(let r):
                let s = r < 0 ? "ping ✓" : "ping \(rttFmt(r))ms"
                return (s, DFColor.success, "checkmark")
            case .unreachable:    return ("ping ✗ (unreach)", DFColor.danger, "xmark")
            case .timedOut:       return ("ping timeout",  DFColor.danger,        "xmark")
            case .notApplicable:  return ("",              DFColor.textSecondary, "minus")
            }
        }()
        if case .notApplicable = ping {
            return AnyView(EmptyView())
        }
        return AnyView(chipText(text, tint: tint, sym: sym))
    }

    private func portChip(_ port: OneClickConnect.CandidateState.PortChip) -> some View {
        let (text, tint, sym): (String, Color, String) = {
            switch port {
            case .unknown:        return (":5530 ?",       DFColor.textSecondary, "questionmark")
            case .probing:        return (":5530…",        DFColor.accent,        "ellipsis")
            case .open(let r):    return (":5530 ✓ \(r)ms", DFColor.success,      "checkmark")
            case .refused:        return (":5530 closed",  DFColor.danger,        "xmark")
            case .unreachable:    return (":5530 unreach", DFColor.danger,        "xmark")
            case .timedOut:       return (":5530 timeout", DFColor.danger,        "xmark")
            case .notApplicable:  return ("",              DFColor.textSecondary, "minus")
            }
        }()
        if case .notApplicable = port {
            return AnyView(EmptyView())
        }
        return AnyView(chipText(text, tint: tint, sym: sym))
    }

    private func chipText(_ s: String, tint: Color, sym: String) -> some View {
        Text(s)
            .font(.system(size: DFFontSize.s9, weight: .semibold, design: .monospaced))
            .padding(.horizontal, DFSpace.xs2 - 1)
            .padding(.vertical, DFSpace.micro)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    private func rttFmt(_ ms: Double) -> String {
        if ms < 0 { return "?" }
        if ms < 10 { return String(format: "%.1f", ms) }
        return String(Int(ms.rounded()))
    }

    @ViewBuilder
    private func stageIcon(_ stage: OneClickConnect.CandidateState.Stage) -> some View {
        switch stage {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(DFColor.textSecondary)
        case .probing:
            ProgressView().controlSize(.small)
        case .found, .readyToConnect:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DFColor.success)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(DFColor.danger.opacity(DFOpacity.o70))
        }
    }

    private func stageDescription(_ c: OneClickConnect.CandidateState) -> String {
        switch c.stage {
        case .pending:                return c.detail
        case .probing:                return "확인 중…"
        case .found(let d):           return d
        case .readyToConnect(let d):  return d
        case .failed(let r):          return r
        }
    }

    private func stageColor(_ stage: OneClickConnect.CandidateState.Stage) -> Color {
        switch stage {
        case .pending, .probing: return DFColor.textSecondary
        case .found, .readyToConnect: return DFColor.success
        case .failed: return DFColor.danger.opacity(DFOpacity.o85)
        }
    }
    private func stageBackground(_ stage: OneClickConnect.CandidateState.Stage) -> Color {
        switch stage {
        case .readyToConnect: return DFColor.success.opacity(DFOpacity.o06)
        case .failed: return DFColor.danger.opacity(0.04)
        default: return DFColor.card
        }
    }
    private func stageBorder(_ stage: OneClickConnect.CandidateState.Stage) -> Color {
        switch stage {
        case .readyToConnect: return DFColor.success.opacity(DFOpacity.strong)
        case .failed: return DFColor.danger.opacity(DFOpacity.o18)
        default: return DFColor.textSecondary.opacity(DFOpacity.subtle)
        }
    }

    private func kindChip(_ kind: OneClickConnect.CandidateState.Kind) -> some View {
        let (text, tint): (String, Color) = {
            switch kind {
            case .usb:            return ("USB",      DFColor.accent)
            case .ethernetDirect: return ("이더넷",    DFColor.success)
            case .lan:            return ("LAN",      DFColor.forge)
            case .mdns:           return ("mDNS",     DFColor.warning)
            }
        }()
        return Text(text)
            .font(.system(size: DFFontSize.s9, weight: .bold))
            .padding(.horizontal, DFSpace.xs2 - 1)
            .padding(.vertical, DFSpace.micro)
            .background(tint.opacity(0.16))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    /// 모든 후보가 실패한 경우 — 큰 [복사] 버튼 + 통합 셋업 블록.
    private var unifiedSetupSection: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(DFColor.warning)
                Text("로봇 PC 셋업이 필요해요")
                    .font(DFFont.bodyEmph)
            }
            Text("아래 한 블록을 로봇 터미널에 붙여넣고 Enter — Ubuntu EOL 저장소·권한·alias를 자동 처리합니다. 한 번이면 영구 셋업.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DFSpace.sm2) {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(RobotSetupCommand.unifiedSetup, forType: .string)
                    copyConfirm = "✓ 클립보드에 복사됐어요"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        copyConfirm = nil
                    }
                } label: {
                    HStack(spacing: DFSpace.xs2) {
                        Image(systemName: "doc.on.clipboard.fill")
                        Text("통합 셋업 복사").font(DFFont.bodyEmph)
                    }
                    .padding(.horizontal, DFSpace.sm3)
                    .padding(.vertical, DFSpace.sm)
                    .background(DFColor.warning)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    oneClick.runOneClick()
                } label: {
                    HStack(spacing: DFSpace.xs2) {
                        Image(systemName: "arrow.clockwise")
                        Text("다시 시도").font(DFFont.body)
                    }
                    .padding(.horizontal, DFSpace.sm3)
                    .padding(.vertical, DFSpace.sm)
                    .background(DFColor.card)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: DFSize.borderHairline))
                }
                .buttonStyle(.plain)

                if let msg = copyConfirm {
                    Text(msg)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.success)
                        .transition(.opacity)
                }
                Spacer()
            }

            DisclosureGroup("미리보기 (실행 전 확인용)") {
                Text(RobotSetupCommand.unifiedSetup)
                    .font(.system(size: DFFontSize.s10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DFSpace.sm)
                    .background(DFColor.elev2)
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
                    .textSelection(.enabled)
                    .padding(.top, DFSpace.xs)
            }
            .font(DFFont.caption)
        }
        .padding(DFSpace.sm)
        .background(DFColor.warning.opacity(DFOpacity.o06))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(DFColor.warning.opacity(DFOpacity.o30), lineWidth: DFSize.borderHairline)
        )
    }

    private var advancedToggleRow: some View {
        HStack {
            Spacer()
            Button {
                isAdvanced = true
                oneClick.cancel()
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "slider.horizontal.3")
                    Text("수동으로 연결하기 (USB · IP · Bonjour)")
                        .font(DFFont.caption)
                }
                .foregroundStyle(DFColor.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private static func relativeTime(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "방금 전" }
        if s < 60 { return "\(s)초 전" }
        return "\(s/60)분 전"
    }

    private var pathPicker: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            HStack {
                Button {
                    isAdvanced = false
                    oneClick.runDiagnosticsOnly()
                } label: {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: "chevron.left")
                        Text("자동 연결로 돌아가기").font(DFFont.caption)
                    }
                    .foregroundStyle(DFColor.accent)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, DFSpace.md)
            .padding(.top, DFSpace.md)

            Text("3가지 방법 중 하나를 선택하세요")
                .font(DFFont.bodyEmph)
                .padding(.horizontal, DFSpace.md)

            ForEach(WizardPath.allCases) { path in
                Button {
                    selectPath(path)
                } label: {
                    pathCard(path)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DFSpace.md)
            }

            Spacer()
        }
    }

    private func pathCard(_ path: WizardPath) -> some View {
        HStack(spacing: DFSpace.md) {
            ZStack {
                Circle()
                    .fill(path.tint.opacity(DFOpacity.o15))
                    .frame(width: DFSize.iconXxl, height: DFSize.iconXxl)
                Image(systemName: path.icon)
                    .font(.system(size: DFFontSize.s22, weight: .semibold))
                    .foregroundStyle(path.tint)
            }
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                HStack(spacing: DFSpace.xs2) {
                    Text(path.title)
                        .font(DFFont.bodyEmph)
                    Text(path.recommendation)
                        .font(DFFont.caption)
                        .foregroundStyle(path.tint)
                        .padding(.horizontal, DFSpace.xs2)
                        .padding(.vertical, DFSpace.micro2)
                        .background(path.tint.opacity(DFOpacity.o10))
                        .clipShape(Capsule())
                }
                Text(path.subtitle)
                    .font(DFFont.body)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(DFSpace.md)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.md)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.subtle), lineWidth: DFSize.borderHairline)
        )
    }

    // MARK: - Steps view

    @ViewBuilder
    private func stepListView(path: WizardPath) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                // 경로 헤더 + 뒤로 버튼.
                HStack(spacing: DFSpace.sm) {
                    Button {
                        selectedPath = nil
                        steps = []
                        bonjour.stop()
                    } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(DFColor.accent)
                        Text("다른 방법 선택")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.accent)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Image(systemName: path.icon)
                        .foregroundStyle(path.tint)
                    Text(path.title).font(DFFont.bodyEmph)
                }
                .padding(.horizontal, DFSpace.md)
                .padding(.top, DFSpace.md)

                // step 카드들.
                VStack(spacing: DFSpace.sm) {
                    ForEach(steps) { step in
                        stepCard(step)
                    }
                }
                .padding(.horizontal, DFSpace.md)

                // 경로별 추가 입력/표시.
                pathSpecificControls(path: path)
                    .padding(.horizontal, DFSpace.md)
                    .padding(.bottom, DFSpace.md)
            }
        }
    }

    private func stepCard(_ step: WizardStep) -> some View {
        HStack(alignment: .top, spacing: DFSpace.sm) {
            // 단계 번호 + 상태 아이콘.
            ZStack {
                Circle()
                    .fill(stepBadgeColor(step.status).opacity(DFOpacity.o18))
                    .frame(width: DFSize.iconXl, height: DFSize.iconXl)
                stepStatusIcon(step.status, fallbackText: "\(step.number)")
                    .frame(width: DFSize.iconXl, height: DFSize.iconXl)
            }

            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text(step.title)
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(DFColor.textPrimary)
                Text(step.detail)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if case .failed(let msg) = step.status {
                    Text(msg)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.danger)
                        .padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(DFSpace.sm)
        .background(stepBgColor(step.status))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(stepBorderColor(step.status), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func stepStatusIcon(_ status: StepStatus, fallbackText: String) -> some View {
        switch status {
        case .pending:
            Text(fallbackText)
                .font(DFFont.bodyEmph)
                .foregroundStyle(DFColor.textSecondary)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .tint(DFColor.accent)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: DFFontSize.s18))
                .foregroundStyle(DFColor.success)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: DFFontSize.s18))
                .foregroundStyle(DFColor.danger)
        }
    }

    private func stepBadgeColor(_ s: StepStatus) -> Color {
        switch s {
        case .pending:    return DFColor.textSecondary
        case .inProgress: return DFColor.accent
        case .success:    return DFColor.success
        case .failed:     return DFColor.danger
        }
    }
    private func stepBgColor(_ s: StepStatus) -> Color {
        switch s {
        case .inProgress: return DFColor.accent.opacity(DFOpacity.o06)
        case .success:    return DFColor.success.opacity(DFOpacity.o06)
        case .failed:     return DFColor.danger.opacity(DFOpacity.o06)
        case .pending:    return DFColor.card
        }
    }
    private func stepBorderColor(_ s: StepStatus) -> Color {
        switch s {
        case .inProgress: return DFColor.accent.opacity(DFOpacity.o45)
        case .success:    return DFColor.success.opacity(DFOpacity.o45)
        case .failed:     return DFColor.danger.opacity(DFOpacity.o45)
        case .pending:    return DFColor.textSecondary.opacity(DFOpacity.o15)
        }
    }

    // MARK: - Path-specific input

    @ViewBuilder
    private func pathSpecificControls(path: WizardPath) -> some View {
        switch path {
        case .usb:
            usbActions
        case .network:
            networkInputs
        case .bonjour:
            bonjourList
        }
    }

    private var usbActions: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            if !store.availablePorts.isEmpty {
                Text("발견된 USB 포트")
                    .font(DFFont.bodyEmph)
                ForEach(store.availablePorts, id: \.self) { p in
                    HStack {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(DFColor.success)
                        Text(URL(fileURLWithPath: p).lastPathComponent)
                            .font(DFFont.body.monospaced())
                        Spacer()
                    }
                    .padding(DFSpace.sm)
                    .background(DFColor.card)
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                }
            }
            HStack {
                Button {
                    runUSBPath()
                } label: {
                    Label("USB 자동 연결", systemImage: "cable.connector")
                }
                .buttonStyle(.glassNeon(tint: DFColor.accent))
                .keyboardShortcut(.defaultAction)

                Button {
                    store.refreshPorts()
                    autoStartUSBSteps()
                } label: {
                    Label("다시 검색", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var networkInputs: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm2) {
            // ROBOTIS-OP2 표준 환경 프리셋.
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                Text("ROBOTIS-OP2 표준 환경")
                    .font(DFFont.bodyEmph)
                Text("이더넷 직결 시 e-Manual 기본값 (DHCP automatic).")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                HStack(spacing: DFSpace.sm) {
                    Button {
                        manualHost = "192.168.123.1"
                        manualPort = "5530"
                    } label: {
                        Label("OP2 표준 (192.168.123.1)", systemImage: "wand.and.stars")
                    }
                    Button {
                        manualHost = "op2.local"
                        manualPort = "5530"
                    } label: {
                        Label("op2.local (mDNS)", systemImage: "globe")
                    }
                }
                .controlSize(.small)
            }
            .padding(DFSpace.sm)
            .background(DFColor.forge.opacity(DFOpacity.o06))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.sm)
                    .stroke(DFColor.forge.opacity(DFOpacity.o30), lineWidth: DFSize.borderHairline)
            )

            // 호스트/포트 입력.
            Text("로봇 정보 입력")
                .font(DFFont.bodyEmph)
            HStack {
                Text("호스트")
                    .frame(width: 60, alignment: .leading)
                    .foregroundStyle(DFColor.textSecondary)
                TextField("", text: $manualHost,
                          prompt: Text("192.168.123.1 또는 op2.local"))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("포트")
                    .frame(width: 60, alignment: .leading)
                    .foregroundStyle(DFColor.textSecondary)
                TextField("", text: $manualPort, prompt: Text("5530"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Spacer()
            }

            // 로봇 측 단계별 명령.
            robotSideCommandsSection

            HStack {
                Button {
                    runNetworkPath()
                } label: {
                    Label("TCP 연결 시도", systemImage: "network")
                }
                .buttonStyle(.glassNeon(tint: DFColor.accent))
                .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// 로봇 PC에서 실행할 명령 — 단계별. 두 경로:
    ///   ① socat 한 줄 (가장 빠름, 의존성 없음)
    ///   ② forge serve (자동 광고 등 추가 기능, RAM/디스크 충분 시)
    /// e-Manual 표준 환경: user `robotis`, pw `111111`, IP `192.168.123.1`.
    private var robotSideCommandsSection: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {

            // 가장 빠른 방법 — socat + alias로 매번 1글자 실행. 우선 노출.
            DisclosureGroup("⚡ 가장 빠른 방법 — 한 번 셋업, 그 후 'f' 한 글자",
                            isExpanded: .constant(true)) {
                VStack(alignment: .leading, spacing: DFSpace.sm2) {
                    Text("OP2 표준(Ubuntu 14.04, Atom Z530, 1 GB RAM)은 cargo build가 비현실적. `socat`+ `alias` 조합으로 매 사용 시 한 글자만 입력하면 됩니다.")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    commandStepCard(
                        step: "1️⃣",
                        title: "한 번만 — 셋업 (이 한 블록만 붙여넣기)",
                        note: "socat + sshd 설치, `f` alias 등록, SSH 시작. 4줄 한 번에 복사.",
                        command: """
                        sudo apt install -y socat openssh-server
                        echo "alias f='socat tcp-l:5530,reuseaddr,fork file:/dev/ttyUSB0,b1000000,raw,echo=0'" >> ~/.bashrc
                        source ~/.bashrc
                        sudo service ssh start
                        """
                    )

                    commandStepCard(
                        step: "2️⃣",
                        title: "매 사용 시 — 한 글자",
                        note: "USB↔TCP bridge 시작. Ctrl-C로 중지.",
                        command: "f"
                    )

                    Text("✓ 검증: `f` 입력 후 커서가 멈추면 listen 중. Mac에서 \"TCP 연결 시도\"를 누르세요.")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.success)

                    Divider()

                    Text("💡 두 IP가 떴다면 (`hostname -I` 출력) — Mac과 같은 공유기에 있는 IP를 선택하세요.\n   • 192.168.123.1: 이더넷 케이블 직결 (e-Manual 표준)\n   • 192.168.0.x:    일반 LAN (대부분의 환경)")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, DFSpace.xs)
            }
            .font(DFFont.bodyEmph)

            // 환경 진단 — 빌드 가능성 확인.
            DisclosureGroup("🔍 로봇 환경 진단 (cargo build 가능성)") {
                VStack(alignment: .leading, spacing: DFSpace.sm2) {
                    Text("로봇 PC에서 다음을 실행하고 결과를 확인하세요. RAM이 2GB 이상이고 cargo가 있으면 forge serve도 가능, 아니면 위 socat 권장.")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)

                    commandStepCard(
                        step: "진단",
                        title: "한 줄로 환경 확인",
                        note: "출력: 아키텍처 / 메모리 / 디스크 / Rust 설치 여부 / USB 디바이스",
                        command: "uname -m && free -m | head -2 && df -h ~ | tail -1 && which cargo && ls /dev/ttyUSB*"
                    )

                    Text("기준: Atom Z530 (i686, 1GB) — Rust 빌드 어려움 → socat 권장.\nIntel NUC i3+ (x86_64, 4GB+) — forge serve 빌드 OK.")
                        .font(DFFont.caption.monospaced())
                        .foregroundStyle(DFColor.textSecondary)
                        .padding(DFSpace.sm)
                        .background(DFColor.elev2)
                        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
                }
                .padding(.top, DFSpace.xs)
            }
            .font(DFFont.bodyEmph)

            // SSH 트러블슈팅.
            DisclosureGroup("🛠 SSH 'Connection refused' 트러블슈팅") {
                VStack(alignment: .leading, spacing: DFSpace.sm2) {
                    Text("`refused`는 호스트는 닿지만 22번 포트에 sshd가 listen하지 않는다는 뜻 (vs `timeout` = 호스트 자체 unreachable).\n\n**이미 로봇 터미널에 접근 가능하다면 SSH는 필수가 아닙니다.** 그 터미널에서 위 socat 한 줄을 바로 실행하세요.")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    commandStepCard(
                        step: "확인",
                        title: "SSH 데몬 상태",
                        note: "active (running)이면 OK, inactive면 다음 단계.",
                        command: "sudo systemctl status ssh || sudo systemctl status sshd"
                    )

                    commandStepCard(
                        step: "수정",
                        title: "SSH 서버 설치 + 활성화",
                        note: "openssh-server가 없거나 중지된 경우.",
                        command: "sudo apt install -y openssh-server && sudo systemctl enable --now ssh"
                    )

                    commandStepCard(
                        step: "확인",
                        title: "방화벽 차단 여부",
                        note: "ufw가 활성이면 22번 허용.",
                        command: "sudo ufw status && sudo ufw allow 22/tcp"
                    )
                }
                .padding(.top, DFSpace.xs)
            }
            .font(DFFont.bodyEmph)

            // forge serve 풀 빌드 (선택, RAM/디스크 충분한 경우만).
            DisclosureGroup("⚙️ (선택) forge serve 풀 빌드 — RAM 2GB+ 환경") {
                VStack(alignment: .leading, spacing: DFSpace.sm2) {
                    Text("Bonjour 자동 광고, 동시 연결 제한, 더 친절한 로그가 필요하면 이 경로. OP3 NUC 또는 외부 SBC 권장.")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)

                    commandStepCard(
                        step: "1",
                        title: "Rust toolchain (없으면)",
                        note: "rustup 한 줄 설치.",
                        command: "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
                    )

                    commandStepCard(
                        step: "2",
                        title: "소스 받고 빌드 (한 번만)",
                        note: "OP2 Atom Z530은 30~60분, OP3 NUC i3는 5~10분.",
                        command: """
                        source $HOME/.cargo/env
                        git clone https://github.com/bbikiming/Darwin
                        cd Darwin/app/core
                        cargo build --release -p forge-cli
                        """
                    )

                    commandStepCard(
                        step: "3",
                        title: "데몬 실행",
                        note: "Bonjour 광고 + 단일 연결 제한 자동.",
                        command: "./target/release/forge serve --port /dev/ttyUSB0 --bind 0.0.0.0:5530 --advertise OP2-MAIN"
                    )
                }
                .padding(.top, DFSpace.xs)
            }
            .font(DFFont.bodyEmph)
        }
    }

    /// 단계 카드 — 번호 + 제목 + 설명 + 복사 가능한 명령 블록.
    private func commandStepCard(step: String, title: String, note: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DFSpace.xs2) {
                Text(step)
                    .font(.system(size: DFFontSize.s11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DFSpace.sm - 1)
                    .padding(.vertical, DFSpace.micro2)
                    .background(DFColor.forge)
                    .clipShape(Capsule())
                Text(title).font(DFFont.bodyEmph)
            }
            Text(note)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: DFSpace.xs2) {
                Text(command)
                    .font(.system(size: DFFontSize.s11, design: .monospaced))
                    .padding(DFSpace.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DFColor.elev2)
                    .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
                    .textSelection(.enabled)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("이 명령 복사")
                .padding(.top, DFSpace.sm)
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private var bonjourList: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack {
                Text("같은 네트워크의 로봇")
                    .font(DFFont.bodyEmph)
                Spacer()
                if bonjour.isBrowsing {
                    HStack(spacing: DFSpace.xs) {
                        ProgressView().controlSize(.small)
                        Text("검색 중…")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.textSecondary)
                    }
                }
                Button {
                    bonjour.stop(); bonjour.start()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("다시 검색")
            }
            if bonjour.discovered.isEmpty {
                VStack(spacing: DFSpace.xs) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: DFFontSize.s24))
                        .foregroundStyle(DFColor.textSecondary)
                    Text("아직 발견된 로봇이 없어요")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                    Text("로봇 PC에서 `forge serve --advertise <이름>`을 실행했나요?")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(DFSpace.md)
                .background(DFColor.card)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            } else {
                ForEach(bonjour.discovered) { svc in
                    Button {
                        runBonjourPath(svc)
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(DFColor.forge)
                            VStack(alignment: .leading, spacing: DFSpace.micro) {
                                Text(svc.serviceName).font(DFFont.bodyEmph)
                                Text("\(svc.host):\(svc.port)")
                                    .font(DFFont.caption.monospaced())
                                    .foregroundStyle(DFColor.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(DFColor.textSecondary)
                        }
                        .padding(DFSpace.sm)
                        .background(DFColor.card)
                        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                    }
                    .buttonStyle(.plain)
                }
            }

            DisclosureGroup("로봇 PC에서 실행할 명령 (자동 광고)") {
                VStack(alignment: .leading, spacing: DFSpace.sm) {
                    Text("Mac이 자동으로 발견할 수 있도록 `--advertise` 옵션과 함께 실행:")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                    let cmd = "./target/release/forge serve --port /dev/ttyUSB0 --bind 0.0.0.0:5530 --advertise OP2-MAIN"
                    HStack(alignment: .top, spacing: DFSpace.xs2) {
                        Text(cmd)
                            .font(.system(size: DFFontSize.s11, design: .monospaced))
                            .padding(DFSpace.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DFColor.elev2)
                            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
                            .textSelection(.enabled)
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(cmd, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .padding(.top, DFSpace.sm)
                    }
                    Text("팁: 로봇이 USB로만 연결됐다면 `--bind 127.0.0.1:5530` + SSH 터널이 더 안전.")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
                .padding(.top, DFSpace.xs)
            }
            .font(DFFont.bodyEmph)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            footerStatus
            Spacer()
            Button("닫기") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(DFSpace.md)
    }

    @ViewBuilder
    private var footerStatus: some View {
        if let path = selectedPath, let last = steps.last {
            statusFooter(path: path, last: last)
        } else if !isAdvanced {
            oneClickFooter
        } else {
            Text("도움말: ⌘K 명령 팔레트 · ⌘⇧. 긴급정지")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    @ViewBuilder
    private var oneClickFooter: some View {
        if store.isReconnecting {
            HStack(spacing: DFSpace.xs2) {
                ProgressView().controlSize(.small)
                Text("자동 재연결 \(store.reconnectAttempt)/5 — 잠시 후 다시 시도해요")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.warning)
            }
        } else {
            oneClickFooterPhase
        }
    }

    @ViewBuilder
    private var oneClickFooterPhase: some View {
        switch oneClick.phase {
        case .idle:
            Text("아래 진단을 보고 [자동 연결 시작] 한 번 클릭")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        case .scanning:
            HStack(spacing: DFSpace.xs2) {
                ProgressView().controlSize(.small)
                Text("주변 검색 중…")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        case .connecting(let label):
            HStack(spacing: DFSpace.xs2) {
                ProgressView().controlSize(.small)
                Text("연결 중 — \(label)")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        case .connected:
            Label("연결 성공! 잠시 후 닫힙니다", systemImage: "checkmark.circle.fill")
                .foregroundStyle(DFColor.success)
                .font(DFFont.bodyEmph)
        case .allFailed:
            Label("응답한 후보 없음 — 위 [통합 셋업 복사] 후 로봇 터미널에 붙여넣기",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DFColor.warning)
                .font(DFFont.caption)
        case .failed(let r):
            Label(r, systemImage: "xmark.octagon.fill")
                .foregroundStyle(DFColor.danger)
                .font(DFFont.caption)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func statusFooter(path: WizardPath, last: WizardStep) -> some View {
        switch last.status {
        case .success:
            Label("연결 성공! 잠시 후 닫힙니다", systemImage: "checkmark.circle.fill")
                .foregroundStyle(DFColor.success)
                .font(DFFont.bodyEmph)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DFColor.danger)
                .font(DFFont.caption)
                .lineLimit(2)
        case .inProgress:
            HStack(spacing: DFSpace.xs2) {
                ProgressView().controlSize(.small)
                Text(last.title)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        case .pending:
            Text("아래 안내에 따라 진행해 주세요")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    // MARK: - Path actions

    private func selectPath(_ path: WizardPath) {
        selectedPath = path
        switch path {
        case .usb:     setupUSBSteps()
        case .network: setupNetworkSteps()
        case .bonjour:
            setupBonjourSteps()
            bonjour.start()
        }
    }

    private func setupUSBSteps() {
        steps = [
            WizardStep(id: "u1", number: 1, title: "USB 케이블 연결",
                       detail: "Mac과 로봇의 CM 보드를 USB 케이블로 연결해 주세요.",
                       icon: "cable.connector"),
            WizardStep(id: "u2", number: 2, title: "로봇 전원 켜기",
                       detail: "로봇 후면 또는 측면의 전원 스위치를 켜고 부팅을 기다려요.",
                       icon: "power"),
            WizardStep(id: "u3", number: 3, title: "USB 포트 검색",
                       detail: "macOS가 USB serial 디바이스를 인식했는지 확인합니다.",
                       icon: "magnifyingglass.circle"),
            WizardStep(id: "u4", number: 4, title: "연결 시도",
                       detail: "감지된 포트로 Bus를 열고 보드 상태를 확인해요.",
                       icon: "checkmark.shield")
        ]
        autoStartUSBSteps()
    }

    private func autoStartUSBSteps() {
        // 1·2번은 사용자가 수동으로 진행하므로 항상 success로 가정.
        // 3번은 포트 검색 — 0.5초 후 검사.
        markStep("u1", .success)
        markStep("u2", .success)
        markStep("u3", .inProgress)
        Task { @MainActor in
            store.refreshPorts()
            try? await Task.sleep(nanoseconds: 400_000_000)
            if store.availablePorts.isEmpty {
                markStep("u3", .failed("USB 포트가 보이지 않아요. 케이블·전원·드라이버를 확인해 주세요."))
            } else {
                markStep("u3", .success)
            }
        }
    }

    private func runUSBPath() {
        markStep("u4", .inProgress)
        store.autoConnect()
        // store.status onChange가 success/failed 갱신.
    }

    private func setupNetworkSteps() {
        steps = [
            WizardStep(id: "n1", number: 1, title: "로봇 PC에서 데몬 실행",
                       detail: "로봇 내장 PC에 SSH 접속 후 `forge serve` 를 실행하세요.",
                       icon: "terminal"),
            WizardStep(id: "n2", number: 2, title: "호스트와 포트 입력",
                       detail: "로봇 IP 주소(예: 10.0.0.42)와 포트(default 5530)를 입력해 주세요.",
                       icon: "keyboard"),
            WizardStep(id: "n3", number: 3, title: "TCP 연결 시도",
                       detail: "Mac이 로봇 PC의 forge serve와 TCP 연결을 시도해요.",
                       icon: "network"),
            WizardStep(id: "n4", number: 4, title: "보드 상태 확인",
                       detail: "USB ↔ TCP bridge를 통해 CM 보드 응답을 받아요.",
                       icon: "checkmark.shield")
        ]
        markStep("n1", .pending)
    }

    private func runNetworkPath() {
        let host = manualHost.trimmingCharacters(in: .whitespaces)
        guard let port = UInt16(manualPort.trimmingCharacters(in: .whitespaces)) else {
            markStep("n2", .failed("포트가 1~65535 사이의 숫자여야 해요"))
            return
        }
        // 1, 2번은 사용자 액션. 3, 4번은 자동.
        markStep("n1", .success)
        markStep("n2", .success)
        markStep("n3", .inProgress)
        store.networkHost = host
        store.networkPort = port
        store.connectNetwork()
        // status onChange로 n3/n4 자동 갱신.
    }

    private func setupBonjourSteps() {
        steps = [
            WizardStep(id: "b1", number: 1, title: "로봇이 광고 중인지 확인",
                       detail: "로봇 PC에서 `forge serve --advertise <이름>` 이 실행 중이어야 해요.",
                       icon: "megaphone"),
            WizardStep(id: "b2", number: 2, title: "같은 네트워크 확인",
                       detail: "Mac과 로봇이 같은 LAN/WiFi에 있어야 자동 검색이 가능해요.",
                       icon: "wifi"),
            WizardStep(id: "b3", number: 3, title: "Bonjour로 자동 검색",
                       detail: "_forge._tcp 서비스를 광고하는 로봇을 찾아요.",
                       icon: "antenna.radiowaves.left.and.right"),
            WizardStep(id: "b4", number: 4, title: "발견된 로봇 클릭",
                       detail: "목록에서 로봇을 클릭하면 자동으로 연결을 시도해요.",
                       icon: "hand.tap")
        ]
        markStep("b1", .pending)
        markStep("b2", .pending)
        markStep("b3", .inProgress)
    }

    private func runBonjourPath(_ svc: BonjourBrowser.Discovered) {
        markStep("b1", .success)
        markStep("b2", .success)
        markStep("b3", .success)
        markStep("b4", .inProgress)
        manualHost = svc.host
        manualPort = String(svc.port)
        let endpoint = bonjour.endpoint(for: svc)
        store.connect(endpoint: endpoint)
    }

    // MARK: - Step state helpers

    private func markStep(_ id: String, _ status: StepStatus) {
        if let idx = steps.firstIndex(where: { $0.id == id }) {
            steps[idx].status = status
        }
    }

    private func currentStepIndex() -> Int? {
        // 첫 inProgress 또는 마지막 항목.
        for (i, s) in steps.enumerated() where s.status == .inProgress {
            return i
        }
        return steps.indices.last
    }

    private func markCurrentStep(_ status: StepStatus) {
        guard let idx = currentStepIndex() else { return }
        steps[idx].status = status
    }
}
