//! **ROBOTIS 공식 walkready 자세** — `motion_4096.bin` page 9 step 0 의 raw 값.
//!
//! 모든 합성 / 재생 / 검증의 anchor 표준. 양 발 위에 CoM 정확 정렬된 deep squat
//! 자세 (hip ±36° / knee ±53° / ankle ±30°). R+L mirror sum ≈ 4096.
//!
//! # 안전 근거
//!
//! - **무릎 굽힘 = 충격 흡수**: knee 0° (T-pose 직립) 은 막대처럼 불안정.
//! - **hip-ankle 균형**: hip 앞으로 굽힘 + ankle 뒤로 보정 = CoM 발 위 정확 유지.
//! - **R+L mirror**: 모든 페어 sum ≈ 4096 → 좌우 비대칭 0, lean 없음.
//!
//! # 변경 이력
//!
//! 1. 초기 — hip±8 / knee±16 / ankle∓7 (ROBOTIS `JointData::Initialize()`) →
//!    무릎 굽힘 부족 + ankle 비대칭으로 뒤쪽 lean → **뒤로 넘어짐**.
//! 2. Hotfix — T-pose 하체 0° → 직립 막대, 충격 흡수 0 → **여전히 뒤로 넘어짐**.
//! 3. **현재** — ROBOTIS 공식 page 9 raw 값 그대로 채택. Mirror sum 검증 ✓.

use crate::motion::{MotionStep, NUM_JOINTS_IN_STEP};

/// `motion_4096.bin` page 9 step 0 의 raw position 31 슬롯.
///
/// 인덱스 매핑: `WALKREADY_RAW[i]` = joint ID `i` 의 raw position.
/// `[0]` 은 reserved (ROBOTIS 표준).
///
/// MX-28 12-bit raw: `2048` = 0°. `4096 raw = 360°` → 1° ≈ 11.4 raw.
///
/// | ID | Joint           | raw  | degree |
/// |---:|-----------------|-----:|-------:|
/// |  1 | R_SHOULDER_PITCH| 1498 | -48.3° |
/// |  2 | L_SHOULDER_PITCH| 2518 | +41.3° |
/// |  3 | R_SHOULDER_ROLL | 1845 | -17.8° |
/// |  4 | L_SHOULDER_ROLL | 2248 | +17.6° |
/// |  5 | R_ELBOW         | 2381 | +29.3° |
/// |  6 | L_ELBOW         | 1712 | -29.5° |
/// |  7 | R_HIP_YAW       | 2048 |   0.0° |
/// |  8 | L_HIP_YAW       | 2048 |   0.0° |
/// |  9 | R_HIP_ROLL      | 2052 |  +0.4° |
/// | 10 | L_HIP_ROLL      | 2044 |  -0.4° |
/// | 11 | R_HIP_PITCH     | 1637 | -36.1° |
/// | 12 | L_HIP_PITCH     | 2459 | +36.1° |
/// | 13 | R_KNEE          | 2653 | +53.2° |
/// | 14 | L_KNEE          | 1443 | -53.2° |
/// | 15 | R_ANKLE_PITCH   | 2389 | +30.0° |
/// | 16 | L_ANKLE_PITCH   | 1707 | -30.0° |
/// | 17 | R_ANKLE_ROLL    | 2057 |  +0.8° |
/// | 18 | L_ANKLE_ROLL    | 2039 |  -0.8° |
/// | 19 | HEAD_PAN        | 2048 |   0.0° |
/// | 20 | HEAD_TILT       | 2161 |  +9.9° |
pub const WALKREADY_RAW: [u16; NUM_JOINTS_IN_STEP] = {
    let mut v = [2048u16; NUM_JOINTS_IN_STEP];
    v[1] = 1498;  v[2] = 2518;   // SHOULDER_PITCH
    v[3] = 1845;  v[4] = 2248;   // SHOULDER_ROLL
    v[5] = 2381;  v[6] = 1712;   // ELBOW
    v[7] = 2048;  v[8] = 2048;   // HIP_YAW
    v[9] = 2052;  v[10] = 2044;  // HIP_ROLL
    v[11] = 1637; v[12] = 2459;  // HIP_PITCH (deep squat 시작)
    v[13] = 2653; v[14] = 1443;  // KNEE (deep squat)
    v[15] = 2389; v[16] = 1707;  // ANKLE_PITCH (CoM 보정)
    v[17] = 2057; v[18] = 2039;  // ANKLE_ROLL
    v[19] = 2048; v[20] = 2161;  // HEAD_PAN / TILT
    v
};

/// walkready 자세의 `MotionStep` (1000 ms hold).
pub fn walkready_step() -> MotionStep {
    MotionStep {
        positions: WALKREADY_RAW,
        pause_time: 0,
        play_time: 125, // 1000 ms / 8 = 125 raw
    }
}

/// 어떤 step 의 본체 관절(ID 1..=18) 자세가 walkready 와 얼마나 가까운지 RMS 측정.
///
/// 반환값은 raw 단위. 1° ≈ 11.4 raw.
/// - RMS < 200 (~17°) → 매우 가까움 (anchor 적합)
/// - RMS < 500 (~44°) → 합리적
/// - RMS > 500 → 큰 차이 (walkready 와 다른 자세)
pub fn rms_distance_from_walkready(step: &MotionStep) -> f64 {
    const FLAG_MASK: u16 = 0xF000;
    const POSITION_MASK: u16 = 0x0FFF;
    let mut sum_sq = 0i64;
    let mut count = 0i64;
    for i in 1..=18 {
        let raw = step.positions[i];
        if (raw & FLAG_MASK) != 0 {
            continue; // INVALID 또는 TORQUE_OFF — anchor 비교 X
        }
        let val = (raw & POSITION_MASK) as i32;
        let wr = (WALKREADY_RAW[i] & POSITION_MASK) as i32;
        let d = val - wr;
        sum_sq += (d * d) as i64;
        count += 1;
    }
    if count == 0 {
        return 0.0;
    }
    ((sum_sq as f64) / (count as f64)).sqrt()
}

/// 해당 step 이 anchor 적합한 자세인가? (RMS 기준)
pub fn is_walkready_anchor(step: &MotionStep, tolerance_raw: f64) -> bool {
    rms_distance_from_walkready(step) <= tolerance_raw
}

#[cfg(test)]
mod tests {
    use super::*;

    /// R+L mirror 페어 (ROBOTIS 모터 영점 거울 관계).
    const LR_PAIRS: &[(usize, usize)] = &[
        (1, 2),   // SHOULDER_PITCH
        (3, 4),   // SHOULDER_ROLL
        (5, 6),   // ELBOW
        (7, 8),   // HIP_YAW
        (9, 10),  // HIP_ROLL
        (11, 12), // HIP_PITCH
        (13, 14), // KNEE
        (15, 16), // ANKLE_PITCH
        (17, 18), // ANKLE_ROLL
    ];

    #[test]
    fn all_walkready_lr_pairs_mirror_within_100_raw() {
        // R+L sum 이 4095 ± 100 (≈ 8.8°) 이내여야 함.
        // ROBOTIS 공식 데이터의 mirror 정밀도 검증.
        for &(r, l) in LR_PAIRS {
            let sum = WALKREADY_RAW[r] as i32 + WALKREADY_RAW[l] as i32;
            let delta = (sum - 4096).abs();
            assert!(
                delta <= 100,
                "ID {r}+{l} sum {sum}, delta {delta} > 100 — mirror 깨짐"
            );
        }
    }

    #[test]
    fn walkready_has_deep_squat_geometry() {
        // 무릎 굽힘이 충분한지 (knee R+L < 4096 ± 100, knee 자체 값 검증).
        // R_KNEE = 2653 (+53°) 이 양수, L_KNEE = 1443 (-53°) 음수.
        assert!(WALKREADY_RAW[13] > 2200, "R_KNEE raw {} 너무 작음", WALKREADY_RAW[13]);
        assert!(WALKREADY_RAW[14] < 1800, "L_KNEE raw {} 너무 큼", WALKREADY_RAW[14]);
        // hip-ankle 균형 (hip 앞으로 + ankle 보정).
        assert!(WALKREADY_RAW[11] < 1900, "R_HIP_PITCH 부족 squat (raw {})", WALKREADY_RAW[11]);
        assert!(WALKREADY_RAW[15] > 2200, "R_ANKLE_PITCH 보정 부족 (raw {})", WALKREADY_RAW[15]);
    }

    #[test]
    fn unused_slots_default_to_center() {
        // slot 0, 21..30 은 unused — 2048 (중심) default.
        assert_eq!(WALKREADY_RAW[0], 2048);
        for i in 21..NUM_JOINTS_IN_STEP {
            assert_eq!(WALKREADY_RAW[i], 2048, "slot {i} not 2048");
        }
    }

    #[test]
    fn walkready_step_is_self_anchor() {
        let s = walkready_step();
        assert_eq!(rms_distance_from_walkready(&s), 0.0);
        assert!(is_walkready_anchor(&s, 100.0));
    }

    #[test]
    fn far_pose_fails_anchor_check() {
        // 모든 본체 관절이 2048 (T-pose 직립) → walkready 와 큰 차이.
        let s = MotionStep {
            positions: [2048u16; NUM_JOINTS_IN_STEP],
            pause_time: 0,
            play_time: 16,
        };
        let rms = rms_distance_from_walkready(&s);
        // hip pitch (1637 vs 2048) + knee (2653 vs 2048) + ankle (2389 vs 2048) 차이.
        assert!(rms > 300.0, "T-pose 와 walkready 차이가 너무 작음: {rms}");
        // 기본 100 raw (≈ 9°) 임계는 통과 X.
        assert!(!is_walkready_anchor(&s, 100.0));
    }

    #[test]
    fn invalid_flag_slots_excluded_from_distance() {
        // INVALID 플래그가 켜진 슬롯은 비교 제외.
        let mut s = walkready_step();
        s.positions[11] = 0x4000; // R_HIP_PITCH INVALID
        s.positions[12] = 0x4000; // L_HIP_PITCH INVALID
        // 나머지 slot 은 walkready 그대로 → RMS 0.
        assert_eq!(rms_distance_from_walkready(&s), 0.0);
    }
}
