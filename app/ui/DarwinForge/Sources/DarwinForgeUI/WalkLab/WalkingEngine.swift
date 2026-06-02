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
/// **File format (1 줄, v1.11.5.2 — 7 필드)**:
/// `enabled x_mm y_mm a_deg period_ms foot_mm hip_pitch_deg`
/// 예: `1 28.0 0.0 0.0 600 40 13.0`
///
/// Mac → robot 명령 주기: 50ms (Mac tick 동기). robot 측 patch 가 file 변경 감지 시
/// `Walking::GetInstance()->X_MOVE_AMPLITUDE = x_mm` 등 적용.
///
/// **v1.11.5.2 (2026-05-18) chain break fix**: 종전 6 필드는 `hipPitchOffsetDeg` 누락 →
/// 사용자가 trim slider 변경해도 `.robotisOnboard` 모드에서 robot 에 전달 안 되는 버그.
/// 7 번째 필드 추가로 Mac sparse / ROBOTIS onboard 양쪽에서 trim 일관 적용.
///
/// **사이클 162 (P0-2, gyro closed-loop review fix)**: balance 3 필드 추가.
/// 종전: balanceGain / enableBalanceCorrection / correctorIntensityLevel 가 Mac UI 만
/// 영향, robot 측 미전달 → Onboard mode 사용자가 자이로 slider 조정해도 robot 동작 동일.
/// 신규 8-10 번째 필드 — 옛 robot daemon (sscanf 7 필드) 는 그대로 무시 (backward compat).
/// 새 daemon (v2 patch) 는 추가 필드 read → robot-side Walking::GetInstance() balance 인자 set.
public struct WalkingEngineCommand: Equatable, Sendable {
    public let enabled: Bool
    public let xMm: Double
    public let yMm: Double
    public let aDeg: Double
    public let periodMs: Double
    public let footHeightMm: Double
    /// **v1.11.5.2 (2026-05-18)**: HIP_PITCH_OFFSET (°). robot-side `Walking::GetInstance()->HIP_PITCH_OFFSET` set.
    /// default 13.0 (ROBOTIS Walking.cpp 원본). UI trim slider 와 일관.
    public let hipPitchOffsetDeg: Double

    /// **사이클 162**: balance gain (0..5). robot-side `Walking::GetInstance()->BALANCE_*` 인자.
    /// default 1.0 (ROBOTIS Walking.cpp 원본).
    public let balanceGain: Double
    /// **사이클 162**: 자이로 보정 enable (0/1). robot-side
    /// `Walking::GetInstance()->BALANCE_ENABLE` set. default false (안전).
    public let balanceEnable: Bool
    /// **사이클 162**: 보정 강도 5단계 (0..4) — Mac UI 의 correctorIntensityLevel.
    /// robot-side 가 0=off, 1=절반, 2=표준, 3=1.5배, 4=2배 매핑. default 2 (표준).
    public let correctorIntensityLevel: Int

    /// **SSH parity (W4)**: 머리 pan (°). robot-side `Robot::Head::GetInstance()->MoveByAngle(pan, tilt)`.
    /// + = 로봇 기준 오른쪽. [-90, 90] clamp. default 0 (정면, backward compat — 옛 daemon 은
    /// trailing 무시). LAN 경로의 head control 과 동등 parity 위해 추가.
    public let headPanDeg: Double
    /// **SSH parity (W4)**: 머리 tilt (°). + = 위. [-45, 45] clamp. default 0 (정면).
    public let headTiltDeg: Double

    /// **볼 트래킹 (2026-06-02)**: 로봇 온보드 자동 헤드 추적 on/off (0/1).
    /// true 면 robot-side 브로커리지가 `LinuxCamera`+`ColorFinder`+`BallTracker`로
    /// 자체 헤드를 움직인다(기본 데모와 동일). 이때 Mac 의 headPan/headTilt 는 무시되어야
    /// 하므로 직렬화 시 head 를 0 으로 고정한다. default false (backward compat — 옛
    /// daemon 은 trailing 필드 무시). [[robot-no-mic-input]] 와 같은 온보드 처리 계열.
    public let ballTrackingEnabled: Bool

    public init(enabled: Bool, xMm: Double, yMm: Double, aDeg: Double,
                periodMs: Double, footHeightMm: Double,
                hipPitchOffsetDeg: Double = 13.0,
                balanceGain: Double = 1.0,
                balanceEnable: Bool = false,
                correctorIntensityLevel: Int = 2,
                headPanDeg: Double = 0,
                headTiltDeg: Double = 0,
                ballTrackingEnabled: Bool = false) {
        self.enabled = enabled
        self.xMm = xMm
        self.yMm = yMm
        self.aDeg = aDeg
        self.periodMs = periodMs
        self.footHeightMm = footHeightMm
        self.hipPitchOffsetDeg = hipPitchOffsetDeg
        self.balanceGain = balanceGain
        self.balanceEnable = balanceEnable
        self.correctorIntensityLevel = max(0, min(4, correctorIntensityLevel))
        // 볼 트래킹 ON 이면 로봇이 헤드를 제어하므로 Mac head 명령을 0 으로 무력화.
        self.ballTrackingEnabled = ballTrackingEnabled
        self.headPanDeg = ballTrackingEnabled ? 0 : max(-90, min(90, headPanDeg))
        self.headTiltDeg = ballTrackingEnabled ? 0 : max(-45, min(45, headTiltDeg))
    }

    /// file 로 write 할 직렬화 — 한 줄, robot-side parser 가 sscanf 로 read.
    /// **SSH parity (W4)**: 12 필드 — 사이클 162 의 10 필드 뒤에 head pan/tilt 2 필드 APPEND.
    /// 옛 daemon (7 또는 10 필드 sscanf) 는 trailing head 필드 무시 (backward compat).
    public var serializedLine: String {
        // `enabled x_mm y_mm a_deg period_ms foot_mm hip_pitch_deg balance_gain balance_enable corrector_level head_pan head_tilt ball_track`.
        // 옛 daemon sscanf: `sscanf(line, "%d %f %f %f %f %f %f", ...)` → 7 필드 read, trailing 무시.
        // 사이클 162 daemon: `sscanf(line, "%d %f %f %f %f %f %f %f %d %d", ...)` → 10 필드.
        // SSH parity daemon: 12 필드 (head pan/tilt 까지).
        // 볼 트래킹 daemon (2026-06-02): 13 필드 read (cmd_id 포함 14) → ball_track 적용.
        // 모든 옛 daemon 은 13번째 필드를 trailing 으로 무시 (backward compat).
        String(format: "%d %.2f %.2f %.2f %.0f %.0f %.2f %.2f %d %d %.2f %.2f %d",
               enabled ? 1 : 0, xMm, yMm, aDeg, periodMs, footHeightMm, hipPitchOffsetDeg,
               balanceGain, balanceEnable ? 1 : 0, correctorIntensityLevel,
               headPanDeg, headTiltDeg, ballTrackingEnabled ? 1 : 0)
    }

    /// 정지 명령 — enabled=0, 나머지 0, hipPitchOffsetDeg=13 (기본 유지),
    /// balance default (1.0 / false / 2), head 0,0 (정면 — SSH parity W4),
    /// ballTracking off (정지 시 추적 해제).
    public static let stop = WalkingEngineCommand(
        enabled: false, xMm: 0, yMm: 0, aDeg: 0, periodMs: 0, footHeightMm: 0,
        headPanDeg: 0, headTiltDeg: 0, ballTrackingEnabled: false
    )

    /// 사이클 164 (codex MAJOR fix, cycle 162 review): 옛 daemon backward compat 경고.
    /// daemon version 확인 전까지 balance 필드는 robot 측 silent ignore 가능 (sscanf 7 필드).
    /// Mac UI 가 "balance ON" 으로 표시했지만 robot 측 무동작 — 사용자 silent failure 위험.
    /// **Mac 측 권고**: Onboard mode HUD 에 본 메시지 영구 표시.
    public static let onboardSchemaWarning: String =
        "⚠ 옛 펌웨어 (v1 patch) 는 balance 필드 (gain/enable/intensity) 무시. " +
        "Robot 측 v2 patch (sscanf 10 필드) 필수. " +
        "현재 ACK 검증 없음 — 사용자가 robot 측 버전 확인 후 보정 활성 권장."
}
