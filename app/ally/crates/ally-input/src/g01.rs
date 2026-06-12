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

/// G01 온보드 intensity 스케줄과 동일 체감을 위한 클라이언트 게이트 보간 끝점
/// (`df_wire::GaitConfig` 로 주입, W1). 온보드: period 700→560ms·foot 18→40mm,
/// intensity^0.7 — df-wire `gait_params` 의 지수와 동일.
pub const GAIT_PERIOD_MAX_MS: f64 = 700.0;
pub const GAIT_PERIOD_MIN_MS: f64 = 560.0;
pub const GAIT_FOOT_MIN_MM: f64 = 18.0;
pub const GAIT_FOOT_MAX_MM: f64 = 40.0;
/// 이동 진폭 기준 (온보드 클램프): x ±38mm · y ±22mm · a ±12°.
pub const STRIDE_MAX_MM: f64 = 38.0;
pub const SIDE_MAX_MM: f64 = 22.0;
pub const TURN_MAX_DEG: f64 = 12.0;

/// 복구(Y) 소프트 토크 램프 — `SG_SOFT_RAMP_VALUES`/`SG_SOFT_RAMP_INTERVAL_MS`.
/// 램프는 로봇 온보드가 수행한다 — 클라이언트는 진행 표시(~0.6s)만 담당.
pub const SOFT_TORQUE_RAMP: [u16; 4] = [300, 600, 900, 1023];
pub const SOFT_TORQUE_RAMP_INTERVAL_MS: u64 = 150;
