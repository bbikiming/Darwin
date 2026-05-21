import SwiftUI

/// **v1.16.0 (2026-05-21) — Phase 2: Recommender 카드 view**.
///
/// `WalkTrialLibraryView` 의 detail pane 하단에 표시되는 추천 카드.
/// 사용자가 "이 config 적용" 버튼 클릭 시 `WalkLabSession` 으로 inject — 다음 보행 자동 사용.
public struct WalkTrialRecommenderCard: View {
    public let recommendation: WalkTrialRecommendation
    public let onApply: () -> Void

    /// **v1.16.0.1 (2026-05-21) — code-reviewer L4**: apply 후 user feedback 시각.
    /// 종전: 카드 자체에 변화 없어서 사용자가 double-tap 가능.
    /// 신규: appliedAt 시각 기록 → 3초간 "✓ 적용됨" 라벨 + 버튼 disable.
    @State private var appliedAt: Date? = nil

    public init(recommendation: WalkTrialRecommendation, onApply: @escaping () -> Void) {
        self.recommendation = recommendation
        self.onApply = onApply
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            configSummary
            rationaleSection
            applyButton
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: recommendation.strategy.icon)
                .foregroundStyle(Color.accentColor)
            Text(recommendation.strategy.label)
                .font(.callout.weight(.semibold))
            Spacer()
            dataMaturityPill
        }
    }

    /// **v1.16.0.1 fix (architect + code-reviewer L5)**: "신뢰도" → "데이터 성숙도".
    /// statistical confidence 가 아닌 sample-size proxy 임을 사용자에게 명시.
    /// Icon 도 `checkmark.seal.fill` (verification 의미 충돌) → `gauge.with.dots.needle.bottom.50percent` (중립 gauge).
    private var dataMaturityPill: some View {
        HStack(spacing: 2) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.caption2)
            Text("데이터 \(Int(recommendation.dataMaturity * 100))%")
                .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(dataMaturityColor.opacity(0.2))
        .foregroundStyle(dataMaturityColor)
        .clipShape(Capsule())
    }

    private var dataMaturityColor: Color {
        if recommendation.dataMaturity >= 0.8 { return .green }
        if recommendation.dataMaturity >= 0.5 { return .blue }
        return .orange
    }

    private var configSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("추천 config")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    Text("preset").foregroundStyle(.secondary)
                    Text(recommendation.preset)
                }
                GridRow {
                    Text("intensity").foregroundStyle(.secondary)
                    Text("\(recommendation.intensityLevel)")
                }
                GridRow {
                    Text("stride").foregroundStyle(.secondary)
                    Text(String(format: "%.0f mm", recommendation.tuning.strideMm))
                }
                GridRow {
                    Text("period").foregroundStyle(.secondary)
                    Text(String(format: "%.0f ms", recommendation.tuning.periodMs))
                }
                GridRow {
                    Text("balanceGain").foregroundStyle(.secondary)
                    Text(String(format: "%.2f", recommendation.tuning.balanceGain))
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    private var rationaleSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("근거")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(recommendation.rationale)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if !recommendation.sourceSampleIds.isEmpty {
                Text("기반 trial: \(recommendation.sourceSampleIds.count)개")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// L4 fix: applied 후 3초간 "✓ 적용됨" 표시 → 사용자 double-tap 차단.
    private var isRecentlyApplied: Bool {
        guard let t = appliedAt else { return false }
        return Date().timeIntervalSince(t) < 3.0
    }

    private var applyButton: some View {
        HStack {
            Spacer()
            if isRecentlyApplied {
                Label("적용됨", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                Button {
                    onApply()
                    appliedAt = Date()
                } label: {
                    Label("이 config 적용", systemImage: "arrow.right.circle.fill")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
