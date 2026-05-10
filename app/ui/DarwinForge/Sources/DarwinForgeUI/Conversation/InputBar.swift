import SwiftUI

/// 메시지 입력 바 — 텍스트 + 보내기 + (음성 후속).
///
/// 근거:
/// - ChatGPT/Claude.ai — TextField axis=.vertical, ⌘↩ 보내기, ⇧↩ 줄바꿈
/// - Wispr Flow — 음성 입력 진입 (Phase 4)
/// - 토스 8원칙 — placeholder도 친절하게
public struct InputBar: View {
    @ObservedObject public var vm: ConversationViewModel
    @FocusState private var focused: Bool

    public init(vm: ConversationViewModel) { self.vm = vm }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: DFSpace.sm) {
                // 음성 버튼 (Phase 4 — 현재 비활성)
                voiceButton
                // 텍스트 입력
                TextField(
                    "로봇에게 한국어로 말해 보세요. 예: '왼팔 들어'",
                    text: $vm.inputText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .font(DFFont.body)
                .padding(.vertical, DFSpace.sm)
                .padding(.horizontal, DFSpace.md)
                .background(
                    RoundedRectangle(cornerRadius: DFRadius.md, style: .continuous)
                        .fill(DFColor.elev2)
                )
                .onSubmit { vm.send() }
                .accessibilityLabel("로봇 명령 입력")

                // 보내기 버튼 (⌘↩)
                Button(action: vm.send) {
                    if vm.isThinking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(canSend ? DFColor.accent : DFColor.textSecondary.opacity(0.3))
                )
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("보내기 (⌘↩)")
                .accessibilityLabel(KoreanUX.Action.send)
            }
            .padding(DFSpace.md)
            .background(.regularMaterial)
        }
        .onAppear { focused = true }
    }

    private var canSend: Bool {
        !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.isThinking
    }

    private var voiceButton: some View {
        Button {
            // Phase 4 — WhisperKit / SpeechAnalyzer
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
        .disabled(true)
        .help("음성 입력 (준비 중)")
        .accessibilityLabel("음성 입력")
        .accessibilityHint("준비 중인 기능이에요")
    }
}
