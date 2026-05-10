import ForgeCore
import SwiftUI

/// DarwinForge 앱 메인 컨테이너.
///
/// **새 1차 인터페이스**: 자연어 대화창 (`ConversationView`).
/// **2차**: 기존 5탭 전문가 콘솔 (Connection / Board / Joint / Motion / Walk / Strategy).
///
/// 토글: ⌘⇧E 단축키 또는 사이드바 첫 항목 선택.
public struct RootView: View {
    @StateObject private var store = ConnectionStore()
    @StateObject private var dispatcher: IntentDispatcher
    private let commander: ClaudeCommander

    @State private var section: Section = .conversation
    @State private var expertTab: ExpertTab = .board

    public init() {
        let d = IntentDispatcher()
        _dispatcher = StateObject(wrappedValue: d)
        self.commander = ClaudeCommander()
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
                .frame(minWidth: 720, minHeight: 540)
        }
        .onAppear {
            dispatcher.connectionStore = store
            dispatcher.mode = store.bus != nil ? .hardware : .simulation
        }
        .onReceive(store.$bus) { bus in
            dispatcher.mode = bus != nil ? .hardware : .simulation
        }
        .environmentObject(store)
        .environmentObject(dispatcher)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DarwinForge")
                    .font(DFFont.title)
                Text("자연어 로봇 조종")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            .padding(.horizontal, DFSpace.md)
            .padding(.top, DFSpace.md)
            .padding(.bottom, DFSpace.sm)

            // 1차 — 대화
            sidebarRow(
                section: .conversation,
                icon: "bubble.left.and.bubble.right.fill",
                label: "대화",
                shortcut: "⌘1"
            )

            Divider()
                .padding(.vertical, DFSpace.xs)

            // 2차 — 전문가 모드
            Text("전문가 모드")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .padding(.horizontal, DFSpace.md)
                .padding(.top, DFSpace.xs)

            ForEach(ExpertTab.allCases) { tab in
                Button {
                    section = .expert
                    expertTab = tab
                } label: {
                    Label(tab.label, systemImage: tab.icon)
                        .font(DFFont.body)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DFSpace.md)
                .padding(.vertical, 2)
                .background(
                    (section == .expert && expertTab == tab)
                        ? DFColor.accent.opacity(0.12)
                        : Color.clear
                )
                .foregroundStyle(
                    (section == .expert && expertTab == tab)
                        ? DFColor.accent
                        : DFColor.textPrimary
                )
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm, style: .continuous))
                .padding(.horizontal, DFSpace.sm)
            }

            Spacer()

            versionFooter
        }
        .frame(minWidth: 240, idealWidth: 260)
    }

    private func sidebarRow(section target: Section, icon: String, label: String, shortcut: String) -> some View {
        Button {
            self.section = target
        } label: {
            HStack {
                Label(label, systemImage: icon)
                    .font(DFFont.bodyEmph)
                Spacer()
                Text(shortcut)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            .padding(.vertical, DFSpace.xs + 2)
            .padding(.horizontal, DFSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                section == target ? DFColor.accent.opacity(0.15) : Color.clear
            )
            .foregroundStyle(section == target ? DFColor.accent : DFColor.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DFSpace.sm)
        .keyboardShortcut("1", modifiers: .command)
    }

    private var versionFooter: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: "cube.box")
                .font(.system(size: 11))
            Text("forge-core \(forgeCoreVersion())")
                .font(DFFont.caption.monospaced())
        }
        .foregroundStyle(DFColor.textSecondary)
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        switch section {
        case .conversation:
            ConversationView(commander: commander, dispatcher: dispatcher)
        case .expert:
            expertDetail(expertTab)
        }
    }

    @ViewBuilder
    private func expertDetail(_ tab: ExpertTab) -> some View {
        switch tab {
        case .board: BoardStatusView()
        case .joints: JointControlView()
        case .motion: MotionLibraryView()
        case .walk: WalkSimView()
        case .strategy: StrategyView()
        }
    }
}

// MARK: - Sections

private enum Section: Hashable {
    case conversation, expert
}

private enum ExpertTab: String, CaseIterable, Identifiable, Hashable {
    case board, joints, motion, walk, strategy
    var id: String { rawValue }

    var label: String {
        switch self {
        case .board: return "보드 상태"
        case .joints: return "관절 제어"
        case .motion: return "동작 라이브러리"
        case .walk: return "보행 시뮬"
        case .strategy: return "전략 FSM"
        }
    }

    var icon: String {
        switch self {
        case .board: return "cpu"
        case .joints: return "slider.horizontal.3"
        case .motion: return "play.rectangle.on.rectangle"
        case .walk: return "figure.walk"
        case .strategy: return "brain.head.profile"
        }
    }
}
