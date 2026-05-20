import SwiftUI

/// 사용자가 "왜 이 데이터가 유용/무용한지" 보는 패널. 숫자판이 아니라 사유 + 지표를 함께.
public struct WalkSessionQualityDetailPanel: View {
    public let summary: WalkSessionSummaryV2

    public init(summary: WalkSessionSummaryV2) {
        self.summary = summary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            grid
            reasons
            recommendation
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            WalkSessionQualityBadge(grade: summary.dataQuality.grade,
                                     useClass: summary.dataQuality.useClass)
            Text(summary.preset)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(String(format: "%.1f초 · %d sample",
                        summary.dataQuality.durationSec,
                        summary.dataQuality.sampleCount))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(label: "독립 IMU 샘플 수",
                value: "\(summary.dataQuality.independentImuSampleCount) / \(summary.dataQuality.sampleCount)")
            row(label: "IMU 중복률",
                value: String(format: "%.1f%%", summary.dataQuality.imuDuplicateRatio * 100))
            row(label: "IMU stale 비율",
                value: String(format: "%.1f%%", summary.dataQuality.staleRatio * 100))
            row(label: "샘플 레이트 (nominal / 효과적)",
                value: String(format: "%.1f / %.1f Hz",
                              summary.dataQuality.nominalSampleRateHz,
                              summary.dataQuality.effectiveImuRateHz))
            if let median = summary.dataQuality.medianImuAgeMs {
                row(label: "IMU age (median / p95)",
                    value: String(format: "%.0f / %.0f ms",
                                  median,
                                  summary.dataQuality.p95ImuAgeMs ?? 0))
            }
            row(label: "버스 실패 / 비상정지",
                value: "\(summary.dataQuality.busFailureCount) / \(summary.dataQuality.emergencyCount)")
            row(label: "평균 기울기 (roll / pitch abs)",
                value: String(format: "%.1f° / %.1f°",
                              summary.meanAbsRollDeg,
                              summary.meanAbsPitchDeg))
            row(label: "Bias (roll / pitch)",
                value: String(format: "%+.1f° / %+.1f°",
                              summary.rollBiasDeg,
                              summary.pitchBiasDeg))
            if let pitchEff = summary.laggedPitchEffectiveness,
               let rollEff = summary.laggedRollEffectiveness,
               let lag = summary.bestLagMs {
                row(label: "보정 회복 (pitch / roll @ lag)",
                    value: String(format: "%+.2f / %+.2f @ %.0f ms",
                                  pitchEff, rollEff, lag))
            } else {
                row(label: "보정 회복 (lagged)",
                    value: "계산 불가 (sample 부족 또는 v1)")
            }
            if let pitchPhase = summary.phaseResidualPitchRms,
               let rollPhase = summary.phaseResidualRollRms {
                row(label: "Phase residual rms (pitch / roll)",
                    value: String(format: "%.2f° / %.2f°", pitchPhase, rollPhase))
            }
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    @ViewBuilder
    private var reasons: some View {
        if !summary.dataQuality.reasons.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("판단 근거")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(summary.dataQuality.reasons, id: \.self) { reason in
                    HStack(spacing: 6) {
                        Image(systemName: reason == .healthy ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(reason == .healthy ? .green : .orange)
                        Text(WalkSessionLabels.reasonLabel(reason))
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var recommendation: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(WalkRecommendationLabels.actionLabel(summary.recommendation.action))
                    .font(.caption.weight(.semibold))
                Text(summary.recommendation.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if summary.recommendation.confidence > 0 {
                    Text(String(format: "신뢰도 %.0f%%", summary.recommendation.confidence * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }
}
