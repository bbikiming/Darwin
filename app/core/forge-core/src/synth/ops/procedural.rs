//! **Procedural** — 시작/끝 anchor + 궤적 함수로 step 을 수학적으로 생성.
//!
//! 본구현 (S9-8). PRD §5.2 FR-OP-6.
//!
//! 두 anchor 페이지 (`inputs[0]` 시작, `inputs[1]` 끝) 의 step 0 을 양 끝점으로
//! 잡고, `num_steps` 만큼 중간 step 을 `Curve` 함수로 보간 생성.
//! - `Linear`: 직선 보간
//! - `EaseInOut`: smoothstep
//! - `Sine`: phase + omega 기반 (간이; 0..1 한 주기로 정규화)
//! - `Bezier`: 2차 베지어 (4 제어점: 0, p1, p2, 1)

use super::mirror::{FLAG_MASK, POSITION_MASK};
use super::SynthOp;
use crate::motion::page::NUM_JOINTS_IN_STEP;
use crate::motion::{MotionPage, MotionStep};
use crate::synth::error::SynthError;
use crate::synth::Result;

const SKIP_MARKER: u16 = 32767;

/// 사용 가능한 궤적 함수.
#[derive(Debug, Clone, Default)]
pub enum Curve {
    /// 선형 보간.
    #[default]
    Linear,
    /// Ease-in-out (smoothstep).
    EaseInOut,
    /// 사인파. `t` 정규화 [0,1] 에서 `0.5 * (1 + sin(omega·t·2π + phase))`.
    Sine {
        /// 사이클 수 (omega/(2π) ≈ 1.0 = 1 cycle over t∈[0,1]).
        omega: f32,
        /// 위상 오프셋 (rad).
        phase: f32,
    },
    /// 큐빅 베지어 — 0, p1, p2, 1 제어점.
    Bezier {
        /// 제어점 1 (t, value).
        p1: (f32, f32),
        /// 제어점 2.
        p2: (f32, f32),
    },
}

/// Procedural 합성기 파라미터.
#[derive(Debug, Clone)]
pub struct ProceduralParams {
    /// 적용할 궤적 함수.
    pub curve: Curve,
    /// 생성할 step 수 (1..=7).
    pub num_steps: u8,
    /// 각 step 의 play_time (raw, ms = ×8). 기본 16 (128ms).
    pub play_time: u8,
}

impl Default for ProceduralParams {
    fn default() -> Self {
        Self {
            curve: Curve::Linear,
            num_steps: 4,
            play_time: 16,
        }
    }
}

/// Procedural 합성 연산자.
#[derive(Debug, Default)]
pub struct Procedural;

impl SynthOp for Procedural {
    type Params = ProceduralParams;

    fn synthesize(
        &self,
        inputs: &[&MotionPage],
        params: &Self::Params,
    ) -> Result<Vec<MotionPage>> {
        if inputs.len() != 2 {
            return Err(SynthError::Other(format!(
                "Procedural expects 2 input pages (start, end), got {}",
                inputs.len()
            )));
        }
        let a = inputs[0]
            .steps
            .first()
            .ok_or_else(|| SynthError::Other("Procedural: start page has no steps".into()))?;
        let b = inputs[1]
            .steps
            .first()
            .ok_or_else(|| SynthError::Other("Procedural: end page has no steps".into()))?;

        let n = params.num_steps.clamp(1, 7) as usize;
        let mut steps = Vec::with_capacity(n);
        for i in 0..n {
            let t = if n > 1 { i as f32 / (n - 1) as f32 } else { 0.5 };
            let alpha = evaluate_curve(&params.curve, t);
            let blended = blend_step(a, b, alpha, params.play_time);
            steps.push(blended);
        }

        let mut out = inputs[0].clone();
        if !out.name.is_empty() {
            out.name = format!("{}_proc", out.name);
        }
        out.steps = steps;
        Ok(vec![out])
    }
}

/// t∈[0,1] → α∈[0,1] (적당히 clamp).
pub fn evaluate_curve(curve: &Curve, t: f32) -> f32 {
    let x = t.clamp(0.0, 1.0);
    match curve {
        Curve::Linear => x,
        Curve::EaseInOut => x * x * (3.0 - 2.0 * x),
        Curve::Sine { omega, phase } => {
            use std::f32::consts::TAU;
            (0.5 + 0.5 * (omega * x * TAU + phase).sin()).clamp(0.0, 1.0)
        }
        Curve::Bezier { p1, p2 } => {
            // 큐빅 베지어 t-axis 직접 사용 (간이): y = 3(1-x)²x·p1.1 + 3(1-x)x²·p2.1 + x³
            let one_t = 1.0 - x;
            (3.0 * one_t * one_t * x * p1.1
                + 3.0 * one_t * x * x * p2.1
                + x * x * x)
                .clamp(0.0, 1.0)
        }
    }
}

fn blend_step(a: &MotionStep, b: &MotionStep, alpha: f32, play_time: u8) -> MotionStep {
    let mut positions = [2048u16; NUM_JOINTS_IN_STEP];
    let a_clamped = alpha.clamp(0.0, 1.0);
    for i in 0..NUM_JOINTS_IN_STEP {
        let av = a.positions[i];
        let bv = b.positions[i];
        let a_skip = av == SKIP_MARKER || (av & FLAG_MASK) != 0;
        let b_skip = bv == SKIP_MARKER || (bv & FLAG_MASK) != 0;
        positions[i] = match (a_skip, b_skip) {
            (false, false) => {
                let aval = (av & POSITION_MASK) as f32;
                let bval = (bv & POSITION_MASK) as f32;
                let blended = (1.0 - a_clamped) * aval + a_clamped * bval;
                (blended.round() as u16) & POSITION_MASK
            }
            (true, false) => bv,
            (false, true) => av,
            (true, true) => av,
        };
    }
    MotionStep {
        positions,
        pause_time: 0,
        play_time,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::motion::MotionPage;

    fn page_with_step_value(slot: usize, value: u16) -> MotionPage {
        let mut positions = [2048u16; NUM_JOINTS_IN_STEP];
        positions[slot] = value;
        let mut p = MotionPage::default();
        p.steps = vec![MotionStep {
            positions,
            pause_time: 0,
            play_time: 16,
        }];
        p
    }

    #[test]
    fn linear_at_zero_returns_a() {
        assert_eq!(evaluate_curve(&Curve::Linear, 0.0), 0.0);
    }

    #[test]
    fn linear_at_one_returns_b() {
        assert_eq!(evaluate_curve(&Curve::Linear, 1.0), 1.0);
    }

    #[test]
    fn easeinout_midpoint_is_half() {
        let a = evaluate_curve(&Curve::EaseInOut, 0.5);
        assert!((a - 0.5).abs() < 1e-5);
    }

    #[test]
    fn easeinout_starts_slow_ends_slow() {
        // d/dt smoothstep at t=0 and t=1 = 0
        let near_start = evaluate_curve(&Curve::EaseInOut, 0.1);
        let near_end = evaluate_curve(&Curve::EaseInOut, 0.9);
        // expected: ~0.028 and ~0.972 (slow at edges)
        assert!(near_start < 0.1);
        assert!(near_end > 0.9);
    }

    #[test]
    fn sine_one_cycle_returns_to_start() {
        let s0 = evaluate_curve(
            &Curve::Sine {
                omega: 1.0,
                phase: 0.0,
            },
            0.0,
        );
        let s1 = evaluate_curve(
            &Curve::Sine {
                omega: 1.0,
                phase: 0.0,
            },
            1.0,
        );
        assert!((s0 - s1).abs() < 1e-5);
    }

    #[test]
    fn procedural_synthesizes_correct_step_count() {
        let a = page_with_step_value(1, 1000);
        let b = page_with_step_value(1, 3000);
        let op = Procedural;
        let out = op
            .synthesize(
                &[&a, &b],
                &ProceduralParams {
                    curve: Curve::Linear,
                    num_steps: 5,
                    play_time: 16,
                },
            )
            .unwrap();
        assert_eq!(out[0].steps.len(), 5);
        // t=0 ≈ A, t=1 ≈ B
        assert_eq!(out[0].steps[0].positions[1], 1000);
        assert_eq!(out[0].steps[4].positions[1], 3000);
    }

    #[test]
    fn procedural_requires_two_inputs() {
        let op = Procedural;
        let p = page_with_step_value(1, 1000);
        assert!(op
            .synthesize(&[&p], &ProceduralParams::default())
            .is_err());
    }

    #[test]
    fn procedural_clamps_num_steps_to_seven() {
        let a = page_with_step_value(1, 1000);
        let b = page_with_step_value(1, 3000);
        let op = Procedural;
        let out = op
            .synthesize(
                &[&a, &b],
                &ProceduralParams {
                    num_steps: 50, // clamp to 7
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(out[0].steps.len(), 7);
    }
}
