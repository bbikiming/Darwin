import ForgeCore
import SwiftUI

/// Walk Lab 고급 — 6 슬라이더 + 실시간 안정성 점수 + smart-clamp + force-override 토글.
///
/// 사용자 흐름:
///   1. 보폭/측면/회전/주기/발 들기/균형 게인 슬라이더를 한 번에 본다.
///   2. 슬라이더가 움직일 때마다 WalkStabilityPredictor 가 점수 0..100 으로 평가.
///   3. 점수 ≥ 60 (HighRisk) 이면 "시작" 게이트가 confirm 요구. ≥ 80 (Critical) 이면 차단.
///   4. recommendedCaps 가 다른 슬라이더의 max 영역을 동적으로 빨간 패턴으로 표시 —
///      "이 보폭에서는 주기를 더 줄이면 위험" 식 cross-slider 보호.
///   5. "안전 한도 해제" 토글로 cap 무시 가능 (단, 점수가 critical 이면 여전히 시작 차단).
public struct AdvancedSlidersPanel: View {
    @ObservedObject var session: WalkLabSession

    public init(session: WalkLabSession) {
        self.session = session
    }

    private var stabilityInput: WalkStabilityInput {
        WalkStabilityInput(
            strideMm: session.strideMm,
            sideMm: session.sideMm,
            turnDeg: session.turnDeg,
            periodMs: session.customPeriodMs,
            footHeightMm: session.footHeightMm,
            balanceGain: session.balanceGain
        )
    }

    private var stability: WalkStabilityResult {
        WalkStabilityPredictor.evaluate(stabilityInput)
    }

    private var caps: WalkStabilityPredictor.Caps {
        WalkStabilityPredictor.recommendedCaps(stabilityInput)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            // 안정성 게이지
            StabilityGauge(result: stability)
                .padding(.vertical, 4)

            // 6 슬라이더 — 각 파라미터의 안전 영역을 명시.
            SafetyBandedSlider(
                value: $session.strideMm,
                range: 0...50,
                bands: .unidirectional(safeUpper: 20, cautionUpper: 30, range: 0...50),
                cap: session.forceOverrideSafety ? nil : caps.maxStrideMm,
                ticks: [10, 20, 30],
                label: "보폭 (앞)",
                forceOverride: session.forceOverrideSafety,
                unitLabel: { String(format: "%.1f mm/cycle", $0) }
            )

            SafetyBandedSlider(
                value: $session.sideMm,
                range: -25...25,
                bands: .unidirectional(safeUpper: 10, cautionUpper: 15, range: 0...25),
                cap: session.forceOverrideSafety ? nil : caps.maxSideMm,
                ticks: [-15, -10, 0, 10, 15],
                label: "측면 보폭",
                bidirectional: true,
                forceOverride: session.forceOverrideSafety,
                unitLabel: { String(format: "%+.1f mm/cycle", $0) }
            )

            SafetyBandedSlider(
                value: $session.turnDeg,
                range: -20...20,
                bands: .unidirectional(safeUpper: 5, cautionUpper: 10, range: 0...20),
                cap: session.forceOverrideSafety ? nil : caps.maxTurnDeg,
                ticks: [-10, -5, 0, 5, 10],
                label: "회전",
                bidirectional: true,
                forceOverride: session.forceOverrideSafety,
                unitLabel: { String(format: "%+.1f °/cycle", $0) }
            )

            SafetyBandedSlider(
                value: $session.customPeriodMs,
                range: 350...1000,
                // 주기는 클수록 안전 (느림). inverted 모드.
                bands: .inverted(safeLower: 600, cautionLower: 500, range: 350...1000),
                cap: nil,
                ticks: [450, 500, 600, 700, 800],
                label: "주기 (작을수록 빠름)",
                unitLabel: { String(format: "%.0f ms", $0) }
            )

            SafetyBandedSlider(
                value: $session.footHeightMm,
                range: 15...80,
                // sweet-spot: 30..50 = safe, 25..60 = caution, 그 외 danger.
                bands: .sweetSpot(safeMin: 30, safeMax: 50, cautionMin: 25, cautionMax: 60),
                cap: nil,
                ticks: [25, 30, 40, 50, 60],
                label: "발 들기 높이",
                unitLabel: { String(format: "%.0f mm", $0) }
            )

            SafetyBandedSlider(
                value: $session.balanceGain,
                range: 0...5,
                // sweet-spot: 0.5..2.0 = safe, 0.3..3.5 = caution, 그 외 danger.
                bands: .sweetSpot(safeMin: 0.5, safeMax: 2.0, cautionMin: 0.3, cautionMax: 3.5),
                cap: nil,
                ticks: [0.3, 0.5, 1.0, 2.0, 3.0],
                label: "균형 게인 (NimbRo lean_fb)",
                unitLabel: { String(format: "%.2f", $0) }
            )

            // 안전 한도 해제 — 사용자가 cap 무시.
            Toggle(isOn: $session.forceOverrideSafety) {
                Label {
                    Text("안전 한도 해제")
                        .font(.system(size: 11, weight: .medium))
                } icon: {
                    Image(systemName: session.forceOverrideSafety
                          ? "lock.open.fill" : "lock.fill")
                        .foregroundStyle(session.forceOverrideSafety
                                          ? DFColor.danger : DFColor.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.top, 4)
            .help("Smart clamp 무시. critical 점수일 때는 여전히 시작 차단됨.")

            if session.forceOverrideSafety {
                Text("⚠️ Smart clamp 가 해제됨. 점수가 critical (≥ 80) 이면 시작은 여전히 차단됩니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.danger)
                    .padding(.horizontal, 4)
            }

            // 메시지
            if !stability.messages.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(stability.messages, id: \.self) { msg in
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(stability.category == .critical
                                                  ? DFColor.danger : DFColor.warning)
                            Text(msg)
                                .font(.system(size: 10))
                                .foregroundStyle(DFColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 6)
            }

            // 빠른 reset
            HStack(spacing: 4) {
                Button("권장 안전 값으로") {
                    session.strideMm       = 15
                    session.sideMm         = 0
                    session.turnDeg        = 0
                    session.customPeriodMs = 700
                    session.footHeightMm   = 40
                    session.balanceGain    = 1.0
                    session.syncCommandToEngine()
                }
                .controlSize(.mini)
                Spacer()
                Button("0 초기화") {
                    session.strideMm       = 0
                    session.sideMm         = 0
                    session.turnDeg        = 0
                    session.customPeriodMs = 600
                    session.footHeightMm   = 40
                    session.balanceGain    = 1.0
                    session.syncCommandToEngine()
                }
                .controlSize(.mini)
            }
        }
        .onChange(of: session.strideMm)       { _, _ in session.syncCommandToEngine() }
        .onChange(of: session.sideMm)         { _, _ in session.syncCommandToEngine() }
        .onChange(of: session.turnDeg)        { _, _ in session.syncCommandToEngine() }
        .onChange(of: session.customPeriodMs) { _, _ in session.syncCommandToEngine() }
        .onChange(of: session.footHeightMm)   { _, _ in session.syncCommandToEngine() }
        .onChange(of: session.balanceGain)    { _, _ in session.syncCommandToEngine() }
    }
}

/// 안정성 점수 게이지 — 가로 막대 0..100 + 카테고리 라벨 + 유효 속도.
public struct StabilityGauge: View {
    public let result: WalkStabilityResult

    public init(result: WalkStabilityResult) {
        self.result = result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: categoryIcon)
                    .foregroundStyle(categoryColor)
                Text("낙상 위험 \(Int(result.score)) / 100")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(categoryColor)
                Spacer()
                Text(result.category.labelKo)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(categoryColor.opacity(0.15))
                    .foregroundStyle(categoryColor)
                    .clipShape(Capsule())
            }

            GeometryReader { geo in
                let pct = max(0, min(1, result.score / 100.0))
                ZStack(alignment: .leading) {
                    // 배경 그라데이션
                    LinearGradient(
                        colors: [
                            DFColor.success.opacity(0.4),
                            DFColor.warning.opacity(0.5),
                            DFColor.danger.opacity(0.6)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 8)
                    .clipShape(Capsule())
                    // 위치 표시 막대
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: 14)
                        .offset(x: CGFloat(pct) * geo.size.width - 1)
                }
            }
            .frame(height: 14)

            HStack {
                Text("유효 속도")
                    .font(.system(size: 10))
                    .foregroundStyle(DFColor.textSecondary)
                Text(String(format: "%.1f mm/s", result.effectiveSpeedMmPerSec))
                    .font(.system(size: 10, design: .monospaced))
                Spacer()
                if !result.breakdown.isEmpty {
                    Text(topContributorsLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
    }

    private var categoryColor: Color {
        switch result.category {
        case .safe:     return DFColor.success
        case .caution:  return DFColor.warning
        case .highRisk: return DFColor.danger
        case .critical: return DFColor.danger
        }
    }

    private var categoryIcon: String {
        switch result.category {
        case .safe:     return "checkmark.shield.fill"
        case .caution:  return "exclamationmark.triangle.fill"
        case .highRisk: return "exclamationmark.octagon.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private var topContributorsLabel: String {
        let top = result.breakdown.prefix(3).map { $0.label }
        return "기여: " + top.joined(separator: " · ")
    }
}
