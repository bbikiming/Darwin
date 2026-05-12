//! **Layer** — 부위별 동시 합성기.
//!
//! 본구현 (S9-4). PRD §5.2 FR-OP-2, §8.2.
//!
//! 상체 / 하체 / 머리 부위를 서로 다른 페이지에서 가져와 같은 시간축에 병합.
//! 슬롯별로 어느 부위에 속하는지를 보고 그 페이지의 값을 채택. step 수가 다른 경우
//! 짧은 페이지의 마지막 step 을 hold (PRD §8.2 algorithm).
//!
//! API 는 `SynthOp::synthesize(&[upper, lower, head])` 형태 (3개 입력) 또는
//! 명시적 `LayerInputs` 의 `layer_pages()` 헬퍼로 호출.

use super::mirror::{FLAG_MASK, POSITION_MASK};
use super::SynthOp;
use crate::motion::page::NUM_JOINTS_IN_STEP;
use crate::motion::{MotionPage, MotionStep};
use crate::synth::error::SynthError;
use crate::synth::Result;

const SKIP_MARKER: u16 = 32767;

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
///
/// `synthesize` 의 `inputs` 는 `[upper, lower, head]` 순. None 자리는 default
/// (해당 부위는 2048 중립 유지).
///
/// 더 표현력 있는 API 가 필요하면 [`layer_pages`] 직접 호출.
#[derive(Debug, Default)]
pub struct Layer;

impl SynthOp for Layer {
    type Params = LayerParams;

    fn synthesize(&self, inputs: &[&MotionPage], params: &Self::Params) -> Result<Vec<MotionPage>> {
        if inputs.len() != 3 {
            return Err(SynthError::Other(format!(
                "Layer expects exactly 3 input pages [upper, lower, head]; got {}",
                inputs.len()
            )));
        }
        let layered = LayerInputs {
            upper: Some(inputs[0]),
            lower: Some(inputs[1]),
            head: Some(inputs[2]),
        };
        layer_pages(&layered, params).map(|p| vec![p])
    }
}

/// 명시적 부위별 페이지 입력으로 layer 합성.
pub fn layer_pages(inputs: &LayerInputs<'_>, params: &LayerParams) -> Result<MotionPage> {
    let pages = [inputs.upper, inputs.lower, inputs.head];
    let any = pages.iter().flatten().next().ok_or_else(|| {
        SynthError::Other("Layer: at least one of upper/lower/head must be Some".into())
    })?;
    let mut base = (*any).clone();
    if !base.name.is_empty() {
        base.name = format!("{}_layered", base.name);
    }

    let n_steps = params.num_steps.min(7) as usize;
    let n_steps = n_steps.max(1);

    let mut steps: Vec<MotionStep> = Vec::with_capacity(n_steps);
    for i in 0..n_steps {
        let upper_step = inputs.upper.and_then(|p| step_or_last(p, i));
        let lower_step = inputs.lower.and_then(|p| step_or_last(p, i));
        let head_step = inputs.head.and_then(|p| step_or_last(p, i));

        let mut positions = [2048u16; NUM_JOINTS_IN_STEP];
        let mut play_time = 16u8;
        let mut pause_time = 0u8;

        for slot in 0..NUM_JOINTS_IN_STEP {
            let region = region_for_slot(slot);
            positions[slot] = pick_region_value(
                region,
                upper_step,
                lower_step,
                head_step,
                params.priority,
                slot,
            );
        }

        // play/pause time: priority 에 따라 picks
        if let Some(s) = match params.priority {
            LayerPriority::Upper => upper_step.or(lower_step).or(head_step),
            LayerPriority::Lower => lower_step.or(upper_step).or(head_step),
            LayerPriority::Head => head_step.or(upper_step).or(lower_step),
        } {
            play_time = s.play_time;
            pause_time = s.pause_time;
        }

        steps.push(MotionStep {
            positions,
            pause_time,
            play_time,
        });
    }

    base.steps = steps;
    Ok(base)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Region {
    Upper,
    Lower,
    Head,
    Other,
}

fn region_for_slot(slot: usize) -> Region {
    match slot {
        1..=6 => Region::Upper,
        7..=18 => Region::Lower,
        19..=20 => Region::Head,
        _ => Region::Other,
    }
}

fn step_or_last(page: &MotionPage, i: usize) -> Option<&MotionStep> {
    if page.steps.is_empty() {
        None
    } else {
        page.steps.get(i).or_else(|| page.steps.last())
    }
}

fn pick_region_value(
    region: Region,
    upper: Option<&MotionStep>,
    lower: Option<&MotionStep>,
    head: Option<&MotionStep>,
    priority: LayerPriority,
    slot: usize,
) -> u16 {
    let from_step = |s: Option<&MotionStep>| {
        s.and_then(|st| {
            let v = st.positions.get(slot).copied()?;
            if v == SKIP_MARKER || (v & FLAG_MASK) != 0 {
                None
            } else {
                Some(v & POSITION_MASK)
            }
        })
    };
    // primary by region
    let primary = match region {
        Region::Upper => upper,
        Region::Lower => lower,
        Region::Head => head,
        Region::Other => match priority {
            LayerPriority::Upper => upper,
            LayerPriority::Lower => lower,
            LayerPriority::Head => head,
        },
    };
    if let Some(v) = from_step(primary) {
        return v;
    }
    // fallback in priority order
    let order: [Option<&MotionStep>; 3] = match priority {
        LayerPriority::Upper => [upper, lower, head],
        LayerPriority::Lower => [lower, upper, head],
        LayerPriority::Head => [head, upper, lower],
    };
    for cand in order.iter().flatten() {
        if let Some(v) = from_step(Some(cand)) {
            return v;
        }
    }
    2048
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::joint::JointId;

    fn step(positions: [u16; NUM_JOINTS_IN_STEP]) -> MotionStep {
        MotionStep {
            positions,
            pause_time: 0,
            play_time: 16,
        }
    }

    fn page_for_region(slot: usize, value: u16) -> MotionPage {
        let mut positions = [2048u16; NUM_JOINTS_IN_STEP];
        positions[slot] = value;
        let mut p = MotionPage::default();
        p.steps = vec![step(positions); 3];
        p
    }

    #[test]
    fn layer_takes_upper_for_arm_slot() {
        let upper = page_for_region(JointId::RShoulderPitch as usize, 1500);
        let lower = page_for_region(JointId::RKnee as usize, 3500);
        let head = page_for_region(JointId::HeadPan as usize, 3000);
        let inputs = LayerInputs {
            upper: Some(&upper),
            lower: Some(&lower),
            head: Some(&head),
        };
        let out = layer_pages(&inputs, &LayerParams::default()).unwrap();
        assert_eq!(
            out.steps[0].positions[JointId::RShoulderPitch as usize],
            1500
        );
        assert_eq!(out.steps[0].positions[JointId::RKnee as usize], 3500);
        assert_eq!(out.steps[0].positions[JointId::HeadPan as usize], 3000);
    }

    #[test]
    fn layer_falls_back_when_region_input_missing() {
        let lower = page_for_region(JointId::RKnee as usize, 3500);
        let inputs = LayerInputs {
            upper: None,
            lower: Some(&lower),
            head: None,
        };
        let out = layer_pages(&inputs, &LayerParams::default()).unwrap();
        // upper slot 은 fallback 으로 2048 또는 lower 의 값 → 여기선 lower 가 upper 슬롯에서 2048
        assert_eq!(
            out.steps[0].positions[JointId::RShoulderPitch as usize],
            2048
        );
        assert_eq!(out.steps[0].positions[JointId::RKnee as usize], 3500);
    }

    #[test]
    fn layer_synth_op_requires_three_inputs() {
        let op = Layer;
        let p = page_for_region(0, 0);
        assert!(op.synthesize(&[&p], &LayerParams::default()).is_err());
    }

    #[test]
    fn layer_extends_to_num_steps_with_hold() {
        let upper = page_for_region(JointId::RShoulderPitch as usize, 1500);
        let lower = page_for_region(JointId::RKnee as usize, 3500);
        let head = page_for_region(JointId::HeadPan as usize, 3000);
        let inputs = LayerInputs {
            upper: Some(&upper),
            lower: Some(&lower),
            head: Some(&head),
        };
        let out = layer_pages(
            &inputs,
            &LayerParams {
                num_steps: 5,
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(out.steps.len(), 5);
        // 5번째 step 도 동일 hold
        assert_eq!(
            out.steps[4].positions[JointId::RShoulderPitch as usize],
            1500
        );
    }
}
