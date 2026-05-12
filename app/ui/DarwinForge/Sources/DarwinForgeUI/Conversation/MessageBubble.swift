import SwiftUI

/// 4종 메시지 버블 — user / system / toolCall / error.
///
/// 근거:
/// - Claude.ai 패턴 — 사용자만 버블, system은 평문 흐름 (IntuitionLabs 비교)
/// - 토스 8원칙 #5 (입으로 말할 수 있는 표현) — 한국어 가독성 위해 버블 좌우 정렬
/// - LiquidGlassReference — 본문 layer는 솔리드 색상
public struct MessageBubble: View {
    public let message: ConversationViewModel.Message
    public let onApprove: () -> Void
    public let onReject: () -> Void

    public init(
        message: ConversationViewModel.Message,
        onApprove: @escaping () -> Void = {},
        onReject: @escaping () -> Void = {}
    ) {
        self.message = message
        self.onApprove = onApprove
        self.onReject = onReject
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            switch message.kind {
            case .user:
                Spacer(minLength: DFSpace.xxl)
                userBubble
            case .system:
                systemBubble
                Spacer(minLength: DFSpace.xxl)
            case .toolCall:
                toolCallCard
                Spacer(minLength: DFSpace.lg)
            case .error:
                errorBubble
                Spacer(minLength: DFSpace.xxl)
            }
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.xs)
    }

    // MARK: - User

    private var userBubble: some View {
        Text(message.text)
            .font(DFFont.body)
            .foregroundStyle(.white)
            .padding(.horizontal, DFSpace.md)
            .padding(.vertical, DFSpace.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.md, style: .continuous)
                    .fill(DFColor.accent)
            )
            .accessibilityLabel("사용자: \(message.text)")
    }

    // MARK: - System

    private var systemBubble: some View {
        HStack(alignment: .top, spacing: DFSpace.sm) {
            Image(systemName: "cpu")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DFColor.accent)
                .padding(.top, 2)
            Text(message.text)
                .font(DFFont.body)
                .foregroundStyle(DFColor.textPrimary)
                .textSelection(.enabled)
                .accessibilityLabel("로봇 응답: \(message.text)")
        }
    }

    // MARK: - Tool Call (HITL)

    private var toolCallCard: some View {
        DFCard(padding: DFSpace.md) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                HStack(spacing: DFSpace.sm) {
                    Image(systemName: "hand.tap.fill")
                        .foregroundStyle(DFColor.accent)
                    Text(message.text)
                        .font(DFFont.bodyEmph)
                    Spacer()
                    if let plan = message.pendingPlan {
                        StatusPill(
                            "신뢰도 \(Int(plan.confidence * 100))%",
                            severity: plan.confidence > 0.85 ? .success : .warning
                        )
                    }
                }
                Divider()
                if let plan = message.pendingPlan, !plan.args.isEmpty {
                    argsList(plan.args)
                    Divider()
                }
                Text("이 동작을 진행할까요? 닫기를 누르면 실행하지 않아요.")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                HStack(spacing: DFSpace.sm) {
                    Spacer()
                    Button(KoreanUX.Action.close, action: onReject)
                        .buttonStyle(.glassNeon(tint: DFColor.textPrimary, prominent: false))
                        .keyboardShortcut(".", modifiers: .command)
                    Button(KoreanUX.Action.execute, action: onApprove)
                        .buttonStyle(.glassNeon(tint: DFColor.accent))
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                        .disabled(message.resolved)
                }
            }
        }
        .frame(maxWidth: 540, alignment: .leading)
        .opacity(message.resolved ? 0.55 : 1.0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("도구 호출 제안: \(message.text)")
        .accessibilityHint("실행하려면 ⌘⇧A, 닫으려면 ⌘.")
    }

    @ViewBuilder
    private func argsList(_ args: [String: ArgValue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(args.keys.sorted(), id: \.self) { key in
                if let v = args[key] {
                    HStack(alignment: .firstTextBaseline) {
                        Text(humanLabelForArg(key))
                            .font(DFFont.caption.weight(.medium))
                            .foregroundStyle(DFColor.textSecondary)
                            .frame(width: 100, alignment: .leading)
                        Text(v.toDisplayString())
                            .font(DFFont.mono)
                            .foregroundStyle(DFColor.textPrimary)
                    }
                }
            }
        }
    }

    /// 인자 키를 한국어로 풀어 표기.
    private func humanLabelForArg(_ key: String) -> String {
        switch key {
        case "id": return "관절"
        case "position": return "보낼 위치"
        case "enable": return "켜기/끄기"
        case "lo": return "시작"
        case "hi": return "끝"
        case "path": return "파일"
        case "reason": return "이유"
        default: return key
        }
    }

    // MARK: - Error

    private var errorBubble: some View {
        HStack(alignment: .top, spacing: DFSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(DFColor.danger)
                .padding(.top, 2)
            Text(message.text)
                .font(DFFont.body)
                .foregroundStyle(DFColor.textPrimary)
                .padding(.horizontal, DFSpace.md)
                .padding(.vertical, DFSpace.sm)
                .background(
                    RoundedRectangle(cornerRadius: DFRadius.md, style: .continuous)
                        .fill(DFColor.danger.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.md, style: .continuous)
                        .stroke(DFColor.danger.opacity(0.4), lineWidth: 0.5)
                )
        }
        .accessibilityLabel("오류: \(message.text)")
    }
}
