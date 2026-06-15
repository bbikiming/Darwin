import SwiftUI

/// 하단 자유 명령 입력바 — mono 입력 + ↑/↓ 히스토리 순환 + 위험 명령 감지 훅.
///
/// 프리셋 칩 행은 폐지(기획 1.3): 카탈로그와 중복이었고, 확인 대상 명령을 무확인
/// 경로로 우회시켰다. 반복 입력은 ↑/↓ 히스토리와 "최근" 섹션이 대체한다.
struct RemoteInputBar: View {
    @EnvironmentObject private var shell: RemoteShell
    /// 전송 요청 — 위험 감지·confirm 경유는 부모(RemoteShellView)가 소유.
    let onSubmit: (String) -> Void

    @State private var inputText: String = ""
    /// ↑/↓ 히스토리 커서 — nil = 현재 입력(미순환).
    @State private var historyCursor: Int? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: DFSpace.sm) {
            TextField(shell.isSending ? "실행 중 — 응답 대기"
                                      : "셸 명령 입력 — ↑로 이전 명령",
                      text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .font(.system(size: DFFontSize.s13, design: .monospaced))
                .padding(DFSpace.sm)
                .background(DFColor.elev2)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                .focused($focused)
                .onSubmit { sendNow() }
                .onKeyPress(.upArrow) { cycleHistory(+1) ? .handled : .ignored }
                .onKeyPress(.downArrow) { cycleHistory(-1) ? .handled : .ignored }
                .background(
                    // ⌘L → 입력창 포커스 (터미널 관례).
                    Button("") { focused = true }
                        .keyboardShortcut("l", modifiers: .command)
                        .opacity(0)
                )

            Button { sendNow() } label: {
                Group {
                    if shell.isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: DFFontSize.s14, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: DFSize.iconXl, height: DFSize.iconXl)
                .background(Circle().fill(canSend ? DFColor.accent
                                                  : DFColor.textSecondary.opacity(DFOpacity.o30)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .help("실행 (⌘↩)")
        }
        .padding(DFSpace.md)
        .background(.regularMaterial)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !shell.isSending
    }

    private func sendNow() {
        guard canSend else { return }
        let text = inputText
        inputText = ""
        historyCursor = nil
        onSubmit(text)
    }

    /// ↑/↓ 히스토리 순환. 멀티라인 편집 중(커서 이동 필요)에는 개입하지 않는다 —
    /// 입력이 비었거나 직전 순환 결과 그대로일 때만 가로챈다.
    private func cycleHistory(_ delta: Int) -> Bool {
        let commands = shell.history.map(\.command)
        guard !commands.isEmpty else { return false }
        let editingFreely = historyCursor == nil && !inputText.isEmpty
        guard !editingFreely else { return false }

        let next: Int
        if let cur = historyCursor {
            next = cur + delta
        } else {
            next = delta > 0 ? commands.count - 1 : commands.count
        }
        if next >= commands.count || next < 0 {
            // 끝을 넘으면 현재 입력으로 복귀.
            historyCursor = nil
            inputText = ""
            return true
        }
        historyCursor = next
        inputText = commands[next]
        return true
    }
}
