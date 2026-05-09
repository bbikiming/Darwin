//! 키프레임 보간 — 선형 / 쿠빅(에르밋) / 이징.
//!
//! `MotionStep`의 `play_time` 동안 `from.positions` → `to.positions`로
//! 보간된 `MotionStep`을 시간 t에서 sample.

use super::page::{MotionStep, NUM_JOINTS_IN_STEP};

/// 보간 모드.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Easing {
    /// 선형.
    Linear,
    /// 부드러운 in-out (smoothstep).
    SmoothInOut,
    /// 부드러운 in (가속만).
    EaseIn,
    /// 부드러운 out (감속만).
    EaseOut,
}

impl Easing {
    /// t in 0..=1 → 보간된 0..=1.
    pub fn apply(self, t: f32) -> f32 {
        let t = t.clamp(0.0, 1.0);
        match self {
            Easing::Linear => t,
            Easing::SmoothInOut => t * t * (3.0 - 2.0 * t),
            Easing::EaseIn => t * t,
            Easing::EaseOut => 1.0 - (1.0 - t) * (1.0 - t),
        }
    }
}

/// `from` → `to`를 t∈[0,1]에서 31-슬롯 단위로 보간.
pub fn interpolate(from: &MotionStep, to: &MotionStep, t: f32, easing: Easing) -> MotionStep {
    let alpha = easing.apply(t);
    let mut positions = [0u16; NUM_JOINTS_IN_STEP];
    for (i, slot) in positions.iter_mut().enumerate() {
        let f = from.positions[i] as f32;
        let g = to.positions[i] as f32;
        *slot = (f + (g - f) * alpha).round() as u16;
    }
    MotionStep {
        positions,
        pause_time: to.pause_time,
        play_time: to.play_time,
    }
}

/// 페이지 시작부터 `elapsed_ms` 시점의 보간된 자세.
///
/// 페이지가 N개 step을 가진다면, step 사이 트랜지션이 N-1개. 각 트랜지션의 길이 = step.play_ms() (target step 기준).
pub fn sample_at_ms(steps: &[MotionStep], elapsed_ms: u32, easing: Easing) -> MotionStep {
    if steps.is_empty() {
        return MotionStep::default();
    }
    if steps.len() == 1 {
        return steps[0].clone();
    }
    let mut acc = 0u32;
    for w in steps.windows(2) {
        let segment_ms = w[1].play_ms() as u32;
        if elapsed_ms < acc + segment_ms {
            let local = (elapsed_ms - acc) as f32 / segment_ms.max(1) as f32;
            return interpolate(&w[0], &w[1], local, easing);
        }
        acc += segment_ms + w[1].pause_ms() as u32;
    }
    steps.last().unwrap().clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn step(positions: u16) -> MotionStep {
        MotionStep {
            positions: [positions; NUM_JOINTS_IN_STEP],
            pause_time: 0,
            play_time: 32,
        }
    }

    #[test]
    fn easing_endpoints() {
        for e in [
            Easing::Linear,
            Easing::SmoothInOut,
            Easing::EaseIn,
            Easing::EaseOut,
        ] {
            assert!((e.apply(0.0) - 0.0).abs() < 1e-6);
            assert!((e.apply(1.0) - 1.0).abs() < 1e-6);
        }
    }

    #[test]
    fn linear_midpoint() {
        let m = interpolate(&step(1000), &step(3000), 0.5, Easing::Linear);
        assert_eq!(m.positions[0], 2000);
    }

    #[test]
    fn smooth_inout_midpoint_equals_half() {
        let m = interpolate(&step(0), &step(4000), 0.5, Easing::SmoothInOut);
        // smoothstep(0.5) = 0.5
        assert_eq!(m.positions[0], 2000);
    }

    #[test]
    fn sample_at_ms_within_segment() {
        // 두 step: 1000 → 3000, play_time=32 (= 256 ms)
        let s = vec![step(1000), step(3000)];
        let mid = sample_at_ms(&s, 128, Easing::Linear); // 절반
        assert_eq!(mid.positions[0], 2000);
    }

    #[test]
    fn sample_at_ms_after_end_returns_last() {
        let s = vec![step(1000), step(3000)];
        let after = sample_at_ms(&s, 999_999, Easing::Linear);
        assert_eq!(after.positions[0], 3000);
    }
}
