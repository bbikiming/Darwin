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
        VStack(alignment: .leading, spacing: DFSpace.sm) {
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
            Divider()
            confidenceFooter
            Spacer()
            buttonRow
        }
        .padding(DFSpace.md)
        .frame(minWidth: 520, minHeight: 540, idealHeight: 620)
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
                onCancel()
            }
            Spacer()
            Button {
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
