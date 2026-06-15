import Foundation

/// 자동 일어나기 (Auto Fall-Recovery) — 순수 로직 네임스페이스.
///
/// # 비유
///
/// 체조 코치가 넘어진 선수를 보고 방향을 판단한 뒤 "앞으로 넘어졌으니 10번,
/// 뒤로 넘어졌으니 11번 동작" 을 지시하는 것과 같다. 코치는 선수를 직접 잡아
/// 일으키지 않는다 — 판단과 지시만 한다. 실제 행동은 WalkLabSession 의 Recovery
/// Task 가 수행한다.
///
/// # 설계 원칙
///
/// - 모든 static helper 는 side-effect 없음 — 입력만 받고 값만 반환.
/// - @MainActor / I/O / ConnectionStore 등 외부 의존 없음.
/// - 실 robot 없이도 XCTest 에서 단독 실행 가능.
///
/// # ROBOTIS 공식 근거
///
/// ROBOTIS-OP2 공식 demo `StatusCheck.cpp:27-43` 참조:
/// - FB accel < 390 → FORWARD (face-down) → Action::Start(10) "f up"
/// - FB accel > 580 → BACKWARD (face-up) → Action::Start(11) "b up"
/// - DarwinForge IMU 매핑: pitchDeg > 0 = forward (pitch-based fallback only).
///   실 robot 1st-attempt + retry 는 ROBOTIS 공식 accelY 기반 감지 사용.
///   실 robot forward-lean ≈ -20° (cm.rs:~80-82) — 보행 중 raw pitch sign 은
///   fall 방향 판정에 신뢰 불가. 가속도계(DC 성분)가 실제 중력 방향을 측정.
/// - page 12 / 13 = kick (rk/lk) — get-up 절대 사용 불가.
public enum AutoFallRecovery {

    // MARK: - 낙하 방향

    /// 낙하 방향 — ROBOTIS 공식 get-up page 와 1:1 매핑.
    public enum FallDirection: Equatable, Sendable {
        /// 앞으로 넘어짐 (face-down). pitchDeg ≥ +threshold.
        case forward
        /// 뒤로 넘어짐 (face-up). pitchDeg ≤ -threshold.
        case backward

        /// ROBOTIS 공식 get-up 페이지 번호.
        ///
        /// - `forward` → 10 "f up"  (motion_4096.bin 파싱 + firmware backup 검증)
        /// - `backward` → 11 "b up" (motion_4096.bin 파싱 + firmware backup 검증)
        ///
        /// **NEVER** 12 / 13 (kick rk/lk). 이 페이지들을 get-up 에 쓰는 것은
        /// 실 robot 에 킥 동작을 실행하는 중대 안전 위반이다.
        public var getUpPage: UInt8 {
            switch self {
            case .forward:  return 10  // "f up"  — 앞으로 넘어진 경우 일어나기
            case .backward: return 11  // "b up"  — 뒤로 넘어진 경우 일어나기
            }
        }
    }

    // MARK: - Recovery 상태 머신 단계

    /// Recovery 진행 단계. tick 에서 읽어 UI 에 표시.
    public enum RecoveryPhase: Equatable, Sendable {
        /// 정상 (낙하 미감지 또는 recovery 완료 후 idle 복귀).
        case idle
        /// 낙하 감지됨 — Recovery Task 시작 직전.
        case fallen(FallDirection)
        /// 자이로 정착 대기 중.
        case settling
        /// get-up 모션 재생 중.
        case gettingUp
        /// Recovery 성공 — walkReady 복귀.
        case done
        /// 최대 시도 횟수 초과 또는 get-up 모션 실패 — emergencyStop fallback.
        case failed
    }

    // MARK: - 상수 (모두 ROBOTIS 근거 명시)

    /// 낙하 판정 pitchDeg 임계 (°).
    ///
    /// ROBOTIS FALLEN_F_LIMIT = 390 raw ≈ 50°,  FALLEN_B_LIMIT = 580 raw ≈ 50°.
    /// 기존 L3 hard gate (50°) 보다 약간 높게 55° 설정 — L3 가 50° 에서 torque OFF 한
    /// 뒤 관성으로 tilt 가 더 커지는 구간에서 recovery 를 촉발하기 위함.
    public static let fallenThresholdDeg: Double = 55.0

    /// **가속도계 기반 낙하 판정 임계 — ROBOTIS 공식 (StatusCheck.cpp:27-43)**.
    ///
    /// ADC center = 512 (10-bit, 1g ≈ 512 LSB).
    ///
    /// - `FALLEN_F_LIMIT = 390`: FB accel < 390 → face-down → FORWARD → page 10 "f up".
    ///   (accelY 가 중립 512 보다 122 LSB 낮음 = 중력이 앞쪽으로 향함)
    /// - `FALLEN_B_LIMIT = 580`: FB accel > 580 → face-up → BACKWARD → page 11 "b up".
    ///   (accelY 가 중립 512 보다 68 LSB 높음 = 중력이 뒤쪽으로 향함)
    ///
    /// **출처**: ROBOTIS-OP2 공식 demo `StatusCheck.cpp:27-43` 의 `FALLEN_F_LIMIT` /
    /// `FALLEN_B_LIMIT` 매크로를 그대로 채용. pitch° 임계와 달리 보행 중 동적 스파이크에
    /// 강인 — 가속도계는 중력 방향(DC 성분)을 측정하여 순간 흔들림(gyro 노이즈)에 둔감.
    public static let fallenAccelForwardLimit: Int = 390

    /// `FALLEN_B_LIMIT` — FB accel > 580 → BACKWARD fall. 상단 `fallenAccelForwardLimit` 참조.
    public static let fallenAccelBackwardLimit: Int = 580

    /// 정착 판정 자이로 속도 임계 (dps).
    ///
    /// 바닥에 닿은 robot 의 자이로 잔류 진동 < 30 dps 이면 "정착됨" 으로 간주.
    /// ROBOTIS StatusCheck 는 명시적 wait 없이 바로 Action 실행하지만, DarwinForge 는
    /// 통신 안전을 위해 자이로 안정화를 확인한 뒤 motionPlaySlot 호출.
    public static let settleGyroDps: Double = 30.0

    /// 정착 판정 연속 샘플 수.
    ///
    /// 100ms 폴링 × 5 sample = 500ms — 반짝 안정화를 무시하고 실제 정착 확인.
    public static let settleConsecutiveSamples: Int = 5

    /// 최대 get-up 시도 횟수. 초과 시 `.failed` → emergencyStop fallback.
    public static let maxGetUpAttempts: Int = 2

    /// 정착 대기 최대 시간 (s). 초과 시 강제 진행 (완전 정착 않더라도 get-up 시도).
    public static let settleTimeoutSec: Double = 4.0

    // MARK: - 순수 helper

    /// 낙하 방향 감지.
    ///
    /// - Parameters:
    ///   - pitchDeg: 현재 IMU pitch 각도 (°). 전방 넘어짐 = 양수, 후방 = 음수.
    ///   - fallenThresholdDeg: 낙하 판정 임계 (°). 기본 `AutoFallRecovery.fallenThresholdDeg`.
    /// - Returns: `.forward` / `.backward` — 낙하 감지 시. `nil` — 미감지.
    public static func detectFall(
        pitchDeg: Double,
        fallenThresholdDeg: Double = AutoFallRecovery.fallenThresholdDeg
    ) -> FallDirection? {
        if pitchDeg >= fallenThresholdDeg  { return .forward  }
        if pitchDeg <= -fallenThresholdDeg { return .backward }
        return nil
    }

    /// **ROBOTIS 공식 가속도계 기반 낙하 방향 감지 (단일 샘플)**.
    ///
    /// pitch° 기반 `detectFall` 의 대체/보완 — ROBOTIS `StatusCheck.cpp:27-43` 의
    /// 공식 `FALLEN_F_LIMIT=390` / `FALLEN_B_LIMIT=580` 임계를 그대로 적용.
    ///
    /// # 비유
    /// 마치 수평계의 기포처럼, 가속도계는 중력(DC 성분)이 어느 방향으로 향하는지를
    /// 알려준다. pitch 각도는 필터링 오차/바이어스에 취약하지만, 가속도계의 중력 방향은
    /// 로봇이 실제로 쓰러진 상태에서 명확하게 나타난다.
    ///
    /// - Parameter accelYRaw: `ImuRaw.accelY` 의 UInt16 원시값을 Int 로 변환한 값
    ///   (0-1023, 10-bit ADC, center=512).
    /// - Returns: `.forward` / `.backward` — 낙하 감지 시. `nil` — 직립(중립 구간).
    public static func detectFallFromAccel(accelYRaw: Int) -> FallDirection? {
        if accelYRaw < fallenAccelForwardLimit  { return .forward  }
        if accelYRaw > fallenAccelBackwardLimit { return .backward }
        return nil
    }

    /// **가속도계 평균 기반 낙하 판정 — 보행 스파이크 억제 (공식 30-sample 평균)**.
    ///
    /// ROBOTIS 공식 데모는 30-sample 이동 평균(accelFBBuffer)을 사용하여 보행 중 동적
    /// 스파이크가 낙하로 오판되는 것을 방지한다. 본 함수는 동일한 원리로 최근 N개
    /// (≈10-30) 원시 accelY 샘플의 평균에 동일한 임계를 적용한다.
    ///
    /// 빈 배열 → nil (샘플 없음). 단일 샘플도 허용 (ring 초기 채움 구간).
    ///
    /// - Parameter samples: 최근 accelY 원시값(Int) 링 버퍼 슬라이스. 최신 순서 불요.
    /// - Returns: `.forward` / `.backward` — 평균값이 임계를 초과할 때. `nil` — 직립.
    public static func isFallenAccelSustained(samples: [Int]) -> FallDirection? {
        guard !samples.isEmpty else { return nil }
        let avg = samples.reduce(0, +) / samples.count
        return detectFallFromAccel(accelYRaw: avg)
    }

    /// 자이로 정착 여부.
    ///
    /// - Parameters:
    ///   - gyroXDps: 자이로 X축 각속도 (dps, roll 방향).
    ///   - gyroYDps: 자이로 Y축 각속도 (dps, pitch 방향).
    ///   - thresholdDps: 정착 임계 (dps). 기본 `AutoFallRecovery.settleGyroDps`.
    /// - Returns: `true` — `hypot(X, Y) < threshold` (바닥에 정착됨).
    public static func isSettled(
        gyroXDps: Double,
        gyroYDps: Double,
        thresholdDps: Double = AutoFallRecovery.settleGyroDps
    ) -> Bool {
        hypot(gyroXDps, gyroYDps) < thresholdDps
    }
}
