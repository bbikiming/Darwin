import Foundation

/// 모션 안전 검증 + 부하 모니터.
///
/// 근거:
///   - ROBOTIS Dynamixel MX-28T datasheet: 안전 한계, 부하 register 정의
///   - DARwIn-OP framework C++ source (MotionManager): 이동 전 검증 패턴
///   - ROBOTIS 포럼 권장: 한 번에 큰 변화 금지, voltage 9.5V 미만 시 abort
///   - 로봇 공학 일반: trapezoidal motion + 부하 watchdog
public enum SafeMotion {

    /// 부하 임계 (백분율 0-100).
    public struct LoadLevel {
        public static let normal: Double = 30      // 정상
        public static let moderate: Double = 60    // 적당 (주의 시작)
        public static let high: Double = 80        // 높음 (경고)
        public static let critical: Double = 95    // 임계 — 즉시 abort 권장
    }

    /// 배터리 안전 임계 (V).
    public struct VoltageLevel {
        public static let healthy: Double = 11.1
        public static let warning: Double = 9.5
        public static let critical: Double = 8.5   // 이 미만 — 모든 동작 금지
    }

    /// 한 번에 변경 가능한 최대 각도 (°).
    /// 큰 변화는 모터 전류 spike + 전압 dip 유발.
    public static let maxStepDegrees: Double = 60

    /// 자세 변경 안전 검증 결과.
    public enum SafetyVerdict: Equatable {
        case safe
        case requireSplit(maxDeltaDeg: Double)  // 거리 너무 큼 — 분할 권장
        case rejectVoltage(currentV: Double)    // 전압 부족
        case rejectLoad(joint: JointID, loadPct: Double)  // 사전 부하 비정상
        case rejectLimit(joint: JointID, requestedDeg: Double, limitDeg: ClosedRange<Double>)

        public var allowsProceed: Bool {
            switch self {
            case .safe: return true
            case .requireSplit: return true  // 분할해서 진행
            default: return false
            }
        }

        public var message: String {
            switch self {
            case .safe:
                return "✓ 안전"
            case .requireSplit(let max):
                return "거리 \(Int(max))° — 분할 이동 권장"
            case .rejectVoltage(let v):
                return "배터리 부족 (\(String(format: "%.1f", v))V) — 자세 변경 위험"
            case .rejectLoad(let j, let p):
                return "\(j.koreanLabel) 부하 \(Int(p))% — 먼저 부하 해소"
            case .rejectLimit(let j, let req, let lim):
                return "\(j.koreanLabel) \(Int(req))° — 한계 \(Int(lim.lowerBound))~\(Int(lim.upperBound))°"
            }
        }
    }

    /// 자세 변경 전 안전 검증. 현재 자세 + 목표 자세 + 부하/전압 정보.
    public static func verify(
        from current: RobotPose,
        to target: RobotPose,
        voltageVolts: Double?,
        loads: [JointID: Int]
    ) -> SafetyVerdict {
        // 1. 배터리 voltage.
        if let v = voltageVolts, v > 0, v < VoltageLevel.critical {
            return .rejectVoltage(currentV: v)
        }

        // 2. 각 관절 안전 한계 검증.
        for j in JointID.allCases {
            let requestedRaw = target.positions[j] ?? 2048
            let requestedDeg = Kinematics.degrees(fromRaw: requestedRaw)
            let limits = j.degreeLimits
            if !limits.contains(requestedDeg) {
                return .rejectLimit(joint: j, requestedDeg: requestedDeg, limitDeg: limits)
            }
        }

        // 3. 사전 부하 체크 — 어떤 관절이 이미 80% 이상이면 변경 위험.
        for (j, raw) in loads {
            let absLoad = abs(Self.normalizeLoadRaw(raw))
            let pct = Double(absLoad) / 10.23
            if pct >= LoadLevel.critical {
                return .rejectLoad(joint: j, loadPct: pct)
            }
        }

        // 4. 최대 거리 — 어떤 관절이 한 번에 60° 이상 이동이면 분할 권장.
        var maxDelta: Double = 0
        for j in JointID.allCases {
            let from = Kinematics.degrees(fromRaw: current.positions[j] ?? 2048)
            let to = Kinematics.degrees(fromRaw: target.positions[j] ?? 2048)
            let delta = abs(to - from)
            if delta > maxDelta { maxDelta = delta }
        }
        if maxDelta > maxStepDegrees {
            return .requireSplit(maxDeltaDeg: maxDelta)
        }

        return .safe
    }

    /// Dynamixel present_load: 10-bit 절대값 + 11번째 비트 방향. -1024..+1023.
    /// 부호 부호화: bit10 (1024) 가 set 이면 음수.
    public static func normalizeLoadRaw(_ raw: Int) -> Int {
        let abs10 = raw & 0x3FF
        return (raw & 0x400) != 0 ? -abs10 : abs10
    }

    /// 부하 raw → 백분율 (0-100).
    public static func loadPercent(_ raw: Int) -> Double {
        let abs = Swift.abs(normalizeLoadRaw(raw))
        return min(100.0, Double(abs) / 10.23)
    }

    /// 부하 색상 분류.
    public enum LoadColor: String {
        case normal     // 초록
        case moderate   // 노랑
        case high       // 주황
        case critical   // 빨강
        case unknown    // 회색
    }

    public static func loadColor(loadPct pct: Double) -> LoadColor {
        if pct < LoadLevel.normal { return .normal }
        if pct < LoadLevel.moderate { return .moderate }
        if pct < LoadLevel.high { return .high }
        return .critical
    }
}
