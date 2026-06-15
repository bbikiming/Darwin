import Foundation
import ForgeCore

/// **v1.18.0 (2026-05-21) Phase 3 — motion 전환 안전 정책**.
///
/// architect FIX-3: 기존 `WalkLabSession.BalanceState.speedScale` 정책 재사용 — 중복 없음.
///
/// # 정책 매트릭스
///
/// | balanceState | speedScale | 결정 |
/// |---|---|---|
/// | `.normal` (0..25°) | 1.0 | ✅ 모든 motion 허용 |
/// | `.caution` (25..35°) | 1.0 | ✅ 모든 motion 허용 (단 highRisk 는 confirm 필요) |
/// | `.warning` (35..45°) | 0.7 | ⚠️ upper-only motion 만 (lower 점유 차단 — 보행 변경 위험) |
/// | `.danger` (45..50°) | 0.0 | ❌ 자세 동결 — 모든 motion 차단 (emergency 제외) |
/// | `.emergency` (≥50°) | 0.0 | ❌ 강제 차단 — emergencyKill 만 허용 |
///
/// # 추가 가드
///
/// - `requireRobotConnected`: 실 robot 연결 필수 motion 인 경우 (예: highRisk page) bus nil 시 차단
/// - `requireRiskAcknowledged`: highRisk motion 시 사용자 동의 필요 (cradle 같은 패턴)
public enum MotionTransitionPolicy {

    /// motion 전환 가능 여부 결정 — pure function.
    public static func validate(
        target: MotionDescriptor,
        balanceState: WalkLabSession.BalanceState,
        robotConnected: Bool,
        riskAcknowledged: Bool
    ) -> TransitionVerdict {
        // 1. emergency / danger 상태: 모든 motion 차단.
        if balanceState == .emergency {
            return .blocked(reason: "안전 상태: emergency — emergency stop 만 허용")
        }
        if balanceState == .danger {
            return .blocked(reason: "안전 상태: danger (45°+) — 자세 동결, motion 차단")
        }
        // 2. warning 상태: lower channel 점유 motion 차단 (보행 변경 = 균형 위험).
        if balanceState == .warning {
            if target.occupiedChannels.contains(.lower) {
                return .blocked(reason: "안전 상태: warning (35°+) — 다리 motion 차단. 상체 motion 만 가능.")
            }
        }
        // 3. highRisk motion 은 사용자 동의 필요.
        if target.safetyClass == .highRisk && !riskAcknowledged {
            return .requireConfirm(reason: "위험 등급 motion — 사용자 위험 동의 필요")
        }
        // 4. caution motion 은 실 robot 연결 시에만 허용 (sim 에선 OK).
        // Note: 본 phase sim 만 — robotConnected=false 라도 OK.
        _ = robotConnected
        return .allow
    }
}

/// 전환 검증 결과.
public enum TransitionVerdict: Equatable, Sendable {
    /// 통과 — 즉시 적용.
    case allow
    /// 사용자 확인 필요 — UI 가 confirm sheet 표시.
    case requireConfirm(reason: String)
    /// 즉시 차단 — UI 가 warning 표시.
    case blocked(reason: String)

    public var isAllowed: Bool {
        switch self {
        case .allow: return true
        default: return false
        }
    }
}
