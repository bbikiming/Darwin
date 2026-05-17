//! V3 — Self-collision 검증.
//!
//! PRD §5.3 V3 / §17.4 참조.
//!
//! # 본구현 (S9-10 V3)
//!
//! 본 validator 는 자체 휴리스틱을 구현하지 않고 [`crate::safety::self_collision`]
//! 의 5종 충돌 룰 (knee hyperextension, hip roll, shoulder roll, arm-head,
//! hip+knee 조합) 을 thin wrapper 로 호출해 [`ValidatorReport`] 로 매핑한다.

use super::{Validator, ValidatorReport, ValidatorStage};
use crate::motion::MotionPage;
use crate::safety::self_collision::check_page as safety_check_page;
use crate::synth::Result;

/// V3 — Self-collision validator (thin wrapper over `safety::self_collision`).
#[derive(Debug, Default)]
pub struct SelfCollisionValidator;

impl Validator for SelfCollisionValidator {
    fn stage(&self) -> ValidatorStage {
        ValidatorStage::SelfCollision
    }

    fn validate(&self, page: &MotionPage) -> Result<ValidatorReport> {
        match safety_check_page(page) {
            Ok(()) => Ok(ValidatorReport::Pass(self.stage())),
            Err(step_errs) => {
                let total_rules: usize = step_errs.iter().map(|(_, es)| es.len()).sum();
                let summary = step_errs
                    .iter()
                    .map(|(step_idx, es)| {
                        let first = es
                            .first()
                            .map(|e| e.to_string())
                            .unwrap_or_else(|| "unknown".to_string());
                        format!("step {} ({} rules): {}", step_idx, es.len(), first)
                    })
                    .collect::<Vec<_>>()
                    .join("; ");
                Ok(ValidatorReport::Fail(
                    self.stage(),
                    format!(
                        "{} step(s) failed, {} total rule violations: {}",
                        step_errs.len(),
                        total_rules,
                        summary
                    ),
                ))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::motion::page::NUM_JOINTS_IN_STEP;
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
    fn validator_stage_is_self_collision() {
        let v = SelfCollisionValidator;
        assert_eq!(v.stage(), ValidatorStage::SelfCollision);
    }

    #[test]
    fn neutral_pose_passes() {
        let v = SelfCollisionValidator;
        let page = neutral_page();
        match v.validate(&page).expect("validate") {
            ValidatorReport::Pass(stage) => assert_eq!(stage, ValidatorStage::SelfCollision),
            other => panic!("expected Pass, got {:?}", other),
        }
    }

    #[test]
    fn hyperextended_knee_fails() {
        // safety::check_step uses `j as usize`. JointId::RKnee = 13 → positions[13].
        // raw 800 → -109° → triggers hyperextension (< -5°).
        let mut page = neutral_page();
        let mut bad = page.steps[0].clone();
        bad.positions[13] = 800;
        page.steps[0] = bad;

        let v = SelfCollisionValidator;
        let report = v.validate(&page).expect("validate");
        assert!(report.is_fail(), "expected Fail, got {:?}", report);
        if let ValidatorReport::Fail(stage, msg) = report {
            assert_eq!(stage, ValidatorStage::SelfCollision);
            assert!(
                msg.to_lowercase().contains("knee") || msg.to_lowercase().contains("hyper"),
                "msg should mention knee/hyper: {}",
                msg
            );
        }
    }

    #[test]
    fn validator_fail_summary_includes_step_count() {
        let mut page = neutral_page();
        let mut s1 = page.steps[0].clone();
        s1.positions[13] = 800; // RKnee hyperextension
        let s2 = s1.clone();
        page.steps = vec![s1, s2];

        let v = SelfCollisionValidator;
        let report = v.validate(&page).expect("validate");
        if let ValidatorReport::Fail(_, msg) = report {
            assert!(msg.contains("2 step"), "msg: {}", msg);
        } else {
            panic!("expected Fail");
        }
    }
}
