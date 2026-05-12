import SwiftUI

/// DarwinForge 대화형 메인 화면.
///
/// 7개 영역 조사 통합:
/// - Claude.ai/ChatGPT 메시지 흐름 + Anthropic HITL
/// - 토스 한국어 UX 라이팅 + KS 안전 색상
/// - ISO 13850 e-stop 좌상단 항상 가시
/// - macOS 14 SDK 호환 (Liquid Glass 폴백)
/// - Apple HIG NavigationSplitView + Material 폴백
public struct ConversationView: View {
    @StateObject private var vm: ConversationViewModel
    @ObservedObject public var dispatcher: IntentDispatcher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dfWindowWidth) private var winWidth

    public init(commander: ClaudeCommander, dispatcher: IntentDispatcher) {
        _vm = StateObject(wrappedValue: ConversationViewModel(
            commander: commander, dispatcher: dispatcher
        ))
        self.dispatcher = dispatcher
    }

    public var body: some View {
        // 비상 정지 overlay 는 사이드바의 [긴급 정지] 버튼 + ⌘⇧. 단축키로 대체.
        DFPageScaffold(
            "DarwinForge",
            subtitle: winWidth >= 700 ? "자연어로 로봇과 대화해 보세요" : nil,
            icon: "bubble.left.and.bubble.right.fill",
            tint: DFColor.info,
            trailing: {
                HStack(spacing: DFSpace.sm) {
                    if winWidth >= 600 {
                        ModeBadge(dispatcher: dispatcher)
                    }
                    Button {
                        vm.clear()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: DFFontSize.s14, weight: .medium))
                            .foregroundStyle(DFColor.accent)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help("새 대화 시작 (⌘⇧N)")
                }
            }
        ) {
            VStack(spacing: DFSpace.none) {
                if vm.messages.isEmpty {
                    EmptyState(vm: vm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    messageList
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)
                }
                InputBar(vm: vm)
            }
        }
        .navigationTitle("DarwinForge")
    }

    // MARK: - Top bar — DFPageScaffold 가 대체

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DFSpace.xs) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(
                            message: msg,
                            onApprove: { vm.approve(msg) },
                            onReject: { vm.reject(msg) }
                        )
                        .id(msg.id)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    }

                    if vm.isThinking {
                        thinkingIndicator
                            .padding(.horizontal, DFSpace.md)
                            .padding(.vertical, DFSpace.xs)
                            .id("thinking")
                    }
                }
                .padding(.vertical, DFSpace.md)
            }
            .glassScroll(accent: DFNeon.magenta, fadeHeight: 16)
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.isThinking) { _, thinking in
                if thinking {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
    }

    private var thinkingIndicator: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: true)
                .foregroundStyle(DFColor.accent)
            Text(KoreanUX.Progress.thinking)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
        .accessibilityLabel(KoreanUX.Progress.thinking)
    }
}
