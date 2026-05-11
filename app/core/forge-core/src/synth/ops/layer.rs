//! **Layer** — 부위별 동시 합성기.
//!
//! 상체 / 하체 / 머리 부위를 서로 다른 페이지에서 가져와 같은 시간축에 병합한다.
//! PRD §5.2 FR-OP-2, §8.2 알고리즘 참조.
//!
//! 구현: Sprint 9-4.

use super::SynthOp;
use crate::motion::MotionPage;
use crate::synth::Result;

/// Layer 합성기 입력 — 각 부위에 매핑할 페이지.
#[derive(Debug, Clone)]
pub struct LayerInputs<'a> {
    /// 상체용 페이지 (관절 1..=6).
    pub upper: Option<&'a MotionPage>,
    /// 하체용 페이지 (관절 7..=18).
    pub lower: Option<&'a MotionPage>,
    /// 머리용 페이지 (관절 19..=20).
    pub head: Option<&'a MotionPage>,
}

/// 동일 관절이 둘 이상의 입력에서 정의될 때 우선순위.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayerPriority {
    /// 상체 입력 우선.
    Upper,
    /// 하체 입력 우선.
    Lower,
    /// 머리 입력 우선.
    Head,
}

/// Layer 합성기 파라미터.
#[derive(Debug, Clone)]
pub struct LayerParams {
    /// 충돌 시 우선순위 (기본 Upper).
    pub priority: LayerPriority,
    /// 결과 페이지의 step 수 (기본 7, max 7).
    pub num_steps: u8,
}

impl Default for LayerParams {
    fn default() -> Self {
        Self {
            priority: LayerPriority::Upper,
            num_steps: 7,
        }
    }
}

/// Layer 합성 연산자.
#[derive(Debug, Default)]
pub struct Layer;

impl SynthOp for Layer {
    type Params = LayerParams;

    fn synthesize(
        &self,
        _inputs: &[&MotionPage],
        _params: &Self::Params,
    ) -> Result<Vec<MotionPage>> {
        todo!("Sprint 9-4 — Layer implementation (PRD §8.2)")
    }
}
