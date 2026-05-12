//! **Mutate** — 단일 페이지 변형.
//!
//! 본구현 (S9-6). PRD §5.2 FR-OP-4 참조.
//!
//! # 지원 변형
//!
//! - [`Mutation::JointOffset`] — 특정 관절에 ±delta (12-bit value 부분만, 플래그 보존)
//! - [`Mutation::TimeScale`] — 모든 step `play_time` 을 k 배 (u8 clamp)
//! - [`Mutation::SpeedScale`] — PAGEHEADER `speed` 를 k 배 (u8 clamp)
//! - [`Mutation::AmplitudeScale`] — 특정 관절 그룹 진폭을 중심(2048) 기준 k 배
//! - [`Mutation::Repeat`] — PAGEHEADER `repeat` 변경
//!
//! 모든 변형은 **byte-preserving** — 상위 플래그 (`0x4000`/`0x2000`) 보존.
//! 결정론적 — 같은 입력 + 같은 mutation list = 같은 출력.

use super::mirror::{FLAG_MASK, MAX_POSITION, POSITION_MASK};
use super::SynthOp;
use crate::motion::MotionPage;
use crate::synth::{Result, SynthError};

/// 12-bit position 의 운동학적 중심점 (MX28 기준).
pub const JOINT_CENTER: u16 = 2048;

/// 적용 가능한 변형 종류.
#[derive(Debug, Clone)]
pub enum Mutation {
    /// 특정 관절(ID 1-based) 의 모든 step 에 delta 적용. 12-bit value 만 변경,
    /// `INVALID`/`TORQUE_OFF` 플래그 슬롯은 건너뛴다 (의미 없음).
    JointOffset {
        /// 1-based joint ID (1..=20).
        joint_id: u8,
        /// raw 단위 delta (음수 가능).
        delta: i16,
    },
    /// 모든 step 의 `play_time` 을 k 배. raw 단위 (= ms × 8) 에서 적용.
    /// u8 범위로 clamp.
    TimeScale {
        /// 배율 (예: 2.0 = 두 배 느리게, 0.5 = 두 배 빠르게).
        factor: f32,
    },
    /// PAGEHEADER.speed 를 k 배. u8 범위로 clamp.
    SpeedScale {
        /// 배율.
        factor: f32,
    },
    /// 특정 관절 ID 그룹의 진폭을 중심점(2048) 기준 k 배 스케일.
    /// (raw - 2048) * k + 2048, 12-bit clamp.
    AmplitudeScale {
        /// 1-based joint ID 목록.
        joint_ids: Vec<u8>,
        /// 배율.
        factor: f32,
    },
    /// PAGEHEADER.repeat 를 변경.
    Repeat {
        /// 새 repeat 값 (1..=255).
        value: u8,
    },
}

/// Mutate 합성기 파라미터.
#[derive(Debug, Clone, Default)]
pub struct MutateParams {
    /// 순서대로 적용할 변형 목록.
    pub mutations: Vec<Mutation>,
    /// 결과 페이지 ID 명시 (None 이면 원본 유지).
    pub new_id: Option<u8>,
    /// 결과 페이지 이름 명시 (None 이면 원본 + `_mutated`).
    pub new_name: Option<String>,
}

/// 12-bit value 에 delta 적용 후 clamp. 플래그 보존.
#[inline]
fn apply_delta_12bit(raw: u16, delta: i16) -> u16 {
    let flags = raw & FLAG_MASK;
    let val = (raw & POSITION_MASK) as i32;
    let new_val = (val + delta as i32).clamp(0, MAX_POSITION as i32) as u16;
    flags | (new_val & POSITION_MASK)
}

/// 12-bit value 에 진폭 스케일 적용 (중심 2048 기준).
#[inline]
fn apply_amplitude_scale(raw: u16, factor: f32) -> u16 {
    let flags = raw & FLAG_MASK;
    let val = (raw & POSITION_MASK) as i32;
    let centered = val - JOINT_CENTER as i32;
    let scaled = (centered as f32 * factor).round() as i32;
    let new_val = (scaled + JOINT_CENTER as i32).clamp(0, MAX_POSITION as i32) as u16;
    flags | (new_val & POSITION_MASK)
}

/// u8 값에 배율 적용 후 clamp (`1..=255`).
#[inline]
fn scale_u8(value: u8, factor: f32) -> u8 {
    let scaled = (value as f32 * factor).round() as i32;
    scaled.clamp(1, 255) as u8
}

/// 한 mutation 을 페이지에 적용.
pub fn apply_mutation(page: &mut MotionPage, mutation: &Mutation) -> Result<()> {
    match mutation {
        Mutation::JointOffset { joint_id, delta } => {
            if *joint_id == 0 || *joint_id > 20 {
                return Err(SynthError::Other(format!(
                    "JointOffset: invalid joint id {joint_id} (must be 1..=20)"
                )));
            }
            // positions[i] = JointId i (slot 0 미사용) — BLOCKER C1/C2 와 동일 규약.
            let idx = *joint_id as usize;
            for step in page.steps.iter_mut() {
                step.positions[idx] = apply_delta_12bit(step.positions[idx], *delta);
            }
        }
        Mutation::TimeScale { factor } => {
            if !factor.is_finite() || *factor <= 0.0 {
                return Err(SynthError::Other(format!(
                    "TimeScale: factor must be positive finite, got {factor}"
                )));
            }
            for step in page.steps.iter_mut() {
                step.play_time = scale_u8(step.play_time, *factor);
            }
        }
        Mutation::SpeedScale { factor } => {
            if !factor.is_finite() || *factor <= 0.0 {
                return Err(SynthError::Other(format!(
                    "SpeedScale: factor must be positive finite, got {factor}"
                )));
            }
            page.speed = scale_u8(page.speed, *factor);
        }
        Mutation::AmplitudeScale { joint_ids, factor } => {
            if !factor.is_finite() || *factor < 0.0 {
                return Err(SynthError::Other(format!(
                    "AmplitudeScale: factor must be non-negative finite, got {factor}"
                )));
            }
            for jid in joint_ids {
                if *jid == 0 || *jid > 20 {
                    return Err(SynthError::Other(format!(
                        "AmplitudeScale: invalid joint id {jid}"
                    )));
                }
                let idx = (*jid - 1) as usize;
                for step in page.steps.iter_mut() {
                    step.positions[idx] = apply_amplitude_scale(step.positions[idx], *factor);
                }
            }
        }
        Mutation::Repeat { value } => {
            if *value == 0 {
                return Err(SynthError::Other(
                    "Repeat: value 0 disables playback; minimum 1".to_string(),
                ));
            }
            page.repeat = *value;
        }
    }
    Ok(())
}

/// Mutate 합성 연산자.
#[derive(Debug, Default)]
pub struct Mutate;

impl SynthOp for Mutate {
    type Params = MutateParams;

    fn synthesize(&self, inputs: &[&MotionPage], params: &Self::Params) -> Result<Vec<MotionPage>> {
        if inputs.is_empty() {
            return Err(SynthError::Other(
                "Mutate requires exactly 1 input page".to_string(),
            ));
        }
        let mut out = inputs[0].clone();
        for m in &params.mutations {
            apply_mutation(&mut out, m)?;
        }
        if let Some(id) = params.new_id {
            out.id = id;
        }
        if let Some(name) = &params.new_name {
            out.name = name.clone();
        } else {
            let trimmed = out.name.trim_end_matches('\0').trim().to_string();
            out.name = format!("{trimmed}_mutated");
        }
        Ok(vec![out])
    }
}

// ---------------------------------------------------------------------------
// Tests — 공식 페이지 fixture 기반
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::synth::test_fixtures::{
        page_12_right_kick, page_1_init, page_2_ok, page_9_walkready,
    };

    // ---- apply_delta_12bit / apply_amplitude_scale ----

    #[test]
    fn apply_delta_12bit_preserves_flags() {
        assert_eq!(apply_delta_12bit(0x4200, 10), 0x4200 | 10);
        assert_eq!(apply_delta_12bit(0x4FFF, 1), 0x4FFF); // clamp at top
        assert_eq!(apply_delta_12bit(0x4000, -1), 0x4000); // clamp at bottom
        assert_eq!(apply_delta_12bit(0x0800, -100), 0x0800 - 100);
    }

    #[test]
    fn apply_amplitude_scale_zero_collapses_to_center() {
        // factor=0 → 모든 값이 2048 (중심).
        assert_eq!(apply_amplitude_scale(0x0100, 0.0) & POSITION_MASK, 2048);
        assert_eq!(apply_amplitude_scale(0x0E00, 0.0) & POSITION_MASK, 2048);
        // 플래그 보존
        assert_eq!(apply_amplitude_scale(0x4500, 0.0) & FLAG_MASK, 0x4000);
    }

    #[test]
    fn apply_amplitude_scale_double_doubles_distance() {
        // 2048 + 100 → factor=2 → 2048 + 200
        assert_eq!(apply_amplitude_scale(2148, 2.0) & POSITION_MASK, 2248);
        // 2048 - 100 → factor=2 → 2048 - 200
        assert_eq!(apply_amplitude_scale(1948, 2.0) & POSITION_MASK, 1848);
    }

    #[test]
    fn apply_amplitude_scale_clamps_at_12bit_extremes() {
        // 큰 진폭 + 큰 factor → clamp.
        assert_eq!(apply_amplitude_scale(4000, 10.0) & POSITION_MASK, 4095);
        assert_eq!(apply_amplitude_scale(100, 10.0) & POSITION_MASK, 0);
    }

    #[test]
    fn scale_u8_basic() {
        assert_eq!(scale_u8(32, 2.0), 64);
        assert_eq!(scale_u8(32, 0.5), 16);
        assert_eq!(scale_u8(32, 10.0), 255); // clamp top
        assert_eq!(scale_u8(0, 1.0), 1); // clamp bottom (0이면 disable)
    }

    // ---- JointOffset ----

    #[test]
    fn joint_offset_shifts_only_target_joint() {
        let mut p = page_1_init();
        let before = p.steps[1].positions;
        apply_mutation(
            &mut p,
            &Mutation::JointOffset {
                joint_id: 20, // HEAD_TILT
                delta: 100,
            },
        )
        .expect("apply");
        // HEAD_TILT (positions[20]) 의 12-bit value 가 +100 되어야 한다.
        let before_val = before[20] & POSITION_MASK;
        let after_val = p.steps[1].positions[20] & POSITION_MASK;
        assert_eq!(
            after_val,
            (before_val + 100).min(MAX_POSITION),
            "HEAD_TILT shifted by 100"
        );
        // 다른 슬롯은 그대로
        for (i, (after, &orig)) in p.steps[1].positions.iter().zip(before.iter()).enumerate() {
            if i != 20 {
                assert_eq!(*after, orig, "slot {i} should be unchanged");
            }
        }
    }

    #[test]
    fn joint_offset_invalid_id_errors() {
        let mut p = page_1_init();
        let r = apply_mutation(
            &mut p,
            &Mutation::JointOffset {
                joint_id: 0,
                delta: 0,
            },
        );
        assert!(r.is_err());
        let r = apply_mutation(
            &mut p,
            &Mutation::JointOffset {
                joint_id: 21,
                delta: 0,
            },
        );
        assert!(r.is_err());
    }

    // ---- TimeScale ----

    #[test]
    fn time_scale_doubles_play_time() {
        let mut p = page_2_ok(); // play_time = 50, 50, 50, 50, 125
        apply_mutation(&mut p, &Mutation::TimeScale { factor: 2.0 }).expect("apply");
        assert_eq!(p.steps[0].play_time, 100);
        assert_eq!(p.steps[4].play_time, 250);
    }

    #[test]
    fn time_scale_clamps_to_u8_max() {
        let mut p = page_2_ok();
        apply_mutation(&mut p, &Mutation::TimeScale { factor: 100.0 }).expect("apply");
        for s in &p.steps {
            assert_eq!(s.play_time, 255);
        }
    }

    #[test]
    fn time_scale_invalid_factor_errors() {
        let mut p = page_1_init();
        assert!(apply_mutation(&mut p, &Mutation::TimeScale { factor: 0.0 }).is_err());
        assert!(apply_mutation(&mut p, &Mutation::TimeScale { factor: -1.0 }).is_err());
        assert!(apply_mutation(&mut p, &Mutation::TimeScale { factor: f32::NAN }).is_err());
    }

    // ---- SpeedScale ----

    #[test]
    fn speed_scale_modifies_page_header() {
        let mut p = page_1_init(); // speed = 32
        apply_mutation(&mut p, &Mutation::SpeedScale { factor: 0.5 }).expect("apply");
        assert_eq!(p.speed, 16);
    }

    // ---- AmplitudeScale ----

    #[test]
    fn amplitude_scale_50pct_halves_joint_motion() {
        // page 12 right kick 의 R_KNEE (id 13, idx 12) — 큰 변화 있는 관절.
        let mut p = page_12_right_kick();
        let before_step3 = p.steps[3].positions[12] & POSITION_MASK; // step 3 = kick impact
        apply_mutation(
            &mut p,
            &Mutation::AmplitudeScale {
                joint_ids: vec![13],
                factor: 0.5,
            },
        )
        .expect("apply");
        let after_step3 = p.steps[3].positions[12] & POSITION_MASK;

        // 중심점(2048)에서의 거리가 절반이 되어야 한다.
        let before_dist = (before_step3 as i32 - 2048).abs();
        let after_dist = (after_step3 as i32 - 2048).abs();
        assert!(
            (after_dist as f32 - before_dist as f32 * 0.5).abs() < 2.0,
            "before_dist={before_dist} after_dist={after_dist} should ratio ≈ 0.5"
        );
    }

    // ---- Repeat ----

    #[test]
    fn repeat_zero_errors() {
        let mut p = page_1_init();
        assert!(apply_mutation(&mut p, &Mutation::Repeat { value: 0 }).is_err());
    }

    #[test]
    fn repeat_changes_header() {
        let mut p = page_1_init();
        apply_mutation(&mut p, &Mutation::Repeat { value: 5 }).expect("apply");
        assert_eq!(p.repeat, 5);
    }

    // ---- SynthOp integration ----

    #[test]
    fn mutate_chains_multiple_mutations_in_order() {
        let p = page_9_walkready();
        let op = Mutate;
        let params = MutateParams {
            mutations: vec![
                Mutation::TimeScale { factor: 2.0 },
                Mutation::SpeedScale { factor: 0.5 },
                Mutation::Repeat { value: 3 },
            ],
            new_id: Some(101),
            new_name: Some("walkready_slow_x3".to_string()),
        };
        let out = op.synthesize(&[&p], &params).expect("synth");
        let r = &out[0];
        assert_eq!(r.id, 101);
        assert_eq!(r.name, "walkready_slow_x3");
        assert_eq!(r.steps[0].play_time, 250); // 125 × 2
        assert_eq!(r.speed, 16); // 32 × 0.5
        assert_eq!(r.repeat, 3);
    }

    #[test]
    fn mutate_with_default_name_appends_suffix() {
        let p = page_1_init();
        let op = Mutate;
        let params = MutateParams {
            mutations: vec![Mutation::SpeedScale { factor: 1.5 }],
            new_id: None,
            new_name: None,
        };
        let out = op.synthesize(&[&p], &params).expect("synth");
        assert_eq!(out[0].name, "init_mutated");
        assert_eq!(out[0].id, p.id); // ID 보존
    }

    #[test]
    fn mutate_preserves_invalid_flag_bits() {
        // page 12 step 0 의 idx 21..=25 (unused) 는 0x4000 (INVALID), idx 0 의
        // R_SHOULDER_PITCH 도 0x4000 — mutation 후에도 상위 4 bit 보존되어야 함.
        let p = page_12_right_kick();
        let op = Mutate;
        let params = MutateParams {
            // 유효 joint id (1..=20) 만 사용. AmplitudeScale 은 12-bit value 만 건드림.
            mutations: vec![Mutation::AmplitudeScale {
                joint_ids: (1u8..=20).collect(),
                factor: 0.5,
            }],
            ..Default::default()
        };
        let out = op.synthesize(&[&p], &params).expect("synth");
        // unused 슬롯 (idx 21..=30) 의 flag bit 가 그대로여야 함.
        for i in 21..31 {
            let before = p.steps[0].positions[i] & FLAG_MASK;
            let after = out[0].steps[0].positions[i] & FLAG_MASK;
            assert_eq!(before, after, "slot {i} flag bits must be preserved");
        }
        // body joint (id 1, idx 0) 의 flag bit 도 보존.
        let before_id1 = p.steps[0].positions[0] & FLAG_MASK;
        let after_id1 = out[0].steps[0].positions[0] & FLAG_MASK;
        assert_eq!(before_id1, after_id1, "id 1 flag bits must be preserved");
    }

    #[test]
    fn mutate_with_empty_input_errors() {
        let op = Mutate;
        let params = MutateParams::default();
        assert!(op.synthesize(&[], &params).is_err());
    }

    #[test]
    fn mutate_is_deterministic_for_same_params() {
        let p = page_2_ok();
        let op = Mutate;
        let params = MutateParams {
            mutations: vec![
                Mutation::TimeScale { factor: 1.5 },
                Mutation::AmplitudeScale {
                    joint_ids: vec![1, 2],
                    factor: 0.8,
                },
            ],
            ..Default::default()
        };
        let out1 = op.synthesize(&[&p], &params).expect("first");
        let out2 = op.synthesize(&[&p], &params).expect("second");
        assert_eq!(out1[0].steps, out2[0].steps, "determinism required");
        assert_eq!(out1[0].speed, out2[0].speed);
        assert_eq!(out1[0].repeat, out2[0].repeat);
    }

    /// 공식 페이지의 모든 step 의 모든 슬롯이 mutation 후에도 12-bit value
    /// 범위 (0..=4095) 안에 있어야 한다.
    #[test]
    fn mutate_does_not_corrupt_position_bits() {
        let p = page_12_right_kick();
        let op = Mutate;
        let params = MutateParams {
            mutations: vec![
                Mutation::AmplitudeScale {
                    joint_ids: (1u8..=20).collect(),
                    factor: 1.2,
                },
                Mutation::TimeScale { factor: 0.75 },
            ],
            ..Default::default()
        };
        let out = op.synthesize(&[&p], &params).expect("synth");
        for step in &out[0].steps {
            for &pos in &step.positions {
                let val = pos & POSITION_MASK;
                assert!(val <= MAX_POSITION);
            }
        }
    }

    // ---- 공식 데이터 sanity ----

    #[test]
    fn time_scale_two_makes_motion_half_speed() {
        // page 2 'ok' 의 총 재생 시간이 정확히 두 배가 되어야 한다.
        let p = page_2_ok();
        let before_total_play: u32 = p.steps.iter().map(|s| s.play_ms() as u32).sum();

        let op = Mutate;
        let params = MutateParams {
            mutations: vec![Mutation::TimeScale { factor: 2.0 }],
            ..Default::default()
        };
        let out = op.synthesize(&[&p], &params).expect("synth");
        let after_total_play: u32 = out[0].steps.iter().map(|s| s.play_ms() as u32).sum();

        assert_eq!(after_total_play, before_total_play * 2);
    }
}
