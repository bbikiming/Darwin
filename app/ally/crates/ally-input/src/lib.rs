//! ally-input — 게임패드 입력·G01 매핑·안전 게이트 (W1).
//!
//! 03 §2 입력 스레드 + 제어 TX 게이트의 헤드리스 코어. 모듈 경계:
//! - [`g01`] — `GamepadPilot.h` 동결 매핑 상수(D2 — INV-4).
//! - [`mapping`] — evdev 방향 스냅샷 → `df_wire::MotionCommand` (1:1 포팅, 순수).
//! - [`gate`] — ARM/ESTOP_LATCH/RECOVER 상태머신 + failsafe 3티어 + EMA 스무더.
//! - [`adapter`] — gilrs(SDL 방향) → evdev 방향 흡수(Y축 반전).
//! - [`source`] — gilrs 250Hz 폴링 스레드 + 무손실 B E-STOP 채널.
//!
//! 안전 경로는 UI 프레임워크 생명주기와 무관한 순수 Rust 스레드다(INV-2).

use std::sync::OnceLock;
use std::time::{Duration, Instant};

pub mod adapter;
pub mod g01;
pub mod gate;
pub mod mapping;
pub mod source;

pub use adapter::{to_evdev, GilrsAxes};
pub use gate::{
    failsafe_decision, ButtonEdges, CommandSmoother, Failsafe, GateEvents, SafetyGate, SafetyState,
};
pub use mapping::{
    apply_deadzone, g01_gait_config, map_gamepad, shape_drive_axis, shape_head_axis, shape_turn,
    trigger_diff, GamepadState, HeadHold,
};
pub use source::{dump_events, EstopReason, EstopSignal, InputFrame, InputService};

/// 입력 폴링 주기 — 250Hz (03 §2: gilrs 폴링 4ms).
pub const POLL_PERIOD: Duration = Duration::from_millis(4);

/// 프로세스 monotonic 기점 — 입력·TX 스레드가 공유하는 단조 ms 시계의 근원.
fn clock_origin() -> Instant {
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    *ORIGIN.get_or_init(Instant::now)
}

/// 단조 증가 ms 시계(프로세스 기동 기준). 게이트 타임스탬프·신선도·failsafe 공용 —
/// 스레드 간 일관된 타임라인. 벽시계가 아니라 `Instant` 기반이라 NTP 점프 면역.
pub fn now_ms() -> i64 {
    clock_origin().elapsed().as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn now_ms_monotonic() {
        let a = now_ms();
        std::thread::sleep(Duration::from_millis(2));
        let b = now_ms();
        assert!(b >= a);
    }
}
