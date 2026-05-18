import Foundation

/// **v1.11.5 (2026-05-18) — 보행 엔진 선택 axis**.
///
/// 사용자 보고 + 2026-05-18 분석: "WalkLab 이 ball tracking 만큼 잘 못 걷는다" 의 근본
/// 원인 = **두 모드가 같은 보행 엔진을 쓰지 않음**:
///
/// | 항목 | Mac sparse keyframe (default) | ROBOTIS onboard |
/// |---|---|---|
/// | 위치 | Mac 측 `WalkMotionLibrary` | robot-side `Walking::GetInstance()` |
/// | sample rate | 6 phase / period (~10 Hz 등가) | 8 ms 루프 (125 Hz) |
/// | IK | 단순화 X/Y/Z swap | 분석적 inverse kinematics |
/// | IMU balance closed-loop | ✗ | ✓ (gyro_x/y P+I+D) |
/// | 송출 | Mac→robot setPosition 순차 (sync write 아님) | robot 내부 direct |
/// | 데이터 보고 | Mac IMU polling 5Hz | robot-side onboard |
///
/// → 같은 robot 에서 ball tracking 은 잘 걷지만 WalkLab 은 흔들리는 이유.
///
/// **ROBOTIS onboard 모드의 구현 패턴**:
/// - `RobotSetupCommand.walkLabRobotisStart` 가 robot 에 `demo-pilot` 실행 (ball tracker 와
///   동일 패턴), 단 `/tmp/df-pilot-mode` 에 `"walklab"` 작성 → robot-side patch 가
///   `WalkLabBrokerage` 모드로 분기 (별도 patch 필요).
/// - Mac 측은 `x/y/a/enabled` 명령만 `/tmp/df-walklab-cmd` 에 write — robot 가 5Hz polling
///   으로 read → `Walking::GetInstance()->X_MOVE_AMPLITUDE` 등 직접 set.
/// - Mac 의 sparse keyframe 합성 / setPosition 송출 경로 **완전 우회**.
///
/// **현재 상태**: Mac-side wrapper + UI 토글만. **robot-side patch 가 별도 작업** —
/// 안전 경고 UI 명시.
public enum WalkingEngine: String, CaseIterable, Codable, Sendable, Identifiable {
    /// **Default** — Mac 합성 6 phase sparse keyframe + setPosition 순차 송출.
    /// 즉시 동작하지만 robot-side 8ms 보행 루프 수준의 안정성 X.
    case macSparseKeyframe
    /// ROBOTIS onboard — robot 측 demo-pilot 실행 + x/y/a brokering.
    /// 안정 보행 (ball tracker 와 동일 엔진) 기대. **robot-side patch 필요**.
    case robotisOnboard

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .macSparseKeyframe: return "Mac sparse keyframe (default)"
        case .robotisOnboard:    return "ROBOTIS onboard ⚠️ patch 필요"
        }
    }

    public var shortLabel: String {
        switch self {
        case .macSparseKeyframe: return "Mac keyframe"
        case .robotisOnboard:    return "ROBOTIS onboard"
        }
    }

    public var icon: String {
        switch self {
        case .macSparseKeyframe: return "laptopcomputer"
        case .robotisOnboard:    return "cpu.fill"
        }
    }

    /// 사용자 친화 설명 — UI 패널에 표시.
    public var description: String {
        switch self {
        case .macSparseKeyframe:
            return "Mac 이 6 phase keyframe 합성 후 setPosition 순차 송출 (sync write 아님, 약 10Hz 등가). 즉시 동작."
        case .robotisOnboard:
            return "robot 측 demo-pilot 의 ROBOTIS Walking 엔진 사용 (8ms / 125Hz 루프 + IK + IMU balance). 안정 보행. robot-side patch 필요."
        }
    }
}

/// ROBOTIS onboard 모드의 명령 패킷 — Mac 이 file 로 write, robot 이 5Hz polling 으로 read.
///
/// File format (1 줄): `enabled x_mm y_mm a_deg period_ms foot_mm`
/// 예: `1 28.0 0.0 0.0 600 40`
///
/// Mac → robot 명령 주기: 50ms (Mac tick 동기). robot 측 patch 가 file 변경 감지 시
/// `Walking::GetInstance()->X_MOVE_AMPLITUDE = x_mm` 등 적용.
public struct WalkingEngineCommand: Equatable, Sendable {
    public let enabled: Bool
    public let xMm: Double
    public let yMm: Double
    public let aDeg: Double
    public let periodMs: Double
    public let footHeightMm: Double

    public init(enabled: Bool, xMm: Double, yMm: Double, aDeg: Double,
                periodMs: Double, footHeightMm: Double) {
        self.enabled = enabled
        self.xMm = xMm
        self.yMm = yMm
        self.aDeg = aDeg
        self.periodMs = periodMs
        self.footHeightMm = footHeightMm
    }

    /// file 로 write 할 직렬화 — 한 줄, robot-side parser 가 sscanf 로 read.
    public var serializedLine: String {
        // `enabled x_mm y_mm a_deg period_ms foot_mm` — space-separated, %f.
        // robot-side patch (예시 sscanf): `sscanf(line, "%d %f %f %f %f %f", &en, &x, &y, &a, &p, &f)`.
        String(format: "%d %.2f %.2f %.2f %.0f %.0f",
               enabled ? 1 : 0, xMm, yMm, aDeg, periodMs, footHeightMm)
    }

    /// 정지 명령 — enabled=0, 나머지 0.
    public static let stop = WalkingEngineCommand(
        enabled: false, xMm: 0, yMm: 0, aDeg: 0, periodMs: 0, footHeightMm: 0
    )
}
