import SwiftUI

/// 사이클 152 (사용자 권고 #1, IMPLEMENTATION audit followup):
/// 앱 전체 공통 상태 배지 — "실제로 되는 것처럼 보이는 UI" 차단용 통합 분류.
///
/// # 비유
///
/// 식당의 음식 라벨과 같음. "이건 조리됨 / 시뮬레이션 / 예약만 / 준비 중" 을 한눈에.
/// 종전: 각 화면이 자기만의 표현 (`[placeholder]` prefix / "추정 진행" / "preview blend" /
/// "DJI SDK 미통합" / WalkLabApplyScopeBadge `.disabledOnboard`) → 사용자가 같은 의미를
/// 다른 모양으로 보게 됨.
/// 신규: 본 enum + DFStatusBadgeView 가 색상 / 아이콘 / 라벨 / a11y 일원화.
///
/// # 기존 ad-hoc 배지 migration 매핑
///
/// | 기존 | 신규 case |
/// |------|----------|
/// | `WalkLabApplyScopeBadge(.disabledOnboard)` | `.simulationOnly` |
/// | `WalkLabApplyScopeBadge(.macSparseOnly)` | `.simulationOnly` |
/// | `PilotTransitionOverlay estimatedProgressBadge` | `.estimatedProgress` |
/// | `[placeholder]` prefix (Get Up Front 등) | `.placeholder` |
/// | MotionBlender "preview blend" | `.previewOnly` |
/// | `DJI Controller "SDK 미통합"` | `.sdkUnavailable` |
/// | SynthInspectorPanel "미검증" | `.unverified` |
/// | ClaudeCritic "추후 통합" | `.futureIntegration` |
/// | "실로봇 송출 진행" / robot connected | `.appliedToRobot` |
///
/// 본 사이클은 enum + view + 테스트만 정의. **migration 은 점진 (별도 사이클)** —
/// 기존 호출자는 그대로 동작.
public enum DFStatusBadge: String, Sendable, Hashable, CaseIterable {
    /// 실제 로봇에 송출 / 적용됨. 사용자가 신뢰할 수 있는 결정 신호.
    case appliedToRobot
    /// 시뮬레이션만 — Mac sparse engine / Onboard 미송신 / sim trial.
    case simulationOnly
    /// 추정 진행 — Task.sleep timer 기반, 실 robot stage polling 안 함.
    case estimatedProgress
    /// Preview only — MotionBlender 등 sim composition, motor 미송출.
    case previewOnly
    /// 미검증 — synth in-app validate 안 됨, CLI 별도 검증 필요.
    case unverified
    /// SDK 미연결 — DJI Controller stub, mock 만 동작.
    case sdkUnavailable
    /// Placeholder — walkReady hold 등 미완성 구현 (Get Up Front 등).
    case placeholder
    /// 준비 중 — claudeCritic / WalkComparisonTag 등 미래 통합 hook.
    case futureIntegration

    /// 한국어 라벨 — 사용자 표시.
    public var koreanLabel: String {
        switch self {
        case .appliedToRobot:     return "실 로봇 적용됨"
        case .simulationOnly:     return "시뮬레이션"
        case .estimatedProgress:  return "추정 진행"
        case .previewOnly:        return "Preview only"
        case .unverified:         return "미검증"
        case .sdkUnavailable:     return "SDK 미연결"
        case .placeholder:        return "Placeholder"
        case .futureIntegration:  return "준비 중"
        }
    }

    /// SF Symbol — 색맹 보강 (color + shape).
    public var icon: String {
        switch self {
        case .appliedToRobot:     return "checkmark.seal.fill"
        case .simulationOnly:     return "cpu"
        case .estimatedProgress:  return "clock.badge.exclamationmark"
        case .previewOnly:        return "eye"
        case .unverified:         return "questionmark.diamond"
        case .sdkUnavailable:     return "link.badge.plus"
        case .placeholder:        return "square.dashed"
        case .futureIntegration:  return "hourglass"
        }
    }

    /// 디자인 시스템 색상.
    public var tintColor: Color {
        switch self {
        case .appliedToRobot:     return DFColor.success
        case .simulationOnly:     return DFColor.info
        case .estimatedProgress:  return DFColor.warning
        case .previewOnly:        return DFColor.info
        case .unverified:         return DFColor.warning
        case .sdkUnavailable:     return DFColor.textSecondary
        case .placeholder:        return DFColor.textSecondary
        case .futureIntegration:  return DFColor.textSecondary
        }
    }

    /// VoiceOver / WCAG 1.4.1 보강 — 색맹 사용자도 의미 식별 가능.
    public var accessibilityLabel: String {
        switch self {
        case .appliedToRobot:
            return "상태: 실 로봇에 적용됨 — 사용자가 신뢰할 수 있는 결과"
        case .simulationOnly:
            return "상태: 시뮬레이션 — 실 로봇 송출 없음"
        case .estimatedProgress:
            return "상태: 추정 진행 — 실 로봇 단계 확인 안 됨"
        case .previewOnly:
            return "상태: Preview only — 시각화 / blender 합성, 모터 송출 없음"
        case .unverified:
            return "상태: 미검증 — 앱 내부 검증 없음, 외부 도구 필요"
        case .sdkUnavailable:
            return "상태: SDK 미연결 — production 입력 소스 없음, mock 만 동작"
        case .placeholder:
            return "상태: Placeholder — 미완성 구현, walkReady hold 만"
        case .futureIntegration:
            return "상태: 준비 중 — 후속 통합 예정"
        }
    }

    /// 사용자가 본 배지가 표시된 항목을 **실 로봇에 안전하게 적용 가능한가**.
    /// 사이클 153 sim 추천 confirmation 등에서 사용.
    public var safeForRealRobot: Bool {
        switch self {
        case .appliedToRobot:
            return true
        case .simulationOnly, .estimatedProgress, .previewOnly,
             .unverified, .sdkUnavailable, .placeholder, .futureIntegration:
            return false
        }
    }
}

// MARK: - View component

/// 통합 상태 배지 SwiftUI view.
///
/// Style:
/// - `.compact`: 작은 아이콘 + 라벨 (일반 toolbar / row trailing).
/// - `.full`: 큰 아이콘 + 라벨 + tooltip (헤더 / 강조 위치).
/// - `.iconOnly`: 아이콘만 (좁은 공간).
public struct DFStatusBadgeView: View {
    public let badge: DFStatusBadge
    public let style: Style

    public init(_ badge: DFStatusBadge, style: Style = .compact) {
        self.badge = badge
        self.style = style
    }

    public enum Style: Sendable {
        case compact, full, iconOnly
    }

    public var body: some View {
        switch style {
        case .compact:
            compactBody
        case .full:
            fullBody
        case .iconOnly:
            iconOnlyBody
        }
    }

    private var compactBody: some View {
        HStack(spacing: 4) {
            Image(systemName: badge.icon)
                .font(.system(size: 11, weight: .semibold))
            Text(badge.koreanLabel)
                .font(.caption)
        }
        .foregroundStyle(badge.tintColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(badge.tintColor.opacity(0.12))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.accessibilityLabel)
    }

    private var fullBody: some View {
        HStack(spacing: 6) {
            Image(systemName: badge.icon)
                .font(.system(size: 14, weight: .semibold))
            Text(badge.koreanLabel)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(badge.tintColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(badge.tintColor.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(badge.tintColor.opacity(0.4), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.accessibilityLabel)
        .help(badge.accessibilityLabel)
    }

    private var iconOnlyBody: some View {
        Image(systemName: badge.icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(badge.tintColor)
            .padding(3)
            .background(
                Circle().fill(badge.tintColor.opacity(0.15))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge.accessibilityLabel)
            .help(badge.accessibilityLabel)
    }
}
