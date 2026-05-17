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
        // 2026-05-17 clippy field_reassign_with_default fix — struct literal.
        MotionPage {
            safety_class: SafetyClass::Safe,
            steps: vec![MotionStep {
                positions: [2048u16; NUM_JOINTS_IN_STEP],
                pause_time: 0,
                play_time: 16,
            }],
            ..Default::default()
        }
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
        p.steps[0].positions[JointId::RKnee as usize] = FLAG_INVALID;
        assert!(matches!(v.validate(&p).unwrap(), ValidatorReport::Pass(_)));
    }

    /// **D3 회귀** — 가장 극단 자세인 page 12 right_kick step 3 (R_HipPitch −78°,
    /// R_AnklePitch −56°, R_AnkleRoll −27°) 가 모든 `JointLimits` 안에 들어감을
    /// explicit 하게 보장. 이전 BLOCKER H3 의 "page 12 가 V1 FAIL 한다"는 주장은
    /// off-by-one 정정(C1) 후 더 이상 성립하지 않는다.
    ///
    /// 각 step 의 가장 작은 마진을 stderr 로 출력해 후속 limit 보정의 기준 데이터로
    /// 사용한다.
    #[test]
    fn page_12_right_kick_passes_v1_with_margins() {
        use crate::synth::test_fixtures::page_12_right_kick;
        let v = JointLimitValidator;
        let p = page_12_right_kick();
        let report = v.validate(&p).expect("v1");
        assert!(
            !report.is_fail(),
            "page 12 right kick must pass V1, got {report:?}"
        );

        // 각 관절의 가장 작은 마진 (raw) 을 산정.
        let mut worst_margin: i32 = i32::MAX;
        let mut worst_joint: Option<JointId> = None;
        for (step_idx, step) in p.steps.iter().enumerate() {
            for slot in 1..=20usize {
                let raw = step.positions[slot];
                if raw == SKIP_MARKER
                    || (raw & FLAG_INVALID) != 0
                    || (raw & FLAG_TORQUE_OFF) != 0
                {
                    continue;
                }
                let Some(joint) = JointId::from_byte(slot as u8) else {
                    continue;
                };
                let limits = JointLimits::for_joint(joint);
                let v = (raw & POSITION_MASK) as i32;
                let lo_margin = v - limits.position_min as i32;
                let hi_margin = limits.position_max as i32 - v;
                let m = lo_margin.min(hi_margin);
                if m < worst_margin {
                    worst_margin = m;
                    worst_joint = Some(joint);
                }
                assert!(
                    m >= 0,
                    "step {step_idx} {joint:?} raw={v} margin={m} (limits {}~{})",
                    limits.position_min,
                    limits.position_max
                );
            }
        }
        // 실측 worst margin = 53 raw (~4.66°) at HeadTilt step 3 (kick 중 공을 보려
        // 머리 40.3° 아래로 향함, 한계 ±45°). 4° 이상이면 안전 마진 확보.
        eprintln!(
            "page 12 worst margin: {worst_margin} raw on {worst_joint:?}"
        );
        assert!(
            worst_margin >= 45,
            "page 12 worst margin {worst_margin} raw is below 4° safety margin"
        );
    }
}
