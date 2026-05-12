//! V1 — 관절 위치 한계 검증.
//!
//! 본구현 (S9-9 V1). PRD §5.3 V1.
//!
//! 각 step 의 각 관절 raw 가 `JointLimits::for_joint(j)` 범위 내인지 확인.
//! INVALID/TORQUE_OFF 플래그 (0x4000/0x2000) 와 SKIP_MARKER (32767) 는 검증 제외.

use super::{Validator, ValidatorReport, ValidatorStage};
use crate::joint::{JointId, JointLimits};
use crate::motion::page::NUM_JOINTS_IN_STEP;
use crate::motion::MotionPage;
use crate::synth::Result;

const SKIP_MARKER: u16 = 32767;
const FLAG_INVALID: u16 = 0x4000;
const FLAG_TORQUE_OFF: u16 = 0x2000;
const POSITION_MASK: u16 = 0x0FFF;

/// V1 — Joint Limit validator.
#[derive(Debug, Default)]
pub struct JointLimitValidator;

impl Validator for JointLimitValidator {
    fn stage(&self) -> ValidatorStage {
        ValidatorStage::JointLimit
    }

    fn validate(&self, page: &MotionPage) -> Result<ValidatorReport> {
        let mut violations: Vec<String> = Vec::new();

        for (step_idx, step) in page.steps.iter().enumerate() {
            for slot in 1..=NUM_JOINTS_IN_STEP.min(20) {
                let i = slot;
                if i >= step.positions.len() {
                    break;
                }
                let raw = step.positions[i];

                // SKIP / INVALID / TORQUE_OFF 제외
                if raw == SKIP_MARKER || (raw & FLAG_INVALID) != 0 || (raw & FLAG_TORQUE_OFF) != 0 {
                    continue;
                }

                let Some(joint) = JointId::from_byte(i as u8) else {
                    continue;
                };
                let limits = JointLimits::for_joint(joint);
                let value = raw & POSITION_MASK;
                if value < limits.position_min || value > limits.position_max {
                    violations.push(format!(
                        "step {}: {:?} raw={} out of [{}, {}]",
                        step_idx, joint, value, limits.position_min, limits.position_max
                    ));
                }
            }
        }

        if violations.is_empty() {
            Ok(ValidatorReport::Pass(self.stage()))
        } else {
            let summary = if violations.len() > 3 {
                format!(
                    "{} violations, first 3: {}",
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

    fn neutral_page() -> MotionPage {
        let mut p = MotionPage::default();
        p.safety_class = SafetyClass::Safe;
        p.steps = vec![MotionStep {
            positions: [2048u16; NUM_JOINTS_IN_STEP],
            pause_time: 0,
            play_time: 16,
        }];
        p
    }

    #[test]
    fn stage_is_joint_limit() {
        assert_eq!(JointLimitValidator.stage(), ValidatorStage::JointLimit);
    }

    #[test]
    fn neutral_page_passes() {
        let v = JointLimitValidator;
        let p = neutral_page();
        assert!(matches!(v.validate(&p).unwrap(), ValidatorReport::Pass(_)));
    }

    #[test]
    fn out_of_range_value_fails() {
        let v = JointLimitValidator;
        let mut p = neutral_page();
        // RKnee (slot 13) at 0 (= -180°) is outside limits (±150° typical).
        p.steps[0].positions[JointId::RKnee as usize] = 0;
        let report = v.validate(&p).unwrap();
        assert!(report.is_fail(), "expected Fail, got {:?}", report);
    }

    #[test]
    fn skip_marker_is_ignored() {
        let v = JointLimitValidator;
        let mut p = neutral_page();
        // SKIP marker should not trigger out-of-range
        p.steps[0].positions[JointId::RKnee as usize] = SKIP_MARKER;
        assert!(matches!(v.validate(&p).unwrap(), ValidatorReport::Pass(_)));
    }

    #[test]
    fn invalid_flag_is_ignored() {
        let v = JointLimitValidator;
        let mut p = neutral_page();
        // Set INVALID flag bit + a value that would otherwise fail
        p.steps[0].positions[JointId::RKnee as usize] = FLAG_INVALID | 0;
        assert!(matches!(v.validate(&p).unwrap(), ValidatorReport::Pass(_)));
    }
}
