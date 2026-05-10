import Foundation
import SwiftUI

/// 대화 화면의 상태 모델 — `@Observable` 대안으로 ObservableObject 사용 (macOS 14 호환).
///
/// 근거: DEV SwiftUI streaming guide + Anthropic tool_use HITL 패턴 +
/// LangGraph 4-way (approve/edit/reject/respond) 차용.
@MainActor
public final class ConversationViewModel: ObservableObject {

    public enum BubbleKind: String, Sendable {
        case user
        case system
        case toolCall    // 사용자 승인 대기
        case error
    }

    public struct Message: Identifiable, Sendable, Equatable {
        public let id: UUID = UUID()
        public let kind: BubbleKind
        public var text: String
        /// toolCall 일 때만 존재 — 승인 대기 중인 plan.
        public var pendingPlan: CommandPlan?
        /// toolCall 처리 후 결과 메시지 ID로 연결.
        public var resolved: Bool = false
        public let timestamp: Date = .init()

        public init(kind: BubbleKind, text: String, pendingPlan: CommandPlan? = nil) {
            self.kind = kind
            self.text = text
            self.pendingPlan = pendingPlan
        }

        public static func == (lhs: Message, rhs: Message) -> Bool {
            lhs.id == rhs.id
        }
    }

    @Published public var messages: [Message] = []
    @Published public var inputText: String = ""
    @Published public var isThinking: Bool = false
    @Published public var lastError: KoreanUX.ErrorMessage?

    private let commander: ClaudeCommander
    private let dispatcher: IntentDispatcher

    public init(commander: ClaudeCommander, dispatcher: IntentDispatcher) {
        self.commander = commander
        self.dispatcher = dispatcher
    }

    // MARK: - Public actions

    /// 사용자가 입력 바에서 보낸 텍스트를 처리.
    public func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        inputText = ""
        messages.append(Message(kind: .user, text: text))
        Task { await processUserInput(text) }
    }

    /// 사용자가 빈 상태에서 추천 칩을 탭한 경우.
    public func sendSuggestion(_ s: String) {
        inputText = s
        send()
    }

    /// 사용자 "실행" 버튼 — toolCall 메시지를 dispatcher로 보냄.
    public func approve(_ message: Message) {
        guard let plan = message.pendingPlan else { return }
        markResolved(message.id)
        Task { await runPlan(plan) }
    }

    /// 사용자 "닫기" 버튼 — toolCall 거부.
    public func reject(_ message: Message) {
        markResolved(message.id)
        messages.append(Message(kind: .system, text: "알겠어요. 그 명령은 실행하지 않을게요."))
    }

    public func clear() {
        messages.removeAll()
        lastError = nil
    }

    // MARK: - Internal

    private func processUserInput(_ text: String) async {
        isThinking = true
        defer { isThinking = false }

        do {
            let plan = try await commander.plan(userText: text)

            if plan.tool == .refuse {
                let reason = plan.args["reason"]?.stringValue ?? plan.speak
                messages.append(Message(kind: .system, text: reason.isEmpty ? plan.speak : reason))
                return
            }

            if plan.needs_confirmation {
                // HITL — 사용자 승인 대기.
                messages.append(Message(kind: .system, text: plan.speak))
                messages.append(Message(kind: .toolCall, text: plan.tool.koreanLabel, pendingPlan: plan))
            } else {
                // 즉시 실행 (정보 조회 또는 비상 정지).
                messages.append(Message(kind: .system, text: plan.speak))
                await runPlan(plan)
            }
        } catch let err as ClaudeCommander.CommanderError {
            handleClaudeError(err)
        } catch {
            messages.append(Message(kind: .error, text: KoreanUX.Errors.parseFailed.title))
            lastError = KoreanUX.Errors.parseFailed
        }
    }

    private func runPlan(_ plan: CommandPlan) async {
        do {
            let result = try await dispatcher.execute(plan)
            // 결과 메시지 — clip 알림 추가
            var displayText = result.speak
            if result.wasClipped {
                displayText += "\n· 안전 범위로 자동 조정됐어요."
            }
            messages.append(Message(kind: .system, text: displayText))
        } catch let err as IntentDispatcher.DispatcherError {
            messages.append(Message(kind: .error, text: err.errorDescription ?? "알 수 없는 오류예요"))
        } catch {
            messages.append(Message(kind: .error, text: error.localizedDescription))
        }
    }

    private func handleClaudeError(_ err: ClaudeCommander.CommanderError) {
        let msg: KoreanUX.ErrorMessage
        switch err {
        case .cliNotFound:
            msg = KoreanUX.Errors.claudeNotInstalled
        case .nonZeroExit(_, let stderr) where stderr.contains("auth") || stderr.contains("login"):
            msg = KoreanUX.Errors.claudeAuthExpired
        case .nonZeroExit(_, let stderr) where stderr.contains("rate") || stderr.contains("429"):
            msg = KoreanUX.Errors.claudeRateLimit
        case .invalidPlan, .invalidWrapper:
            msg = KoreanUX.Errors.parseFailed
        default:
            msg = KoreanUX.ErrorMessage(
                title: err.errorDescription ?? "오류가 발생했어요",
                body: "잠시 후 다시 시도해 주세요.",
                action: KoreanUX.Action.retry,
                rawDetail: err.localizedDescription
            )
        }
        messages.append(Message(kind: .error, text: msg.title))
        lastError = msg
    }

    private func markResolved(_ id: UUID) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].resolved = true
        }
    }
}
