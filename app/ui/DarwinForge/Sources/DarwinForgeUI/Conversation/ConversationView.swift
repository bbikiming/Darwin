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
    @State private var estopAck: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(commander: ClaudeCommander, dispatcher: IntentDispatcher) {
        _vm = StateObject(wrappedValue: ConversationViewModel(
            commander: commander, dispatcher: dispatcher
        ))
        self.dispatcher = dispatcher
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // 메인 콘텐츠
            VStack(spacing: 0) {
                topBar
                Divider()
                if vm.messages.isEmpty {
                    EmptyState(vm: vm)
                } else {
                    messageList
                }
                InputBar(vm: vm)
            }

            // L5 — E-Stop 좌상단 항상 가시 (모달 위에서도)
            EStopOverlay(dispatcher: dispatcher, ack: $estopAck)
                .allowsHitTesting(true)
        }
        .background(DFColor.canvas)
        .navigationTitle("DarwinForge")
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: DFSpace.md) {
            // 좌측 padding (E-Stop 아래)
            Color.clear.frame(width: DFSize.estop + DFSpace.lg, height: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("DarwinForge")
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(DFColor.textPrimary)
                Text("자연어로 로봇과 대화해 보세요")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }

            Spacer()

            ModeBadge(dispatcher: dispatcher)

            Button {
                vm.clear()
            } label: {
                Label("새 대화", systemImage: "square.and.pencil")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("새 대화 시작 (⌘⇧N)")
            .accessibilityLabel("새 대화 시작")
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm + 2)
        .background(.regularMaterial)
    }

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
