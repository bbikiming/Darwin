//! 입력 성형 순함수 — `GamepadPilot.cpp` 의 `Gp*` 매핑을 1:1 포팅(동결 수치 [`crate::g01`]).
//!
//! 전부 순수(상태 없음) → 호스트 단위 테스트가 참조 `tests/test_gamepad.cpp` 의 값표를
//! 그대로 거울로 검증한다. 정규화([-1,1]/[0,1]) 이후 공간에서 동작(계약 04 §2).

use crate::frame::InputFrame;
use crate::g01;

/// 데드존 적용 + 잔여 [0,1] 재스케일(부호 보존) — `GpApplyDeadzone`.
/// `|v| < DEADZONE` 이면 0(경계 포함: `|v| == DEADZONE` 도 0).
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

/// 이동축 성형 — 데드존 → 곡선 `DRIVE_CURVE`(부호 보존). `GpShapeDriveAxis`.
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

/// 헤드축 성형 — 데드존 → 곡선 `HEAD_CURVE`(부호 보존). `GpShapeHeadAxis`(F10b).
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

/// RT−LT 차분 + 트리거 데드존 → 재스케일(부호 보존) — `GpTriggerDiff`.
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

/// 턴 저압 부스트 — `|d|^TURN_CURVE`(0.65, 부호 보존). `GpShapeTurn`.
/// 살짝 눌러도 체감 회전이 시작되고 풀프레스(±1)는 불변.
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

/// 이동 의도 유무 — 전진/측보/턴 성형값 중 하나라도 0 이 아닌가. `GpMovingIntent`.
/// 부호 승수는 0 여부에 무관해 생략. 머리(우스틱)는 비게이트라 제외.
pub fn moving_intent(f: &InputFrame) -> bool {
    shape_drive_axis(f.ly) != 0.0
        || shape_drive_axis(f.lx) != 0.0
        || shape_turn(trigger_diff(f.rt, f.lt)) != 0.0
}

#[cfg(test)]
mod tests {
    use super::*;

    const EPS: f64 = 1e-9;

    #[test]
    fn deadzone_zeroes_below_threshold_and_at_boundary() {
        assert_eq!(apply_deadzone(0.05), 0.0);
        assert_eq!(apply_deadzone(-0.09), 0.0);
        // 경계: |v| == DEADZONE → (0)/(0.9) = 0.
        assert_eq!(apply_deadzone(g01::STICK_DEADZONE), 0.0);
        // 풀스틱 → 1.0, 부호 보존.
        assert!((apply_deadzone(1.0) - 1.0).abs() < EPS);
        assert!((apply_deadzone(-1.0) + 1.0).abs() < EPS);
    }

    #[test]
    fn deadzone_rescales_remainder() {
        // v=0.55, dz=0.10 → (0.45/0.90)=0.5.
        assert!((apply_deadzone(0.55) - 0.5).abs() < EPS);
    }

    #[test]
    fn drive_and_head_curve_fix_endpoints() {
        // 풀스틱은 곡선 무관 1.0(pow(1,k)=1).
        assert!((shape_drive_axis(1.0) - 1.0).abs() < EPS);
        assert!((shape_head_axis(-1.0) + 1.0).abs() < EPS);
        // 데드존 내는 0.
        assert_eq!(shape_drive_axis(0.05), 0.0);
        // 곡선 지수 차이: 같은 입력에서 헤드(1.7)가 이동(1.35)보다 더 줄어든다(저속 미세).
        let v = 0.6;
        assert!(shape_head_axis(v) < shape_drive_axis(v));
    }

    #[test]
    fn trigger_diff_deadzone_and_sign() {
        // 차분 0.01 < 0.02 데드존 → 0.
        assert_eq!(trigger_diff(0.51, 0.50), 0.0);
        // RT 우세 → 양수, LT 우세 → 음수.
        assert!(trigger_diff(1.0, 0.0) > 0.0);
        assert!(trigger_diff(0.0, 1.0) < 0.0);
        // 풀 RT → 1.0.
        assert!((trigger_diff(1.0, 0.0) - 1.0).abs() < EPS);
    }

    #[test]
    fn turn_low_press_boost_full_press_invariant() {
        // 풀프레스 ±1 불변.
        assert!((shape_turn(1.0) - 1.0).abs() < EPS);
        assert!((shape_turn(-1.0) + 1.0).abs() < EPS);
        // 저압 부스트: 0.1^0.65 ≈ 0.224 > 0.1.
        assert!(shape_turn(0.1) > 0.1);
        assert_eq!(shape_turn(0.0), 0.0);
    }

    #[test]
    fn moving_intent_detects_each_axis() {
        let mut f = InputFrame::default();
        assert!(!moving_intent(&f));
        f.ly = 1.0;
        assert!(moving_intent(&f));
        f = InputFrame::default();
        f.lx = -1.0;
        assert!(moving_intent(&f));
        f = InputFrame::default();
        f.rt = 1.0; // 우회전
        assert!(moving_intent(&f));
        // 데드존 내 미세 입력은 의도 아님.
        f = InputFrame::default();
        f.ly = 0.05;
        f.lx = -0.05;
        assert!(!moving_intent(&f));
    }
}
