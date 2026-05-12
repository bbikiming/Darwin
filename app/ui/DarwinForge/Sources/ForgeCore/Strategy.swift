import CForgeCore
import Foundation

/// 전략 FSM 5상태.
public enum StrategyState: UInt8, CaseIterable, Sendable {
    case idle             = 0
    case lookingForBall   = 1
    case approachingBall  = 2
    case kicking          = 3
    case cooldown         = 4

    public var label: String {
        switch self {
        case .idle:            return "Idle"
        case .lookingForBall:  return "Looking for Ball"
        case .approachingBall: return "Approaching Ball"
        case .kicking:         return "Kicking"
        case .cooldown:        return "Cooldown"
        }
    }
}

/// 한 step 전이.
public enum Strategy {
    public static func step(
        from state: StrategyState,
        ballPixelCount: UInt32,
        sinceKickMs: UInt32,
        abort: Bool
    ) -> StrategyState {
        let next = fc_strategy_step(state.rawValue, ballPixelCount, sinceKickMs, abort ? 1 : 0)
        return StrategyState(rawValue: next) ?? .idle
    }
}
