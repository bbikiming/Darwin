import SwiftUI
import ForgeCore

/// **v1.11.21 (2026-05-20)** — 전문가 보행 진단 메뉴에 워크랩 v1.11.19+ 시각화 통합.
///
/// 사용자 요청: "워크랩에서 업데이트 된 워킹 기능과 시각화 데이터 정보를 전문가의 보행 진단
/// 메뉴에도 기능적으로 추가".
///
/// # 통합 항목 (워크랩 → 보행 진단)
///
/// 1. **보행 운영 상태** — 현재 preset, BalanceState 5-tier (25/35/45/50°), corrector
///    Δmax + ramp + ON/OFF.
/// 2. **자세 진단 (EST)** — pitch/roll display 값 + CoM offset (HUDMetrics 추정) +
///    ankle residual L/R (corrector 기반 추정).
/// 3. **낙상 예측 (v1.11.19 모델)** — FallPredictor score + ETA (50° 임계) + 권고.
///
/// # 워크랩 ↔ 진단 메뉴 차이
///
/// 워크랩 HUD (SceneSpeedometerOverlay): 컴팩트 PFD overlay, 보행 중 실시간 모니터.
/// 진단 카드: 정량 분석 우선 — DFPanel 형식, 통계 + 임계값 라벨 명시, CSV/log 호환.
///
/// # 데이터 출처
///
/// - LIVE: BalanceState, lastCorrections, rampProgress, fallPrediction, displayImu*
/// - EST (모델 추정): CoM offset, ankle residual — HUDMetrics 사용, EST badge 표시
public struct WalkLabIntegrationCards: View {
    @Environment(WalkLabSession.self) private var session

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            operationStateCard
            attitudeAndComCard
            fallPredictorCard
            // 사이클 183 (P1 #3.5 fix, cycle 177 audit): Trial Library 통합 — 과거
            // trial vs 현재 metric 비교 view. 이전엔 WalkDiagnostics 가 live session
            // 만 본 → 학습 / 진척 분석 불가능. 본 card 가 user-driven dropdown 으로
            // 두 trial 의 4 metric diff 표시.
            TrialComparisonCard()
        }
    }

    // MARK: - 1. 보행 운영 상태 (LIVE)

    /// Current preset · BalanceState · Corrector Δmax · Ramp · ON/OFF.
    private var operationStateCard: some View {
        DFPanel(
            "보행 운영 상태",
            subtitle: "워크랩 세션 라이브",
            icon: "figure.walk.motion",
            tint: balanceStateColor
        ) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                walkLabMetaRow(label: "현재 프리셋",
                                value: session.current.label,
                                color: session.current == .idle
                                    ? DFColor.textSecondary
                                    : DFColor.success)
                walkLabMetaRow(label: "보행 phase",
                                value: session.phaseLabel,
                                color: session.current == .idle
                                    ? DFColor.textSecondary
                                    : DFColor.accent)
                walkLabMetaRow(label: "안전 상태",
                                value: balanceStateLabel,
                                color: balanceStateColor)
                walkLabMetaRow(label: "임계 분류",
                                value: "25 / 35 / 45 / 50°",
                                color: DFColor.textSecondary)
                Divider().padding(.vertical, 2)
                walkLabMetaRow(label: "자세 보정",
                                value: session.enableBalanceCorrection ? "ON" : "OFF",
                                color: session.enableBalanceCorrection
                                    ? DFColor.success
                                    : DFColor.textSecondary)
                if session.enableBalanceCorrection {
                    walkLabMetaRow(label: "최대 보정 Δ",
                                    value: String(format: "%.2f°",
                                                  session.lastCorrections?.maxAbs ?? 0),
                                    color: DFColor.accent)
                    if let r = session.rampProgress {
                        walkLabMetaRow(label: "Ramp 진행",
                                        value: String(format: "%.0f%%", r * 100),
                                        color: r >= 1.0 ? DFColor.success : DFColor.accent)
                    }
                }
                Divider().padding(.vertical, 2)
                walkLabMetaRow(label: "보폭",
                                value: String(format: "%.0f mm", session.strideMm),
                                color: DFColor.textPrimary)
                walkLabMetaRow(label: "보행 주기",
                                value: String(format: "%.0f ms", session.customPeriodMs),
                                color: DFColor.textPrimary)
                walkLabMetaRow(label: "추정 속도",
                                value: String(format: "%.2f km/h",
                                              HUDMetrics.speedKmh(strideMm: session.strideMm,
                                                                  periodMs: session.customPeriodMs)),
                                color: DFColor.accent)
                walkLabMetaRow(label: "추정 cadence",
                                value: String(format: "%.0f spm",
                                              HUDMetrics.cadenceSpm(periodMs: session.customPeriodMs)),
                                color: DFColor.accent)
            }
        }
    }

    // MARK: - 2. 자세 진단 + CoM + 발목 (EST)

    /// IMU pitch/roll + HUDMetrics 모델 추정 CoM + ankle residual.
    private var attitudeAndComCard: some View {
        DFPanel(
            "자세 · 무게중심 · 발목 수평",
            subtitle: "IMU 직접 + 모델 추정 (EST)",
            icon: "figure.stand",
            tint: tiltTintColor
        ) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                Text("자세 (LIVE — IMU 직접)")
                    .font(.system(size: DFFontSize.s9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
                    .tracking(1.0)
                walkLabMetaRow(label: "Pitch",
                                value: String(format: "%+.1f°", session.displayImuPitchDeg),
                                color: tiltTintColor)
                walkLabMetaRow(label: "Roll",
                                value: String(format: "%+.1f°", session.displayImuRollDeg),
                                color: tiltTintColor)
                walkLabMetaRow(label: "Tilt max",
                                value: String(format: "%.1f° (5-tier %@)",
                                              tiltMax, tiltTier),
                                color: tiltTintColor)
                Divider().padding(.vertical, 2)
                HStack(spacing: 4) {
                    Text("무게중심 / 발목")
                        .font(.system(size: DFFontSize.s9, weight: .heavy, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                        .tracking(1.0)
                    estBadge
                }
                walkLabMetaRow(label: "CoM 전방 offset",
                                value: comSaturationText(offsetMm: comFwdMm),
                                color: comColor(pct: HUDMetrics.comSaturationPct(offsetMm: comFwdMm)))
                walkLabMetaRow(label: "CoM 측방 offset",
                                value: comSaturationText(offsetMm: comLatMm),
                                color: comColor(pct: HUDMetrics.comSaturationPct(offsetMm: comLatMm)))
                walkLabMetaRow(label: "발목 잔여각 (L)",
                                value: ankleResidualText(residual: ankleResidualLeft),
                                color: ankleColor(absResidual: abs(ankleResidualLeft)))
                walkLabMetaRow(label: "발목 잔여각 (R)",
                                value: ankleResidualText(residual: ankleResidualRight),
                                color: ankleColor(absResidual: abs(ankleResidualRight)))
                Divider().padding(.vertical, 2)
                Text("산출 (v1.11.22 정정): CoM ≈ h × sin(angle), h=220mm "
                     + "(ROBOTIS-OP2 height 454.5mm × 0.5 humanoid CoM ratio). "
                     + "발 지지 폴리곤 반경=30mm (발 width 60mm / 2, single-foot lateral). "
                     + "Ankle = sign(body) × max(0, |body|-|corrector Δ|) (magnitude 기반, "
                     + "L/R motor mirror 부호 무관 — 외부 dorsiflex 효과는 동일).")
                    .font(.system(size: DFFontSize.s9))
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 3. 낙상 예측 (v1.11.19 — 50° 임계)

    private var fallPredictorCard: some View {
        let pred = session.fallPrediction
        return DFPanel(
            "낙상 예측",
            subtitle: "v1.11.19 — 50° 임계 모델",
            icon: "exclamationmark.shield",
            tint: predictionScoreColor(pred.score)
        ) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                walkLabMetaRow(label: "score",
                                value: String(format: "%.0f / 100", pred.score),
                                color: predictionScoreColor(pred.score))
                walkLabMetaRow(label: "안정성 (역수)",
                                value: String(format: "%.0f / 100", max(0, 100 - pred.score)),
                                color: predictionScoreColor(pred.score))
                if let eta = pred.etaMs {
                    walkLabMetaRow(label: "ETA (50° 도달)",
                                    value: HUDMetrics.formatLag(eta),
                                    color: eta < 400 ? DFColor.danger : DFColor.warning)
                } else {
                    walkLabMetaRow(label: "ETA",
                                    value: "안정 (회복 중 또는 임계 이하)",
                                    color: DFColor.textSecondary)
                }
                walkLabMetaRow(label: "권고",
                                value: pred.recommendEmergency
                                    ? "위험 임박 (선제 경고)"
                                    : "정상",
                                color: pred.recommendEmergency
                                    ? DFColor.danger
                                    : DFColor.success)
                Divider().padding(.vertical, 2)
                Text("모델: tilt 60점 (max @ 50°) + tilt_rate 30점 (max @ 60dps) "
                     + "+ gyro_variance 10점. score ≥ 80 또는 ETA < 400ms → 권고.")
                    .font(.system(size: DFFontSize.s9))
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text("주의: 권고는 이벤트 로그만 — 실 motor torque-off 는 별도 layer.")
                    .font(.system(size: DFFontSize.s9, weight: .semibold))
                    .foregroundStyle(DFColor.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers — derived

    private var tiltMax: Double {
        max(abs(session.displayImuRollDeg), abs(session.displayImuPitchDeg))
    }

    private var tiltTintColor: Color {
        if tiltMax >= 50 { return DFColor.danger }
        if tiltMax >= 45 { return DFColor.severe }
        if tiltMax >= 35 { return DFColor.warning }
        if tiltMax >= 25 { return DFColor.warning.opacity(0.7) }
        return DFColor.success
    }

    private var tiltTier: String {
        if tiltMax >= 50 { return "emergency" }
        if tiltMax >= 45 { return "danger" }
        if tiltMax >= 35 { return "warning" }
        if tiltMax >= 25 { return "caution" }
        return "normal"
    }

    private var comFwdMm: Double {
        HUDMetrics.comOffsetMm(angleDeg: session.displayImuPitchDeg)
    }

    private var comLatMm: Double {
        HUDMetrics.comOffsetMm(angleDeg: session.displayImuRollDeg)
    }

    private var ankleResidualLeft: Double {
        HUDMetrics.ankleResidualDeg(
            bodyPitch: session.displayImuPitchDeg,
            correctionAnklePitch: session.lastCorrections?.lAnklePitch,
            correctorEnabled: session.enableBalanceCorrection,
            actuallyApplied: session.lastCorrectionApplied
        )
    }

    private var ankleResidualRight: Double {
        HUDMetrics.ankleResidualDeg(
            bodyPitch: session.displayImuPitchDeg,
            correctionAnklePitch: session.lastCorrections?.rAnklePitch,
            correctorEnabled: session.enableBalanceCorrection,
            actuallyApplied: session.lastCorrectionApplied
        )
    }

    // MARK: - Helpers — color

    private var balanceStateColor: Color {
        switch session.balanceState {
        case .normal:    return DFColor.success
        case .caution:   return DFColor.warning
        case .warning:   return DFColor.severe
        case .danger, .emergency: return DFColor.danger
        }
    }

    private var balanceStateLabel: String {
        switch session.balanceState {
        case .normal:    return "정상 — 임계 미초과"
        case .caution:   return "주의 (25° 이상)"
        case .warning:   return "경고 (35° 이상)"
        case .danger:    return "위험 (45° 이상)"
        case .emergency: return "비상 (50° — 자동 정지)"
        }
    }

    private func comColor(pct: Double) -> Color {
        if pct >= 100 { return DFColor.danger }
        if pct >= 70  { return DFColor.severe }
        if pct >= 40  { return DFColor.warning }
        return DFColor.success
    }

    private func ankleColor(absResidual: Double) -> Color {
        if absResidual >= 6 { return DFColor.danger }
        if absResidual >= 3 { return DFColor.warning }
        if absResidual >= 1 { return DFColor.warning.opacity(0.7) }
        return DFColor.success
    }

    private func predictionScoreColor(_ score: Double) -> Color {
        if score >= 80 { return DFColor.danger }
        if score >= 60 { return DFColor.severe }
        if score >= 30 { return DFColor.warning }
        return DFColor.success
    }

    // MARK: - Helpers — formatting

    private func comSaturationText(offsetMm: Double) -> String {
        let pct = HUDMetrics.comSaturationPct(offsetMm: offsetMm)
        return String(format: "%+.0f mm  (지지폴리곤 %.0f%%)", offsetMm, pct)
    }

    private func ankleResidualText(residual: Double) -> String {
        let absR = abs(residual)
        let label: String = {
            if absR < 1 { return "LVL"   }
            if absR < 3 { return "OK"    }
            if absR < 6 { return "DEV"   }
            return "TILT"
        }()
        return String(format: "%+.1f° (%@)", residual, label)
    }

    // MARK: - Helpers — UI

    /// metaRow 패턴 — WalkDiagnosticsView 의 private metaRow 와 동일 구조 (재구현).
    private func walkLabMetaRow(label: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DFSpace.xs2) {
            Text(label)
                .font(.system(size: DFFontSize.s10, weight: .medium))
                .foregroundStyle(DFColor.textSecondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: DFFontSize.s10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
    }

    /// EST 배지 — 모델 추정 데이터 명시.
    private var estBadge: some View {
        Text("EST")
            .font(.system(size: DFFontSize.s8, weight: .heavy, design: .monospaced))
            .foregroundStyle(DFColor.warning)
            .tracking(0.5)
            .padding(.horizontal, 3)
            .padding(.vertical, 0.5)
            .background(DFColor.warning.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(DFColor.warning.opacity(0.5), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

#if DEBUG
#Preview("Idle (no walking)") {
    let session = WalkLabSession()
    return WalkLabIntegrationCards()
        .environment(session)  // @Observable 마이그레이션 v1.14.9
        .frame(width: 360)
        .padding()
        .background(DFColor.canvas)
}

#Preview("Walking + Corrector ON") {
    let session = WalkLabSession()
    session.strideMm = 80
    session.customPeriodMs = 600
    session.phaseLabel = "PHASE3"
    session.imuRollDeg = 12
    session.imuPitchDeg = -8
    session.enableBalanceCorrection = true
    return WalkLabIntegrationCards()
        .environment(session)  // @Observable 마이그레이션 v1.14.9
        .frame(width: 360)
        .padding()
        .background(DFColor.canvas)
}

#Preview("Danger state (45°+)") {
    let session = WalkLabSession()
    session.strideMm = 60
    session.customPeriodMs = 700
    session.phaseLabel = "PHASE2"
    session.imuRollDeg = 47
    session.imuPitchDeg = 15
    return WalkLabIntegrationCards()
        .environment(session)  // @Observable 마이그레이션 v1.14.9
        .frame(width: 360)
        .padding()
        .background(DFColor.canvas)
}
#endif
