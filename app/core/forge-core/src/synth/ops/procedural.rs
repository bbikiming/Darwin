//! **Procedural** — 시작/끝 anchor + 궤적 함수로 step을 수학적으로 생성.
//!
//! 카탈로그에 없는 새 패턴 (예: 사인파 head sway) 을 생성하기 위한 연산자.
//! PRD §5.2 FR-OP-6 참조.
//!
//! 구현: Sprint 9-8.

use super::SynthOp;
use crate::motion::MotionPage;
use crate::synth::Result;

/// 사용 가능한 궤적 함수.
#[derive(Debug, Clone, Default)]
pub enum Curve {
    /// 선형 보간.
    #[default]
    Linear,
    /// Ease-in-out.
    EaseInOut,
    /// 사인파.
    Sine {
        /// 각속도 (rad/s).
        omega: f32,
        /// 위상 오프셋 (rad).
        phase: f32,
    },
    /// 베지어 (0..=1 정규화 제어점 2개).
    Bezier {
        /// 제어점 1.
        p1: (f32, f32),
        /// 제어점 2.
        p2: (f32, f32),
    },
}

/// Procedural 합성기 파라미터.
#[derive(Debug, Clone, Default)]
pub struct ProceduralParams {
    /// 시작 anchor 페이지 (`inputs[0]`).
    /// 끝 anchor 페이지 (`inputs[1]`).
    /// 적용할 궤적 함수.
    pub curve: Curve,
    /// 생성할 step 수 (1..=7).
    pub num_steps: u8,
}

/// Procedural 합성 연산자.
#[derive(Debug, Default)]
pub struct Procedural;

impl SynthOp for Procedural {
    type Params = ProceduralParams;

    fn synthesize(
        &self,
        _inputs: &[&MotionPage],
        _params: &Self::Params,
    ) -> Result<Vec<MotionPage>> {
        todo!("Sprint 9-8 — Procedural implementation (PRD §5.2 FR-OP-6)")
    }
}
