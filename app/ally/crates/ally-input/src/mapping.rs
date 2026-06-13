//! G01 매핑·성형 — `firmware-patches/walklab-brokerage/GamepadPilot.{h,cpp}` 의
//! 순수 로직을 **정규화 [-1,1] 공간에서 1:1** 로 포팅한 것(D2 동결 — INV-4).
//!
//! 핵심 규율: 이 모듈은 **evdev 방향 좌표**(원본 GamepadPilot 의 `GamepadSnapshot`
//! 과 동일: 스틱 ABS_Y 아래=+ · ABS_X 오른쪽=+ · 트리거 0..1)를 입력으로 받는다.
//! XInput(gilrs)의 축 방향·원시 범위 차이는 [`crate::adapter`] 가 흡수하고, 여기의
//! 데드존·곡선·레이트·부호 수치는 `GamepadPilot.h` 의 GP_* 와 바이트 단위로 같다
//! (04 §2 W1 "정규화 이후 곡선·데드존·레이트 수치는 바이트 단위 동결").
//!
//! 게이트 보간(period/foot)은 여기서 다시 구현하지 않는다 — [`g01_gait_config`] 가
//! G01 의 intensity^0.7 스케줄(700→560 / 18→40)을 재현하는 `df_wire::GaitConfig`
//! 를 돌려주고, `df_wire::build_line` 이 골든 벡터 검증된 `gait_params` 로 계산한다.

use crate::g01;
use df_wire::{GaitConfig, MotionCommand};

/// evdev 방향 정규화 스냅샷 — `GamepadPilot.h::GamepadSnapshot` 등가.
/// 스틱은 [-1,1](부호 그대로 — 부호 적용은 매핑이 한다), 트리거는 [0,1].
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct GamepadState {
    /// 왼스틱 X — 오른쪽 = + (evdev ABS_X).
    pub lx: f64,
    /// 왼스틱 Y — 아래 = + (evdev ABS_Y).
    pub ly: f64,
    /// 오른스틱 X — 오른쪽 = + (evdev ABS_RX).
    pub rx: f64,
    /// 오른스틱 Y — 아래 = + (evdev ABS_RY).
    pub ry: f64,
    /// LT [0,1].
    pub lt: f64,
    /// RT [0,1].
    pub rt: f64,
    pub btn_a: bool,
    pub btn_b: bool,
    pub btn_x: bool,
    pub btn_y: bool,
    pub btn_lb: bool,
    pub btn_rb: bool,
}

/// 머리 hold 상태 — 입력 0 이면 직전 각 유지(레이트 제어의 적분기).
/// `GamepadPilot.h::GamepadHeadHold` 등가.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct HeadHold {
    pub pan_deg: f64,
    pub tilt_deg: f64,
}

fn clamp1(v: f64) -> f64 {
    v.clamp(-1.0, 1.0)
}

fn clamp_abs(v: f64, cap: f64) -> f64 {
    v.clamp(-cap, cap)
}

/// 데드존 0.10 → 잔여 [0,1] 재스케일(부호 보존) — `GpApplyDeadzone`.
pub fn apply_deadzone(v: f64) -> f64 {
    let mag = v.abs();
    if mag < g01::STICK_DEADZONE {
        return 0.0;
    }
    let scaled = ((mag - g01::STICK_DEADZONE) / (1.0 - g01::STICK_DEADZONE)).min(1.0);
    if v >= 0.0 {
        scaled
    } else {
        -scaled
    }
}

/// 데드존 → 이동 곡선 1.35(부호 보존) — `GpShapeDriveAxis`.
pub fn shape_drive_axis(v: f64) -> f64 {
    let n = apply_deadzone(v);
    if n == 0.0 {
        return 0.0;
    }
    let shaped = n.abs().powf(g01::DRIVE_CURVE);
    if n >= 0.0 {
        shaped
    } else {
        -shaped
    }
}

/// 데드존 → 헤드 곡선 1.7(부호 보존) — `GpShapeHeadAxis` (F10b: 저속 미세 보존).
pub fn shape_head_axis(v: f64) -> f64 {
    let n = apply_deadzone(v);
    if n == 0.0 {
        return 0.0;
    }
    let shaped = n.abs().powf(g01::HEAD_CURVE);
    if n >= 0.0 {
        shaped
    } else {
        -shaped
    }
}

/// RT−LT 차분 [-1,1] — 차분에 트리거 데드존 0.02 적용 후 재스케일 — `GpTriggerDiff`.
pub fn trigger_diff(rt: f64, lt: f64) -> f64 {
    let d = rt - lt;
    let mag = d.abs();
    if mag < g01::TRIGGER_DEADZONE {
        return 0.0;
    }
    let scaled = ((mag - g01::TRIGGER_DEADZONE) / (1.0 - g01::TRIGGER_DEADZONE)).min(1.0);
    if d >= 0.0 {
        scaled
    } else {
        -scaled
    }
}

/// 턴 저압 부스트 |d|^0.65(부호 보존, 풀프레스 ±1 불변) — `GpShapeTurn`.
pub fn shape_turn(d: f64) -> f64 {
    if d == 0.0 {
        return 0.0;
    }
    let shaped = d.abs().powf(g01::TURN_CURVE);
    if d >= 0.0 {
        shaped
    } else {
        -shaped
    }
}

/// G01 intensity^0.7 게이트 스케줄(period 700→560 · foot 18→40 · stride 기준 38mm)을
/// 재현하는 `df_wire::GaitConfig`. df-wire `gait_params` 의 enabled 분기가
/// `GpGaitSchedule` 과 수치적으로 동일해지도록 끝점을 주입한다(원식: 횡도 stride
/// 기준으로 정규화 → `stride_ref_mm = 38`).
pub fn g01_gait_config() -> GaitConfig {
    GaitConfig {
        period_ms: g01::GAIT_PERIOD_DEFAULT_MS, // 비활성 시 반환값 (600)
        foot_mm: g01::GAIT_FOOT_MAX_MM,         // 비활성 시 반환값 + max_foot (40)
        hip_deg: g01::HIP_DEG,                  // 13
        min_period_ms: g01::GAIT_PERIOD_MIN_MS, // 560
        max_period_ms: g01::GAIT_PERIOD_MAX_MS, // 700
        min_foot_mm: g01::GAIT_FOOT_MIN_MM,     // 18
        stride_ref_mm: g01::STRIDE_MAX_MM,      // 38 — intensity 분모(횡 포함)
        turn_ref_deg: g01::TURN_MAX_DEG,        // 12
    }
}

/// 스냅샷 → 보행/머리 명령 — `MapGamepad` 1:1 포팅.
///
/// - 이동(전후/횡)·턴: 데드존 → 곡선 → 부호 → (터보 ×1.3 클램프) → MAX 스케일.
///   `armed && moving` 일 때만 enabled(데드맨 해제 — 이동 게이트는 ARM 단일).
/// - 머리: **비게이트**(armed 무관). 우스틱 레이트 제어 — 곡선 성형 × RATE × dt 적분,
///   ±클램프, dt ≤ 0 이면 적분 생략(획득 직후/리셋 점프 방지). `hold` 를 갱신한다.
///
/// `df_wire::MotionCommand` 를 돌려준다(period/foot/hip 은 `g01_gait_config()` +
/// `build_line` 이 산출 — 여기서 손대지 않음). 부호 5종은 전부 −1.0(GP_SIGN_*).
pub fn map_gamepad(
    s: &GamepadState,
    armed: bool,
    dt_ms: f64,
    hold: &mut HeadHold,
) -> MotionCommand {
    // 이동/턴 — 부호 5종 동결(GP_SIGN_STRIDE/SIDE/TURN = −1.0).
    let mut fwd = g01::SIGN_STRIDE * shape_drive_axis(s.ly);
    let mut side = g01::SIGN_SIDE * shape_drive_axis(s.lx);
    let mut turn = g01::SIGN_TURN * shape_turn(trigger_diff(s.rt, s.lt));
    if s.btn_rb {
        // 터보 — 정규화 ×1.3 후 ±1 클램프(콕핏 turboScale 패리티).
        fwd = clamp1(fwd * g01::TURBO_SCALE);
        side = clamp1(side * g01::TURBO_SCALE);
        turn = clamp1(turn * g01::TURBO_SCALE);
    }
    let moving = fwd != 0.0 || side != 0.0 || turn != 0.0;
    // 데드맨 해제(GP_DEADMAN_REQUIRED=false) — 이동 게이트는 armed 단일.
    let enabled = armed && moving;

    // 머리 레이트 적분(비게이트) — dt 상한으로 이벤트 공백 점프 방지.
    if dt_ms > 0.0 {
        let dt_s = dt_ms.min(g01::HEAD_INTEGRATE_DT_MAX_MS as f64) / 1000.0;
        let pan_rate = g01::SIGN_PAN * shape_head_axis(s.rx);
        let tilt_rate = g01::SIGN_TILT * shape_head_axis(s.ry);
        hold.pan_deg = clamp_abs(
            hold.pan_deg + pan_rate * g01::HEAD_PAN_RATE_DPS * dt_s,
            g01::HEAD_PAN_CLAMP_DEG,
        );
        hold.tilt_deg = clamp_abs(
            hold.tilt_deg + tilt_rate * g01::HEAD_TILT_RATE_DPS * dt_s,
            g01::HEAD_TILT_CLAMP_DEG,
        );
    }

    MotionCommand {
        enabled,
        stride_mm: if enabled {
            fwd * g01::STRIDE_MAX_MM
        } else {
            0.0
        },
        side_mm: if enabled {
            side * g01::SIDE_MAX_MM
        } else {
            0.0
        },
        turn_deg: if enabled {
            turn * g01::TURN_MAX_DEG
        } else {
            0.0
        },
        head_pan_deg: hold.pan_deg,
        head_tilt_deg: hold.tilt_deg,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── 데드존·곡선·트리거 (test_gamepad.cpp::test_deadzone_curve/test_trigger_diff 거울) ──

    #[test]
    fn deadzone_rescales_preserving_sign() {
        assert_eq!(apply_deadzone(0.05), 0.0); // 데드존 내
        assert_eq!(apply_deadzone(-0.0999), 0.0);
        assert!((apply_deadzone(0.55) - 0.5).abs() < 1e-9); // (0.55-0.1)/0.9 = 0.5
        assert_eq!(apply_deadzone(1.0), 1.0);
        assert_eq!(apply_deadzone(-1.0), -1.0); // 부호 보존
    }

    #[test]
    fn drive_curve_135() {
        // 0.5^1.35 ≈ 0.39229 — 데드존 통과값 0.5 에 곡선.
        assert!((shape_drive_axis(0.55) - 0.392_29).abs() < 1e-3);
        assert!((shape_drive_axis(-0.55) + 0.392_29).abs() < 1e-3);
        assert_eq!(shape_drive_axis(1.0), 1.0);
        assert_eq!(shape_drive_axis(0.08), 0.0); // 데드존 내
    }

    #[test]
    fn trigger_diff_deadzone_and_scale() {
        assert_eq!(trigger_diff(0.0, 0.0), 0.0);
        assert_eq!(trigger_diff(1.0, 0.0), 1.0);
        assert_eq!(trigger_diff(0.0, 1.0), -1.0);
        assert_eq!(trigger_diff(0.51, 0.5), 0.0); // 차분 0.01 < 0.02
        assert!((trigger_diff(0.55, 0.0) - (0.55 - 0.02) / 0.98).abs() < 1e-9);
        assert_eq!(trigger_diff(1.0, 1.0), 0.0); // 상쇄
    }

    #[test]
    fn turn_low_press_boost() {
        // 저압 부스트: 트리거 0.10 → 정규 턴 > 0.15 (종전 0.05 대비 ~3.7배).
        let light = shape_turn(trigger_diff(0.10, 0.0));
        assert!(light > 0.15, "light={light}");
        assert_eq!(shape_turn(1.0), 1.0); // 풀프레스 불변
        assert_eq!(shape_turn(-1.0), -1.0);
    }

    // ── 부호·게이트·터보·헤드 레이트 (test_mapping_* 거울) ──

    #[test]
    fn signs_full_stick() {
        // 풀스틱 전진(evdev 위=−ly) + 우횡(lx=+) + RT 풀(우회전) + RS 우+위(헤드).
        let s = GamepadState {
            ly: -1.0,
            lx: 1.0,
            rx: 1.0,
            ry: -1.0,
            rt: 1.0,
            ..Default::default()
        };
        let mut hold = HeadHold::default();
        let c = map_gamepad(&s, true, 1000.0, &mut hold); // dt 1s → 200ms 캡
        assert!(c.enabled);
        assert!((c.stride_mm - g01::STRIDE_MAX_MM).abs() < 1e-6); // 위 → 전진 +38
        assert!((c.side_mm + g01::SIDE_MAX_MM).abs() < 1e-6); // 우 → 우횡 −22
        assert!((c.turn_deg + g01::TURN_MAX_DEG).abs() < 1e-6); // RT 풀 → 우회전 −12
                                                                // 헤드 레이트 — 200ms 캡 적분.
        assert!((c.head_tilt_deg - g01::HEAD_TILT_RATE_DPS * 0.2).abs() < 1e-6);
        assert!((c.head_pan_deg + g01::HEAD_PAN_RATE_DPS * 0.2).abs() < 1e-6);
    }

    #[test]
    fn arm_is_single_move_gate() {
        let s = GamepadState {
            ly: -1.0,
            ry: -1.0,
            ..Default::default()
        };
        // armed + 이동(데드맨 LB 없이) → enabled.
        let mut hold = HeadHold::default();
        let c = map_gamepad(&s, true, 100.0, &mut hold);
        assert!(c.enabled);
        assert!(c.stride_mm > 0.0);
        assert!(hold.tilt_deg > 0.0, "머리는 비게이트");
        // ARM 전 → 이동 잠금, 머리는 계속.
        let mut hold2 = HeadHold::default();
        let c = map_gamepad(&s, false, 100.0, &mut hold2);
        assert!(!c.enabled);
        assert_eq!(c.stride_mm, 0.0);
        assert!(hold2.tilt_deg > 0.0);
        // armed 인데 중립 → 정지.
        let mut hold3 = HeadHold::default();
        let c = map_gamepad(&GamepadState::default(), true, 100.0, &mut hold3);
        assert!(!c.enabled);
    }

    #[test]
    fn turbo_scales_and_clamps() {
        let mut hold = HeadHold::default();
        let s = GamepadState {
            ly: -0.55,
            ..Default::default()
        };
        let base = map_gamepad(&s, true, 0.0, &mut hold).stride_mm;
        assert!((base - 0.392_29 * g01::STRIDE_MAX_MM).abs() < 0.05);
        let s_turbo = GamepadState {
            ly: -0.55,
            btn_rb: true,
            ..Default::default()
        };
        let turbo = map_gamepad(&s_turbo, true, 0.0, &mut hold).stride_mm;
        assert!((turbo - 0.392_29 * g01::TURBO_SCALE * g01::STRIDE_MAX_MM).abs() < 0.05);
        // 풀스틱 + 터보 → ±1 클램프(38 초과 금지).
        let s_full = GamepadState {
            ly: -1.0,
            btn_rb: true,
            ..Default::default()
        };
        let full = map_gamepad(&s_full, true, 0.0, &mut hold).stride_mm;
        assert!((full - g01::STRIDE_MAX_MM).abs() < 1e-6);
    }

    #[test]
    fn head_rate_integrates_holds_and_clamps() {
        let mut hold = HeadHold::default();
        let s = GamepadState {
            rx: 1.0,
            ..Default::default()
        };
        // RS 우 풀스틱 100ms — 팬 적분 −(rate×0.1).
        let c = map_gamepad(&s, true, 100.0, &mut hold);
        assert!((c.head_pan_deg + g01::HEAD_PAN_RATE_DPS * 0.1).abs() < 1e-6);
        // 추가 100ms 누적.
        let c = map_gamepad(&s, true, 100.0, &mut hold);
        assert!((c.head_pan_deg + g01::HEAD_PAN_RATE_DPS * 0.2).abs() < 1e-6);
        // 스틱 해제 → 유지(hold).
        let held = hold.pan_deg;
        let c = map_gamepad(&GamepadState::default(), true, 100.0, &mut hold);
        assert!((c.head_pan_deg - held).abs() < 1e-6);
        // dt=0 → 적분 생략.
        let c = map_gamepad(&s, true, 0.0, &mut hold);
        assert!((c.head_pan_deg - held).abs() < 1e-6);
        // 풀스틱 최고속 = 150°/s (1.0^1.7 = 1.0).
        assert!((shape_head_axis(1.0) * g01::HEAD_PAN_RATE_DPS - 150.0).abs() < 1e-6);
        // 틸트 클램프 +35 — 위로 계속 밀어도 초과 금지.
        let up = GamepadState {
            ry: -1.0,
            ..Default::default()
        };
        let mut hold_t = HeadHold::default();
        let mut last = 0.0;
        for _ in 0..20 {
            last = map_gamepad(&up, true, 100.0, &mut hold_t).head_tilt_deg;
        }
        assert!((last - g01::HEAD_TILT_CLAMP_DEG).abs() < 1e-6);
    }

    // ── 게이트 스케줄: G01 GaitConfig 가 build_line 에서 700→560/18→40 재현 ──

    #[test]
    fn gait_config_reproduces_g01_schedule() {
        let cfg = g01_gait_config();
        // 풀스틱 전진 → period 560 · foot 40.
        let full = MotionCommand {
            enabled: true,
            stride_mm: g01::STRIDE_MAX_MM,
            side_mm: 0.0,
            turn_deg: 0.0,
            head_pan_deg: 0.0,
            head_tilt_deg: 0.0,
        };
        let (period, foot) = df_wire::gait_params(&cfg, &full);
        assert!((period - g01::GAIT_PERIOD_MIN_MS).abs() < 1e-9);
        assert!((foot - g01::GAIT_FOOT_MAX_MM).abs() < 1e-9);
        // 정지(비활성) → 600 / 40.
        let (period, foot) = df_wire::gait_params(&cfg, &MotionCommand::zero());
        assert!((period - g01::GAIT_PERIOD_DEFAULT_MS).abs() < 1e-9);
        assert!((foot - g01::GAIT_FOOT_MAX_MM).abs() < 1e-9);
        // 중간 강도 0.5(= stride 19mm) → shaped 0.5^0.7 ≈ 0.61557.
        let half = MotionCommand {
            enabled: true,
            stride_mm: 19.0,
            ..full
        };
        let (period, foot) = df_wire::gait_params(&cfg, &half);
        assert!((period - (700.0 - 140.0 * 0.61557)).abs() < 0.1);
        assert!((foot - (18.0 + 22.0 * 0.61557)).abs() < 0.1);
    }
}
