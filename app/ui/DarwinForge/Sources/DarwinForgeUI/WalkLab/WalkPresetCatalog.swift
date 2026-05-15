import ForgeCore
import SwiftUI

/// SwiftUI 측 보행 프리셋 — `forge-core::walk::preset::WalkPreset` 와 1:1.
///
/// Rust 코어의 enum 변형이 새로 추가되면 본 enum도 같이 갱신해야 한다.
/// 임시로 SwiftUI 측에 재정의하는 이유:
/// - forge-ffi 가 `fc_walk_apply_preset` 같은 함수를 아직 export 하지 않음
/// - 정확한 안전 등급 / 한국어 라벨 / SF Symbol 을 UI 측이 직접 보유해야 인터넷 없이 즉시 표시
///
/// 향후 forge-ffi 에 enum + 한국어 라벨 export 추가 시 본 파일은 thin wrapper 로 축소.
public enum WalkLabPreset: String, CaseIterable, Identifiable, Hashable {
    case idle, march, slowWalk, normalWalk, fastWalk, jog, turnLeft, turnRight

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .idle: return "정지"
        case .march: return "제자리 걸음"
        case .slowWalk: return "천천히 걷기"
        case .normalWalk: return "보통 속도"
        case .fastWalk: return "빠르게 걷기"
        case .jog: return "공 접근+오른발 킥"
        case .turnLeft: return "좌회전"
        case .turnRight: return "우회전"
        }
    }

    public var icon: String {
        switch self {
        case .idle: return "pause.circle.fill"
        case .march: return "figure.walk.motion"
        case .slowWalk: return "tortoise.fill"
        case .normalWalk: return "figure.walk"
        case .fastWalk: return "hare.fill"
        case .jog: return "soccerball"
        case .turnLeft: return "arrow.turn.up.left"
        case .turnRight: return "arrow.turn.up.right"
        }
    }

    /// `forge-core::walk::WalkCommand` 와 등가.
    public var command: (x: Double, y: Double, a: Double, enabled: Bool) {
        switch self {
        case .idle:       return (0, 0, 0, false)
        case .march:      return (0, 0, 0, true)
        case .slowWalk:   return (0.015, 0, 0, true)
        case .normalWalk: return (0.025, 0, 0, true)
        case .fastWalk:   return (0.035, 0, 0, true)
        case .jog:        return (0.024, 0, 0, true)
        case .turnLeft:   return (0.010, 0, 0.10, true)
        case .turnRight:  return (0.010, 0, -0.10, true)
        }
    }

    public var periodMs: UInt32 {
        switch self {
        case .fastWalk: return 500
        case .jog:      return 620
        default:        return 600
        }
    }

    public var safety: WalkLabSafety {
        switch self {
        case .idle, .march, .slowWalk, .normalWalk:
            return .safe
        case .fastWalk, .turnLeft, .turnRight:
            return .caution
        case .jog:
            return .highRisk
        }
    }

    /// 자동 stop 시간 (초). 0 = ∞.
    public var maxDurationSec: Int {
        switch self {
        case .idle:                                      return 0
        case .march:                                     return 30
        case .slowWalk, .normalWalk:                     return 60
        case .fastWalk, .turnLeft, .turnRight:           return 30
        case .jog:                                       return 4
        }
    }

    public var warning: String? {
        switch self {
        case .fastWalk:
            return "ROBOTIS 기본 600ms → 500ms 단축 변형. 무릎/발목 부하 증가."
        case .jog:
            return "ROBOTIS SOCCER 데모 흐름: walking 접근 후 page 12 오른발 킥. 정비 스탠드 + 전방 50cm 빈 공간 필수."
        case .turnLeft, .turnRight:
            return "회전 시 좌·우 발 위상 차이로 균형 흔들림 가능."
        default:
            return nil
        }
    }

    public var requiresRiskConfirmation: Bool {
        safety == .highRisk
    }
}

public enum WalkLabSafety: String, Hashable {
    case safe, caution, highRisk

    /// 디자인 시스템 매핑 — DFColor 사용 (사용자 Mac 측에서 보강).
    /// 기본은 SwiftUI 표준 색.
    public var tintColor: Color {
        switch self {
        case .safe:     return .green
        case .caution:  return .orange
        case .highRisk: return .red
        }
    }

    public var labelKo: String {
        switch self {
        case .safe:     return "안전"
        case .caution:  return "주의"
        case .highRisk: return "위험"
        }
    }
}
