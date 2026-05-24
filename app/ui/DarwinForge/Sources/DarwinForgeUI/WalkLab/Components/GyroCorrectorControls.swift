import SwiftUI

/// **v1.9 (2026-05-17 사용자 요청)**: CircularGyroMeter 하단에 표시되는 보정 제어 카드.
///
/// 두 카드를 분리한 이유:
/// - `WalkSessionAutoTuner` 가 `@Published var` 인 `WalkLabSession.autoTuner` 안에
///   nested ObservableObject 인데, SwiftUI 의 객체 그래프 구독은 nested 변경을 자동
///   propagate 하지 않음 → toggle 켜도 옆 라벨이 안 바뀜.
/// - Card 자체가 `@ObservedObject var tuner` 직접 받으면 nested 변경도 즉시 view update.
///
/// **레이아웃**: 보정 강도 + 자동 튜닝 두 카드를 VStack 으로 묶고, 부모는 GyroMeter 아래
/// 에 배치.

// MARK: - CorrectorIntensityCard

public struct CorrectorIntensityCard: View {
    var session: WalkLabSession

    public init(session: WalkLabSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "slider.horizontal.3")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.accent)
                Text("자이로 보정 강도")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textSecondary)
                // **v1.15.5 (2026-05-21) Phase 1.5**: Onboard 모드에선 Mac corrector 전용 안내.
                WalkLabApplyScopeBadge(
                    scope: WalkLabApplyScopeResolver.scope(
                        for: .correctorIntensityLevel, engine: session.walkingEngine
                    ),
                    style: .compact
                )
                Spacer()
                Text(WalkLabSession.intensityLabel(level: session.correctorIntensityLevel))
                    .font(DFFont.monoLabel)
                    .foregroundStyle(intensityColor(level: session.correctorIntensityLevel))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(spacing: DFSpace.xs2) {
                ForEach(0..<5) { lvl in
                    Button {
                        session.correctorIntensityLevel = lvl
                        session.enableBalanceCorrection = (lvl > 0)
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(lvl)")
                                .font(DFFont.bodyEmph.monospaced())
                                .foregroundStyle(lvl == session.correctorIntensityLevel
                                    ? intensityColor(level: lvl)
                                    : DFColor.textSecondary)
                            Text(intensityShortLabel(for: lvl))
                                .font(DFFont.micro)
                                .foregroundStyle(DFColor.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DFSpace.xs2)
                        .background(intensityBackground(for: lvl, current: session.correctorIntensityLevel))
                        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
                        .overlay(
                            RoundedRectangle(cornerRadius: DFRadius.xs2)
                                .stroke(lvl == session.correctorIntensityLevel
                                        ? DFColor.accent
                                        : DFColor.textSecondary.opacity(DFOpacity.o25),
                                        lineWidth: lvl == session.correctorIntensityLevel ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("강도 \(lvl): \(WalkLabSession.intensityLabel(level: lvl))")
                }
            }
        }
        .padding(DFSpace.xs2)
        .background(DFColor.accent.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private func intensityColor(level: Int) -> Color {
        switch level {
        case 0: return DFColor.textSecondary
        case 1: return DFColor.info
        case 2: return DFColor.success
        case 3: return DFColor.warning
        case 4: return DFColor.danger
        default: return DFColor.textSecondary
        }
    }

    private func intensityBackground(for lvl: Int, current: Int) -> Color {
        guard lvl == current else { return Color.clear }
        return intensityColor(level: lvl).opacity(DFOpacity.o15)
    }

    private func intensityShortLabel(for lvl: Int) -> String {
        switch lvl {
        case 0: return "꺼짐"
        case 1: return "약함"
        case 2: return "표준"
        case 3: return "강함"
        case 4: return "최대"
        default: return ""
        }
    }
}

// MARK: - AutoTunerCard

/// `@ObservedObject var tuner` 로 직접 구독 — toggle 변경이 즉시 view update.
public struct AutoTunerCard: View {
    @ObservedObject var tuner: WalkSessionAutoTuner
    var session: WalkLabSession

    public init(tuner: WalkSessionAutoTuner, session: WalkLabSession) {
        self.tuner = tuner
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "brain.head.profile")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.info)
                Text("자동 튜닝 (학습 기반)")
                    .font(DFFont.sectionLabel)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                // V279-2 (P1 discoverability fix): help/accessibilityLabel — 토글 의미가
                // 단지 "자동 적용" 만으로는 모호 (어떤 적용? 무엇이 자동?). 사용자에게
                // 동작 + 안전 조건 명시.
                Toggle("자동 적용", isOn: $tuner.autoApplyEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("AI 권고 강도를 다음 보행 cycle 에 자동 적용합니다. " +
                          "실 robot 적용 모드에선 데이터 검증 후 수동 적용 권장 — 자동 변경 차단. " +
                          "수동 강도 변경 시 일시 중단됩니다.")
                    .accessibilityLabel(tuner.autoApplyEnabled
                        ? "AI 권고 강도 자동 적용 켜짐 — 끄려면 클릭"
                        : "AI 권고 강도 자동 적용 꺼짐 — 켜려면 클릭")
                Text(tuner.autoApplyEnabled ? "ON" : "OFF")
                    .font(DFFont.label)
                    .foregroundStyle(tuner.autoApplyEnabled ? DFColor.success : DFColor.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // **v1.11.1 (2026-05-18 사용자 review HIGH-2) — 실 robot 자동 적용 차단 안내**.
            // 데이터 품질 검증 (duplicate ratio / stale ratio / 독립 sample count) 이
            // v2 quality analyzer 수준 미달이므로 실 robot 적용 모드에선 자동 변경 차단.
            // **V280-E (2026-05-24)**: hardcoded HStack/background → DFBanner (.warning).
            if tuner.autoApplyEnabled && session.correctionApplyMode == "robotApplied" {
                DFBanner(
                    title: "실 robot 적용 모드 — 자동 변경 차단됨",
                    message: "수동 강도 유지. 데이터 검증 후 수동 적용 권장.",
                    severity: .warning
                )
            }
            if let rec = tuner.pendingRecommendation {
                Text(rec.reason)
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.info)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DFSpace.xs2) {
                    Button("바로 적용") {
                        session.correctorIntensityLevel = rec.level
                        tuner.userOverride()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("무시") {
                        tuner.userOverride()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(DFColor.textSecondary)
                }
            } else if tuner.recentSummaries.isEmpty {
                Text("아직 분석 데이터 없음 — 보행 cycle 종료 후 권고 표시됨")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
            } else {
                Text("최근 \(tuner.recentSummaries.count)회 session — 현재 강도 적정 (변경 권고 없음)")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.success)
            }
            if let latest = tuner.recentSummaries.first {
                HStack(spacing: DFSpace.sm) {
                    metric("평균 tilt", String(format: "%.1f°", max(latest.meanAbsRoll, latest.meanAbsPitch)))
                    metric("진동", String(format: "%.1fHz", latest.oscillationScore))
                    metric("효과", String(format: "%+.2f", latest.correctorEffectivenessScore))
                    metric("샘플", "\(latest.sampleCount)")
                }
                .font(DFFont.monoLabel)
            }
        }
        .padding(DFSpace.xs2)
        .background(DFColor.info.opacity(DFOpacity.o10))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(DFFont.micro).foregroundStyle(DFColor.textSecondary)
            Text(value).font(DFFont.monoLabel).foregroundStyle(DFColor.info)
        }
    }
}
