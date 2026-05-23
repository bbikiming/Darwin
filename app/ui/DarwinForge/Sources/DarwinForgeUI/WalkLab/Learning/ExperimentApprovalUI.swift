import SwiftUI

/// **v1.11.12 (2026-05-19)** — Critic 권고 → 사용자 명시 승인 → ExperimentLoop start.
///
/// 진단 문서 §4 critic-controller 분리 + Agent 5 architect 설계.
///
/// sheet UI:
/// - critic 의 nextExperiment 표시
/// - axis 변경 미리보기 (현재 → 제안)
/// - safetyVerdict 명시
/// - safety 안내 (cradle/tether)
/// - success metric + rollback condition
/// - "실험 시작" 버튼 (ExperimentLoop.startExperiment)
/// - "취소" 버튼
public struct ExperimentApprovalUI: View {
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
            Divider()
            if let exp = response.nextExperiment {
                experimentPreview(exp)
                Divider()
                safetyNotice(exp)
                Divider()
                metricsRow(exp)
                if let risk = exp.riskNote {
                    riskBanner(risk)
                }
            } else {
                Text("Critic 응답에 nextExperiment 없음 — Quality verdict = \(response.dataQuality.verdict.rawValue) 으로 실험 권고 안 됨")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.warning)
            }
            Divider()
            // v1.11.13: safety verdict 미리보기 — deterministic gate 결과.
            safetyVerdictPreview
            // v1.11.14.1: validate(currentConfig:) issues 사전 표시.
            if let vr = validationResult, !vr.passed {
                Divider()
                validationIssuesBanner(vr)
            }
            // **v1.11.14.6 (2026-05-19)** — tuning slider axis 권고 + advanced=false 면
            // 자동 활성 안내. 사용자 명시 동의 없이 UI 상태 변경되는 silent UX 차단.
            if isTuningSliderAxis(response.nextExperiment?.axis), !session.advanced {
                Divider()
                advancedAutoEnableBanner
            }
            // **v1.11.14.6** — walkingEngine axis 권고 + 보행 중이면 reject 예상 안내.
            if response.nextExperiment?.axis == .walkingEngine, session.current != .idle {
                Divider()
                walkingNotIdleBanner
            }
            Divider()
            confidenceFooter
            Spacer()
            buttonRow
        }
        .padding(DFSpace.md)
        .frame(minWidth: 520, minHeight: 540, idealHeight: 620)
        // v1.11.14.6: 테마 통합 — flat 시 #FFFFFF, 그 외 default light/dark.
        .background(DFColor.adaptiveCanvas(theme))
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

    @ViewBuilder
    private func safetyNotice(_ exp: NextExperiment) -> some View {
        HStack(alignment: .top, spacing: DFSpace.xs) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(DFColor.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("안전 절차")
                    .font(DFFont.sectionLabel)
                Text(exp.safety)
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(DFSpace.xs)
        .background(DFColor.warning.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
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

    @ViewBuilder
    private func riskBanner(_ note: String) -> some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DFColor.warning)
            Text(note)
                .font(DFFont.label)
                .foregroundStyle(DFColor.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DFSpace.xs)
        .background(DFColor.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
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

    private var buttonRow: some View {
        HStack(spacing: DFSpace.sm) {
            Button("취소", role: .cancel) {
                Harness.shared.record(
                    .walklabExperimentRejected, level: .info, actor: .user,
                    data: [
                        "axis": AnyCodable(response.nextExperiment?.axis.rawValue ?? "none"),
                        "baseline_session_id": AnyCodable(Harness.shortHash(baselineSessionId)),
                    ]
                )
                onCancel()
            }
            Spacer()
            Button {
                Harness.shared.record(
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
