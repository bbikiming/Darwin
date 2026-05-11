//! V2 — 각속도 / 가속도 검증.
//!
//! step 간 위치 변화량 ÷ time 으로 추정 각속도를 계산하여 MX28 한계의 75%
//! (보수적 임계) 를 넘으면 WARN/FAIL. PRD §5.3 V2 참조.
//!
//! 구현: Sprint 9-9.

use super::{Validator, ValidatorReport, ValidatorStage};
use crate::motion::MotionPage;
use crate::synth::Result;

/// V2 — Velocity / Acceleration validator.
#[derive(Debug, Default)]
pub struct VelocityValidator;

impl Validator for VelocityValidator {
    fn stage(&self) -> ValidatorStage {
        ValidatorStage::Velocity
    }

    fn validate(&self, _page: &MotionPage) -> Result<ValidatorReport> {
        todo!("Sprint 9-9 — Velocity validator (PRD §5.3 V2)")
    }
}
