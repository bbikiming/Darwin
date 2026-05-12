import Foundation

/// 관절 raw 위치 ↔ 각도 변환 + 안전 한계 + 본 트리.
///
/// 출처: `docs/architecture/joint-conventions.md` + `forge-core::joint::position_to_radians`.
/// MX-28T 12-bit position: `0..4095`, 2048 = 0 rad.
public enum Kinematics {
    /// 한 보각도(=한 step in raw position) 라디안 값.
    public static let radiansPerStep: Double = .pi / 2048.0

    /// raw position → 라디안.
    @inlinable
    public static func radians(fromRaw raw: Int) -> Double {
        Double(raw - 2048) * radiansPerStep
    }

    /// raw position → 도(°).
    @inlinable
    public static func degrees(fromRaw raw: Int) -> Double {
        Double(raw - 2048) * (180.0 / 2048.0)
    }

    /// 라디안 → raw position (0..4095 클램프).
    @inlinable
    public static func raw(fromRadians rad: Double) -> Int {
        let v = (rad / radiansPerStep) + 2048.0
        return Int(v.rounded()).clamped(to: 0...4095)
    }

    /// 도 → raw position.
    @inlinable
    public static func raw(fromDegrees deg: Double) -> Int {
        let v = deg * (2048.0 / 180.0) + 2048.0
        return Int(v.rounded()).clamped(to: 0...4095)
    }
}

// MARK: - JointID 각도 확장

extension JointID {
    /// 보수적 각도 한계 (도) — ROBOTIS-OP2 e-Manual + DARwIn-OP framework JointData.h 기반.
    public var degreeLimits: ClosedRange<Double> {
        switch self {
        case .rShoulderPitch, .lShoulderPitch: return -180...180
        case .rShoulderRoll, .lShoulderRoll:    return -90...90
        case .rElbow, .lElbow:                   return 0...150
        case .rHipYaw, .lHipYaw:                 return -90...90
        case .rHipRoll, .lHipRoll:               return -45...45
        case .rHipPitch, .lHipPitch:             return -90...60
        case .rKnee, .lKnee:                     return 0...150
        case .rAnklePitch, .lAnklePitch:         return -75...90
        case .rAnkleRoll, .lAnkleRoll:           return -45...45
        case .headPan:                           return -90...90
        case .headTilt:                          return -45...45
        }
    }

    /// 한계를 raw position 단위로.
    public var rawLimits: ClosedRange<Int> {
        let lo = Kinematics.raw(fromDegrees: degreeLimits.lowerBound)
        let hi = Kinematics.raw(fromDegrees: degreeLimits.upperBound)
        return min(lo, hi)...max(lo, hi)
    }

    /// 회전 축 — 3D 시각화에서 어느 축으로 회전하는지.
    public var rotationAxis: SIMD3<Double> {
        switch self {
        // Pitch (Y축) — 측면에서 본 회전
        case .rShoulderPitch, .lShoulderPitch,
             .rElbow, .lElbow,
             .rHipPitch, .lHipPitch,
             .rKnee, .lKnee,
             .rAnklePitch, .lAnklePitch,
             .headTilt:
            return SIMD3(0, 1, 0)
        // Roll (X축) — 정면에서 본 회전
        case .rShoulderRoll, .lShoulderRoll,
             .rHipRoll, .lHipRoll,
             .rAnkleRoll, .lAnkleRoll:
            return SIMD3(1, 0, 0)
        // Yaw (Z축) — 위에서 본 회전
        case .rHipYaw, .lHipYaw, .headPan:
            return SIMD3(0, 0, 1)
        }
    }

    /// 한국어 라벨 (UI / 음성 응답용).
    public var koreanLabel: String {
        switch self {
        case .rShoulderPitch: return "오른쪽 어깨 (앞뒤)"
        case .lShoulderPitch: return "왼쪽 어깨 (앞뒤)"
        case .rShoulderRoll:  return "오른쪽 어깨 (벌리기)"
        case .lShoulderRoll:  return "왼쪽 어깨 (벌리기)"
        case .rElbow:         return "오른쪽 팔꿈치"
        case .lElbow:         return "왼쪽 팔꿈치"
        case .rHipYaw:        return "오른쪽 골반 (회전)"
        case .lHipYaw:        return "왼쪽 골반 (회전)"
        case .rHipRoll:       return "오른쪽 골반 (벌리기)"
        case .lHipRoll:       return "왼쪽 골반 (벌리기)"
        case .rHipPitch:      return "오른쪽 골반 (앞뒤)"
        case .lHipPitch:      return "왼쪽 골반 (앞뒤)"
        case .rKnee:          return "오른쪽 무릎"
        case .lKnee:          return "왼쪽 무릎"
        case .rAnklePitch:    return "오른쪽 발목 (앞뒤)"
        case .lAnklePitch:    return "왼쪽 발목 (앞뒤)"
        case .rAnkleRoll:     return "오른쪽 발목 (벌리기)"
        case .lAnkleRoll:     return "왼쪽 발목 (벌리기)"
        case .headPan:        return "목 (좌우)"
        case .headTilt:       return "목 (위아래)"
        }
    }

    /// 좌우 거울 짝 — `pose.mirror()`에서 사용.
    public var mirrored: JointID {
        switch self {
        case .rShoulderPitch: return .lShoulderPitch
        case .lShoulderPitch: return .rShoulderPitch
        case .rShoulderRoll:  return .lShoulderRoll
        case .lShoulderRoll:  return .rShoulderRoll
        case .rElbow:         return .lElbow
        case .lElbow:         return .rElbow
        case .rHipYaw:        return .lHipYaw
        case .lHipYaw:        return .rHipYaw
        case .rHipRoll:       return .lHipRoll
        case .lHipRoll:       return .rHipRoll
        case .rHipPitch:      return .lHipPitch
        case .lHipPitch:      return .rHipPitch
        case .rKnee:          return .lKnee
        case .lKnee:          return .rKnee
        case .rAnklePitch:    return .lAnklePitch
        case .lAnklePitch:    return .rAnklePitch
        case .rAnkleRoll:     return .lAnkleRoll
        case .lAnkleRoll:     return .rAnkleRoll
        case .headPan, .headTilt: return self
        }
    }

    /// 거울 시 부호 반전이 필요한가 (yaw/roll 축은 좌우 대칭이므로 부호 반전).
    public var mirrorSignFlip: Bool {
        switch self {
        case .rShoulderRoll, .lShoulderRoll,
             .rHipYaw, .lHipYaw,
             .rHipRoll, .lHipRoll,
             .rAnkleRoll, .lAnkleRoll,
             .headPan:
            return true
        default:
            return false
        }
    }
}

// MARK: - Comparable clamp helper

extension Comparable {
    @inlinable
    public func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
