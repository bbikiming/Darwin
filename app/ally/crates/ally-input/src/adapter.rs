//! XInput(gilrs) → evdev 방향 어댑터.
//!
//! 매핑 코어([`crate::mapping`])는 원본 `GamepadPilot` 과 1:1 이 되도록 **evdev 방향**
//! (스틱 아래=+·오른쪽=+, 트리거 [0,1])을 입력으로 받는다. gilrs 는 SDL 관례
//! (스틱 **위=+**·오른쪽=+)라 Y축 부호만 다르다 — 여기서 흡수한다(04 §2 W1:
//! "축 원시 범위 차이는 어댑터 레이어에서 흡수, 정규화 이후 수치는 동결").
//!
//! 이 Y축 반전 가정과 XInput 트리거가 축/버튼 어느 쪽으로 오는지는 기기 편차가
//! 있어(04 §2 리스크), 유선 게이트의 **축 덤프 모드**(ally-cli)로 현장 확정한다.

use crate::mapping::GamepadState;

/// gilrs 관례의 정규화 축/버튼(스틱 위=+·오른쪽=+, 트리거 [0,1]).
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct GilrsAxes {
    pub left_x: f64,
    pub left_y: f64,
    pub right_x: f64,
    pub right_y: f64,
    pub lt: f64,
    pub rt: f64,
    pub btn_a: bool,
    pub btn_b: bool,
    pub btn_x: bool,
    pub btn_y: bool,
    pub btn_lb: bool,
    pub btn_rb: bool,
}

/// gilrs 방향 → evdev 방향 스냅샷. 차이는 스틱 Y 부호뿐(gilrs 위=+ → evdev 아래=+).
pub fn to_evdev(g: &GilrsAxes) -> GamepadState {
    GamepadState {
        lx: g.left_x,   // 오른쪽 + — gilrs·evdev 동일
        ly: -g.left_y,  // 위 + → 아래 + 반전
        rx: g.right_x,  // 오른쪽 + — 동일
        ry: -g.right_y, // 반전
        lt: g.lt,
        rt: g.rt,
        btn_a: g.btn_a,
        btn_b: g.btn_b,
        btn_x: g.btn_x,
        btn_y: g.btn_y,
        btn_lb: g.btn_lb,
        btn_rb: g.btn_rb,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mapping::{map_gamepad, HeadHold};

    #[test]
    fn y_axes_inverted_others_passthrough() {
        let g = GilrsAxes {
            left_x: 0.7,
            left_y: 0.9,
            right_x: -0.3,
            right_y: 0.4,
            lt: 0.2,
            rt: 0.8,
            btn_a: true,
            ..Default::default()
        };
        let e = to_evdev(&g);
        assert_eq!(e.lx, 0.7);
        assert_eq!(e.ly, -0.9); // 반전
        assert_eq!(e.rx, -0.3);
        assert_eq!(e.ry, -0.4); // 반전
        assert_eq!(e.lt, 0.2);
        assert_eq!(e.rt, 0.8);
        assert!(e.btn_a);
    }

    #[test]
    fn end_to_end_stick_forward_drives_forward() {
        // gilrs 왼스틱 위로 끝까지(+1) → 로봇 전진(+stride). 전 사슬(gilrs 위=+ →
        // evdev 아래=− → SIGN_STRIDE=−1 → +stride) 부호 검증 — 한 군데만 틀려도 실패.
        let g = GilrsAxes {
            left_y: 1.0,
            ..Default::default()
        };
        let mut hold = HeadHold::default();
        let c = map_gamepad(&to_evdev(&g), true, 0.0, &mut hold);
        assert!(c.enabled);
        assert!(c.stride_mm > 0.0, "스틱 위 → 전진 (+stride)");

        // 왼스틱 오른쪽(+1) → 우횡(−side).
        let g = GilrsAxes {
            left_x: 1.0,
            ..Default::default()
        };
        let c = map_gamepad(&to_evdev(&g), true, 0.0, &mut hold);
        assert!(c.side_mm < 0.0, "스틱 우 → 우횡 (−side)");

        // RT 풀(우회전 트리거) → 우회전(−turn).
        let g = GilrsAxes {
            rt: 1.0,
            ..Default::default()
        };
        let c = map_gamepad(&to_evdev(&g), true, 0.0, &mut hold);
        assert!(c.turn_deg < 0.0, "RT → 우회전 (−turn)");
    }
}
