//! V2 — 각속도 / 가속도 검증.
//!
//! 본구현 (S9-9 V2). PRD §5.3 V2.
//!
//! step 간 위치 변화량 ÷ play_time 으로 추정 각속도 (raw/ms) 를 계산. MX-28 의
//! `moving_speed_max` 한계 (1023 raw → 약 117 rpm) 의 75% (보수적 임계) 를
//! 넘으면 FAIL.
//!
//! ## 단위 변환
//! - MX-28: 1 raw 위치 step = 360°/4096 = 0.088°
//! - 시간: `play_time` raw = ms × 8
//! - 속도 raw/ms → deg/s = `raw / ms × 0.088 × 1000 = raw / ms × 88`
//! - MX-28 max moving speed raw = 1023 → 약 84 RPM → 504°/s
//! - 75% threshold → 378°/s
//!
//! 보수적: raw 변화 / play_time(ms) > 약 4.3 → fail.

use super::{Validator, ValidatorReport, ValidatorStage};
use crate::motion::page::NUM_JOINTS_IN_STEP;
use crate::motion::MotionPage;
use crate::synth::Result;

const SKIP_MARKER: u16 = 32767;
const FLAG_INVALID: u16 = 0x4000;
const FLAG_TORQUE_OFF: u16 = 0x2000;
const POSITION_MASK: u16 = 0x0FFF;

/// `raw_change / ms` 임계. MX-28 max 의 약 75%.
///
/// max_moving_speed = 1023 raw ≈ 504°/s ≈ 5727 raw_pos/s ≈ 5.7 raw/ms.
/// 75% → 4.3 raw/ms.
pub const MAX_RAW_PER_MS: f64 = 4.3;

/// V2 — Velocity / Acceleration validator.
#[derive(Debug, Default)]
pub struct VelocityValidator;

impl Validator for VelocityValidator {
    fn stage(&self) -> ValidatorStage {
        ValidatorStage::Velocity
    }

    fn validate(&self, page: &MotionPage) -> Result<ValidatorReport> {
        if page.steps.len() < 2 {
            return Ok(ValidatorReport::Pass(self.stage()));
        }

        let mut violations: Vec<String> = Vec::new();

        for win in page.steps.windows(2) {
            let a = &win[0];
            let b = &win[1];
            // play_time of B = duration to reach B from A.
            let play_ms = (b.play_time as f64) * 8.0;
            if play_ms <= 0.0 {
                continue;
            }
            for i in 1..=NUM_JOINTS_IN_STEP.min(20) {
                let av = a.positions[i];
                let bv = b.positions[i];
                if av == SKIP_MARKER
                    || bv == SKIP_MARKER
                    || (av & FLAG_INVALID) != 0
                    || (bv & FLAG_INVALID) != 0
                    || (av & FLAG_TORQUE_OFF) != 0
                    || (bv & FLAG_TORQUE_OFF) != 0
                {
                    continue;
                }
                let av_pos = (av & POSITION_MASK) as i32;
                let bv_pos = (bv & POSITION_MASK) as i32;
                let delta = (bv_pos - av_pos).abs() as f64;
                let speed = delta / play_ms;
                if speed > MAX_RAW_PER_MS {
                    violations.push(format!(
                        "joint slot {} {:.2} raw/ms > {:.2} max",
                        i, speed, MAX_RAW_PER_MS
                    ));
                }
            }
        }

        if violations.is_empty() {
            Ok(ValidatorReport::Pass(self.stage()))
        } else {
            let summary = if violations.len() > 3 {
                format!(
                    "{} velocity violations, first 3: {}",
                    violations.len(),
                    violations[..3].join("; ")
                )
            } else {
                violations.join("; ")
            };
            Ok(ValidatorReport::Fail(self.stage(), summary))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::motion::{MotionPage, MotionStep, SafetyClass};

    fn page_with_steps(steps: Vec<MotionStep>) -> MotionPage {
        let mut p = MotionPage::default();
        p.safety_class = SafetyClass::Safe;
        p.steps = steps;
        p
    }

    fn step(positions: [u16; NUM_JOINTS_IN_STEP], play_time: u8) -> MotionStep {
        MotionStep {
            positions,
            pause_time: 0,
            play_time,
        }
    }

    #[test]
    fn single_step_passes() {
        let p = page_with_steps(vec![step([2048; NUM_JOINTS_IN_STEP], 16)]);
        assert!(matches!(
            VelocityValidator.validate(&p).unwrap(),
            ValidatorReport::Pass(_)
        ));
    }

    #[test]
    fn slow_change_passes() {
        // 약 20ms 동안 raw 50 변화 = 2.5 raw/ms < 4.3 limit
        let mut a = [2048u16; NUM_JOINTS_IN_STEP];
        let mut b = [2048u16; NUM_JOINTS_IN_STEP];
        a[1] = 2000;
        b[1] = 2050;
        // play_time = 4 → 32 ms; delta 50 → 50/32 = 1.56 raw/ms
        let p = page_with_steps(vec![step(a, 16), step(b, 4)]);
        assert!(matches!(
            VelocityValidator.validate(&p).unwrap(),
            ValidatorReport::Pass(_)
        ));
    }

    #[test]
    fn fast_change_fails() {
        // 8ms (play_time=1) 동안 raw 100 변화 = 12.5 raw/ms > 4.3 limit
        let mut a = [2048u16; NUM_JOINTS_IN_STEP];
        let mut b = [2048u16; NUM_JOINTS_IN_STEP];
        a[1] = 2000;
        b[1] = 2100;
        let p = page_with_steps(vec![step(a, 16), step(b, 1)]);
        let report = VelocityValidator.validate(&p).unwrap();
        assert!(report.is_fail(), "expected Fail, got {:?}", report);
    }

    #[test]
    fn skip_marker_does_not_violate() {
        let mut a = [SKIP_MARKER; NUM_JOINTS_IN_STEP];
        let mut b = [SKIP_MARKER; NUM_JOINTS_IN_STEP];
        a[1] = 2000;
        b[1] = SKIP_MARKER;
        let p = page_with_steps(vec![step(a, 16), step(b, 1)]);
        assert!(matches!(
            VelocityValidator.validate(&p).unwrap(),
            ValidatorReport::Pass(_)
        ));
    }
}
