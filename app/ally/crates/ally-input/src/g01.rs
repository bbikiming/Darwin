//! RG G01 실기 검증 매핑 상수 — **동결** (PRD §14 D2).
//!
//! 원본: `firmware-patches/walklab-brokerage/GamepadPilot.h` (실기 브링업
//! 2026-06-13, `docs/reports/2026-06-13-rgg01-bringup.md`). 이 수치를 바꾸면
//! "검증된 손맛"이 깨진다 — 변경은 실기 재검증을 통과한 뒤에만 허용된다.
//!
//! 역할 매핑 (콕핏 컨텍스트):
//! 왼스틱=전후/횡이동 · 오른스틱=헤드 레이트 제어(놓으면 유지) ·
//! LT/RT 차분=아날로그 턴 · A=ARM · B=E-STOP(rising edge) · Y=복구(소프트 토크
//! 램프) · X=볼트랙 토글 · RB=터보.

/// 스틱 데드존 — `GP_DEADZONE` (잔여 [0,1] 재스케일, 부호 보존).
pub const STICK_DEADZONE: f64 = 0.10;
/// 이동축 응답 곡선 — `GP_DRIVE_CURVE`.
pub const DRIVE_CURVE: f64 = 1.35;
/// 헤드축 응답 곡선 — `GP_HEAD_CURVE` (F10b: 저속 미세 조작 보존).
pub const HEAD_CURVE: f64 = 1.7;
/// 터보 배율 — `GP_TURBO_SCALE` (콕핏 ControllerDriveModifiers.turboScale 동일).
pub const TURBO_SCALE: f64 = 1.3;

/// RT−LT 차분 데드존 — `GP_TRIGGER_DEADZONE` (휴지 노이즈 제거).
pub const TRIGGER_DEADZONE: f64 = 0.02;
/// 턴 저압 부스트 지수 — `GP_TURN_CURVE` (|d|^0.65, 부호 보존).
pub const TURN_CURVE: f64 = 0.65;

/// 헤드 팬 레이트 — `GP_HEAD_PAN_RATE_DPS` (풀스틱, 풀스윕 ±70° ≈ 0.9s).
pub const HEAD_PAN_RATE_DPS: f64 = 150.0;
/// 헤드 틸트 레이트 — `GP_HEAD_TILT_RATE_DPS` (풀스틱, 풀스윕 ±35° ≈ 0.8s).
pub const HEAD_TILT_RATE_DPS: f64 = 85.0;
/// 헤드 팬 적분 클램프 (±deg).
pub const HEAD_PAN_CLAMP_DEG: f64 = 70.0;
/// 헤드 틸트 적분 클램프 (±deg).
pub const HEAD_TILT_CLAMP_DEG: f64 = 35.0;
/// 레이트 적분 dt 상한 (ms) — 프레임 정체 시 점프 방지.
pub const HEAD_INTEGRATE_DT_MAX_MS: u64 = 200;

/// 이벤트 침묵 → 완만 정지 임계 — `GP_SILENCE_SLEW_MS` (③티어 failsafe).
pub const SILENCE_SLEW_MS: u64 = 1500;
/// InputFrame 신선도 임계 — TX 틱이 이보다 오래된 입력이면 zero+disarm
/// (docs/03_ARCHITECTURE.md §2, 로봇측 워치독 ≤320ms 계약과 이중 방어).
pub const INPUT_STALE_MS: u64 = 150;
/// 명령 스무딩 EMA 계수 — Mac 콕핏 CockpitCommandSmoother(2026-06-12 O2) 동일.
pub const CMD_EMA_ALPHA: f64 = 0.5;

/// 클라이언트 게이트 보간 **끝점** (`df_wire::GaitConfig` 로 주입, W1). 온보드 G01 스케줄과
/// 같은 끝점(period 700→560ms·foot 18→40mm)·같은 지수(intensity^0.7)를 쓴다.
///
/// **주의(검증 MEDIUM-1)**: 끝점은 같지만 *결합*이 다르다. df-wire `gait_params`(Python 패리티)는
/// max-of-axes 로 결합하고 side 를 stride_ref 로 정규화하는 반면, 온보드 `GpGaitSchedule` 은 L2
/// magnitude 로 결합하고 side 를 SIDE_MAX 로 정규화한다. 그래서 순수 좌우·복합 보행의 period/foot
/// 체감이 **미세하게 다르다**(진폭은 동일 — 안전/엔벨로프 불변, INV-5 거버너 흡수). 완전 1:1
/// 패리티는 df-wire 의 Python 골든벡터를 깨므로 W1 범위 밖. "동일 끝점, 단순화된 결합"으로 이해.
pub const GAIT_PERIOD_MAX_MS: f64 = 700.0;
pub const GAIT_PERIOD_MIN_MS: f64 = 560.0;
pub const GAIT_FOOT_MIN_MM: f64 = 18.0;
pub const GAIT_FOOT_MAX_MM: f64 = 40.0;
/// 이동 진폭 클램프 (UI 레이어 — 최종 클램프는 로봇 거버너 INV-5): x ±38mm · y ±22mm · a ±12°.
///
/// **출처(검증 MEDIUM-2)**: RG G01 브링업 라운드4(2026-06-13) 보수값. 온보드 헤더는 이후
/// Anbernic 고도화(P2/P4, 2026-06-14)로 side 32·turn 28 까지 상향했으나, ally 는 4개 SSOT 문서
/// (roadmap §2·arch §6·PRD·PRODUCT_BRIEF)가 일관 명시한 22/12 에 동결(D2). ally 값이 거버너
/// (32/28)보다 작아 "작은 쪽이 클램프"(INV-5)로 안전 측 — 변경 시 실기 재검증 필수.
pub const STRIDE_MAX_MM: f64 = 38.0;
pub const SIDE_MAX_MM: f64 = 22.0;
pub const TURN_MAX_DEG: f64 = 12.0;
/// 고관절 각 — `GP_HIP_DEG` (ROBOTIS 원본 고정).
pub const HIP_DEG: f64 = 13.0;

/// 복구(Y) 소프트 토크 램프 — `SG_SOFT_RAMP_VALUES`/`SG_SOFT_RAMP_INTERVAL_MS`.
/// 램프는 로봇 온보드가 수행한다 — 클라이언트는 진행 표시(~0.6s)만 담당.
pub const SOFT_TORQUE_RAMP: [u16; 4] = [300, 600, 900, 1023];
pub const SOFT_TORQUE_RAMP_INTERVAL_MS: u64 = 150;

/// 축 부호 (실측 — `GP_SIGN_*`, 브링업 라운드4 확정). **전부 −1.0**.
/// 로봇 좌표: X+=전진 · Y+=좌횡 · A+=좌회전 · pan+=좌 · tilt+=상.
pub const SIGN_STRIDE: f64 = -1.0;
pub const SIGN_SIDE: f64 = -1.0;
pub const SIGN_TURN: f64 = -1.0;
pub const SIGN_TILT: f64 = -1.0;
pub const SIGN_PAN: f64 = -1.0;

/// 정지 시(스케줄 비적용) 기본 케이던스 — `GP_GAIT_PERIOD_DEFAULT`.
pub const GAIT_PERIOD_DEFAULT_MS: f64 = 600.0;

/// ARM idle timeout — `GP_ARM_IDLE_TIMEOUT_MS` (하드닝 B3). ARM 후 의도적 입력이 이만큼
/// 없으면 auto-disarm(거치 중 스틱 오접촉 차단). 데드맨 제거의 완화책(약식 등가).
pub const ARM_IDLE_TIMEOUT_MS: u64 = 15000;
/// 보유 상태 재공급 주기 — `GP_REFRESH_MS` (스트림 워치독 600/2500ms 정합).
pub const REFRESH_MS: u64 = 50;
