//! V1 — 관절 위치 한계 검증.
//!
//! 각 step의 관절 값이 `joint_limits.toml`의 (min, max) 범위 내인지 확인.
//! `0x4000` (INVALID), `0x2000` (TORQUE_OFF) 플래그 비트는 검증 제외.
//! PRD §5.3 V1 참조.
//!
//! 구현: Sprint 9-9.

use super::{Validator, ValidatorReport, ValidatorStage};
use crate::motion::MotionPage;
use crate::synth::Result;

/// V1 — Joint Limit validator.
#[derive(Debug, Default)]
pub struct JointLimitValidator;

impl Validator for JointLimitValidator {
    fn stage(&self) -> ValidatorStage {
        ValidatorStage::JointLimit
    }

    fn validate(&self, _page: &MotionPage) -> Result<ValidatorReport> {
        todo!("Sprint 9-9 — Joint Limit validator (PRD §5.3 V1)")
    }
}
