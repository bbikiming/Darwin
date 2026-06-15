import SwiftUI

/// **v1.11.12 (2026-05-19)** — Critic 권고 → 사용자 명시 승인 → ExperimentLoop start.
///
/// 진단 문서 §4 critic-controller 분리 + Agent 5 architect 설계.
///
/// # V280-B (2026-05-24) — 3-step Wizard 패턴 도입
///
/// 비유: 11 section sheet = "한 페이지 11 단락 계약서". 사용자가 어디부터 봐야 할지 막막.
/// Wizard 패턴 = "계약서 11 단락을 3 페이지로 분권". 한 페이지에 3-4 단락만 보임.
///
/// 사용자 mental model (Norman 1988):
/// 1. "이게 뭔가?" → preview step (header / experimentPreview / confidenceFooter)
/// 2. "위험한가?" → safety step (safetyNotice / safetyVerdictPreview / risk / validation / walkingNotIdle)
/// 3. "승인하나?" → approve step (metricsRow / advancedAutoEnable / buttonRow)
///
/// Hick's Law: 11 → 3 step 분할로 각 step 의 인지 부하 ↓ (49pt/section → 120pt/section, breathing).
///
/// Material 3 Stepper + Polaris Wizard: linear progression + 진행 인디케이터 + 이전/다음 navigation.
///
/// sheet UI (step 별):
/// - Step 1 (1/3 · 미리보기): critic 의 nextExperiment + axis 변경 + confidence
/// - Step 2 (2/3 · 안전 확인): safetyVerdict + cradle/tether + risk + validation
/// - Step 3 (3/3 · 승인): success metric + rollback + advanced 자동 활성 + 실험 시작 버튼
public struct ExperimentApprovalUI: View {

    // MARK: - Wizard step (V280-B)

    /// Wizard step enum — 사용자 mental model 순서 (preview → safety → approve).
    public enum WizardStep: Int, CaseIterable, Hashable {
        case preview = 1, safety = 2, approve = 3

        /// 상단 인디케이터에 표시할 step 라벨 ("1/3 · 미리보기").
        var label: String {
            switch self {
            case .preview: return "미리보기"
            case .safety:  return "안전 확인"
            case .approve: return "승인"
            }
        }

        /// 다음 step (.approve 면 nil).
        var next: WizardStep? {
            switch self {
            case .preview: return .safety
            case .safety:  return .approve
            case .approve: return nil
            }
        }

        /// 이전 step (.preview 면 nil).
        var previous: WizardStep? {
            switch self {
            case .preview: return nil
            case .safety:  return .preview
            case .approve: return .safety
            }
        }
    }

    /// 현재 step (default = .preview, mental model 첫 질문).
    @State private var currentStep: WizardStep = .preview

    public let response: ClaudeCriticResponse
    public let baselineSessionId: String
    /// **v1.11.14.3 (2026-05-19) — 진단 cold #F fix**: closure 로 변경.
    /// 종전 immutable struct field — sheet 열어둔 채 외부에서 session.config 변경 시
    /// stale. closure 는 body 재평가 시마다 호출되어 최신 session 값 반영.
    private let proposedConfigProvider: () -> BalanceExperimentConfig
    private let validationResultProvider: () -> ClaudeCriticResponse.ValidationResult?
    /// **v1.11.14.4 — cold 3차 HIGH 5**: session 을 명시적으로 observe.
    /// 종전 closure 로만 의존성 표시 — SwiftUI body 재평가 trigger 가 외부 view 의
    /// re-eval 에 의존. 본 view 가 session 직접 @EnvironmentObject 로 받으면
    /// session.@Published 변경 시 본 view body 자체가 재평가 → closure 재호출 보장.
    @Environment(WalkLabSession.self) private var session
    /// **v1.11.14.6 (2026-05-19)** — 테마 통합. flat 모드에서 sheet 배경 #FFFFFF 사용.
    /// 종전: DFColor 직접 사용으로 light 의 #F2F2F7 표시 → flat 의도와 불일치.
    @Environment(\.dfTheme) private var theme: DFTheme
    public let onApprove: () -> Void
    public let onCancel: () -> Void

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

    /// **v1.11.14.3 신 init**: closure 기반 — dynamic 재계산.
    public init(response: ClaudeCriticResponse,
                baselineSessionId: String,
                proposedConfig: @escaping @autoclosure () -> BalanceExperimentConfig,
                validationResult: @escaping @autoclosure () -> ClaudeCriticResponse.ValidationResult? = nil,
                onApprove: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.response = response
        self.baselineSessionId = baselineSessionId
        self.proposedConfigProvider = proposedConfig
        self.validationResultProvider = validationResult
        self.onApprove = onApprove
        self.onCancel = onCancel
    }

    /// 현재 proposed config (body 평가 시 매번 재계산).
    private var proposedConfig: BalanceExperimentConfig { proposedConfigProvider() }
    /// 현재 validation 결과 (body 평가 시 매번 재계산).
    private var validationResult: ClaudeCriticResponse.ValidationResult? { validationResultProvider() }

    public var body: some View {
        // v1.11.14.4: session 의 @Published 값 명시 read — SwiftUI subscription 보장.
        // 종전 closure-only 의존성 — SwiftUI 가 본 view 의 body 재평가 trigger 못 잡을
        // 위험. 직접 read 로 dependency tracking 강제.
        let _ = session.balanceExperimentConfig
        let _ = session.hipPitchOffsetTrimDeg
        return VStack(alignment: .leading, spacing: DFSpace.sm) {
            header
            stepperIndicator
            Divider()
            currentStepContent
            Spacer()
            wizardButtonRow
        }
        .padding(DFSpace.md)
        .frame(minWidth: 520, minHeight: 540, idealHeight: 620)
        // v1.11.14.6: 테마 통합 — flat 시 #FFFFFF, 그 외 default light/dark.
        .background(DFColor.adaptiveCanvas(theme))
    }

    // MARK: - Wizard step content dispatcher (V280-B)

    /// 현재 step 에 해당하는 sub-view 만 노출. 한 화면에 3-4 section 보장 (Hick's Law).
    @ViewBuilder
    private var currentStepContent: some View {
        switch currentStep {
        case .preview: previewStep
        case .safety:  safetyStep
        case .approve: approveStep
        }
    }

    /// Step 1 — "이게 뭔가?" (header 는 공통, 본문 = experimentPreview + confidenceFooter).
    @ViewBuilder
    private var previewStep: some View {
        if let exp = response.nextExperiment {
            experimentPreview(exp)
            Divider()
            confidenceFooter
        } else {
            Text("Critic 응답에 nextExperiment 없음 — Quality verdict = \(response.dataQuality.verdict.rawValue) 으로 실험 권고 안 됨")
                .font(DFFont.label)
                .foregroundStyle(DFColor.warning)
        }
    }

    /// Step 2 — "위험한가?" (safetyNotice + safetyVerdictPreview + risk + validation + walkingNotIdle).
    @ViewBuilder
    private var safetyStep: some View {
        if let exp = response.nextExperiment {
            safetyNotice(exp)
            Divider()
        }
        safetyVerdictPreview
        if let risk = response.nextExperiment?.riskNote {
            Divider()
            riskBanner(risk)
        }
        if let vr = validationResult, !vr.passed {
            Divider()
            validationIssuesBanner(vr)
        }
        if response.nextExperiment?.axis == .walkingEngine, session.current != .idle {
            Divider()
            walkingNotIdleBanner
        }
    }

    /// Step 3 — "승인하나?" (metricsRow + advancedAutoEnable banner).
    /// buttonRow 는 wizardButtonRow 에서 step-aware 처리.
    @ViewBuilder
    private var approveStep: some View {
        if let exp = response.nextExperiment {
            metricsRow(exp)
        }
        if isTuningSliderAxis(response.nextExperiment?.axis), !session.advanced {
            Divider()
            advancedAutoEnableBanner
        }
    }

    // MARK: - Stepper indicator (V280-B, Material 3 패턴)

    /// "1/3 · 미리보기 → 안전 확인 → 승인" 진행 인디케이터.
    /// 비유: 지하철 노선도 — 현재역 highlight, 지난역 dimmed, 다음역 outline.
    private var stepperIndicator: some View {
        HStack(spacing: DFSpace.xs) {
            ForEach(WizardStep.allCases, id: \.rawValue) { step in
                stepperPill(step)
                if step != .approve {
                    Image(systemName: "chevron.right")
                        .font(DFFont.micro)
                        .foregroundStyle(DFColor.textSecondary.opacity(0.5))
                }
            }
            Spacer()
            Text("\(currentStep.rawValue)/3")
                .font(DFFont.micro)
                .foregroundStyle(DFColor.textSecondary)
        }
    }

    /// 단일 step pill — current/past/future 별 색상 차등 (Material 3 Stepper 패턴).
    @ViewBuilder
    private func stepperPill(_ step: WizardStep) -> some View {
        let isCurrent = step == currentStep
        let isPast = step.rawValue < currentStep.rawValue
        let bg: Color = isCurrent ? DFColor.info : (isPast ? DFColor.success.opacity(0.15) : DFColor.textSecondary.opacity(0.08))
        let fg: Color = isCurrent ? .white : (isPast ? DFColor.success : DFColor.textSecondary)
        HStack(spacing: 4) {
            if isPast {
                Image(systemName: "checkmark.circle.fill").font(DFFont.micro)
            } else {
                Text("\(step.rawValue)").font(DFFont.micro.bold())
            }
            Text(step.label).font(DFFont.micro)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(bg)
        .clipShape(Capsule())
    }


    @ViewBuilder
    private var safetyVerdictPreview: some View {
        let verdict = proposedConfig.safetyVerdict
        HStack(alignment: .top, spacing: DFSpace.xs) {
            Image(systemName: safetyIcon(verdict))
                .foregroundStyle(safetyColor(verdict))
            VStack(alignment: .leading, spacing: 2) {
                Text("safetyVerdict (적용 후)").font(DFFont.sectionLabel)
                Text(safetyText(verdict))
                    .font(DFFont.label)
                    .foregroundStyle(safetyColor(verdict))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(DFSpace.xs)
        .background(safetyColor(verdict).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }

    private func safetyIcon(_ v: BalanceExperimentConfig.SafetyVerdict) -> String {
        switch v {
        case .safe: return "checkmark.shield.fill"
        case .caution: return "exclamationmark.shield.fill"
        case .blocked: return "xmark.shield.fill"
        }
    }
    private func safetyColor(_ v: BalanceExperimentConfig.SafetyVerdict) -> Color {
        switch v {
        case .safe: return DFColor.success
        case .caution: return DFColor.warning
        case .blocked: return DFColor.danger
        }
    }
    private func safetyText(_ v: BalanceExperimentConfig.SafetyVerdict) -> String {
        switch v {
        case .safe: return "안전 — 적용 가능"
        case .caution(let msg): return msg
        case .blocked(let msg): return msg
        }
    }

    /// Telemetry-safe verdict key — PII 없는 enum case 문자열만 반환.
    private func safetyVerdictKey(_ v: BalanceExperimentConfig.SafetyVerdict) -> String {
        switch v {
        case .safe: return "safe"
        case .caution: return "caution"
        case .blocked: return "blocked"
        }
    }

    private var header: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: "hand.tap.fill")
                .font(DFFont.sectionLarge)
                .foregroundStyle(DFColor.info)
            VStack(alignment: .leading, spacing: 2) {
                Text("실험 승인")
                    .font(DFFont.sectionLarge)
                Text("Claude critic 권고 — 사용자 검토 + 명시 승인 후만 적용")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func experimentPreview(_ exp: NextExperiment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("axis 변경 미리보기")
                .font(DFFont.sectionLabel)
                .foregroundStyle(DFColor.textSecondary)
            HStack(spacing: DFSpace.xs) {
                Text("`\(exp.axis.rawValue)`")
                    .font(DFFont.monoLabel)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DFColor.textSecondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(exp.from)
                    .font(DFFont.monoLabel.bold())
                    .foregroundStyle(DFColor.textSecondary)
                Image(systemName: "arrow.right")
                    .font(DFFont.label)
                Text(exp.to)
                    .font(DFFont.monoLabel.bold())
                    .foregroundStyle(DFColor.info)
                Spacer()
            }
            HStack(spacing: DFSpace.xs) {
                Label("preset: \(exp.preset)", systemImage: "figure.walk")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                Label("changeOneAxisOnly", systemImage: "1.circle.fill")
                    .font(DFFont.micro)
                    .foregroundStyle(exp.changeOneAxisOnly ? DFColor.success : DFColor.danger)
            }
        }
    }

    /// **V280-E (2026-05-24)**: hardcoded HStack/background → DFBanner (.warning).
    /// 종전 shield 아이콘 → DFNotification 표준 triangle 아이콘 (Carbon consistency).
    @ViewBuilder
    private func safetyNotice(_ exp: NextExperiment) -> some View {
        DFBanner(
            title: "안전 절차",
            message: exp.safety,
            severity: .warning
        )
    }

    @ViewBuilder
    private func metricsRow(_ exp: NextExperiment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: DFSpace.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DFColor.success)
                VStack(alignment: .leading) {
                    Text("성공 metric").font(DFFont.sectionLabel)
                    Text(exp.successMetric)
                        .font(DFFont.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: DFSpace.xs) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(DFColor.danger)
                VStack(alignment: .leading) {
                    Text("Rollback 조건").font(DFFont.sectionLabel)
                    Text(exp.rollbackCondition)
                        .font(DFFont.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// **V280-E (2026-05-24)**: hardcoded HStack/background → DFBanner (.warning).
    @ViewBuilder
    private func riskBanner(_ note: String) -> some View {
        DFBanner(title: note, severity: .warning)
    }

    private var confidenceFooter: some View {
        HStack(spacing: DFSpace.xs) {
            if let conf = response.confidence {
                Label("전체 confidence \(Int(conf * 100))%",
                      systemImage: "percent")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            if let rec = response.recommendation {
                Text("권고 action: \(rec.action.rawValue)")
                    .font(DFFont.micro)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
    }

    // MARK: - Step-aware button row (V280-B)

    /// Wizard 의 단계별 버튼 row.
    /// - step 1/2: [취소] [이전 (step1=hidden)] [다음 (검증 통과 시만 enabled)]
    /// - step 3 (final): [취소] [이전] [실험 시작 (safety/validation 통과 시만 enabled)]
    private var wizardButtonRow: some View {
        HStack(spacing: DFSpace.sm) {
            cancelButton
            Spacer()
            if currentStep.previous != nil {
                Button("이전") {
                    if let prev = currentStep.previous { currentStep = prev }
                }
            }
            if currentStep == .approve {
                approveButton
            } else {
                nextButton
            }
        }
    }

    /// 취소 버튼 — 모든 step 에서 동일 (telemetry 포함).
    private var cancelButton: some View {
        Button("취소", role: .cancel) {
            harness.record(
                .walklabExperimentRejected, level: .info, actor: .user,
                data: [
                    "axis": AnyCodable(response.nextExperiment?.axis.rawValue ?? "none"),
                    "baseline_session_id": AnyCodable(Harness.shortHash(baselineSessionId)),
                    "rejected_at_step": AnyCodable(currentStep.label),
                ]
            )
            onCancel()
        }
    }

    /// "다음" 버튼 — step 1/2. nextExperiment 없거나 step 2 에서 blocked/validation 실패 시 disabled.
    private var nextButton: some View {
        Button {
            if let next = currentStep.next { currentStep = next }
        } label: {
            Label("다음", systemImage: "chevron.right")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isNextDisabled)
    }

    /// "다음" 버튼 disable 조건 — step 별 분기.
    private var isNextDisabled: Bool {
        // nextExperiment 없으면 어느 step 에서도 진행 불가.
        if response.nextExperiment == nil { return true }
        // safety step 통과 → approve 진행 시 safety/validation 통과 필수
        // (사용자가 위험 모르고 final step 까지 가는 것 차단).
        if currentStep == .safety {
            if case .blocked = proposedConfig.safetyVerdict { return true }
            if let vr = validationResult, !vr.passed { return true }
        }
        return false
    }

    /// 최종 "실험 시작" 버튼 — step 3 (approve) 전용.
    /// 기존 disabled / telemetry logic 보존 (behavior 무변경).
    private var approveButton: some View {
        Button {
            harness.record(
                .walklabExperimentApproved, level: .info, actor: .user,
                data: [
                    "axis": AnyCodable(response.nextExperiment?.axis.rawValue ?? "none"),
                    "confidence_pct": AnyCodable(response.confidence.map { Int($0 * 100) }),
                    "safety_verdict": AnyCodable(safetyVerdictKey(proposedConfig.safetyVerdict)),
                    "baseline_session_id": AnyCodable(Harness.shortHash(baselineSessionId)),
                ]
            )
            onApprove()
        } label: {
            Label("실험 시작 (사용자 명시 승인)", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        // safetyVerdict.blocked 또는 validation 실패 → 승인 불가.
        // v1.11.14.1: validate(currentConfig:) issue 도 disable 트리거.
        .disabled(response.nextExperiment == nil || {
            if case .blocked = proposedConfig.safetyVerdict { return true }
            if let vr = validationResult, !vr.passed { return true }
            return false
        }())
    }

    /// **v1.11.14.6**: tuning slider axis 인지 검사.
    private func isTuningSliderAxis(_ axis: ResponseAxis?) -> Bool {
        guard let axis = axis else { return false }
        switch axis {
        case .strideMm, .sideMm, .turnDeg, .periodMs, .footHeightMm, .balanceGain:
            return true
        default:
            return false
        }
    }

    /// **v1.11.14.6**: advanced 자동 활성 안내 — 사용자 동의 transparency.
    private var advancedAutoEnableBanner: some View {
        HStack(alignment: .top, spacing: DFSpace.xs) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(DFColor.info)
            VStack(alignment: .leading, spacing: 2) {
                Text("Advanced 모드 자동 활성").font(DFFont.sectionLabel)
                Text("tuning slider 변경이 실 보행에 반영되려면 advanced=true 필요. 승인 시 자동으로 활성됩니다.")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(DFSpace.xs)
        .background(DFColor.info.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }

    /// **v1.11.14.6**: 보행 중 walkingEngine 변경 reject 예상 안내.
    private var walkingNotIdleBanner: some View {
        HStack(alignment: .top, spacing: DFSpace.xs) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(DFColor.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("walkingEngine 변경은 보행 중 적용 불가").font(DFFont.sectionLabel)
                Text("현재 보행 중 (\(session.current.label)) — 정지 (idle) 후 다시 승인해야 적용됩니다.")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(DFSpace.xs)
        .background(DFColor.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }

    @ViewBuilder
    private func validationIssuesBanner(_ vr: ClaudeCriticResponse.ValidationResult) -> some View {
        HStack(alignment: .top, spacing: DFSpace.xs) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(DFColor.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text("승인 검증 실패 — 현재 config 기준")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.danger)
                ForEach(vr.issues, id: \.self) { issue in
                    Text("• \(issue)")
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(DFSpace.xs)
        .background(DFColor.danger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }
}
