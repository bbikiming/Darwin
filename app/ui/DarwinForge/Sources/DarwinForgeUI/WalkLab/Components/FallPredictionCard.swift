import SwiftUI
import ForgeCore

/// **V272-1 (2026-05-24) WCAG 1.4.1 fix — Fall prediction severity dual encoding**.
///
/// `scoreColor` (0..30 green / ..60 yellow / ..80 orange / 80+ red) 가 색상-only
/// 인디케이터로 WCAG 1.4.1 위반. systemImage 아이콘 + 한글 라벨 dual encoding 으로
/// color-blind 사용자도 안정/주의/경고/위험 4-tier 즉시 인식 가능.
///
/// **Domain 분리**: GyroSeverity (자세 5-tier) / SceneSeverity (자세 5-tier) /
/// PilotLatencyPanel.statusLabel (지연 3-tier) 와 별도 — 낙상 점수는 0-100 정규화 4-tier.
enum FallSeverity {
    static func icon(score: Double) -> String {
        switch score {
        case ..<30:  return "checkmark.circle.fill"           // 안정
        case ..<60:  return "exclamationmark.circle.fill"     // 주의
        case ..<80:  return "exclamationmark.triangle.fill"   // 경고
        default:     return "octagon.fill"                    // 위험
        }
    }

    static func label(score: Double) -> String {
        switch score {
        case ..<30:  return "안정"
        case ..<60:  return "주의"
        case ..<80:  return "경고"
        default:     return "위험"
        }
    }
}

/// v1.1 Stage 5 — fall prediction score + ETA countdown UI.
///
/// 0..100 score 게이지 + emergency(50°) 도달 예측 시간 (있을 때만). 권고 시 빨간
/// "위험 임박" 표시. **주의 (2026-05-20)**: 현재 `recommendEmergency` 는 이벤트 로그만
/// 남기고 실 motor torque-off 를 직접 호출하지 않음. UI 라벨은 사용자에게 사전 경고
/// 의미로만 사용 — "정지 발동" 이 아닌 "위험 임박".
///
/// **출처 표기 (2026-05-17 Codex audit)**: 단독으로 다른 화면에 박힐 때 점수가 실 IMU
/// 기반인지 시뮬인지 사용자가 알 수 없는 문제. optional `imuSource` 받으면 작은 칩으로 표시.
/// 기본 nil 이면 표시 안 함 (기존 호출처 호환성 유지).
public struct FallPredictionCard: View {
    public let prediction: FallPredictor.Prediction
    public let imuSource: WalkLabSession.ImuSource?

    public init(prediction: FallPredictor.Prediction,
                imuSource: WalkLabSession.ImuSource? = nil) {
        self.prediction = prediction
        self.imuSource = imuSource
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: DFFontSize.s12))
                    .foregroundStyle(scoreColor)
                Text("예측 낙상 위험")
                    .font(.system(size: DFFontSize.s11, weight: .medium))
                if let source = imuSource {
                    sourcePill(source)
                }
                Spacer()
                // **V272-1 WCAG 1.4.1 fix**: 점수 옆 severity 아이콘 + 한글 라벨.
                // 색상-only 인디케이터를 dual encoding 으로 보강. color-blind 사용자도
                // 안정/주의/경고/위험 4-tier 즉시 인식 가능.
                Image(systemName: FallSeverity.icon(score: prediction.score))
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
                    .foregroundStyle(scoreColor)
                Text(FallSeverity.label(score: prediction.score))
                    .font(.system(size: DFFontSize.s10, weight: .semibold))
                    .foregroundStyle(scoreColor)
                Text("\(Int(prediction.score))")
                    .font(.system(size: DFFontSize.s13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(scoreColor)
            }

            // Score 게이지 — horizontal bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(DFColor.textSecondary.opacity(0.15))
                        .frame(height: 6)
                    Rectangle()
                        .fill(scoreColor)
                        .frame(width: geo.size.width * min(1.0, max(0.0, prediction.score / 100.0)),
                               height: 6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 6)

            // ETA + emergency 권고.
            HStack(spacing: 6) {
                if let etaMs = prediction.etaMs {
                    Image(systemName: "hourglass")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(DFColor.textSecondary)
                    Text(etaLabel(etaMs))
                        .font(.system(size: DFFontSize.s10, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                } else {
                    Text("ETA: 안정 (회복 중 또는 정상)")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(DFColor.textSecondary)
                }
                Spacer()
                if prediction.recommendEmergency {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: DFFontSize.s10))
                        .foregroundStyle(.red)
                    Text("위험 임박")
                        .font(.system(size: DFFontSize.s10, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(8)
        .background(scoreColor.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.xs2)
                .stroke(scoreColor.opacity(0.35), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs2))
    }

    private var scoreColor: Color {
        switch prediction.score {
        case ..<30:  return .green
        case ..<60:  return .yellow
        case ..<80:  return .orange
        default:     return .red
        }
    }

    /// 출처 칩 — 점수가 실 IMU/시뮬/지연 중 어느 데이터에 기반했는지 한눈에.
    private func sourcePill(_ s: WalkLabSession.ImuSource) -> some View {
        let tint: Color
        switch s {
        case .real:  tint = DFColor.success
        case .sim:   tint = DFColor.info
        case .stale: tint = DFColor.warning
        }
        return Text(s.label)
            .font(.system(size: DFFontSize.s9, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(tint, lineWidth: 0.5)
            )
    }

    private func etaLabel(_ ms: Double) -> String {
        if ms < 100 { return "ETA <0.1s" }
        if ms < 1000 { return String(format: "ETA %.0fms", ms) }
        return String(format: "ETA %.1fs", ms / 1000)
    }
}
