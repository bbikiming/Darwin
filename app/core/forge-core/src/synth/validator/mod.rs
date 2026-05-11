//! 4-stage 안전 검증 파이프라인.
//!
//! 모든 합성 결과는 V1 → V2 → V3 → V4 순으로 검증된다. **FAIL = commit 거부.**
//! PRD §5.3 참조.

pub mod joint_limit;
pub mod self_collision;
pub mod static_stability;
pub mod velocity;

use super::Result;
use crate::motion::MotionPage;

/// Validator 단계 식별자.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValidatorStage {
    /// V1 — 관절 위치 한계.
    JointLimit,
    /// V2 — 각속도 / 가속도 한계.
    Velocity,
    /// V3 — Self-collision.
    SelfCollision,
    /// V4 — 정적 안정성 (CoM in support polygon).
    StaticStability,
}

/// Validator 검사 결과.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValidatorReport {
    /// 통과.
    Pass(ValidatorStage),
    /// 경고 — 사용자 확인 후 진행 가능.
    Warn(ValidatorStage, String),
    /// 실패 — commit 거부.
    Fail(ValidatorStage, String),
}

impl ValidatorReport {
    /// `Fail` 인지 여부.
    pub fn is_fail(&self) -> bool {
        matches!(self, ValidatorReport::Fail(_, _))
    }

    /// 단계 식별자.
    pub fn stage(&self) -> ValidatorStage {
        match self {
            ValidatorReport::Pass(s)
            | ValidatorReport::Warn(s, _)
            | ValidatorReport::Fail(s, _) => *s,
        }
    }
}

/// 검증기 공통 trait.
pub trait Validator {
    /// 해당 검증기가 담당하는 단계.
    fn stage(&self) -> ValidatorStage;

    /// 페이지를 검사하고 보고서를 반환.
    fn validate(&self, page: &MotionPage) -> Result<ValidatorReport>;
}
