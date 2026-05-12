import Foundation

/// 모터 이동 속도 프로파일 — 자세 변경 시 보간 시간을 결정.
/// Mac 측에서 50ms 단계별로 중간 위치를 전송 (FFI 없이 동작).
public enum MotorSpeedProfile: String, CaseIterable, Codable, Sendable, Identifiable {
    case instant     // 즉시 (보간 없이 한 번에)
    case fast        // 0.5초
    case smooth      // 1.0초 (기본)
    case slow        // 2.5초
    case verySlow    // 5.0초

    public var id: String { rawValue }

    public var koreanLabel: String {
        switch self {
        case .instant:   return "즉시"
        case .fast:      return "빠르게"
        case .smooth:    return "부드럽게"
        case .slow:      return "천천히"
        case .verySlow:  return "매우 천천히"
        }
    }

    public var icon: String {
        switch self {
        case .instant:   return "forward.end.fill"
        case .fast:      return "forward.fill"
        case .smooth:    return "play.fill"
        case .slow:      return "tortoise.fill"
        case .verySlow:  return "moon.zzz.fill"
        }
    }

    /// 전체 자세 전환에 걸리는 시간 (초).
    public var durationSeconds: TimeInterval {
        switch self {
        case .instant:   return 0
        case .fast:      return 0.5
        case .smooth:    return 1.0
        case .slow:      return 2.5
        case .verySlow:  return 5.0
        }
    }

    /// 보간 step 간격 (초). 50ms = 20Hz 갱신.
    public static let stepIntervalSeconds: TimeInterval = 0.05

    public var stepCount: Int {
        let raw = durationSeconds / Self.stepIntervalSeconds
        return max(1, Int(raw.rounded()))
    }

    public var subtitle: String {
        switch self {
        case .instant:   return "보간 없이 한 번에"
        case .fast:      return "0.5초 부드럽게"
        case .smooth:    return "1초 천천히 (기본)"
        case .slow:      return "2.5초 매우 부드럽게"
        case .verySlow:  return "5초 안전 모드"
        }
    }

    /// Dynamixel MX-28T moving_speed register 값 (address 32-33).
    /// 0 = 무제한 (default), 1-1023 = 단위 0.114 rpm.
    /// 60 rpm (1초에 360°) ≈ 526. 일반 자세 변화 ≈ 60-120° → 적당한 값:
    ///   - instant:  0   (무제한, 모터 최대 속도)
    ///   - fast:     600 (~1.1초로 360°, 자세 변화 0.3-0.5초)
    ///   - smooth:   300 (~2.2초로 360°, 자세 변화 0.7-1.1초) ← 기본
    ///   - slow:     120 (~5초로 360°, 자세 변화 1.8-2.5초)
    ///   - verySlow: 60  (~11초로 360°, 자세 변화 3.5-5초)
    public var rawSpeedValue: UInt16 {
        switch self {
        case .instant:  return 0
        case .fast:     return 600
        case .smooth:   return 300
        case .slow:     return 120
        case .verySlow: return 60
        }
    }
}
