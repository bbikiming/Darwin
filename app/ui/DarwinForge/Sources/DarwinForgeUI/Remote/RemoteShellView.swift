import SwiftUI

/// SMB 기반 원격 명령 실행 패널.
///
/// UI 구성:
///   - 상단: host/share 정보 + 셋업 명령 복사 + 마운트 상태
///   - 중앙: 명령 입력 (multi-line) + 자주 쓰는 프리셋 칩
///   - 하단: 실행 기록 (명령 + 결과 + 경과 시간)
public struct RemoteShellView: View {
    @StateObject private var shell = RemoteShell()
    @State private var inputText: String = ""
    @State private var copyToast: String?
    @State private var confirmAction: QuickAction?
    @State private var selectedCategory: QuickActionCategory = .system
    /// nil = 자동 (셋업 미완료면 wizard, 완료면 shell). true/false = 사용자 강제.
    @State private var showSetupWizard: Bool? = nil
    @Environment(\.dfWindowWidth) private var winWidth

    public init() {}

    /// 셋업 wizard 표시 여부 — SSH 채널 OK 면 자동 hide.
    private var shouldShowSetupWizard: Bool {
        if let forced = showSetupWizard { return forced }
        // SSH 가 동작 안 하면 셋업 wizard 우선 노출.
        return shell.activeChannel != .ssh
    }

    public var body: some View {
        DFPageScaffold(
            "원격 명령",
            subtitle: shouldShowSetupWizard
                ? "처음이라면 4단계 셋업 — 한 번이면 영구"
                : "SSH 30ms 즉시 / SMB 2초 폴링 자동 선택",
            icon: "terminal.fill",
            tint: DFColor.forge,
            trailing: { headerTrailing }
        ) {
            VStack(spacing: 0) {
                if shouldShowSetupWizard {
                    setupWizardContent
                } else {
                    quickActionsBar
                    Divider()
                    content
                    Divider()
                    inputBar
                }
            }
        }
        .alert(item: $confirmAction) { action in
            Alert(
                title: Text("\(action.label) 실행?"),
                message: Text(action.command),
                primaryButton: .destructive(Text("실행"), action: {
                    Task { await shell.send(action.command) }
                }),
                secondaryButton: .cancel(Text("취소"))
            )
        }
    }

    /// Page scaffold header 우측 — 채널 칩 + 모드 토글.
    @ViewBuilder
    private var headerTrailing: some View {
        HStack(spacing: 6) {
            channelChip
            if let path = shell.lastMountPath {
                DFChip(URL(fileURLWithPath: path).lastPathComponent,
                       icon: "externaldrive.fill",
                       style: .neutral, mono: true)
            }
            modeToggle
        }
    }

    // MARK: - Setup wizard

    private var setupWizardContent: some View {
        VStack(spacing: 0) {
            InitialSetupWizardView()
                .environmentObject(shellStoreOrFallback)
            Divider()
            HStack {
                Text("셋업이 끝났는데도 wizard 가 보이나요? SSH 채널 인식 안 됐을 수 있어요.")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                Button {
                    Task { await shell.probeChannel() }
                } label: {
                    Label("채널 재탐색", systemImage: "arrow.clockwise")
                        .font(DFFont.caption)
                }
                .buttonStyle(.borderless)

                Button {
                    showSetupWizard = false
                } label: {
                    Label("셸로 건너뛰기", systemImage: "forward.fill")
                        .font(DFFont.caption)
                }
                .buttonStyle(.borderless)
                .help("셋업 무시하고 명령 패널로 — 채널은 SMB 가 됨")
            }
            .padding(DFSpace.sm)
            .background(DFColor.elev2)
        }
    }

    /// InitialSetupWizardView 가 환경에서 받을 ConnectionStore — RemoteShellView 도 받으므로 forward.
    @EnvironmentObject private var connectionStore: ConnectionStore
    private var shellStoreOrFallback: ConnectionStore { connectionStore }

    // MARK: - Quick actions

    private var quickActionsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 카테고리 picker (segmented).
            Picker("", selection: $selectedCategory) {
                ForEach(QuickActionCategory.allCases) { cat in
                    Label(cat.label, systemImage: cat.icon).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            // 액션 카드 그리드 — 가로 스크롤.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(QuickActionCatalog.actions(in: selectedCategory)) { action in
                        quickActionButton(action)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm)
        .background(DFColor.elev2)
    }

    private func quickActionButton(_ action: QuickAction) -> some View {
        Button {
            if action.requiresConfirm {
                confirmAction = action
            } else {
                Task { await shell.send(action.command) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: action.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(action.category.tint)
                    Text(action.label)
                        .font(.system(size: 11, weight: .semibold))
                    if action.requiresConfirm {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(DFColor.warning)
                    }
                }
                Text(action.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minWidth: 130, alignment: .leading)
            .background(action.category.tint.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(action.category.tint.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(action.command)
    }

    // MARK: - Header (DFPageScaffold가 대신함)

    /// 셋업 wizard / 셸 명령 모드 수동 전환.
    @ViewBuilder
    private var modeToggle: some View {
        Button {
            showSetupWizard = !(shouldShowSetupWizard)
        } label: {
            Label(shouldShowSetupWizard ? "셸 모드" : "셋업 가이드",
                  systemImage: shouldShowSetupWizard ? "terminal" : "sparkles")
                .font(DFFont.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(DFColor.card)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DFColor.textSecondary.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var mountChip: some View {
        HStack(spacing: 4) {
            channelChip
            if let path = shell.lastMountPath {
                Label(URL(fileURLWithPath: path).lastPathComponent,
                      systemImage: "externaldrive.fill")
                    .font(DFFont.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(DFColor.textSecondary.opacity(0.10))
                    .foregroundStyle(DFColor.textSecondary)
                    .clipShape(Capsule())
            }
        }
    }

    /// SSH(즉시) / SMB(폴링) 채널 표시 — 사용자가 응답 속도 인지.
    private var channelChip: some View {
        let (text, icon, tint): (String, String, Color) = {
            switch shell.activeChannel {
            case .ssh:     return ("SSH",      "bolt.fill",     DFColor.success)
            case .smb:     return ("SMB",      "tray.fill",     DFColor.warning)
            case .unknown: return ("탐색 중", "ellipsis.circle", DFColor.textSecondary)
            }
        }()
        return Label(text, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(Capsule())
            .help(channelHelp)
    }

    private var channelHelp: String {
        switch shell.activeChannel {
        case .ssh:     return "SSH 채널 — 30-80ms 즉시 응답 (key 인증 완료)"
        case .smb:     return "SMB watcher — 2초 폴링. SSH key 인증 셋업하면 즉시로 전환"
        case .unknown: return "채널 탐색 중…"
        }
    }

    // MARK: - Content (history)

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if shell.history.isEmpty {
                        emptyState
                            .padding(.top, DFSpace.lg)
                    } else {
                        ForEach(shell.history) { ex in
                            exchangeCard(ex).id(ex.id)
                        }
                    }
                }
                .padding(DFSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .glassScroll(accent: DFNeon.electric)
            .onChange(of: shell.history.count) { _, _ in
                if let last = shell.history.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("처음 사용 — 로봇 측 셋업이 필요해요",
                  systemImage: "wand.and.stars")
                .font(DFFont.bodyEmph)
                .foregroundStyle(DFColor.forge)

            Text("아래 한 블록을 로봇 VNC 터미널에 한 번만 붙여넣으세요. 그 후 부팅마다 자동.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)

            HStack(spacing: 8) {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(RobotSetupCommand.remoteShellSetup, forType: .string)
                    copyToast = "✓ 클립보드에 복사됨 — VNC 터미널에 붙여넣기"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { copyToast = nil }
                } label: {
                    Label("셋업 명령 복사", systemImage: "doc.on.clipboard.fill")
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(DFColor.forge)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if let msg = copyToast {
                    Text(msg).font(DFFont.caption).foregroundStyle(DFColor.success)
                }
                Spacer()
            }

            DisclosureGroup("셋업 명령 미리보기 (SMB watcher)") {
                Text(RobotSetupCommand.remoteShellSetup)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(DFColor.elev2)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .textSelection(.enabled)
            }
            .font(DFFont.caption)

            Divider().padding(.vertical, 4)

            // SSH 채널 추가 셋업 — 30배 빠른 응답.
            Label("⚡ 30배 빠른 응답 — SSH key 셋업", systemImage: "bolt.fill")
                .font(DFFont.bodyEmph)
                .foregroundStyle(DFColor.success)

            Text("위 SMB 셋업 후 Mac 터미널에서 한 번만 실행 — 그 다음부터 명령이 30-80ms 안에 응답합니다 (SMB 의 2초 대비).")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)

            HStack(spacing: 8) {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(SSHShell.keyAuthSetupCommand(host: shell.host, user: shell.username),
                                 forType: .string)
                    copyToast = "✓ Mac 터미널에 붙여넣기 (한 번만)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { copyToast = nil }
                } label: {
                    Label("SSH key 셋업 복사", systemImage: "key.fill")
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(DFColor.success)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    Task { await shell.probeChannel() }
                } label: {
                    Label("채널 재탐색", systemImage: "arrow.clockwise")
                        .font(DFFont.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(DFColor.card)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(DFColor.textSecondary.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            Divider().padding(.vertical, 6)

            Text("💡 빠르게 시도해 보기")
                .font(DFFont.bodyEmph)
            Text("셋업 완료 후 아래 입력에 `ls ~/Desktop` 을 보내보세요. 정상이면 1-2초 안에 파일 목록이 돌아옵니다.")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(DFSpace.md)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
    }

    private func exchangeCard(_ ex: RemoteShell.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: ex.error == nil ? "arrow.up.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ex.error == nil ? DFColor.accent : DFColor.danger)
                Text("명령")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                if let ms = ex.elapsedMs {
                    Text("\(ms)ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
            Text(ex.command)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DFColor.elev2)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)

            if let err = ex.error {
                Label(err, systemImage: "xmark.octagon.fill")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.danger)
                    .padding(.horizontal, 4)
            } else if let result = ex.result {
                Text("결과")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Text(result)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DFColor.success.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("실행 중…")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(10)
        .background(DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(DFColor.textSecondary.opacity(0.10), lineWidth: 0.5)
        )
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            presetRow
            HStack(alignment: .bottom, spacing: 8) {
                TextField("로봇에서 실행할 명령 (예: ls ~/Desktop, sudo /etc/init.d/df-inbox status)",
                          text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .background(DFColor.elev2)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onSubmit { sendNow() }

                Button {
                    sendNow()
                } label: {
                    Image(systemName: shell.isSending ? "ellipsis" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(canSend ? DFColor.accent : DFColor.textSecondary.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("실행 (⌘↩)")
            }
        }
        .padding(DFSpace.md)
        .background(.regularMaterial)
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                presetChip("inbox 상태", cmd: "sudo /etc/init.d/df-inbox status")
                presetChip("ttyUSB0 확인", cmd: "ls -la /dev/ttyUSB* 2>/dev/null; lsof /dev/ttyUSB0 2>/dev/null")
                presetChip("5530 listen", cmd: "ss -lnt | grep :5530 || netstat -lnt | grep :5530")
                presetChip("uptime / temp", cmd: "uptime; cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null")
                presetChip("disk / memory", cmd: "df -h ~ | tail -1; free -m | head -2")
                presetChip("ssh 시작", cmd: "sudo service ssh start && sudo update-rc.d ssh defaults")
                presetChip("framework 재시작", cmd: "sudo killall socat 2>/dev/null; sudo /etc/init.d/forge-bridge restart")
                Spacer()
            }
        }
    }

    private func presetChip(_ label: String, cmd: String) -> some View {
        Button {
            inputText = cmd
        } label: {
            Text(label)
                .font(.system(size: 10))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(DFColor.accent.opacity(0.10))
                .foregroundStyle(DFColor.accent)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DFColor.accent.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(cmd)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !shell.isSending
    }

    private func sendNow() {
        let text = inputText
        inputText = ""
        Task { await shell.send(text) }
    }
}
