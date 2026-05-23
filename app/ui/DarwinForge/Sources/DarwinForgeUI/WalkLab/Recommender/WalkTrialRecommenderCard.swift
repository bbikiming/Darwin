import SwiftUI

/// **v1.16.0 (2026-05-21) — Phase 2: Recommender 카드 view**.
///
/// `WalkTrialLibraryView` 의 detail pane 하단에 표시되는 추천 카드.
/// 사용자가 "이 config 적용" 버튼 클릭 시 `WalkLabSession` 으로 inject — 다음 보행 자동 사용.
public struct WalkTrialRecommenderCard: View {
    public let recommendation: WalkTrialRecommendation
    public let onApply: () -> Void
    /// 사이클 153 (사용자 권고 #3): robot 연결 여부 — sim 추천 적용 confirmation 트리거.
    /// nil 이면 robot 연결 검증 skip (legacy / 테스트 호환).
    public let robotConnected: Bool

    /// **v1.16.0.1 (2026-05-21) — code-reviewer L4**: apply 후 user feedback 시각.
    /// 종전: 카드 자체에 변화 없어서 사용자가 double-tap 가능.
    /// 신규: appliedAt 시각 기록 → 3초간 "✓ 적용됨" 라벨 + 버튼 disable.
    @State private var appliedAt: Date? = nil

    /// 사이클 153 (사용자 권고 #3): sim 추천을 실 robot 에 적용하려 할 때 confirmation.
    @State private var showingSimConfirmation = false

    public init(
        recommendation: WalkTrialRecommendation,
        robotConnected: Bool = false,
        onApply: @escaping () -> Void
    ) {
        self.recommendation = recommendation
        self.robotConnected = robotConnected
        self.onApply = onApply
    }

    /// 사이클 153: sim only 추천을 실 robot 에 적용 시 위험 경고 필요 여부.
    /// - 조건: robot 연결됨 + breakdown 의 실로봇 trial 수 == 0 (시뮬만).
    /// - true 면 confirmation dialog 표시.
    private var needsSimConfirmation: Bool {
        Self.needsSimConfirmation(
            recommendation: recommendation,
            robotConnected: robotConnected
        )
    }

    /// 사이클 153: 단위 테스트 가능한 static 변형 — predicate logic 격리.
    public static func needsSimConfirmation(
        recommendation: WalkTrialRecommendation,
        robotConnected: Bool
    ) -> Bool {
        guard robotConnected else { return false }
        guard let breakdown = recommendation.sourceBreakdown else { return false }
        return breakdown.realRobotCount == 0 && breakdown.simCount > 0
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
            // 사이클 147 (IMPLEMENTATION audit #16): sim/real breakdown badge.
            // 사용자가 추천 적용 전 데이터 출처 확인.
            if let breakdown = recommendation.sourceBreakdown {
                HStack(spacing: 4) {
                    Image(systemName: breakdown.realRobotCount > 0
                          ? (breakdown.simCount > 0 ? "circle.lefthalf.filled" : "checkmark.circle.fill")
                          : "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(breakdown.realRobotCount > 0
                                         ? (breakdown.simCount > 0 ? .blue : .green)
                                         : .orange)
                    Text(breakdown.displayLabel)
                        .font(.caption2)
                        .foregroundStyle(breakdown.realRobotCount == 0 ? .orange : .secondary)
                }
                .accessibilityIdentifier("recommender.card.source.breakdown")
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
                    // 사이클 153 (사용자 권고 #3): sim only + robot 연결 시 confirmation.
                    // sim 데이터만 기반 추천이 실 robot 에 무경고 적용되면 낙상 / 부적합
                    // 자세 위험. 사용자 명시 확인 필요.
                    if needsSimConfirmation {
                        showingSimConfirmation = true
                    } else {
                        performApply()
                    }
                } label: {
                    Label("이 config 적용", systemImage: "arrow.right.circle.fill")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .confirmationDialog(
                    "시뮬레이션 데이터 기반 추천 — 실 로봇 적용?",
                    isPresented: $showingSimConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("그래도 적용", role: .destructive) {
                        Harness.shared.record(
                            .walklabRecommenderSimConfirmed, level: .info, actor: .user,
                            data: [
                                "strategy": AnyCodable(recommendation.strategy.rawValue),
                                "sim_count": AnyCodable(recommendation.sourceBreakdown?.simCount ?? 0),
                            ]
                        )
                        performApply()
                    }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text(simConfirmationMessage)
                }
            }
        }
    }

    /// 사이클 153: confirmation dialog 의 본문 메시지.
    /// 시뮬 데이터만으로 학습된 추천이 실 robot 에 적합하지 않을 수 있다는 위험 명시.
    private var simConfirmationMessage: String {
        let simCount = recommendation.sourceBreakdown?.simCount ?? 0
        return """
        이 추천은 시뮬레이션 trial \(simCount)개만 기반으로 산출됐습니다. 실 로봇 데이터 없음.

        실 robot 의 동역학 / 부하 / 마찰은 시뮬과 다를 수 있어 낙상 / 자세 불안정 위험이 있습니다. \
        실 robot 데이터 누적 후 재추천 받기를 권장합니다.

        그래도 적용하시려면 정비 스탠드 + 사용자 supervised 환경에서 시도하세요.
        """
    }

    /// 사이클 153: confirmation 통과 후 실제 apply (또는 sim/disconnected 시 직접 호출).
    private func performApply() {
        Harness.shared.record(
            .walklabRecommenderApplied, level: .info, actor: .user,
            data: [
                "strategy": AnyCodable(recommendation.strategy.rawValue),
                "data_maturity": AnyCodable(recommendation.dataMaturity),
                "preset": AnyCodable(recommendation.preset),
                "intensity_level": AnyCodable(recommendation.intensityLevel),
            ]
        )
        onApply()
        appliedAt = Date()
    }
}
