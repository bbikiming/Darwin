import SwiftUI

/// 첫 진입 시 보여줄 환영 + 4개 추천 칩.
///
/// 근거: Mobbin Empty State 패턴 + Gemini 4-suggestion 카드 패턴 +
/// 토스 8원칙 — 능동형 권유, "이렇게 해 보세요".
public struct EmptyState: View {
    @ObservedObject public var vm: ConversationViewModel

    public init(vm: ConversationViewModel) { self.vm = vm }

    public var body: some View {
        VStack(spacing: DFSpace.lg) {
            Spacer()
            Image(systemName: "figure.stand")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(DFColor.accent.gradient)
                .symbolEffect(.pulse, options: .repeating, isActive: true)
            VStack(spacing: DFSpace.xs) {
                Text(KoreanUX.Welcome.greeting)
                    .font(DFFont.title)
                    .foregroundStyle(DFColor.textPrimary)
                Text(KoreanUX.Welcome.prompt)
                    .font(DFFont.body)
                    .foregroundStyle(DFColor.textSecondary)
            }

            // 4개 추천 칩
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: DFSpace.sm),
                GridItem(.flexible(), spacing: DFSpace.sm)
            ], spacing: DFSpace.sm) {
                ForEach(KoreanUX.Welcome.suggestions, id: \.self) { suggestion in
                    suggestionChip(suggestion)
                }
            }
            .frame(maxWidth: 480)

            Text(KoreanUX.Welcome.hint)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
                .padding(.top, DFSpace.md)

            Spacer()
        }
        .padding(.horizontal, DFSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            vm.sendSuggestion(text)
        } label: {
            HStack {
                Text(text)
                    .font(DFFont.body)
                    .foregroundStyle(DFColor.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DFColor.textSecondary)
            }
            .padding(.horizontal, DFSpace.md)
            .padding(.vertical, DFSpace.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.md, style: .continuous)
                    .fill(DFColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DFRadius.md, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("추천: \(text)")
        .accessibilityHint("탭하여 보내기")
    }
}
