//! **Morph** — 두 페이지 사이 포즈 보간/모핑.
//!
//! 본구현 (S9-5). PRD §5.2 FR-OP-3, §8.3.
//!
//! 두 페이지 A·B 의 각 step 관절을 ratio α 가중합으로 섞는다.
//! - `Constant(α)` — 모든 step 에 동일 α.
//! - `Progressive` — step i 에 대해 t = i / (n-1), α 보간 (smoothstep 적용).
//!
//! 플래그 (0x4000/0x2000) 가 한쪽이라도 있으면 그쪽 값을 채택 (덮어쓰지 않음).
//! 32767 (SKIP) 도 동일.

use super::mirror::{FLAG_MASK, POSITION_MASK};
use super::SynthOp;
use crate::motion::page::NUM_JOINTS_IN_STEP;
use crate::motion::{MotionPage, MotionStep};
use crate::synth::error::SynthError;
use crate::synth::Result;

const SKIP_MARKER: u16 = 32767;

/// Morph ratio — 상수 또는 시간 함수.
#[derive(Debug, Clone)]
pub enum MorphRatio {
    /// 모든 step 에 동일 α 적용.
    Constant(f32),
    /// step 인덱스 i (0..n-1) 에 대해 t = i/(n-1), 결과 smoothstep(t) 반환.
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
        inputs: &[&MotionPage],
        params: &Self::Params,
    ) -> Result<Vec<MotionPage>> {
        if inputs.len() != 2 {
            return Err(SynthError::Other(format!(
                "Morph expects 2 input pages, got {}",
                inputs.len()
            )));
        }
        let a = inputs[0];
        let b = inputs[1];
        let n = a.steps.len().min(b.steps.len());
        if n == 0 {
            return Err(SynthError::Other(
                "Morph: both inputs must have at least 1 step".into(),
            ));
        }

        let mut steps = Vec::with_capacity(n);
        for i in 0..n {
            let t = if n > 1 { i as f32 / (n - 1) as f32 } else { 0.5 };
            let alpha = match &params.ratio {
                MorphRatio::Constant(a) => a.clamp(0.0, 1.0),
                MorphRatio::Progressive => smoothstep(t),
            };
            steps.push(morph_step(&a.steps[i], &b.steps[i], alpha));
        }

        let mut out = a.clone();
        if !out.name.is_empty() {
            out.name = format!("{}_morph", out.name);
        }
        out.steps = steps;
        Ok(vec![out])
    }
}

/// 단일 step 보간. 같은 슬롯에 양쪽 값이 모두 정상이면 weighted blend, 한쪽
/// 플래그/SKIP 이면 다른 쪽 값 채택.
pub fn morph_step(a: &MotionStep, b: &MotionStep, alpha: f32) -> MotionStep {
    let a_clamped = alpha.clamp(0.0, 1.0);
    let mut positions = [2048u16; NUM_JOINTS_IN_STEP];
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
    let pause_time = lerp_u8(a.pause_time, b.pause_time, a_clamped);
    let play_time = lerp_u8(a.play_time, b.play_time, a_clamped);
    MotionStep {
        positions,
        pause_time,
        play_time,
    }
}

fn lerp_u8(a: u8, b: u8, t: f32) -> u8 {
    let v = (1.0 - t) * a as f32 + t * b as f32;
    v.round().clamp(0.0, 255.0) as u8
}

/// Smoothstep curve — 0..1 부드러운 S-curve.
fn smoothstep(t: f32) -> f32 {
    let x = t.clamp(0.0, 1.0);
    x * x * (3.0 - 2.0 * x)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::motion::page::NUM_JOINTS_IN_STEP;
    use crate::motion::MotionPage;

    fn step(positions: [u16; NUM_JOINTS_IN_STEP], play_time: u8) -> MotionStep {
        MotionStep {
            positions,
            pause_time: 0,
            play_time,
        }
    }

    fn page_with_steps(steps: Vec<MotionStep>) -> MotionPage {
        let mut p = MotionPage::default();
        p.steps = steps;
        p
    }

    #[test]
    fn morph_with_alpha_zero_returns_a() {
        let mut a_pos = [2048u16; NUM_JOINTS_IN_STEP];
        let mut b_pos = [2048u16; NUM_JOINTS_IN_STEP];
        a_pos[1] = 1000;
        b_pos[1] = 3000;
        let merged = morph_step(&step(a_pos, 16), &step(b_pos, 16), 0.0);
        assert_eq!(merged.positions[1], 1000);
    }

    #[test]
    fn morph_with_alpha_one_returns_b() {
        let mut a_pos = [2048u16; NUM_JOINTS_IN_STEP];
        let mut b_pos = [2048u16; NUM_JOINTS_IN_STEP];
        a_pos[1] = 1000;
        b_pos[1] = 3000;
        let merged = morph_step(&step(a_pos, 16), &step(b_pos, 16), 1.0);
        assert_eq!(merged.positions[1], 3000);
    }

    #[test]
    fn morph_with_alpha_half_is_midpoint() {
        let mut a_pos = [2048u16; NUM_JOINTS_IN_STEP];
        let mut b_pos = [2048u16; NUM_JOINTS_IN_STEP];
        a_pos[1] = 1000;
        b_pos[1] = 3000;
        let merged = morph_step(&step(a_pos, 16), &step(b_pos, 16), 0.5);
        assert!((merged.positions[1] as i32 - 2000).abs() <= 1);
    }

    #[test]
    fn morph_preserves_skip_from_a_when_b_skip() {
        let mut a_pos = [SKIP_MARKER; NUM_JOINTS_IN_STEP];
        let b_pos = [SKIP_MARKER; NUM_JOINTS_IN_STEP];
        a_pos[1] = SKIP_MARKER;
        let merged = morph_step(&step(a_pos, 16), &step(b_pos, 16), 0.5);
        assert_eq!(merged.positions[1], SKIP_MARKER);
    }

    #[test]
    fn morph_uses_other_value_when_one_side_is_skip() {
        let mut a_pos = [2048u16; NUM_JOINTS_IN_STEP];
        let mut b_pos = [2048u16; NUM_JOINTS_IN_STEP];
        a_pos[1] = SKIP_MARKER;
        b_pos[1] = 1500;
        let merged = morph_step(&step(a_pos, 16), &step(b_pos, 16), 0.5);
        assert_eq!(merged.positions[1], 1500);
    }

    #[test]
    fn morph_op_requires_two_inputs() {
        let op = Morph;
        let p = page_with_steps(vec![step([2048; NUM_JOINTS_IN_STEP], 16)]);
        assert!(op.synthesize(&[&p], &MorphParams::default()).is_err());
        assert!(op
            .synthesize(&[&p, &p, &p], &MorphParams::default())
            .is_err());
    }

    #[test]
    fn morph_progressive_starts_at_a_ends_at_b() {
        let mut a_pos = [2048u16; NUM_JOINTS_IN_STEP];
        let mut b_pos = [2048u16; NUM_JOINTS_IN_STEP];
        a_pos[1] = 1000;
        b_pos[1] = 3000;
        let a = page_with_steps(vec![
            step(a_pos, 16),
            step(a_pos, 16),
            step(a_pos, 16),
        ]);
        let b = page_with_steps(vec![
            step(b_pos, 16),
            step(b_pos, 16),
            step(b_pos, 16),
        ]);
        let op = Morph;
        let out = op
            .synthesize(
                &[&a, &b],
                &MorphParams {
                    ratio: MorphRatio::Progressive,
                },
            )
            .unwrap();
        assert_eq!(out.len(), 1);
        let result = &out[0];
        assert_eq!(result.steps.len(), 3);
        // 첫 step (t=0) ≈ A
        assert_eq!(result.steps[0].positions[1], 1000);
        // 마지막 step (t=1) ≈ B
        assert_eq!(result.steps[2].positions[1], 3000);
    }
}
