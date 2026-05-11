//! V4 — 정적 안정성 검증.
//!
//! 각 step 에서 CoM(질량 중심) 의 ground projection이 지지 다각형(support polygon)
//! 내부에 있는지 확인. 단일발 지지 페이지는 `single_foot_ok` 메타데이터 플래그가
//! 있을 때만 허용. PRD §5.3 V4, §8.5 알고리즘 참조.
//!
//! 구현: Sprint 9-10.

use super::{Validator, ValidatorReport, ValidatorStage};
use crate::motion::MotionPage;
use crate::synth::Result;

/// V4 — Static stability validator.
#[derive(Debug, Default)]
pub struct StaticStabilityValidator;

impl Validator for StaticStabilityValidator {
    fn stage(&self) -> ValidatorStage {
        ValidatorStage::StaticStability
    }

    fn validate(&self, _page: &MotionPage) -> Result<ValidatorReport> {
        todo!("Sprint 9-10 — Static stability validator (PRD §5.3 V4, §8.5)")
    }
}
