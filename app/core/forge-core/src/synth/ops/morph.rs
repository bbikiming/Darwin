//! **Morph** — 두 페이지 사이 포즈 보간/모핑.
//!
//! 두 페이지 A·B 의 각 step 관절을 ratio α 가중합으로 섞는다.
//! α 가 상수이면 균일 morph, 함수이면 progressive morph (A → B 전이).
//! PRD §5.2 FR-OP-3, §8.3 알고리즘 참조.
//!
//! 구현: Sprint 9-5.

use super::SynthOp;
use crate::motion::MotionPage;
use crate::synth::Result;

/// Morph ratio — 상수 또는 시간 함수.
#[derive(Debug, Clone)]
pub enum MorphRatio {
    /// 모든 step에 동일 α 적용.
    Constant(f32),
    /// step 인덱스 i (0..n-1) 에 대해 t = i/(n-1), 결과 α 반환.
    /// (스켈레톤 단계에서는 placeholder; 실제 함수는 Sprint 9-5에서 정의.)
    Progressive,
}

impl Default for MorphRatio {
    fn default() -> Self {
        Self::Constant(0.5)
    }
}

/// Morph 합성기 파라미터.
#[derive(Debug, Clone, Default)]
pub struct MorphParams {
    /// 보간 비율 (0..=1).
    pub ratio: MorphRatio,
}

/// Morph 합성 연산자.
#[derive(Debug, Default)]
pub struct Morph;

impl SynthOp for Morph {
    type Params = MorphParams;

    fn synthesize(
        &self,
        _inputs: &[&MotionPage],
        _params: &Self::Params,
    ) -> Result<Vec<MotionPage>> {
        todo!("Sprint 9-5 — Morph implementation (PRD §8.3)")
    }
}
