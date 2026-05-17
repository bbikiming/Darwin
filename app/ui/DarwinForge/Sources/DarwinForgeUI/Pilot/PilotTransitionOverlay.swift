import SwiftUI

/// Pilot 모드 전환 시 표시되는 단계별 진행 모달.
///
/// **목적**: 사용자가 "공 자동 추적" 등 모드를 바꾸면 무엇이 자동으로 진행 중인지,
/// 어디서 사용자가 로봇 후면 버튼을 눌러야 하는지 단계별로 명확히 표시.
///
/// 사용 시점:
///   - RemotePilotView 가 mode 변경 → `currentSteps` 채움 → overlay 표시.
///   - 각 단계 완료 / 실패 시 RemotePilotView 가 `markStep` 호출.
///   - 모든 단계 완료 시 자동 dismiss.
public struct PilotTransitionOverlay: View {
    let title: String
    let steps: [PilotTransitionStep]
    /// 현재 진행 중인 step 의 index — nil 이면 모두 완료.
    let activeIndex: Int?
    /// 사용자가 .waitingForUser 단계에서 "확인" 누르면 호출 — RemotePilotView 가 다음 step 으로.
    let onAdvance: () -> Void
    let onCancel: () -> Void

    public init(title: String, steps: [PilotTransitionStep],
                activeIndex: Int?,
                onAdvance: @escaping () -> Void = {},
                onCancel: @escaping () -> Void) {
        self.title = title
        self.steps = steps
        self.activeIndex = activeIndex
        self.onAdvance = onAdvance
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            header
            Divider()
            stepsList
            Divider()
            progressFooter
        }
        .padding(DFSpace.lg)
        .frame(width: 480)
        .background(
            RoundedRectangle(cornerRadius: DFRadius.lg)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.lg)
                .stroke(DFColor.accent.opacity(DFOpacity.o25), lineWidth: 0.5)
        )
        .accessibilityIdentifier("pilot.transition.overlay")
    }

    private var header: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: DFFontSize.s22))
                .foregroundStyle(DFColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DFFont.title)
                    .foregroundStyle(DFColor.textPrimary)
                Text(subtitle)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer(minLength: 0)
            Button("취소") { onCancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(!cancellable)
        }
    }

    /// 사용자 액션 대기 단계는 cancel 허용 — 그 외 자동 단계는 cancel 비활성.
    private var cancellable: Bool {
        guard let i = activeIndex, steps.indices.contains(i) else { return true }
        if case .waitingForUser = steps[i].kind { return true }
        return false
    }

    private var subtitle: String {
        if let i = activeIndex, steps.indices.contains(i) {
            return "단계 \(i + 1) / \(steps.count) — \(steps[i].title)"
        }
        return "모든 단계 완료"
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                stepRow(index: idx, step: step)
            }
        }
    }

    @ViewBuilder
    private func stepRow(index: Int, step: PilotTransitionStep) -> some View {
        let isActive = activeIndex == index
        let state = stateFor(index: index, step: step)
        HStack(alignment: .top, spacing: DFSpace.sm) {
            indicator(state: state, isActive: isActive)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DFSpace.xs2) {
                    Text("\(index + 1).")
                        .font(DFFont.bodyEmph.monospaced())
                        .foregroundStyle(DFColor.textSecondary)
                    Text(step.title)
                        .font(DFFont.bodyEmph)
                        .foregroundStyle(titleColor(state: state, isActive: isActive))
                    if case .waitingForUser = step.kind, isActive {
                        UserActionPulse()
                    }
                }
                Text(step.detail)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let reason) = step.kind {
                    Text("실패: \(reason)")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.danger)
                }
            }
        }
        .padding(.horizontal, DFSpace.sm)
        .padding(.vertical, DFSpace.xs2)
        .background(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .fill(isActive ? DFColor.accent.opacity(DFOpacity.o10) : Color.clear)
        )
    }

    /// 각 단계의 시각 상태 (completed / inProgress / waiting / pending / failed).
    private enum StepState {
        case pending, inProgress, waitingForUser, completed, failed
    }

    private func stateFor(index: Int, step: PilotTransitionStep) -> StepState {
        if case .failed = step.kind { return .failed }
        if case .completed = step.kind { return .completed }
        guard let active = activeIndex else { return .completed }   // 전부 종료.
        if index < active { return .completed }
        if index == active {
            if case .waitingForUser = step.kind { return .waitingForUser }
            return .inProgress
        }
        return .pending
    }

    @ViewBuilder
    private func indicator(state: StepState, isActive: Bool) -> some View {
        switch state {
        case .pending:
            Circle()
                .stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: 1.5)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .tint(DFColor.accent)
        case .waitingForUser:
            ZStack {
                Circle()
                    .fill(DFColor.warning.opacity(DFOpacity.o25))
                Image(systemName: "hand.point.up.fill")
                    .font(.system(size: DFFontSize.s14, weight: .bold))
                    .foregroundStyle(DFColor.warning)
            }
        case .completed:
            ZStack {
                Circle().fill(DFColor.success.opacity(DFOpacity.o15))
                Image(systemName: "checkmark")
                    .font(.system(size: DFFontSize.s14, weight: .bold))
                    .foregroundStyle(DFColor.success)
            }
        case .failed:
            ZStack {
                Circle().fill(DFColor.danger.opacity(DFOpacity.o15))
                Image(systemName: "xmark")
                    .font(.system(size: DFFontSize.s14, weight: .bold))
                    .foregroundStyle(DFColor.danger)
            }
        }
    }

    private func titleColor(state: StepState, isActive: Bool) -> Color {
        switch state {
        case .pending:        return DFColor.textSecondary
        case .inProgress:     return DFColor.accent
        case .waitingForUser: return DFColor.warning
        case .completed:      return DFColor.textPrimary.opacity(DFOpacity.o70)
        case .failed:         return DFColor.danger
        }
    }

    // MARK: - Progress footer

    private var progressFooter: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            HStack {
                Text("진행률")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                Text("\(completedCount) / \(steps.count)")
                    .font(DFFont.caption.monospaced())
                    .foregroundStyle(DFColor.textPrimary)
            }
            ProgressView(value: progressFraction)
                .tint(progressColor)

            // 사용자 액션 단계일 때만 "확인" 버튼 — 후면 버튼 눌렀음을 사용자가 알려줌.
            if let i = activeIndex,
               steps.indices.contains(i),
               case .waitingForUser = steps[i].kind {
                HStack {
                    Spacer()
                    Button {
                        onAdvance()
                    } label: {
                        HStack(spacing: DFSpace.xs) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("후면 버튼 눌렀음 — 다음 단계")
                                .font(DFFont.bodyEmph)
                        }
                        .padding(.horizontal, DFSpace.md)
                        .padding(.vertical, DFSpace.xs2)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(DFColor.warning))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                    .accessibilityIdentifier("pilot.transition.advance")
                }
            }
        }
    }

    private var completedCount: Int {
        steps.indices.filter { stateFor(index: $0, step: steps[$0]) == .completed }.count
    }

    private var progressFraction: Double {
        guard !steps.isEmpty else { return 1.0 }
        return Double(completedCount) / Double(steps.count)
    }

    private var progressColor: Color {
        if steps.contains(where: { if case .failed = $0.kind { return true } else { return false } }) {
            return DFColor.danger
        }
        if activeIndex == nil { return DFColor.success }
        return DFColor.accent
    }
}

/// 사용자가 로봇 후면 버튼을 눌러야 하는 단계에 표시되는 작은 펄스 — UX 의도 명확화.
///
/// 2026-05-17 a11y audit CRITICAL fix (WCAG 2.3.3 vestibular + 2.3.1 광과민성):
/// Reduce Motion ON 시 펄스 정지. 정적 빨간 점만 유지 (의미 보존).
private struct UserActionPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DFColor.warning)
                .frame(width: 8, height: 8)
                .scaleEffect(reduceMotion ? 1.0 : (pulsing ? 1.4 : 0.9))
                .opacity(reduceMotion ? 1.0 : (pulsing ? 0.6 : 1.0))
            Text("로봇 만지기")
                .font(.system(size: DFFontSize.s9, weight: .bold))
                .foregroundStyle(DFColor.warning)
        }
        .padding(.horizontal, DFSpace.xs2)
        .padding(.vertical, 2)
        .background(Capsule().fill(DFColor.warning.opacity(DFOpacity.o15)))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}
