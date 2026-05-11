//! **Sequence** — 시간축 연결 합성기.
//!
//! 페이지 A → B → C 순서로 step을 이어 붙이고, 사이에 bridge step을 자동
//! 삽입한다. PRD §5.2 FR-OP-1, §8.1 알고리즘 참조.
//!
//! 구현: Sprint 9-3.

use super::SynthOp;
use crate::motion::MotionPage;
use crate::synth::Result;

/// Sequence 합성기 파라미터.
#[derive(Debug, Clone)]
pub struct SequenceParams {
    /// 페이지 사이 bridge step의 보간 시간(ms). 기본 800.
    pub transition_ms: u16,
}

impl Default for SequenceParams {
    fn default() -> Self {
        Self { transition_ms: 800 }
    }
}

/// Sequence 합성 연산자.
#[derive(Debug, Default)]
pub struct Sequence;

impl SynthOp for Sequence {
    type Params = SequenceParams;

    fn synthesize(
        &self,
        _inputs: &[&MotionPage],
        _params: &Self::Params,
    ) -> Result<Vec<MotionPage>> {
        todo!("Sprint 9-3 — Sequence implementation (PRD §8.1)")
    }
}
