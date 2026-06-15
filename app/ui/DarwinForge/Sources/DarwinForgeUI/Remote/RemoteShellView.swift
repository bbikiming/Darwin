import SwiftUI

/// SSH 기반 원격 명령 실행 패널 — UX 리디자인 (2026-06-13, 기획서 v1).
///
/// 구성: HSplitView 2열
///   - 좌: QuickActionPanel — 검색 + 최근 + 섹션 리스트 + 위험 명령 격리
///   - 우: RemoteConsoleView(실행 기록) + RemoteInputBar(자유 명령)
/// 원칙: 클릭과 결과가 같은 시야(콘솔 상시 노출) · 위험은 공간 격리 + 홀드 확인 ·
/// 정직한 결과(exit code 뱃지 — ACK ≠ 성공이라는 실기 브링업 교훈의 UI 버전).
///
/// 실행 시맨틱(승인 → shell.send → 히스토리)은 종전과 동일 — 라우팅만
/// QuickActionRunner 가 소유(티어 분기·실행 중 잠금·텔레메트리 시점).
public struct RemoteShellView: View {
    // RemoteShell 은 RootView 가 환경에 주입 (Sprint 18) — Pilot 등 다른 화면이
    // 같은 인스턴스를 공유하여 명령 히스토리가 통합됨.
    @EnvironmentObject private var shell: RemoteShell
    @EnvironmentObject private var connectionStore: ConnectionStore
    @StateObject private var runner = QuickActionRunner()
    @State private var confirmModel: ConfirmRequest?
    /// nil = 자동 (셋업 미완료면 가이드, 완료면 셸). true/false = 사용자 강제.
    @State private var showSetupWizard: Bool? = nil
    /// 컴팩트 폭에서 액션 패널 접기(⌘⇧A).
    @State private var panelVisible = true
    @Environment(\.dfWindowWidth) private var winWidth

    // MARK: - Harness DI (Wave 3 Phase 3.2, 사이클 242)
    @Environment(\.harness) private var harness

    public init() {}

    /// 확인 시트 요청 — 카탈로그 액션 또는 직접 입력 위험 명령(합성 액션).
    private struct ConfirmRequest: Identifiable {
        let id = UUID()
        let action: QuickAction
        /// true = 카탈로그 액션(runner 경유 — 상태 추적), false = 자유 명령.
        let viaRunner: Bool
    }

    /// 셋업 가이드 표시 여부 — SSH 채널 OK 면 자동 hide.
    private var shouldShowSetupWizard: Bool {
        if let forced = showSetupWizard { return forced }
        return shell.activeChannel != .ssh
    }

    private var isCompact: Bool { winWidth > 0 && winWidth < 820 }

    public var body: some View {
        DFPageScaffold(
            "원격 명령",
            subtitle: shouldShowSetupWizard
                ? "로봇 원격 구성을 단계별로 진행합니다"
                : "SSH 로 로봇에 명령을 보냅니다",
            icon: "terminal.fill",
            tint: DFColor.forge,
            trailing: { headerTrailing }
        ) {
            if shouldShowSetupWizard {
                setupWizardContent
            } else {
                shellContent
            }
        }
        .sheet(item: $confirmModel) { req in
            QuickActionConfirmSheet(
                model: QuickActionConfirmModel(action: req.action,
                                               contextLine: confirmContext(for: req.action)),
                onRun: {
                    confirmModel = nil
                    execute(req)
                },
                onCancel: { confirmModel = nil }
            )
        }
    }

    // MARK: - 셸 본문

    private var shellContent: some View {
        HSplitView {
            if panelVisible {
                QuickActionPanel(runner: runner, onTrigger: trigger(_:))
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            }
            VStack(spacing: DFSpace.none) {
                RemoteConsoleView(onRerun: rerun(_:))
                Divider()
                RemoteInputBar(onSubmit: submitFreeform(_:))
            }
            .frame(minWidth: 480, maxWidth: .infinity)
        }
        .background(
            // ⌘⇧A — 액션 패널 접기/펴기 (컴팩트 폭 대응).
            Button("") { withAnimation { panelVisible.toggle() } }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .opacity(0)
        )
        .onAppear { if isCompact { panelVisible = false } }
    }

    // MARK: - 실행 라우팅 (승인 → 실행 → 히스토리, 티어는 QuickAction.confirmTier)

    private func trigger(_ action: QuickAction) {
        switch action.confirmTier {
        case .none:
            execute(ConfirmRequest(action: action, viaRunner: true))
        case .sheet, .hold:
            confirmModel = ConfirmRequest(action: action, viaRunner: true)
        }
    }

    /// 콘솔 "다시 실행" — 카탈로그 매칭 시 해당 액션의 confirm 위계 재경유(기획 3.2).
    private func rerun(_ command: String) {
        if let action = QuickActionCatalog.action(command: command) {
            trigger(action)
        } else {
            submitFreeform(command)
        }
    }

    /// 자유 입력 — 위험 패턴이면 합성 confirm 경유(차단 아닌 1단계 마찰, 기획 3.5).
    private func submitFreeform(_ command: String) {
        if let catalogAction = QuickActionCatalog.action(command: command),
           catalogAction.confirmTier != .none {
            // 카탈로그 confirm 명령을 그대로 타이핑한 경우 — 동일 위계 적용.
            confirmModel = ConfirmRequest(action: catalogAction, viaRunner: true)
            return
        }
        if DangerCommandDetector.isDangerous(command) {
            let synthetic = QuickAction(
                id: "freeform-danger", category: .danger,
                label: "직접 입력 명령",
                detail: firstLine(command),
                icon: "keyboard",
                command: command,
                requiresConfirm: true,
                confirmSummary: "타이핑한 명령이 로봇 전원·연결에 영향을 줄 수 있습니다 — "
                    + "아래 '명령 보기'에서 내용을 확인하고 실행하세요.",
                confirmTitle: "위험할 수 있는 명령이에요",
                confirmVerb: "확인하고 실행")
            confirmModel = ConfirmRequest(action: synthetic, viaRunner: false)
            return
        }
        Task { await shell.send(command) }
    }

    private func execute(_ req: ConfirmRequest) {
        if req.viaRunner {
            Task { await runner.run(req.action, shell: shell, harness: harness) }
        } else {
            Task { await shell.send(req.action.command) }
        }
    }

    /// T3 확인 시트의 동적 컨텍스트 — 실행 직전 로봇이 어떤 상태인지(기획 5.3).
    private func confirmContext(for action: QuickAction) -> String? {
        guard action.confirmTier == .hold else { return nil }
        let channel: String = {
            switch shell.activeChannel {
            case .ssh: return "SSH 연결됨"
            case .unavailable: return "연결 없음"
            case .unknown: return "채널 탐색 중"
            }
        }()
        return "현재: \(channel) · \(connectionStore.currentMode.label) 모드"
    }

    private func firstLine(_ s: String) -> String {
        String(s.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    // MARK: - 헤더

    @ViewBuilder
    private var headerTrailing: some View {
        HStack(spacing: DFSpace.xs2) {
            channelPill
            if !shouldShowSetupWizard && isCompact {
                Button {
                    withAnimation { panelVisible.toggle() }
                } label: {
                    Label("명령 목록", systemImage: "sidebar.left")
                        .font(DFFont.caption)
                }
                .buttonStyle(.borderless)
                .help("액션 패널 접기/펴기 (⌘⇧A)")
            }
            modeToggle
        }
    }

    @ViewBuilder
    private var channelPill: some View {
        switch shell.activeChannel {
        case .ssh:
            DFStatusPill("SSH 연결됨", severity: .success, icon: "bolt.fill", compact: true)
                .help("SSH 채널 — 30-80ms 즉시 응답 (key 인증 완료)")
        case .unavailable:
            DFStatusPill("연결 없음", severity: .warning, icon: "bolt.slash.fill", compact: true)
                .help("SSH 연결 불가 — 로봇 전원과 유선 LAN 을 확인하고 '채널 재탐색'을 누르세요")
        case .unknown:
            DFStatusPill("탐색 중", severity: .neutral, icon: "ellipsis.circle", compact: true)
                .help("채널 탐색 중…")
        }
    }

    /// 셋업 가이드 / 셸 모드 수동 전환.
    private var modeToggle: some View {
        Button {
            let toMode = shouldShowSetupWizard ? "shell" : "wizard"
            harness.record(
                .remoteModeToggled,
                level: .info,
                actor: .user,
                data: ["to_mode": AnyCodable(toMode),
                       "source": AnyCodable("mode_toggle")]
            )
            showSetupWizard = !(shouldShowSetupWizard)
        } label: {
            Label(shouldShowSetupWizard ? "셸" : "셋업 가이드",
                  systemImage: shouldShowSetupWizard ? "terminal" : "sparkles")
                .font(DFFont.caption)
        }
        .dfPill(active: false, tint: DFColor.textSecondary)
        .buttonStyle(.plain)
    }

    // MARK: - 셋업 가이드

    private var setupWizardContent: some View {
        VStack(spacing: DFSpace.none) {
            InitialSetupWizardView()
                .environmentObject(connectionStore)
            Divider()
            HStack {
                Text("셋업이 끝났는데도 가이드가 보이나요? SSH 채널 인식이 안 됐을 수 있어요.")
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
                    harness.record(
                        .remoteModeToggled,
                        level: .info,
                        actor: .user,
                        data: ["to_mode": AnyCodable("shell"),
                               "source": AnyCodable("wizard_skip")]
                    )
                    showSetupWizard = false
                } label: {
                    Label("셸로 건너뛰기", systemImage: "forward.fill")
                        .font(DFFont.caption)
                }
                .buttonStyle(.borderless)
                .help("셋업을 건너뛰고 명령 패널로 — SSH 미연결이면 명령은 실패해요")
            }
            .padding(DFSpace.sm)
            .background(DFColor.elev2)
        }
    }
}
