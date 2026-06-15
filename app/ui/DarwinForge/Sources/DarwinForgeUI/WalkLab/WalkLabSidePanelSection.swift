import ForgeCore
import SwiftUI

/// 사이클 V281-1 (V280-A1) — `WalkLabView` 우측 사이드 패널 (2 disclosure 그룹) 분리.
///
/// # 비유
///
/// 자동차 dashboard 우측의 **계기판 cluster** — 운용 (속도/연료/RPM) 와 진단
/// (engine temp/voltage) 를 2 그룹 으로 묶어 정보 hierarchy 표현. 동일하게
/// 보행 중 핵심 (`runGroup`) 과 분석 보조 (`diagGroup`) 분리.
///
/// # 책임 (Single Responsibility)
///
/// - **운용 (Run) 그룹** (기본 OPEN, Apple HIG Progressive Disclosure):
///   `FootTrailCanvas` + IMU 출처 라벨 + `balanceStateCard`
/// - **진단 (Diagnostics) 그룹** (기본 CLOSED, IBM Carbon IA secondary):
///   `FallPredictionCard` + `balanceCorrectionCard` + `IMUGauge` × 2
///
/// # 비-책임 (절대 안 함)
///
/// - 3D scene rendering
/// - actionBar / banner / sidebar
/// - session lifecycle
///
/// # 의존성
///
/// - `@Environment(WalkLabSession.self)` — 보행 상태 read + balance toggle write
/// - `@Binding var expandedRunGroup` — 부모 `@AppStorage` 와 연결
/// - `@Binding var expandedDiagGroup` — 부모 `@AppStorage` 와 연결
///
/// behavior 0 변경 — V281-1 이전 inline 구현과 layout / animation / visibility
/// 모두 동일 (pure structural refactoring).
struct WalkLabSidePanelSection: View {
    @Environment(WalkLabSession.self) private var session
    @Binding var expandedRunGroup: Bool
    @Binding var expandedDiagGroup: Bool

    var body: some View {
        VStack(spacing: DFSpace.sm) {
            DisclosureGroup(isExpanded: $expandedRunGroup) {
                runGroupBody
                    .padding(.top, DFSpace.xs)
            } label: {
                WalkLabDisclosureHeader(icon: "play.circle.fill",
                                       title: "운용",
                                       subtitle: "보행 중 핵심")
            }
            DisclosureGroup(isExpanded: $expandedDiagGroup) {
                diagGroupBody
                    .padding(.top, DFSpace.xs)
            } label: {
                WalkLabDisclosureHeader(icon: "waveform.path.ecg",
                                       title: "진단",
                                       subtitle: "예측·보정·IMU 게이지")
            }
        }
    }

    /// "운용" 그룹 본문 — 보행 중 항상 참조하는 정보.
    private var runGroupBody: some View {
        VStack(spacing: DFSpace.sm2) {
            FootTrailCanvas(trail: session.footTrail,
                            leftFoot: session.leftFoot,
                            rightFoot: session.rightFoot)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
                .overlay(
                    RoundedRectangle(cornerRadius: DFRadius.button)
                        .stroke(DFColor.textSecondary.opacity(DFOpacity.o20),
                                lineWidth: DFSize.borderHairline)
                )
            // **Stage 1 (v1.1 fall prevention)**: 실 IMU 출처 라벨 표시.
            HStack(spacing: DFSpace.xs) {
                Circle()
                    .fill(imuSourceColor)
                    .frame(width: DFSize.indicatorXxs,
                           height: DFSize.indicatorXxs)
                Text("IMU 출처: \(session.imuSource.label)")
                    .font(DFFont.monoLabel)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
            }
            // **Stage 2 (v1.1 fall prevention)**: 안전 상태 + 자동 보정 토글.
            balanceStateCard
        }
    }

    /// "진단" 그룹 본문 — 분석/실험 시 펼침. 기본 CLOSED.
    private var diagGroupBody: some View {
        VStack(spacing: DFSpace.sm2) {
            // **Stage 5 (v1.1 fall prevention)**: 예측 score + ETA.
            FallPredictionCard(prediction: session.fallPrediction,
                               imuSource: session.imuSource)
            // **Stage 4 (v1.1 fall prevention)**: balance correction 토글 + delta 미리보기.
            balanceCorrectionCard
            IMUGauge(axis: "Roll", degrees: session.displayImuRollDeg, dangerThreshold: 50)
            IMUGauge(axis: "Pitch", degrees: session.displayImuPitchDeg, dangerThreshold: 50)
        }
    }

    /// **Stage 1 (v1.1 fall prevention)**: IMU 출처별 색.
    /// sim = 회색 (참고용), real = 녹색 (정상), stale = 주황 (경고).
    private var imuSourceColor: Color {
        switch session.imuSource {
        case .sim:   return DFColor.textSecondary
        case .real:  return DFColor.success
        case .stale: return DFColor.warning
        }
    }

    /// **Stage 2 (v1.1 fall prevention)**: 안전 상태 카드 + 자동 보정 토글.
    /// 2026-05-16: design system 토큰화 완료 (raw 4/6/8/0.10/0.4/0.5 → DFSpace/DFOpacity/DFSize).
    private var balanceStateCard: some View {
        // **v1.14.9 (2026-05-21) Fix #7**: @Observable session — local @Bindable.
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: DFSpace.xs) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: balanceStateIcon)
                    .font(DFFont.bodySmall)
                    .foregroundStyle(balanceStateColor)
                Text("안전 상태: \(session.balanceState.label)")
                    .font(DFFont.captionEmph)
                    .foregroundStyle(balanceStateColor)
                    .lineLimit(1)
                Spacer()
            }
            if session.balanceState >= .warning {
                Text(balanceStateMessage)
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("자동 균형 보정", isOn: $session.autoFallPrevention)
                .toggleStyle(.checkbox)
                .font(DFFont.label)
                .help("기울기 임계 도달 시 자동 감속/동결 — OFF 시 50° emergency 만 작동")
        }
        .padding(DFSpace.sm)
        .background(balanceStateColor.opacity(DFOpacity.o10))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.button)
                .stroke(balanceStateColor.opacity(DFOpacity.o40),
                        lineWidth: DFSize.borderHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("안전 상태 카드 — \(session.balanceState.label)")
    }

    private var balanceStateIcon: String {
        switch session.balanceState {
        case .normal:    return "checkmark.circle.fill"
        case .caution:   return "exclamationmark.circle"
        case .warning:   return "exclamationmark.triangle.fill"
        case .danger:    return "exclamationmark.octagon.fill"
        case .emergency: return "xmark.octagon.fill"
        }
    }

    private var balanceStateColor: Color {
        switch session.balanceState {
        case .normal:    return DFColor.success
        case .caution:   return DFColor.warning
        case .warning:   return DFColor.severe
        case .danger:    return DFColor.danger
        case .emergency: return DFColor.danger
        }
    }

    private var balanceStateMessage: String {
        switch session.balanceState {
        case .warning:   return "기울기 35°+ — 보행 속도 70% 자동 감속"
        case .danger:    return "기울기 45°+ — 자세 동결 (보행 일시 정지)"
        case .emergency: return "기울기 50°+ — 토크 OFF + walkReady 복귀"
        default:         return ""
        }
    }

    /// **Stage 4 (v1.1 fall prevention)**: balance correction 토글 + delta 미리보기.
    /// 2026-05-16: design system 토큰화 완료.
    private var balanceCorrectionCard: some View {
        // **v1.14.9 (2026-05-21) Fix #7**: @Observable session — local @Bindable.
        @Bindable var session = session
        return VStack(alignment: .leading, spacing: DFSpace.xs) {
            // **v1.15.5 (2026-05-21) Phase 1.5**: enableBalanceCorrection 의 apply scope.
            // Onboard 모드에선 .macSparseOnly — 펌웨어 자체 보정 알고리즘 사용 (Mac 토글 무의미).
            HStack {
                Spacer()
                WalkLabApplyScopeBadge(
                    scope: WalkLabApplyScopeResolver.scope(
                        for: .enableBalanceCorrection, engine: session.walkingEngine
                    ),
                    style: .compact
                )
            }
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "figure.balanced")
                    .font(DFFont.bodySmall)
                    .foregroundStyle(session.enableBalanceCorrection
                                     ? DFColor.success
                                     : DFColor.textSecondary)
                Toggle("자세 보정 (실험)", isOn: $session.enableBalanceCorrection)
                    .toggleStyle(.checkbox)
                    .font(DFFont.label)
                    .help(session.enableBalanceCorrection
                          ? "현재 ON — Walking.cpp sensoryFeedback 패턴 적용 중. 1초 ramp."
                          : "ROBOTIS Walking.cpp 패턴 corrector — 실 robot 검증 후 활성 권장")
                Spacer()
            }
            if session.enableBalanceCorrection {
                if let c = session.lastCorrections {
                    HStack(spacing: DFSpace.xs) {
                        Text(String(format: "hipRoll %+.1f°", c.rHipRoll))
                            .font(DFFont.monoLabel)
                        Text(String(format: "knee %+.1f°", c.rKnee))
                            .font(DFFont.monoLabel)
                    }
                    .foregroundStyle(DFColor.textSecondary)
                    HStack(spacing: DFSpace.xs) {
                        Text(String(format: "ankP %+.1f°", c.rAnklePitch))
                            .font(DFFont.monoLabel)
                        Text(String(format: "ankR %+.1f°", c.rAnkleRoll))
                            .font(DFFont.monoLabel)
                    }
                    .foregroundStyle(DFColor.textSecondary)
                } else {
                    Text("ROBOTIS Walking.cpp::sensoryFeedback 패턴 (gain 0.5/0.3/1.0/0.9)")
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textSecondary)
                }
            } else {
                Text("기본 OFF — 실 robot 검증 + Codex audit 후 활성화 권장")
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(DFSpace.sm)
        .background(DFColor.textSecondary.opacity(DFOpacity.ghost))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.button)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.o25),
                        lineWidth: DFSize.borderHairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.enableBalanceCorrection
            ? "자세 보정 ON — 최대 보정 \(String(format: "%.1f", session.lastCorrections?.maxAbs ?? 0))°"
            : "자세 보정 OFF")
    }
}

/// 사이클 V281-1 — `WalkLabSidePanelSection` 과 `WalkLabAuxSection` 공통 헤더.
///
/// IBM Carbon style hierarchy (primary title + secondary descriptor).
/// 부 view 2 개가 동일한 `disclosureHeader(icon:title:subtitle:)` 헬퍼를 쓰던 것을
/// 단일 view 로 추출 (DRY) — 종전 1427 LOC view 내부 private func.
struct WalkLabDisclosureHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: icon)
                .font(DFFont.bodySmall)
                .foregroundStyle(DFColor.accent)
                .frame(width: DFSpace.md, alignment: .center)
            VStack(alignment: .leading, spacing: DFSpace.micro) {
                Text(title)
                    .font(DFFont.bodySmallEmph)
                    .foregroundStyle(DFColor.textPrimary)
                Text(subtitle)
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
    }
}
