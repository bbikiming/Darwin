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

    // MARK: - Harness DI (Wave 3 Phase 3.2, 사이클 242)
    //
    // 종전: `Harness.shared.record(...)` 직접 호출 → RecordingHarness 주입 불가.
    // 신규: init 시점에 HarnessFacade 주입 (default = LiveHarness.shared — 기존 호출
    //       site 무손상). 테스트는 RecordingHarness 주입으로 plan approve/reject/clear
    //       등 사용자 행동 telemetry 검증.
    //
    // **default arg = nil pattern**: LiveHarness.shared 는 @MainActor 격리. Swift 6
    // strict concurrency 에서 nonisolated default arg evaluation warning 회피용.
    private let harness: any HarnessFacade

    public init(commander: ClaudeCommander,
                dispatcher: IntentDispatcher,
                harness: (any HarnessFacade)? = nil) {
        self.commander = commander
        self.dispatcher = dispatcher
        self.harness = harness ?? LiveHarness.shared
    }

    // MARK: - Public actions

    /// 사용자가 입력 바에서 보낸 텍스트를 처리.
    public func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        inputText = ""
        messages.append(Message(kind: .user, text: text))
        // v1.12.0 telemetry — Claude 프롬프트 송신. PII 회피: 본문 X, 길이만.
        harness.record(
            .claudePromptSent, level: .info, actor: .user,
            data: ["text_length": AnyCodable(text.count),
                   "turn": AnyCodable(messages.count)]
        )
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
        // 사이클 181 (P1 #3.4 fix): HITL plan 승인 telemetry. PII 회피 — tool name 만.
        harness.record(
            .claudePlanApproved, level: .info, actor: .user,
            data: ["tool": AnyCodable(String(describing: plan.tool)),
                   "turn": AnyCodable(messages.count)]
        )
        Task { await runPlan(plan) }
    }

    /// 사용자 "닫기" 버튼 — toolCall 거부.
    public func reject(_ message: Message) {
        markResolved(message.id)
        // 사이클 181 (P1 #3.4 fix): HITL plan 거부 telemetry. tool name 만 — UX 분석 용.
        let tool = message.pendingPlan.map { String(describing: $0.tool) } ?? "unknown"
        harness.record(
            .claudePlanRejected, level: .info, actor: .user,
            data: ["tool": AnyCodable(tool),
                   "turn": AnyCodable(messages.count)]
        )
        messages.append(Message(kind: .system, text: "알겠어요. 그 명령은 실행하지 않을게요."))
    }

    public func clear() {
        // 사이클 181 (P1 #3.4 fix): clear 시 telemetry — 사용자 행동 분석 (혼란 / 재시작 등).
        let count = messages.count
        harness.record(
            .claudeSessionCleared, level: .info, actor: .user,
            data: ["messages_cleared": AnyCodable(count)]
        )
        messages.removeAll()
        lastError = nil
    }

    // MARK: - Internal

    private func processUserInput(_ text: String) async {
        isThinking = true
        defer { isThinking = false }

        do {
            let plan = try await commander.plan(userText: text)
            // **v1.14.2 (2026-05-21)** — Claude 응답 수신 telemetry. PII 회피 — plan
            // 본문은 X, tool 이름 / refuse 여부 / 확인 필요 여부만.
            harness.record(
                .claudeResponseReceived, level: .info, actor: .claude,
                data: ["tool": AnyCodable(String(describing: plan.tool)),
                       "needs_confirmation": AnyCodable(plan.needs_confirmation),
                       "is_refuse": AnyCodable(plan.tool == .refuse),
                       "turn": AnyCodable(messages.count)]
            )

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
            // **v1.14.2** — Claude 에러 telemetry. case 만 (메시지 본문 X).
            harness.record(
                .claudeError, level: .error, actor: .claude,
                data: ["error_case": AnyCodable(String(describing: err)),
                       "turn": AnyCodable(messages.count)]
            )
            handleClaudeError(err)
        } catch {
            let errMsg = error.localizedDescription
            harness.record(
                .claudeError, level: .error, actor: .claude,
                data: ["error_case": AnyCodable("parseFailed"),
                       "error_len": AnyCodable(errMsg.count),
                       "error_hash": AnyCodable(Harness.shortHash(errMsg)),
                       "turn": AnyCodable(messages.count)]
            )
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
            // 사이클 181 (P1 #3.4 fix): plan 성공 telemetry — 분석 용 (도구 별 성공률).
            harness.record(
                .claudePlanExecuted, level: .info, actor: .system,
                data: ["tool": AnyCodable(String(describing: plan.tool)),
                       "was_clipped": AnyCodable(result.wasClipped),
                       "turn": AnyCodable(messages.count)]
            )
        } catch let err as IntentDispatcher.DispatcherError {
            // 사이클 181 + 187 (codex MINOR fix): dispatcher 실패. error_case 는
            // enum case name 만 (cycle 187 — err.telemetryCase 신규). 종전
            // `String(describing: err)` 가 associated value (사용자 입력 본문) 노출.
            harness.record(
                .claudePlanExecutionFailed, level: .error, actor: .system,
                data: ["tool": AnyCodable(String(describing: plan.tool)),
                       "error_case": AnyCodable(err.telemetryCase)]
            )
            messages.append(Message(kind: .error, text: err.errorDescription ?? "알 수 없는 오류예요"))
        } catch {
            harness.record(
                .claudePlanExecutionFailed, level: .error, actor: .system,
                data: ["tool": AnyCodable(String(describing: plan.tool)),
                       "error_case": AnyCodable("generic")]
            )
            messages.append(Message(kind: .error, text: error.localizedDescription))
        }
    }

    private func handleClaudeError(_ err: ClaudeCommander.CommanderError) {
        let msg: KoreanUX.ErrorMessage
        switch err {
        case .cliNotFound:
            msg = KoreanUX.Errors.claudeNotInstalled
        case .notLoggedIn:
            msg = KoreanUX.ErrorMessage(
                title: "Claude 로그인이 필요해요",
                body: "Mac 터미널에서 다음을 한 번만 실행한 뒤 다시 시도하세요:\n\n  claude /login\n\n브라우저가 열리면 Anthropic 계정으로 인증하세요. 토큰은 이후 자동 저장됩니다.",
                action: KoreanUX.Action.retry,
                rawDetail: err.localizedDescription
            )
        case .nonZeroExit(_, let stderr) where stderr.contains("auth") || stderr.contains("login"):
            msg = KoreanUX.Errors.claudeAuthExpired
        case .nonZeroExit(_, let stderr) where stderr.contains("rate") || stderr.contains("429"):
            msg = KoreanUX.Errors.claudeRateLimit
        case .invalidPlan, .invalidWrapper:
            msg = KoreanUX.Errors.parseFailed
        default:
            // 2026-05-17 UX audit: 무의미 "오류가 발생했어요" → 구체적 원인 + 행동 가능 안내.
            msg = KoreanUX.ErrorMessage(
                title: err.errorDescription ?? "응답을 받지 못했어요",
                body: "네트워크 연결을 확인하고 다시 보내 주세요.",
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
