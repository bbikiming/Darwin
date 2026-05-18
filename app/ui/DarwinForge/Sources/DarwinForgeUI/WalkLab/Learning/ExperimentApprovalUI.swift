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
    public let onApprove: () -> Void
    public let onCancel: () -> Void

    public init(response: ClaudeCriticResponse,
                onApprove: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.response = response
        self.onApprove = onApprove
        self.onCancel = onCancel
    }

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
            confidenceFooter
            Spacer()
            buttonRow
        }
        .padding(DFSpace.md)
        .frame(minWidth: 520, minHeight: 480, idealHeight: 560)
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
            .disabled(response.nextExperiment == nil)
        }
    }
}
