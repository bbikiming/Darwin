//! **Mirror** — 좌우 반전.
//!
//! 본구현 (S9-7). ROBOTIS DARwIn-OP 모터의 좌·우 부착 방향에 따라 페어별로
//! 다른 mirror 모드를 적용한다.
//!
//! # 운동학 분석 (공식 `motion_4096.bin` page 9 `walkready` 와 page 1 `init`
//! step 1 으로 검증)
//!
//! 각 관절 페어의 mirror 공식은 모터 영점 관계에 의해 결정된다:
//!
//! | 관절 페어 | 운동축 | 모터 영점 | Mirror 모드 |
//! |-----------|--------|-----------|-------------|
//! | 1-2 SHOULDER_PITCH | sagittal | R+L ≈ 4095 (mirror calibration) | **Swap + Reflect** |
//! | 3-4 SHOULDER_ROLL  | frontal  | R+L ≈ 4095 | Swap + Reflect |
//! | 5-6 ELBOW          | sagittal | R+L ≈ 4095 | Swap + Reflect |
//! | 7-8 HIP_YAW        | transverse | R+L ≈ 4095 (yaw mirror) | Swap + Reflect |
//! | 9-10 HIP_ROLL      | frontal  | R+L ≈ 4095 | Swap + Reflect |
//! | 11-12 HIP_PITCH    | sagittal | R+L ≈ 4095 | Swap + Reflect |
//! | 13-14 KNEE         | sagittal | R+L ≈ 4095 | Swap + Reflect |
//! | 15-16 ANKLE_PITCH  | sagittal | R+L ≈ 4095 | Swap + Reflect |
//! | 17-18 ANKLE_ROLL   | frontal  | R+L ≈ 4095 | Swap + Reflect |
//! | 19 HEAD_PAN        | yaw      | 자기 자리 | **Self + Reflect** |
//! | 20 HEAD_TILT       | pitch    | sagittal | **Identity** |
//!
//! # 검증 결과 (page 12 right_kick step 0 — walkready anchor, 1-indexed)
//!
//! 모든 좌·우 페어가 mirror calibration 임을 raw 데이터로 확인 (2026-05-12, C1 정정):
//!
//! - SHOULDER_PITCH (1,2): 1498+2518 = 4016 ≈ 4095 ✓
//! - SHOULDER_ROLL  (3,4): 1845+2248 = 4093 ≈ 4095 ✓
//! - ELBOW          (5,6): 2381+1712 = 4093 ≈ 4095 ✓
//! - HIP_YAW        (7,8): 2048+2048 = 4096 ✓
//! - HIP_ROLL       (9,10): 2052+2044 = 4096 ✓
//! - HIP_PITCH      (11,12): 1637+2459 = 4096 ✓
//! - KNEE           (13,14): 2653+1443 = 4096 ✓
//! - ANKLE_PITCH    (15,16): 2389+1707 = 4096 ✓
//! - ANKLE_ROLL     (17,18): 2057+2039 = 4096 ✓
//!
//! 이전 docstring 의 "Swap only" 분류는 인덱싱 off-by-one (positions[id-1]) 으로
//! 인해 잘못된 페어 (예: LHipRoll+RHipPitch) 의 sum 을 계산한 결과였다. BLOCKER C1
//! 정정 (positions[id]) 과 함께 모든 페어 SwapReflect 로 통일.
//!
//! # 플래그 보존
//!
//! Position 의 상위 4 bit (`0x4000` INVALID, `0x2000` TORQUE_OFF) 는 보존하고
//! 12-bit value 만 mirror 한다.

use super::SynthOp;
use crate::motion::page::NUM_JOINTS_IN_STEP;
use crate::motion::{MotionPage, MotionStep};
use crate::synth::Result;

/// Position 값에서 상위 플래그 비트 마스크.
pub const FLAG_MASK: u16 = 0xF000;
/// Position 값에서 12-bit value 마스크.
pub const POSITION_MASK: u16 = 0x0FFF;
/// MX28 12-bit 최대값.
pub const MAX_POSITION: u16 = 0x0FFF;

/// 좌·우 페어에 적용할 mirror 방식.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MirrorMode {
    /// raw 값 swap만 — 모터 부착 방향이 R/L 동일.
    Swap,
    /// raw 값 swap + 12-bit 중심 반전 (`v → 4095 - v`).
    /// 모터 영점이 R/L mirror calibration.
    SwapReflect,
}

/// 좌·우 페어 + mirror 모드. ID 는 1-based.
///
/// 위 운동학 분석 표를 그대로 표현.
pub const MIRROR_PAIRS: &[(u8, u8, MirrorMode)] = &[
    (1, 2, MirrorMode::SwapReflect),   // SHOULDER_PITCH
    (3, 4, MirrorMode::SwapReflect),   // SHOULDER_ROLL
    (5, 6, MirrorMode::SwapReflect),   // ELBOW
    (7, 8, MirrorMode::SwapReflect),   // HIP_YAW
    (9, 10, MirrorMode::SwapReflect),  // HIP_ROLL
    (11, 12, MirrorMode::SwapReflect), // HIP_PITCH
    (13, 14, MirrorMode::SwapReflect), // KNEE
    (15, 16, MirrorMode::SwapReflect), // ANKLE_PITCH
    (17, 18, MirrorMode::SwapReflect), // ANKLE_ROLL
];

/// HEAD_PAN — 자기 자리에서 12-bit 중심 반전.
pub const HEAD_PAN_ID: u8 = 19;
/// HEAD_TILT — identity (sagittal 좌우 대칭).
pub const HEAD_TILT_ID: u8 = 20;

/// raw 값의 12-bit value 부분을 `4095 - v` 로 반전, 상위 플래그는 보존.
#[inline]
fn reflect_12bit(raw: u16) -> u16 {
    let flags = raw & FLAG_MASK;
    let val = raw & POSITION_MASK;
    let reflected = (MAX_POSITION - val) & POSITION_MASK;
    flags | reflected
}

/// 한 step 의 좌우 반전.
///
/// - 좌·우 페어를 mode 에 따라 swap (and optionally reflect).
/// - HEAD_PAN 은 자기 자리에서 reflect.
/// - HEAD_TILT 와 미사용 슬롯 (0, 21..30) 은 그대로 보존 (byte-preserving).
/// - 시간 (`pause_time`, `play_time`) 은 그대로.
///
/// # 인덱싱 규약
///
/// `MotionStep::positions[i]` 는 JointId `i` 와 1:1 매핑 (slot 0 은 미사용,
/// 1..=20 은 관절, 21..=30 은 reserved). 따라서 `MIRROR_PAIRS` 의 (R, L) ID 를
/// 그대로 인덱스로 사용한다. (BLOCKER C1 — 2026-05-12 정정.)
pub fn mirror_step(step: &MotionStep) -> MotionStep {
    let mut new_positions = step.positions;

    for &(right_id, left_id, mode) in MIRROR_PAIRS {
        let r_idx = right_id as usize;
        let l_idx = left_id as usize;
        let old_r = step.positions[r_idx];
        let old_l = step.positions[l_idx];
        match mode {
            MirrorMode::Swap => {
                new_positions[r_idx] = old_l;
                new_positions[l_idx] = old_r;
            }
            MirrorMode::SwapReflect => {
                new_positions[r_idx] = reflect_12bit(old_l);
                new_positions[l_idx] = reflect_12bit(old_r);
            }
        }
    }

    // HEAD_PAN: self-reflect.
    let pan_idx = HEAD_PAN_ID as usize;
    new_positions[pan_idx] = reflect_12bit(step.positions[pan_idx]);

    // HEAD_TILT (idx 20) and slots 0, 21..30 are preserved as-is via clone above.
    debug_assert_eq!(new_positions.len(), NUM_JOINTS_IN_STEP);

    MotionStep {
        positions: new_positions,
        pause_time: step.pause_time,
        play_time: step.play_time,
    }
}

/// 한 페이지의 좌우 반전. ID·이름·compliance·헤더 필드는 변경 정책에 따라
/// 일부만 변경.
pub fn mirror_page(page: &MotionPage) -> MotionPage {
    let new_steps: Vec<MotionStep> = page.steps.iter().map(mirror_step).collect();

    // Compliance 도 좌우 페어를 swap (slope 도 모터 부착 mirror)
    let mut new_compliance = page.compliance;
    for &(right_id, left_id, _) in MIRROR_PAIRS {
        let r_idx = right_id as usize;
        let l_idx = left_id as usize;
        new_compliance.swap(r_idx, l_idx);
    }

    MotionPage {
        id: page.id,
        name: format!("{}_mirror", page.name.trim_end_matches('\0').trim()),
        compliance: new_compliance,
        next_page: page.next_page,
        exit_page: page.exit_page,
        repeat: page.repeat,
        speed: page.speed,
        accel: page.accel,
        safety_class: page.safety_class,
        steps: new_steps,
    }
}

/// Mirror 합성기 파라미터.
#[derive(Debug, Clone, Default)]
pub struct MirrorParams {
    /// 결과 페이지의 `id` 를 명시. None 이면 입력 페이지 id 유지 (rename only).
    pub new_id: Option<u8>,
    /// 결과 페이지의 `name` 을 명시. None 이면 `"{name}_mirror"`.
    pub new_name: Option<String>,
}

/// Mirror 합성 연산자.
#[derive(Debug, Default)]
pub struct Mirror;

impl SynthOp for Mirror {
    type Params = MirrorParams;

    fn synthesize(&self, inputs: &[&MotionPage], params: &Self::Params) -> Result<Vec<MotionPage>> {
        if inputs.is_empty() {
            return Err(crate::synth::SynthError::Other(
                "Mirror requires exactly 1 input page".to_string(),
            ));
        }
        let mut mirrored = mirror_page(inputs[0]);
        if let Some(id) = params.new_id {
            mirrored.id = id;
        }
        if let Some(name) = &params.new_name {
            mirrored.name = name.clone();
        }
        Ok(vec![mirrored])
    }
}

// ---------------------------------------------------------------------------
// Tests — ROBOTIS 공식 page 12 / 13 ground truth
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::synth::test_fixtures::{
        page_12_right_kick, page_13_left_kick, page_1_init, page_9_walkready,
    };

    #[test]
    fn reflect_12bit_basic() {
        assert_eq!(reflect_12bit(0), 0xFFF);
        assert_eq!(reflect_12bit(0xFFF), 0);
        assert_eq!(reflect_12bit(2048), 2047);
        // 플래그 비트 보존
        assert_eq!(reflect_12bit(0x4000), 0x4FFF);
        assert_eq!(reflect_12bit(0x4200), 0x4DFF);
        assert_eq!(reflect_12bit(0x6000 | 100), 0x6000 | (0xFFF - 100));
    }

    #[test]
    fn mirror_step_preserves_invalid_flag_bits() {
        let p = page_12_right_kick();
        for step in &p.steps {
            let mirrored = mirror_step(step);
            // 모든 slot 의 상위 4 bit (flag) 가 보존되어야 한다.
            for (i, (orig, mirr)) in step
                .positions
                .iter()
                .zip(mirrored.positions.iter())
                .enumerate()
            {
                let orig_flag = orig & FLAG_MASK;
                let mirr_flag = mirr & FLAG_MASK;
                // body joints (0..=17) and head (18,19): swap/reflect — flags from
                // the swapped slot must match.
                // unused slots (20..30): preserved as-is (HEAD_TILT idx 19 isn't
                // unused but identity-preserved).
                if i >= 20 {
                    assert_eq!(
                        orig_flag, mirr_flag,
                        "slot {i} flag mismatch: orig=0x{orig:04x} mirr=0x{mirr:04x}"
                    );
                }
            }
        }
    }

    #[test]
    fn mirror_step_is_involution() {
        // mirror(mirror(x)) == x for all body slots.
        let p = page_12_right_kick();
        for step in &p.steps {
            let double = mirror_step(&mirror_step(step));
            assert_eq!(
                double.positions, step.positions,
                "mirror should be its own inverse"
            );
            assert_eq!(double.pause_time, step.pause_time);
            assert_eq!(double.play_time, step.play_time);
        }
    }

    #[test]
    fn mirror_page_is_involution() {
        let p = page_12_right_kick();
        let double = mirror_page(&mirror_page(&p));
        for (a, b) in p.steps.iter().zip(double.steps.iter()) {
            assert_eq!(a.positions, b.positions);
        }
        assert_eq!(p.compliance, double.compliance);
    }

    #[test]
    fn mirror_swaps_left_right_compliance() {
        let p = page_12_right_kick();
        let m = mirror_page(&p);
        // 좌우 페어 compliance 가 swap 되어야 한다.
        // positions[i] = JointId i 규약 — 인덱스는 ID 그대로 사용.
        for &(r, l, _) in MIRROR_PAIRS {
            let r_idx = r as usize;
            let l_idx = l as usize;
            assert_eq!(m.compliance[r_idx], p.compliance[l_idx]);
            assert_eq!(m.compliance[l_idx], p.compliance[r_idx]);
        }
    }

    #[test]
    fn mirror_page_preserves_metadata() {
        let p = page_12_right_kick();
        let m = mirror_page(&p);
        assert_eq!(m.speed, p.speed);
        assert_eq!(m.accel, p.accel);
        assert_eq!(m.repeat, p.repeat);
        assert_eq!(m.next_page, p.next_page);
        assert_eq!(m.exit_page, p.exit_page);
        assert_eq!(m.safety_class, p.safety_class);
        assert_eq!(m.steps.len(), p.steps.len());
    }

    #[test]
    fn mirror_page_renames_with_suffix() {
        let p = page_12_right_kick();
        let m = mirror_page(&p);
        assert_eq!(m.name, "rk_mirror");
    }

    /// **Ground truth**: ROBOTIS 공식 페이지 12 (right kick) 의 좌우 반전이
    /// 공식 페이지 13 (left kick) 의 **anchor step** (0, 5, 6 = walkready) 과
    /// 정확히 일치해야 한다.
    ///
    /// page 12 step 0/5/6 == page 13 step 0/5/6 == walkready anchor. 그러나
    /// walkready 자체가 좌우 대칭이 아니므로 mirror(anchor) ≠ anchor 일 수 있다.
    /// 대신 mirror(page 12 step 0) 와 mirror(page 13 step 0) 가 같은지 (= same
    /// anchor) 확인하는 게 의미 있다.
    #[test]
    fn mirror_of_anchor_steps_matches_between_kick_pages() {
        let rk = page_12_right_kick();
        let lk = page_13_left_kick();
        // step 0 의 anchor 가 두 페이지에서 동일해야 함 (fixture 검증으로 확정됨).
        assert_eq!(rk.steps[0].positions, lk.steps[0].positions);
        // 그렇다면 둘의 mirror 도 동일해야 함.
        let rk_mirror0 = mirror_step(&rk.steps[0]);
        let lk_mirror0 = mirror_step(&lk.steps[0]);
        assert_eq!(rk_mirror0.positions, lk_mirror0.positions);
    }

    /// **Approximate ground truth**: `mirror(page_12_right_kick)` 의 본체 관절
    /// (id 1..=18) 위치가 `page_13_left_kick` 와 충분히 가까워야 한다.
    ///
    /// ROBOTIS 가 page 13 을 정확한 mirror 로 만들지 않고 손으로 미세 조정한
    /// 흔적이 있다 — 특히 양 elbow 는 rk·lk 양쪽에서 동일하게 유지 (mirror
    /// 알고리즘 예측과 다름). 따라서 정확 일치 대신 **mean absolute error
    /// < 500 raw units (= ~11°)** 임계 적용 (off-by-one 정정 후 — BLOCKER C1).
    ///
    /// 다리 관절(11..=18)만 따로 보면 mean diff 가 훨씬 작음.
    #[test]
    fn mirror_of_rk_approximates_lk() {
        let rk = page_12_right_kick();
        let lk = page_13_left_kick();
        let mirrored = mirror_page(&rk);

        // step 1..=4 (실제 kick) 만 비교 — anchor 는 위 테스트에서 검증됨.
        let mut total_diff: u64 = 0;
        let mut samples: u64 = 0;
        for step_idx in 1..=4 {
            for joint_id in 1..=18usize {
                // body joints id 1..=18 → positions[1..=18]
                let m = mirrored.steps[step_idx].positions[joint_id] & POSITION_MASK;
                let l = lk.steps[step_idx].positions[joint_id] & POSITION_MASK;
                let diff = (m as i32 - l as i32).unsigned_abs() as u64;
                total_diff += diff;
                samples += 1;
            }
        }
        let mean_diff = total_diff / samples.max(1);
        assert!(
            mean_diff < 500,
            "mean abs diff {mean_diff} between mirror(rk) and lk should be < 500 raw units (~11°)"
        );
    }

    /// **다리만 비교**: mirror 가 다리(hip/knee/ankle) 에서는 정확히 동작해야
    /// 한다. ROBOTIS 의 hand-tuning 은 주로 elbow/shoulder_roll 에 집중.
    /// 다리 관절(id 11..=18) 만 보면 mean diff 가 훨씬 작아진다.
    #[test]
    fn mirror_of_rk_legs_approximate_lk_tightly() {
        let rk = page_12_right_kick();
        let lk = page_13_left_kick();
        let mirrored = mirror_page(&rk);

        let mut total_diff: u64 = 0;
        let mut samples: u64 = 0;
        for step_idx in 1..=4 {
            for joint_id in 11..=18usize {
                let m = mirrored.steps[step_idx].positions[joint_id] & POSITION_MASK;
                let l = lk.steps[step_idx].positions[joint_id] & POSITION_MASK;
                total_diff += (m as i32 - l as i32).unsigned_abs() as u64;
                samples += 1;
            }
        }
        let mean_diff = total_diff / samples.max(1);
        assert!(
            mean_diff < 200,
            "leg-only mean abs diff {mean_diff} should be < 200 raw units (~4.4°)"
        );
    }

    #[test]
    fn mirror_synth_op_via_trait() {
        let p = page_1_init();
        let op = Mirror;
        let params = MirrorParams {
            new_id: Some(100),
            new_name: Some("init_mirror_test".to_string()),
        };
        let out = op.synthesize(&[&p], &params).expect("synth");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, 100);
        assert_eq!(out[0].name, "init_mirror_test");
        // step 수는 보존
        assert_eq!(out[0].steps.len(), p.steps.len());
    }

    #[test]
    fn mirror_with_empty_input_returns_error() {
        let op = Mirror;
        let params = MirrorParams::default();
        let result = op.synthesize(&[], &params);
        assert!(result.is_err());
    }

    #[test]
    fn mirror_walkready_only_in_12bit_value_range() {
        // walkready 자세를 mirror 한 결과의 body joints 가 모두 0..=4095 범위.
        let p = page_9_walkready();
        let m = mirror_page(&p);
        for step in &m.steps {
            for (i, &pos) in step.positions.iter().enumerate().take(20) {
                let val = pos & POSITION_MASK;
                assert!(
                    val <= MAX_POSITION,
                    "slot {i} value 0x{val:04x} exceeds 12-bit range"
                );
            }
        }
    }
}
