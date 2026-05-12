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
    /// 관절별 안전 각도 한계 (도) — **좌·우 대칭 signed range**.
    ///
    /// 출처: `docs/architecture/joint-conventions.md` + `forge-core::joint::state::JointLimits`.
    /// 공식 ROBOTIS-OP2 `motion_4096.bin` page 9 / `ini_pose.yaml` 의 좌측 관절 부호
    /// (`lElbow ≈ -29°`, `lKnee ≈ -53° / -130°`, `lAnklePitch ≈ -30° / -70°`) 가 자연스럽게
    /// 통과하도록 mirror joint 들을 대칭 범위로 정의. 종전엔 `0...150` 처럼 단방향이어서
    /// 좌측 음수 값이 `RobotPose.with()` 의 자동 clamp 로 0° 근처로 잘렸다.
    ///
    /// get-up page (10/11) 의 hip pitch ±100° 까지의 확장은 Rust `JointLimits` 와 함께
    /// 별도 P1 작업에서 처리 (Swift 만 독자적으로 ±110° 로 넓히지 말 것).
    public var degreeLimits: ClosedRange<Double> {
        switch self {
        case .rShoulderPitch, .lShoulderPitch: return -180...180
        case .rShoulderRoll, .lShoulderRoll:    return -90...90
        case .rElbow, .lElbow:                   return -150...150
        case .rHipYaw, .lHipYaw:                 return -90...90
        case .rHipRoll, .lHipRoll:               return -45...45
        case .rHipPitch, .lHipPitch:             return -90...90
        case .rKnee, .lKnee:                     return -150...150
        case .rAnklePitch, .lAnklePitch:         return -90...90
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

    /// 거울 시 중심(2048) 기준 반사(reflect)가 필요한가.
    ///
    /// 공식 ROBOTIS-OP2 `motion_4096.bin` page 9 기준으로 모든 좌·우 pair (pitch / roll /
    /// yaw 무관) 는 중심 반사 관계다. 예: `rKnee +53° ↔ lKnee -53°`, `rElbow +29° ↔
    /// lElbow -29°`, `rHipPitch -36° ↔ lHipPitch +36°`. `headPan` 도 좌우 방향이라 반사.
    /// 유일한 예외는 `headTilt` — 위/아래 단축이라 좌우 미러로 부호가 바뀌지 않는다.
    ///
    /// 종전엔 yaw/roll 만 반전하도록 되어 있어 knee / elbow / hipPitch / anklePitch /
    /// shoulderPitch 의 좌우 미러가 raw 그대로 복사돼 `PoseInspector` mirror mode 에서
    /// 우측 +50° 가 좌측 +50° 로 들어가는 부호 오류가 있었다. Rust `synth/ops/mirror.rs`
    /// 는 이미 모든 pair 를 reflect 한다 — Swift 도 같은 기준으로 통일.
    public var mirrorSignFlip: Bool {
        switch self {
        case .headTilt:
            return false
        default:
            return true
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
