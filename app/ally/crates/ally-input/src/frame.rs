//! `InputFrame` — 정규화된 게임패드 한 틱 스냅샷 (gilrs 비의존 → 호스트 테스트 가능).
//!
//! 원본 `GamepadPilot.h::GamepadSnapshot` 의 Rust 등가. evdev 원시 디코드(스틱 ±32767·트리거
//! 0..255)는 로봇 온보드 전용이고, Ally 는 XInput(gilrs)이 이미 [-1,1]/[0,1] 부동소수를 주므로
//! 여기서는 정규화 결과만 담고 **범위 클램프만** 보장한다(계약 04 §2: "정규화 후 [-1,1]
//! 공간에서 동결 수치 1:1"). 원시 부호는 그대로 — 부호 승수는 매핑([`crate::command`])이 적용.

/// 스틱 축 클램프 [-1, 1] — `NormStick` 의 클램프부 등가(−32768→−1.00003 방지).
pub fn clamp_stick(v: f64) -> f64 {
    v.clamp(-1.0, 1.0)
}

/// 트리거 클램프 [0, 1] — `NormTrigger` 등가.
pub fn clamp_trigger(v: f64) -> f64 {
    v.clamp(0.0, 1.0)
}

/// 정규화된 패드 한 틱(EV_SYN 커밋 단위 등가). 축은 클램프된 [-1,1]/[0,1] 가정.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct InputFrame {
    /// 왼스틱 X (횡) [-1,1].
    pub lx: f64,
    /// 왼스틱 Y (전후) [-1,1].
    pub ly: f64,
    /// 오른스틱 X (헤드 팬 레이트) [-1,1].
    pub rx: f64,
    /// 오른스틱 Y (헤드 틸트 레이트) [-1,1].
    pub ry: f64,
    /// LT (좌회전) [0,1].
    pub lt: f64,
    /// RT (우회전) [0,1].
    pub rt: f64,
    pub btn_a: bool,
    pub btn_b: bool,
    pub btn_x: bool,
    pub btn_y: bool,
    pub btn_lb: bool,
    pub btn_rb: bool,
    /// 수신 시각(로컬 클럭, ms) — 신선도 기준.
    pub ts_ms: i64,
}

impl InputFrame {
    /// 전축 0·전버튼 false 의 중립 프레임(주어진 타임스탬프).
    pub fn neutral(ts_ms: i64) -> Self {
        InputFrame {
            ts_ms,
            ..Default::default()
        }
    }

    /// 축을 유효 범위로 클램프한 사본(어댑터 경계 방어).
    pub fn clamped(self) -> Self {
        InputFrame {
            lx: clamp_stick(self.lx),
            ly: clamp_stick(self.ly),
            rx: clamp_stick(self.rx),
            ry: clamp_stick(self.ry),
            lt: clamp_trigger(self.lt),
            rt: clamp_trigger(self.rt),
            ..self
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamp_bounds() {
        assert_eq!(clamp_stick(2.0), 1.0);
        assert_eq!(clamp_stick(-2.0), -1.0);
        assert_eq!(clamp_stick(0.5), 0.5);
        assert_eq!(clamp_trigger(-0.3), 0.0);
        assert_eq!(clamp_trigger(1.4), 1.0);
        assert_eq!(clamp_trigger(0.25), 0.25);
    }

    #[test]
    fn neutral_is_zero_with_ts() {
        let f = InputFrame::neutral(42);
        assert_eq!(f.ts_ms, 42);
        assert_eq!(f.lx, 0.0);
        assert!(!f.btn_a && !f.btn_b);
    }

    #[test]
    fn clamped_constrains_axes_keeps_buttons() {
        let raw = InputFrame {
            lx: -3.0,
            ly: 3.0,
            rx: 0.4,
            ry: -0.4,
            lt: 9.0,
            rt: -9.0,
            btn_b: true,
            ts_ms: 7,
            ..Default::default()
        };
        let c = raw.clamped();
        assert_eq!((c.lx, c.ly), (-1.0, 1.0));
        assert_eq!((c.lt, c.rt), (1.0, 0.0));
        assert_eq!((c.rx, c.ry), (0.4, -0.4));
        assert!(c.btn_b);
        assert_eq!(c.ts_ms, 7);
    }
}
