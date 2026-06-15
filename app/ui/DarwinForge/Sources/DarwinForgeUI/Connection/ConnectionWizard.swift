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

/// 연결 방식 — 제어 경로 선택. 마법사 진입 시 사용자가 고르고, `@AppStorage` 로 영속.
///
/// 두 경로는 서로 다른 트레이드를 가진다:
///   - `.sshOnboard` (기본): 로봇 자신의 `demo-pilot` 이 모터를 소유 → 보행이 안정적.
///     Mac 은 SSH 로 명령/텔레메트리를 주고받는다 (온보드 브로커리지).
///   - `.lan`: Mac 의 `Bus` 가 5530 TCP bridge 로 모터를 직접 구동 → 풀 텔레메트리·헤드·
///     긴급정지가 즉시 동작하지만, 왕복 지연 때문에 보행이 흔들릴 수 있다.
public enum ConnectionMethod: String, CaseIterable, Identifiable {
    case sshOnboard
    case lan

    public var id: String { rawValue }

    /// 기본값 — 안정 보행 우선.
    public static let `default`: ConnectionMethod = .sshOnboard

    public var title: String {
        switch self {
        case .sshOnboard: return "SSH 온보드"
        case .lan:        return "LAN (5530·유선)"
        }
    }

    public var badge: String {
        switch self {
        case .sshOnboard: return "기본"
        case .lan:        return "고급"
        }
    }

    public var icon: String {
        switch self {
        case .sshOnboard: return "cpu"
        case .lan:        return "cable.connector.horizontal"
        }
    }

    public var tint: Color {
        switch self {
        case .sshOnboard: return DFColor.success
        case .lan:        return DFColor.forge
        }
    }

    /// 한 줄 핵심 트레이드.
    public var summary: String {
        switch self {
        case .sshOnboard: return "로봇이 직접 걷기 — 보행 안정적"
        case .lan:        return "Mac이 직접 구동 — 풀 텔레메트리·헤드·긴급정지 (유선 전용)"
        }
    }

    /// 장점/주의 상세 설명 (선택 후 카드에 표기).
    public var detail: String {
        switch self {
        case .sshOnboard:
            return "로봇의 demo-pilot 이 모터를 소유해 보행이 안정적입니다. Mac은 SSH로 텔레메트리·헤드·긴급정지를 중계합니다."
        case .lan:
            return "유선 직결 전용(192.168.123.1). Mac의 Bus가 5530 bridge로 모터를 직접 구동합니다. 텔레메트리·헤드·긴급정지가 즉시 동작하지만, 왕복 지연으로 보행이 흔들릴 수 있어요. 랜선 필요."
        }
    }
}

/// **유무선 링크 선택 (2026-06-02)** — SSH 온보드 안에서 로봇에 닿는 물리 경로.
/// 둘 다 SSH 온보드(로봇이 보행) 동일하고, 차이는 Mac↔로봇 네트워크뿐:
///   - `.wired`: USB 직결 이더넷 (192.168.123.1). 지연 ~1ms, 항상 안정.
///   - `.wireless`: WiFi (로봇 wlan0, DHCP). 케이블 없이 조종. 지연 ~80-200ms.
public enum ConnectionLink: String, CaseIterable, Identifiable {
    case wired
    case wireless
    public var id: String { rawValue }
    public var title: String { self == .wired ? "유선" : "무선" }
    public var icon: String { self == .wired ? "cable.connector.horizontal" : "wifi" }
    public var hint: String {
        self == .wired
            ? "USB 직결 이더넷 (192.168.123.1) — 지연 최소, 항상 안정"
            : "WiFi (로봇 wlan0) — 케이블 없이 무선 조종"
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
    /// SSH 명령 채널 (앱 전역 주입). LAN 포트 자동 오픈 + SSH 온보드 연결에 사용.
    @EnvironmentObject var remoteShell: RemoteShell
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
    /// 연결 방식 — SSH 온보드(기본) / LAN(5530). 영속되어 다음 실행 때 자동 복원.
    @AppStorage("df.connection.preferredMethod") private var connectionMethodRaw: String =
        ConnectionMethod.default.rawValue

    /// 현재 선택된 연결 방식 — 잘못된 raw 값은 기본값으로 폴백.
    private var connectionMethod: ConnectionMethod {
        ConnectionMethod(rawValue: connectionMethodRaw) ?? .default
    }

    /// **유무선 링크 (2026-06-02)** — SSH 온보드의 물리 경로. 영속.
    @AppStorage("df.connection.link") private var connectionLinkRaw: String =
        ConnectionLink.wired.rawValue
    /// 무선 WiFi 호스트 (로봇 wlan0 IP, DHCP). 사용자 입력 또는 자동 탐지. 영속.
    @AppStorage("df.connection.wifiHost") private var wifiHost: String = "192.168.0.33"
    /// WiFi IP 자동 탐지 진행 상태(스피너).
    @State private var detectingWifi: Bool = false

    private var connectionLink: ConnectionLink {
        ConnectionLink(rawValue: connectionLinkRaw) ?? .wired
    }

    /// SSH 온보드가 실제로 접속할 호스트 — 링크 선택에 따라 유선 IP 또는 WiFi IP.
    /// 무선인데 wifiHost 가 비어도 **유선으로 silent fallback 하지 않는다**(사용자가 무선을
    /// 골랐는데 유선으로 붙는 거짓 동작 방지). connectSSHOnboard 가 사전 검증한다.
    private func resolvedSSHHost() -> String {
        switch connectionLink {
        case .wired:
            return DFConnectionConstants.robotEthernetIP
        case .wireless:
            return wifiHost.trimmingCharacters(in: .whitespaces)
        }
    }

    /// 호스트 형식 검증 — IPv4(4옥텟 0-255) 또는 점/`.local` 포함 호스트명.
    static func isLikelyValidHost(_ raw: String) -> Bool {
        let h = raw.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return false }
        // 빈 옥텟/라벨(192..168 / .192 / 192.) 도 잡도록 빈 항목 유지하고 분리.
        let octets = h.split(separator: ".", omittingEmptySubsequences: false)
        let allNumeric = octets.allSatisfy { Int($0) != nil }   // 빈 문자열 → Int nil → false
        if allNumeric {
            // 숫자만 = IPv4 시도 → 정확히 4옥텟 모두 0-255 여야 유효 (300.1.1.1 은 reject).
            return octets.count == 4
                && octets.allSatisfy { let v = Int($0) ?? -1; return v >= 0 && v <= 255 }
        }
        // 비숫자 포함 = 호스트명 → 점 포함 + 각 라벨이 [A-Za-z0-9-], 빈 라벨/양끝 하이픈 없음.
        guard h.contains(".") else { return false }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty
                && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

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
                harness.record(
                    .setupConnWizardStarted, level: .info, actor: .user,
                    data: ["has_last_endpoint": AnyCodable(store.lastSuccessfulEndpoint != nil),
                           "is_advanced": AnyCodable(isAdvanced)]
                )
                if !isAdvanced && selectedPath == nil {
                    // SSH 온보드(기본)일 때만 진입 즉시 자동 연결 시도. LAN 은 사용자가
                    // 명시적으로 [LAN(5530)으로 연결] 을 누르도록 진단만 표시 (오작동 방지).
                    if connectionMethod == .sshOnboard,
                       store.lastSuccessfulEndpoint != nil, store.bus == nil {
                        harness.record(
                            .setupConnOneClickFired, level: .info, actor: .system,
                            data: ["trigger": AnyCodable("auto"),
                                   "connection_method": AnyCodable(connectionMethod.rawValue)]
                        )
                        // 검토 fix: SSH 온보드는 :5530(runOneClick) 가 아니라 실제 SSH 경로.
                        connectSSHOnboard()
                    } else {
                        oneClick.runDiagnosticsOnly()
                    }
                }
            }
            .onChange(of: store.status) { _, new in
                if case .connected = new {
                    markCurrentStep(.success)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        isPresented = false
                    }
                } else if case .error(let m) = new {
                    markCurrentStep(.failed(m))
                }
            }
            .onChange(of: oneClick.phase) { _, newPhase in
                if case .allFailed = newPhase {
                    harness.record(
                        .setupConnOneClickAllFailed, level: .notice, actor: .system,
                        data: ["candidate_count": AnyCodable(oneClick.candidates.count)]
                    )
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
                connectionMethodSelector
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
        var set: [String] = [DFConnectionConstants.robotEthernetIP]
        for h in NetworkProbe.likelyRobotCandidates() where !set.contains(h) {
            set.append(h)
        }
        return Array(set.prefix(4))
    }

    // MARK: - Connection method selector

    /// 제어 경로 선택 — SSH 온보드(기본) vs LAN(5530). 두 칩 + 선택된 방식의 트레이드 설명.
    private var connectionMethodSelector: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(DFColor.accent)
                Text("연결 방식")
                    .font(DFFont.bodyEmph)
                Text("(제어 경로를 고르세요)")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }

            HStack(spacing: DFSpace.sm) {
                ForEach(ConnectionMethod.allCases) { method in
                    connectionMethodChip(method)
                }
            }

            // 선택된 방식의 상세 트레이드.
            HStack(alignment: .top, spacing: DFSpace.xs2) {
                Image(systemName: connectionMethod.icon)
                    .font(.system(size: DFFontSize.s11))
                    .foregroundStyle(connectionMethod.tint)
                    .padding(.top, 1)
                Text(connectionMethod.detail)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // **유무선 링크 (2026-06-02)** — SSH 온보드일 때만 노출. 그룹 내 하위 선택.
            if connectionMethod == .sshOnboard {
                Divider().background(DFColor.textSecondary.opacity(DFOpacity.subtle))
                linkSelector
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

    /// 유무선 링크 하위 선택 — 유선/무선 세그먼트 + (무선 시) WiFi IP 입력·자동탐지.
    private var linkSelector: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: DFFontSize.s11))
                    .foregroundStyle(DFColor.accent)
                Text("연결 매체")
                    .font(DFFont.caption.weight(.semibold))
                Text("(유선/무선)")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            // 유선/무선 세그먼트.
            HStack(spacing: DFSpace.xs2) {
                ForEach(ConnectionLink.allCases, id: \.self) { link in
                    let on = link == connectionLink
                    Button {
                        connectionLinkRaw = link.rawValue
                    } label: {
                        HStack(spacing: DFSpace.xs) {
                            Image(systemName: link.icon)
                                .font(.system(size: DFFontSize.s11, weight: .semibold))
                            Text(link.title).font(DFFont.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DFSpace.xs)
                        .background(on ? DFColor.accent.opacity(DFOpacity.o18) : DFColor.card)
                        .overlay(RoundedRectangle(cornerRadius: DFRadius.xs)
                            .stroke(on ? DFColor.accent : DFColor.textSecondary.opacity(DFOpacity.subtle),
                                    lineWidth: on ? DFSize.borderStrong : DFSize.borderHairline))
                        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("link.\(link.rawValue)")
                }
            }
            Text(connectionLink.hint)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
            // 무선: WiFi IP 입력 + 자동 탐지.
            if connectionLink == .wireless {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "wifi").font(.system(size: DFFontSize.s11))
                        .foregroundStyle(DFColor.textSecondary)
                    TextField("로봇 WiFi IP (예: 192.168.0.33)", text: $wifiHost)
                        .textFieldStyle(.roundedBorder)
                        .font(DFFont.caption)
                        .frame(maxWidth: 200)
                    Button {
                        autoDetectWifiIP()
                    } label: {
                        HStack(spacing: DFSpace.xs2) {
                            if detectingWifi { ProgressView().controlSize(.small) }
                            else { Image(systemName: "antenna.radiowaves.left.and.right") }
                            Text("자동 탐지").font(DFFont.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(detectingWifi)
                    .help("유선 연결을 통해 로봇 wlan0 IP 를 읽어 채웁니다")
                }
            }
        }
    }

    /// 로봇 wlan0 IP 자동 탐지 — 유선(192.168.123.1) 경유 SSH 로 `ip addr` 읽어 wifiHost 채움.
    private func autoDetectWifiIP() {
        detectingWifi = true
        let wiredHost = DFConnectionConstants.robotEthernetIP
        Task { @MainActor in
            defer { detectingWifi = false }
            // 리뷰(codex H2) fix: 공유 remoteShell.host 를 임시 변경하면 그 await 동안 스트리밍/
            // e-stop/telemetry 가 엉뚱한 호스트로 가거나 동시 connect 의 host 를 덮어쓰는 레이스.
            // → 공유 인스턴스 건드리지 않고 SSHShell.run 으로 유선 호스트 일회성 조회.
            let result = try? await SSHShell.run(
                command: RobotSetupCommand.readWifiIP, host: wiredHost, timeoutSeconds: 8)
            if let ip = ConnectionWizardView.parseWifiIP(result?.combined ?? "") { wifiHost = ip }
        }
    }

    /// SSH combined 출력에서 "WIFI_IP=x.x.x.x" 라인의 IPv4 추출 (순수 함수, 테스트 가능).
    /// 빈 값/없음/형식오류면 nil. exit suffix·stderr 가 섞여도 견고.
    static func parseWifiIP(_ output: String) -> String? {
        for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("WIFI_IP=") else { continue }
            let ip = String(line.dropFirst("WIFI_IP=".count)).trimmingCharacters(in: .whitespaces)
            // 간단한 IPv4 형태 검증 (4옥텟).
            let parts = ip.split(separator: ".")
            guard parts.count == 4, parts.allSatisfy({ Int($0).map { $0 >= 0 && $0 <= 255 } ?? false })
            else { return nil }
            return ip
        }
        return nil
    }

    private func connectionMethodChip(_ method: ConnectionMethod) -> some View {
        let selected = method == connectionMethod
        return Button {
            selectConnectionMethod(method)
        } label: {
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: method.icon)
                        .font(.system(size: DFFontSize.s12, weight: .semibold))
                    Text(method.title)
                        .font(DFFont.bodyEmph)
                    Text(method.badge)
                        .font(.system(size: DFFontSize.s9, weight: .bold))
                        .padding(.horizontal, DFSpace.xs2 - 1)
                        .padding(.vertical, DFSpace.micro)
                        .background(method.tint.opacity(DFOpacity.o18))
                        .foregroundStyle(method.tint)
                        .clipShape(Capsule())
                }
                Text(method.summary)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DFSpace.sm)
            .background(selected ? method.tint.opacity(DFOpacity.o15) : DFColor.elev2)
            .foregroundStyle(selected ? method.tint : DFColor.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.xs)
                    .stroke(selected ? method.tint.opacity(DFOpacity.o45)
                                     : DFColor.textSecondary.opacity(DFOpacity.o15),
                            lineWidth: selected ? DFSize.borderHairline + 1 : DFSize.borderHairline)
            )
        }
        .buttonStyle(.plain)
        .help(method.detail)
    }

    private func selectConnectionMethod(_ method: ConnectionMethod) {
        guard method != connectionMethod else { return }
        connectionMethodRaw = method.rawValue
        harness.record(
            .setupConnAdvancedToggle, level: .info, actor: .user,
            data: ["connection_method": AnyCodable(method.rawValue)]
        )
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
        // SSH 온보드 경로는 store.status 로 단계를 진행(oneClick.phase 와 분리). 둘 중 하나라도
        // connecting 이면 버튼을 스피너+비활성 — 종전엔 oneClick.phase 만 봐 SSH 온보드 연결 중에도
        // 버튼이 활성/평상 라벨이라 중복 클릭이 가능했다(불일치 fix).
        let isConnecting: Bool = {
            if case .connecting = oneClick.phase { return true }
            if case .connecting = store.status { return true }
            return false
        }()
        let isScanning: Bool = oneClick.phase == .scanning
        Button {
            harness.record(
                .setupConnOneClickFired, level: .info, actor: .user,
                data: ["trigger": AnyCodable("manual"),
                       "connection_method": AnyCodable(connectionMethod.rawValue)]
            )
            runPreferredConnect()
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
        // SSH 온보드/LAN 경로는 store.status 로 단계 진행을 표시(oneClick.phase 와 분리).
        // connecting 단계 라벨(①②③ / 5530 포트…)을 그대로 노출해 "무엇을 하는 중"인지 정직하게.
        if case .connecting(let label) = store.status { return "연결 중 — \(label)" }
        if case .connected = store.status { return "✅ 연결됨" }
        switch oneClick.phase {
        case .idle, .allFailed, .failed:
            switch connectionMethod {
            case .sshOnboard: return "🚀  자동 연결 시작 (SSH 온보드)"
            case .lan:        return "🔌  LAN(5530)으로 연결"
            }
        case .scanning:                  return "주변 검색 중…"
        case .connecting(let label):     return "연결 중 — \(label)"
        case .connected:                 return "✅ 연결됨"
        }
    }

    /// 선택된 연결 방식에 따라 연결 시작.
    ///   - `.sshOnboard`: 기존 자동 연결(원클릭) — 온보드 제어 경로.
    ///   - `.lan`: 5530 TCP bridge 직결 — `store.connectNetwork()` 사용.
    private func runPreferredConnect() {
        switch connectionMethod {
        case .sshOnboard:
            connectSSHOnboard()
        case .lan:
            connectLAN()
        }
    }

    /// 클래식 LAN(5530 bridge) 연결 — **"알아서 포트 열어서 연결"**.
    /// 시퀀스(데모 종료 + socat 기동 → BRIDGE_OK → bus 연결)는 `store.connectLANBridge` 가 소유한다
    /// (모드전환 `switchToJointEdit` 와 공유 — divergence 제거). 여기선 진행/에러를 `status` 로 표시.
    /// ⚠️ demo 종료 시 로봇 토크가 풀리므로 거치/파지 상태에서 사용.
    private func connectLAN() {
        store.status = .connecting("5530 포트 여는 중… (유선 직결)")
        Task { @MainActor in
            let result = await store.connectLANBridge(remoteShell: remoteShell) { _ in
                // 마법사는 단일 "5530 포트 여는 중…" 표시 유지 — 중간 단계 별도 표시 없음.
            }
            switch result {
            case .connected, .superseded:
                // .connected: connect(endpoint:) 가 status 를 갱신. .superseded: 새 시도가 소유.
                break
            case .failed(let reason):
                store.status = .error(reason)
            }
        }
    }

    /// SSH 온보드 연결 — 검토 지적 fix: 종전엔 `oneClick.runOneClick()`(=:5530 TCP) 라
    /// "SSH 온보드" 라벨과 실제 동작이 불일치했다. 이제 SSH 경로로:
    ///   1) walklab 모드 검증 — 미실행이면 demo 를 walklab 으로 기동(`walkLabRobotisStart`)
    ///   2) Mac telemetry poller 시작(`startOnboardTelemetry`) → telemetryMode `.onboard`
    ///      → HUD + L0/L3 안전게이트 + 콕핏 게이트가 onboard 를 live 로 인식.
    private func connectSSHOnboard() {
        // === View 전용 검증 (마법사 전용, 보존) — 무선 IP 유효성·유선IP-무선혼동 ===
        // 무선 선택인데 IP 가 비었거나 형식 오류면 — 유선으로 silent fallback 하지 않고 명확히 막는다.
        if connectionLink == .wireless && !ConnectionWizardView.isLikelyValidHost(wifiHost) {
            store.status = .error("무선 WiFi IP 가 비었거나 형식 오류 — IP 입력 또는 [자동 탐지] (유선 연결 필요)")
            return
        }
        // **무선/유선 명확성 (2026-06-02)**: 무선인데 유선 직결 IP(192.168.123.x)를 넣으면 케이블에
        // 묶인 "가짜 무선"이 된다(랜선 뽑으면 끊김). 명확히 막아 사용자가 로봇 WiFi IP 를 넣게 한다.
        if connectionLink == .wireless && ConnectionLinkKind.classify(host: wifiHost) == .wired {
            store.status = .error("무선인데 유선 직결 IP(192.168.123.x)입니다 — 로봇 WiFi IP(예: 192.168.0.33)를 입력하세요")
            return
        }
        // 유무선 링크 선택에 따라 호스트 확정 (유선 192.168.123.1 / 무선 wlan0 IP).
        let host = resolvedSSHHost()
        store.status = .connecting("① 데모 모드 확인 중…")
        Task { @MainActor in
            // 시퀀스(verify → 기동 → ✅ 마커 → 온보드 텔레메트리)는 store.connectOnboard 가 소유
            // (모드전환 switchToWalk 와 공유 — divergence 제거). 여기선 진행/에러를 status 로 표시.
            let result = await store.connectOnboard(host: host, remoteShell: remoteShell) { step in
                switch step {
                case .verifyingMode:
                    store.status = .connecting("① 데모 모드 확인 중…")
                case .startingWalklab:
                    // **정직성 UX**: 이 단계에서 로봇 demo 가 재기동되며 init 자세로 움직인다.
                    store.status = .connecting("② walklab 전환 중 — 로봇이 init 자세로 움직입니다(잡아주세요)")
                case .waitingTelemetry:
                    store.status = .connecting("③ 텔레메트리 대기 중…")
                default:
                    break
                }
            }
            switch result {
            case .connected:
                // === 12s 연결 타임아웃 (마법사 전용 UX, 보존) ===
                // 텔레메트리(연결됨)가 안 흐르면 "연결 중" 고착 대신 명확한 에러.
                // result 가 .connected 면 시퀀스 도중 세대 전진이 없었으므로 현재 세대가 곧 그 시도.
                let attemptGen = store.connectAttemptGeneration
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    // 세대가 바뀌었으면(=새 연결 시도/해제) 이 타임아웃은 무효.
                    guard attemptGen == store.connectAttemptGeneration else { return }
                    if case .connecting = store.status {
                        store.stopOnboardTelemetry()
                        store.status = .error("온보드 텔레메트리 없음 — demo 가 walklab 으로 기동 안 됨(카메라/포트 충돌 가능). 다시 연결 시도")
                    }
                }
            case .failed(let reason):
                store.status = .error(reason)
            case .superseded:
                break   // 새 시도가 status 를 소유 — 건드리지 않음.
            }
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
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
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
                harness.record(
                    .setupConnAdvancedToggle, level: .info, actor: .user,
                    data: ["to_advanced": AnyCodable(true)]
                )
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
                    harness.record(
                        .setupConnAdvancedToggle, level: .info, actor: .user,
                        data: ["to_advanced": AnyCodable(false)]
                    )
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
                            .font(DFIcon.micro)
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
                        manualHost = DFConnectionConstants.robotEthernetIP
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
            // 사이클 138 (audit #24 codex sweep)
            Button("닫기", role: .cancel) { isPresented = false }
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
        harness.record(
            .setupConnPathSelected, level: .info, actor: .user,
            data: ["path": AnyCodable(path.rawValue)]
        )
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
        harness.record(
            .setupConnPathConnect, level: .info, actor: .user,
            data: ["path": AnyCodable("usb")]
        )
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
        harness.record(
            .setupConnPathConnect, level: .info, actor: .user,
            data: ["path": AnyCodable("network"),
                   "host_hash": AnyCodable(Harness.shortHash(host)),
                   "port": AnyCodable(Int(port))]
        )
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
        harness.record(
            .setupConnPathConnect, level: .info, actor: .user,
            data: ["path": AnyCodable("bonjour"),
                   "service_hash": AnyCodable(Harness.shortHash(svc.serviceName))]
        )
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
