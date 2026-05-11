//! **Sequence** — 시간축 연결 합성기.
//!
//! 본구현 (S9-3). PRD §5.2 FR-OP-1, §8.1 알고리즘 참조.
//!
//! # 알고리즘
//!
//! 1. 입력 페이지 배열 `[A, B, C, ...]` 의 모든 step 을 순서대로 평탄화.
//! 2. 페이지 경계마다 **bridge step** 1개를 삽입 (선형 중간점 + transition_time).
//!    `transition_ms = 0` 이면 생략.
//! 3. 결과 step 수가 `MAX_STEPS_PER_PAGE = 7` 을 초과하면 페이지 분할 +
//!    각 페이지의 `next_page` 로 chain.
//!
//! # 플래그 보존
//!
//! 두 step 의 동일 슬롯 모두 `INVALID` 또는 `TORQUE_OFF` 면 bridge 도 동일 플래그
//! 유지 (보간하지 않음). 한쪽만 플래그면 valid 한 쪽 값을 그대로 사용 (보간
//! 생략) — 데이터의 의미를 보존.
//!
//! # 페이지 분할 규칙 (ROBOTIS PAGEHEADER 호환)
//!
//! ROBOTIS 의 `MAXNUM_STEP = 7` 을 그대로 유지. 따라서 8 step 이상의 시퀀스는
//! 자동으로 `[7-step 페이지 A] -- next=B --> [n-step 페이지 B]` chain 으로 변환.
//! 각 페이지의 ID 는 `MutateParams.base_id` + offset 으로 할당.

use super::SynthOp;
use super::mirror::{FLAG_MASK, POSITION_MASK};
use crate::motion::page::NUM_JOINTS_IN_STEP;
use crate::motion::{MotionPage, MotionStep};
use crate::synth::{Result, SynthError};

/// ROBOTIS 페이지당 최대 step 수 (`MAXNUM_STEP`).
pub const MAX_STEPS_PER_PAGE: usize = 7;

/// 기본 transition 시간 (ms) — bridge step 의 play_ms.
pub const DEFAULT_TRANSITION_MS: u16 = 800;

/// Sequence 합성기 파라미터.
#[derive(Debug, Clone)]
pub struct SequenceParams {
    /// 페이지 사이 bridge step 의 play 시간 (ms). `0` 이면 bridge 생략.
    pub transition_ms: u16,
    /// 결과 페이지의 첫 ID. chain 시 `base_id`, `base_id+1`, ... 순.
    pub base_id: u8,
    /// 결과 첫 페이지의 이름. None 이면 입력 페이지 이름을 `+` 로 연결.
    pub new_name: Option<String>,
}

impl Default for SequenceParams {
    fn default() -> Self {
        Self {
            transition_ms: DEFAULT_TRANSITION_MS,
            base_id: 100,
            new_name: None,
        }
    }
}

/// 두 raw position 의 선형 중간점. 플래그 비트는 정책에 따라 처리.
///
/// - 둘 다 동일 플래그(예: `0x4000`) 면 그 플래그 유지, value 도 동일하게.
/// - 한 쪽이 `INVALID` (`0x4000`) 이면 valid 한 쪽의 raw 값을 그대로 (보간 생략).
/// - 둘 다 normal 이면 12-bit value 중간점 + flag 보존 (둘 다 flag 0).
fn blend_position(a: u16, b: u16) -> u16 {
    const INVALID_BIT: u16 = 0x4000;
    let a_flags = a & FLAG_MASK;
    let b_flags = b & FLAG_MASK;
    let a_invalid = a_flags & INVALID_BIT != 0;
    let b_invalid = b_flags & INVALID_BIT != 0;

    match (a_invalid, b_invalid) {
        (true, true) => a, // 둘 다 INVALID → 그대로
        (true, false) => b, // a 만 INVALID → b 사용 (보간 생략)
        (false, true) => a, // b 만 INVALID → a 사용
        (false, false) => {
            // 두 valid 값의 12-bit 평균. flag 는 두 값의 일관성 검사 후 보존.
            let av = (a & POSITION_MASK) as u32;
            let bv = (b & POSITION_MASK) as u32;
            let mid = ((av + bv) / 2) as u16;
            // 둘 다 같은 비-INVALID 플래그면 그것을 유지 (보통 둘 다 0x0000).
            let common_flag = a_flags & b_flags;
            common_flag | (mid & POSITION_MASK)
        }
    }
}

/// 두 step 사이의 bridge step 을 만든다. 시간은 `transition_ms` (raw = ms/8).
fn make_bridge(prev: &MotionStep, next: &MotionStep, transition_ms: u16) -> MotionStep {
    let mut positions = [0u16; NUM_JOINTS_IN_STEP];
    for (i, slot) in positions.iter_mut().enumerate() {
        *slot = blend_position(prev.positions[i], next.positions[i]);
    }
    let play_raw = ms_to_raw_time(transition_ms);
    MotionStep {
        positions,
        pause_time: 0,
        play_time: play_raw,
    }
}

/// ms → raw `play_time` (= ms / 8). 범위 1..=255 로 clamp.
fn ms_to_raw_time(ms: u16) -> u8 {
    let raw = ms / 8;
    raw.clamp(1, 255) as u8
}

/// 평탄화 — 입력 페이지들의 모든 step 을 한 줄로 + 페이지 경계에 bridge 삽입.
fn flatten_steps(inputs: &[&MotionPage], transition_ms: u16) -> Result<Vec<MotionStep>> {
    if inputs.is_empty() {
        return Err(SynthError::Other(
            "Sequence requires at least 1 input page".to_string(),
        ));
    }
    let mut out: Vec<MotionStep> = Vec::new();
    for (page_idx, page) in inputs.iter().enumerate() {
        if page.steps.is_empty() {
            return Err(SynthError::Other(format!(
                "Sequence: input page {} ('{}') has no steps",
                page.id, page.name
            )));
        }
        if page_idx > 0 && transition_ms > 0 {
            // 이전 페이지 마지막 step 과 현재 페이지 첫 step 사이에 bridge.
            let prev_last = out.last().expect("non-empty");
            let next_first = &page.steps[0];
            let bridge = make_bridge(prev_last, next_first, transition_ms);
            out.push(bridge);
        }
        for step in &page.steps {
            out.push(step.clone());
        }
    }
    Ok(out)
}

/// step 시퀀스를 페이지 단위로 분할. 각 페이지 최대 7 step, `next_page` 로 chain.
///
/// 결과의 첫 페이지 id 는 `base_id`, 다음은 `base_id + 1`, ...
fn split_into_pages(
    steps: Vec<MotionStep>,
    base_id: u8,
    name: String,
    template: &MotionPage,
) -> Result<Vec<MotionPage>> {
    if steps.is_empty() {
        return Err(SynthError::Other(
            "split_into_pages: no steps to package".to_string(),
        ));
    }
    let total_steps = steps.len();
    let total_pages = total_steps.div_ceil(MAX_STEPS_PER_PAGE);
    let last_id = (base_id as usize).checked_add(total_pages - 1).ok_or_else(|| {
        SynthError::Other(format!(
            "Sequence: chain of {total_pages} pages exceeds u8 page ID range"
        ))
    })?;
    if last_id > 255 {
        return Err(SynthError::Other(format!(
            "Sequence: chain extends to id {last_id} > 255"
        )));
    }

    let mut pages = Vec::with_capacity(total_pages);
    let mut cursor = 0usize;
    let mut page_index = 0usize;
    while cursor < total_steps {
        let chunk_end = (cursor + MAX_STEPS_PER_PAGE).min(total_steps);
        let chunk: Vec<MotionStep> = steps[cursor..chunk_end].to_vec();
        let current_id = base_id + page_index as u8;
        let next_id = if chunk_end < total_steps {
            base_id + page_index as u8 + 1
        } else {
            0
        };
        let page_name = if page_index == 0 {
            name.clone()
        } else {
            format!("{name}_p{page_index}")
        };
        let page = MotionPage {
            id: current_id,
            name: page_name,
            compliance: template.compliance,
            next_page: next_id,
            exit_page: template.exit_page,
            repeat: 1,
            speed: template.speed,
            accel: template.accel,
            safety_class: template.safety_class,
            steps: chunk,
        };
        pages.push(page);
        cursor = chunk_end;
        page_index += 1;
    }
    Ok(pages)
}

/// Sequence 합성 연산자.
#[derive(Debug, Default)]
pub struct Sequence;

impl SynthOp for Sequence {
    type Params = SequenceParams;

    fn synthesize(
        &self,
        inputs: &[&MotionPage],
        params: &Self::Params,
    ) -> Result<Vec<MotionPage>> {
        let steps = flatten_steps(inputs, params.transition_ms)?;
        let name = params.new_name.clone().unwrap_or_else(|| {
            inputs
                .iter()
                .map(|p| p.name.trim_end_matches('\0').trim().to_string())
                .collect::<Vec<_>>()
                .join("+")
        });
        // 첫 입력 페이지를 메타데이터 template 으로 사용.
        split_into_pages(steps, params.base_id, name, inputs[0])
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::synth::test_fixtures::{
        page_12_right_kick, page_13_left_kick, page_16_stand_up, page_1_init, page_2_ok,
        page_9_walkready,
    };

    // ---- blend_position / make_bridge ----

    #[test]
    fn blend_two_valid_positions_returns_midpoint() {
        assert_eq!(blend_position(100, 200), 150);
        assert_eq!(blend_position(0x0500, 0x0900), 0x0700);
    }

    #[test]
    fn blend_invalid_with_valid_keeps_valid_value() {
        // INVALID + valid → valid 그대로
        assert_eq!(blend_position(0x4000, 0x0800), 0x0800);
        assert_eq!(blend_position(0x0800, 0x4000), 0x0800);
    }

    #[test]
    fn blend_both_invalid_returns_first() {
        assert_eq!(blend_position(0x4200, 0x4200), 0x4200);
        assert_eq!(blend_position(0x4000, 0x4500), 0x4000);
    }

    #[test]
    fn make_bridge_uses_transition_time() {
        let a = MotionStep {
            positions: [100; NUM_JOINTS_IN_STEP],
            pause_time: 0,
            play_time: 32,
        };
        let b = MotionStep {
            positions: [200; NUM_JOINTS_IN_STEP],
            pause_time: 0,
            play_time: 32,
        };
        let bridge = make_bridge(&a, &b, 800);
        assert_eq!(bridge.play_time, 100); // 800 / 8 = 100
        for v in bridge.positions {
            assert_eq!(v, 150);
        }
    }

    // ---- ms_to_raw_time ----

    #[test]
    fn ms_to_raw_time_basic() {
        assert_eq!(ms_to_raw_time(800), 100);
        assert_eq!(ms_to_raw_time(8), 1);
        assert_eq!(ms_to_raw_time(0), 1); // clamp to 1
        assert_eq!(ms_to_raw_time(10000), 255); // clamp to 255
    }

    // ---- flatten_steps ----

    #[test]
    fn flatten_single_page_without_transition_returns_steps() {
        let p = page_1_init();
        let steps = flatten_steps(&[&p], 0).expect("flatten");
        assert_eq!(steps.len(), p.steps.len());
        for (a, b) in steps.iter().zip(p.steps.iter()) {
            assert_eq!(a.positions, b.positions);
        }
    }

    #[test]
    fn flatten_two_pages_with_transition_inserts_one_bridge() {
        let a = page_1_init(); // 2 step
        let b = page_2_ok();   // 5 step
        let steps = flatten_steps(&[&a, &b], 800).expect("flatten");
        // 2 + 1 bridge + 5 = 8 step
        assert_eq!(steps.len(), 8);
        // Bridge 는 idx 2 (0-based).
        let bridge = &steps[2];
        assert_eq!(bridge.play_time, 100); // 800 / 8
    }

    #[test]
    fn flatten_two_pages_with_zero_transition_omits_bridge() {
        let a = page_1_init(); // 2 step
        let b = page_2_ok();   // 5 step
        let steps = flatten_steps(&[&a, &b], 0).expect("flatten");
        assert_eq!(steps.len(), 7); // bridge 없음
    }

    #[test]
    fn flatten_three_pages_inserts_two_bridges() {
        let a = page_1_init();        // 2
        let b = page_9_walkready();    // 1
        let c = page_16_stand_up();    // 1
        let steps = flatten_steps(&[&a, &b, &c], 800).expect("flatten");
        // 2 + 1 + 1 + 1 + 1 = 6
        assert_eq!(steps.len(), 6);
    }

    #[test]
    fn flatten_empty_inputs_errors() {
        let r = flatten_steps(&[], 800);
        assert!(r.is_err());
    }

    // ---- split_into_pages ----

    #[test]
    fn split_seven_steps_fits_in_one_page() {
        let steps: Vec<MotionStep> = (0..7)
            .map(|_| MotionStep {
                positions: [2048; NUM_JOINTS_IN_STEP],
                pause_time: 0,
                play_time: 16,
            })
            .collect();
        let pages = split_into_pages(steps, 100, "test".to_string(), &page_1_init()).expect("split");
        assert_eq!(pages.len(), 1);
        assert_eq!(pages[0].id, 100);
        assert_eq!(pages[0].next_page, 0);
        assert_eq!(pages[0].steps.len(), 7);
    }

    #[test]
    fn split_eight_steps_creates_two_pages_chained() {
        let steps: Vec<MotionStep> = (0..8)
            .map(|_| MotionStep {
                positions: [2048; NUM_JOINTS_IN_STEP],
                pause_time: 0,
                play_time: 16,
            })
            .collect();
        let pages = split_into_pages(steps, 100, "long".to_string(), &page_1_init()).expect("split");
        assert_eq!(pages.len(), 2);
        assert_eq!(pages[0].id, 100);
        assert_eq!(pages[0].next_page, 101);
        assert_eq!(pages[0].steps.len(), 7);
        assert_eq!(pages[1].id, 101);
        assert_eq!(pages[1].next_page, 0);
        assert_eq!(pages[1].steps.len(), 1);
        assert_eq!(pages[1].name, "long_p1");
    }

    #[test]
    fn split_into_pages_overflow_errors() {
        let steps: Vec<MotionStep> = (0..14)
            .map(|_| MotionStep {
                positions: [2048; NUM_JOINTS_IN_STEP],
                pause_time: 0,
                play_time: 16,
            })
            .collect();
        // base_id=255 + 2 pages → 256 overflow.
        let r = split_into_pages(steps, 255, "ovf".to_string(), &page_1_init());
        assert!(r.is_err());
    }

    // ---- SynthOp integration ----

    #[test]
    fn sequence_single_page_returns_one_page() {
        let p = page_2_ok();
        let op = Sequence;
        let params = SequenceParams {
            base_id: 100,
            ..Default::default()
        };
        let out = op.synthesize(&[&p], &params).expect("synth");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, 100);
        // 단일 페이지면 bridge 가 추가될 자리가 없음 — step 수는 원본과 동일.
        assert_eq!(out[0].steps.len(), p.steps.len());
    }

    #[test]
    fn sequence_two_pages_with_bridge_chains_pages_when_overflow() {
        let a = page_2_ok();         // 5 step
        let b = page_12_right_kick(); // 7 step
        // 5 + 1 bridge + 7 = 13 step → 2 페이지 (7 + 6)
        let op = Sequence;
        let params = SequenceParams {
            transition_ms: 800,
            base_id: 200,
            new_name: Some("ok_then_rk".to_string()),
        };
        let out = op.synthesize(&[&a, &b], &params).expect("synth");
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].id, 200);
        assert_eq!(out[0].next_page, 201);
        assert_eq!(out[0].steps.len(), 7);
        assert_eq!(out[1].id, 201);
        assert_eq!(out[1].next_page, 0);
        assert_eq!(out[1].steps.len(), 6);
        assert_eq!(out[0].name, "ok_then_rk");
        assert_eq!(out[1].name, "ok_then_rk_p1");
    }

    #[test]
    fn sequence_default_name_concatenates_inputs_with_plus() {
        let a = page_1_init();
        let b = page_16_stand_up();
        let op = Sequence;
        let params = SequenceParams {
            base_id: 100,
            transition_ms: 0,
            new_name: None,
        };
        let out = op.synthesize(&[&a, &b], &params).expect("synth");
        assert_eq!(out[0].name, "init+stand up");
    }

    #[test]
    fn sequence_preserves_template_metadata_from_first_page() {
        let a = page_12_right_kick(); // safety = HighRisk
        let b = page_16_stand_up();
        let op = Sequence;
        let params = SequenceParams {
            base_id: 100,
            ..Default::default()
        };
        let out = op.synthesize(&[&a, &b], &params).expect("synth");
        for page in &out {
            assert_eq!(page.safety_class, a.safety_class, "HighRisk inherited from first input");
            assert_eq!(page.speed, a.speed);
            assert_eq!(page.accel, a.accel);
        }
    }

    #[test]
    fn sequence_is_deterministic() {
        let a = page_1_init();
        let b = page_9_walkready();
        let c = page_16_stand_up();
        let op = Sequence;
        let params = SequenceParams {
            base_id: 100,
            transition_ms: 400,
            new_name: Some("triple".to_string()),
        };
        let out1 = op.synthesize(&[&a, &b, &c], &params).expect("first");
        let out2 = op.synthesize(&[&a, &b, &c], &params).expect("second");
        assert_eq!(out1.len(), out2.len());
        for (p1, p2) in out1.iter().zip(out2.iter()) {
            assert_eq!(p1.steps, p2.steps);
            assert_eq!(p1.id, p2.id);
            assert_eq!(p1.name, p2.name);
        }
    }

    #[test]
    fn sequence_empty_input_errors() {
        let op = Sequence;
        let params = SequenceParams::default();
        let r = op.synthesize(&[], &params);
        assert!(r.is_err());
    }

    #[test]
    fn sequence_with_invalid_input_returns_decode_error() {
        let mut bad = page_1_init();
        bad.steps.clear();
        let op = Sequence;
        let params = SequenceParams::default();
        let r = op.synthesize(&[&bad], &params);
        assert!(r.is_err());
    }

    // ---- 공식 데이터 sanity ----

    /// 보행 시연 시나리오: `walkready → right kick → walkready` 시퀀스를 합성.
    /// 결과의 첫 step 과 마지막 step 이 모두 walkready anchor 와 일치해야 한다.
    #[test]
    fn sequence_walkready_kick_walkready_anchors_match() {
        let wr1 = page_9_walkready();
        let rk = page_12_right_kick();
        let wr2 = page_9_walkready();

        let op = Sequence;
        let params = SequenceParams {
            base_id: 100,
            transition_ms: 0, // bridge 없이 정확한 step preservation
            new_name: Some("kick_routine".to_string()),
        };
        let out = op.synthesize(&[&wr1, &rk, &wr2], &params).expect("synth");

        // 평탄화: 1 + 7 + 1 = 9 step → 2 페이지 (7 + 2)
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].steps[0].positions, wr1.steps[0].positions);
        let last_page = out.last().unwrap();
        assert_eq!(
            last_page.steps[last_page.steps.len() - 1].positions,
            wr2.steps[0].positions
        );
    }

    /// 좌우 대칭 시퀀스: right kick → left kick. 두 페이지 모두 안전 분류는
    /// HighRisk 라 결과도 HighRisk.
    #[test]
    fn sequence_rk_lk_preserves_highrisk_safety() {
        let rk = page_12_right_kick();
        let lk = page_13_left_kick();
        let op = Sequence;
        let params = SequenceParams {
            base_id: 100,
            transition_ms: 200,
            new_name: Some("rk_lk".to_string()),
        };
        let out = op.synthesize(&[&rk, &lk], &params).expect("synth");
        // 7 + 1 + 7 = 15 step → 3 페이지 (7+7+1)
        assert_eq!(out.len(), 3);
        for page in &out {
            assert_eq!(page.safety_class, crate::motion::SafetyClass::HighRisk);
        }
        assert_eq!(out[0].next_page, 101);
        assert_eq!(out[1].next_page, 102);
        assert_eq!(out[2].next_page, 0);
    }
}
