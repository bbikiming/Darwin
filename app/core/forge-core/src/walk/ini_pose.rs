//! **OP2 manager init pose** — ROBOTIS-OP2 `op2_manager/config/ini_pose.yaml` 1:1.
//!
//! ## 중요: 이건 "공식 walkReady" 두 가지 중 하나다 (Codex audit P0-3, 2026-05-14)
//!
//! | anchor | 출처 | hip pitch | knee | ankle |
//! |---|---|---:|---:|---:|
//! | **OP2 manager init** (이 모듈) | `op2_manager/config/ini_pose.yaml:47-52` | ±65° | ±130° | ±70° |
//! | **Action page 9** ([`crate::motion::walkready`]) | `motion_4096.bin` page 9 step 0 | ±36° | ±53° | ±30° |
//! | **차이** | 두 자세는 의미가 다름 | **29°** | **77°** | **40°** |
//!
//! 이 모듈은 **OP2 manager init pose** — `op2_manager` 의 walk 시작 자세이며 6 초 동안
//! 부드럽게 진입한다 (`mov_time = 6.0`). deep squat 이 강해서 SOCCER demo / walk_tuner 의
//! 보행 시작 자세로 적합.
//!
//! **Action 기반 단발 자세 anchor 는 [`crate::motion::walkready`]** —
//! `ACTION_PAGE9_WALKREADY_RAW`. UI `RobotPose.walkReady`, Pilot teleop ARM 상태,
//! BalanceCritical 안전 검증은 모두 page 9 자세를 가리킨다.
//!
//! 모든 20관절의 목표 각도를 도(degree) 단위로 정의하고, MX-28 raw로 변환한
//! `(JointId, u16)` 시퀀스를 제공한다. 토크 ramp + 부드러운 보간으로 적용하는
//! 것은 호출자(safety::torque_ramp + control)의 책임.
//!
//! # 출처
//! `research/robotis-official/ROBOTIS-OP2/op2_manager/config/ini_pose.yaml:36-56`
//! - mov_time = 6.0 s (전체 이동 시간)
//! - via_time = 4.0 s (중간 경유 시점)
//! - via_pose = 모두 0° (중립 경유)

use crate::joint::{degrees_to_position, JointId};

/// **OP2 manager init pose** — `ini_pose.yaml` tar_pose. 20관절 도 단위.
///
/// 각 entry는 `op2_manager/config/ini_pose.yaml:36-56` 의 `tar_pose:` 와 같은 순서·값.
/// hip ±65° / knee ±130° / ankle ±70° — Action page 9 (`ACTION_PAGE9_WALKREADY_RAW`) 보다
/// **deep squat 강도가 약 2배** 라서 SOCCER demo 의 보행 시작 자세로 적합.
pub const OP2_MANAGER_INI_POSE_DEGREES: [(JointId, f64); 20] = [
    (JointId::RShoulderPitch, -48.0),
    (JointId::LShoulderPitch, 48.0),
    (JointId::RShoulderRoll, -20.0),
    (JointId::LShoulderRoll, 20.0),
    (JointId::RElbow, 30.0),
    (JointId::LElbow, -30.0),
    (JointId::RHipYaw, 0.0),
    (JointId::LHipYaw, 0.0),
    (JointId::RHipRoll, 0.0),
    (JointId::LHipRoll, 0.0),
    (JointId::RHipPitch, -65.0),
    (JointId::LHipPitch, 65.0),
    (JointId::RKnee, 130.0),
    (JointId::LKnee, -130.0),
    (JointId::RAnklePitch, 70.0),
    (JointId::LAnklePitch, -70.0),
    (JointId::RAnkleRoll, 0.0),
    (JointId::LAnkleRoll, 0.0),
    (JointId::HeadPan, 0.0),
    (JointId::HeadTilt, 10.0),
];

/// 모든 관절 중립(0°). via_pose 중간 자세 — 시작 직후 짧게 거치는 정렬 자세.
pub fn neutral_targets() -> [(JointId, u16); 20] {
    let mut out = [(JointId::HeadPan, 2048u16); 20];
    for (i, j) in JointId::ALL.iter().enumerate() {
        out[i] = (*j, 2048);
    }
    out
}

/// **OP2 manager init pose** 의 raw 위치 — `(JointId, raw u16)` 20개.
pub fn op2_manager_ini_pose_targets() -> [(JointId, u16); 20] {
    let mut out = [(JointId::HeadPan, 2048u16); 20];
    for (i, (j, deg)) in OP2_MANAGER_INI_POSE_DEGREES.iter().enumerate() {
        out[i] = (*j, degrees_to_position(*deg));
    }
    out
}

// Phase G3 (Codex audit P0-3, 2026-05-14): `walk_ready_targets` / `OP2_MANAGER_INI_POSE_DEGREES`
// 옛 이름은 외부 사용처 (forge-cli main.rs, walk/mod.rs re-export) 정리 후 완전 제거.
// 현재는 새 이름만 노출 — pub use 로 backward compat 제공.

/// 두 자세 사이를 t∈[0,1]로 선형 보간.
///
/// 한 관절씩 raw u16을 linear interp. 다중 step으로 호출해 부드러운 전이.
pub fn interpolate(
    from: &[(JointId, u16); 20],
    to: &[(JointId, u16); 20],
    t: f64,
) -> [(JointId, u16); 20] {
    let t = t.clamp(0.0, 1.0);
    let mut out = [(JointId::HeadPan, 2048u16); 20];
    for i in 0..20 {
        let (j, a) = from[i];
        let (j2, b) = to[i];
        debug_assert_eq!(j, j2, "interpolate: joint order mismatch");
        let blended = (a as f64) * (1.0 - t) + (b as f64) * t;
        out[i] = (j, blended.round().clamp(0.0, 4095.0) as u16);
    }
    out
}

/// 공식 mov_time 6.0 s 기준 — 보간 step 개수.
///
/// # 도출 (Provenance — BLOCKER M2, 2026-05-12)
///
/// ROBOTIS-OP2 `op2_manager/config/OP2.robot` 의 `control_cycle = 8 ms` 와
/// `ini_pose.yaml` 의 `mov_time = 6.0 s` 로부터:
///
/// ```text
/// WALK_READY_MOV_STEPS = mov_time × 1000 / control_cycle
///                      = 6.0 × 1000 / 8
///                      = 750
/// ```
///
/// `control_cycle` 또는 `mov_time` 변경 시 본 상수도 함께 갱신해야 한다.
pub const WALK_READY_MOV_STEPS: usize = 750;

/// via_time 4.0 s — via_pose(중립)에서 walkReady로 가는 후반 ratio.
///
/// `ini_pose.yaml` 의 `via_time = 4.0` / `mov_time = 6.0` 비율. 즉 mov_time 의
/// 처음 4 s 동안 via_pose(모든 관절 0°) 로, 나머지 2 s 동안 walkReady 로 이동.
pub const VIA_TIME_RATIO: f64 = 4.0 / 6.0;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn walk_ready_has_20_joints() {
        assert_eq!(OP2_MANAGER_INI_POSE_DEGREES.len(), 20);
        assert_eq!(op2_manager_ini_pose_targets().len(), 20);
    }

    #[test]
    fn walk_ready_joint_order_matches_official() {
        // ini_pose.yaml 의 1..20 순서 그대로.
        let expected_order: [JointId; 20] = JointId::ALL;
        for (i, (j, _)) in OP2_MANAGER_INI_POSE_DEGREES.iter().enumerate() {
            assert_eq!(*j, expected_order[i]);
        }
    }

    #[test]
    fn walk_ready_critical_angles_match_yaml() {
        let map: std::collections::HashMap<JointId, f64> =
            OP2_MANAGER_INI_POSE_DEGREES.iter().copied().collect();
        // ini_pose.yaml:47-52
        assert!((map[&JointId::RHipPitch] - -65.0).abs() < 1e-9);
        assert!((map[&JointId::LHipPitch] - 65.0).abs() < 1e-9);
        assert!((map[&JointId::RKnee] - 130.0).abs() < 1e-9);
        assert!((map[&JointId::LKnee] - -130.0).abs() < 1e-9);
        assert!((map[&JointId::RAnklePitch] - 70.0).abs() < 1e-9);
        assert!((map[&JointId::LAnklePitch] - -70.0).abs() < 1e-9);
        // ini_pose.yaml:37-42
        assert!((map[&JointId::RShoulderPitch] - -48.0).abs() < 1e-9);
        assert!((map[&JointId::LShoulderPitch] - 48.0).abs() < 1e-9);
        assert!((map[&JointId::HeadTilt] - 10.0).abs() < 1e-9);
    }

    #[test]
    fn walk_ready_raw_values_within_limits() {
        use crate::joint::JointLimits;
        for (j, raw) in op2_manager_ini_pose_targets() {
            let limits = JointLimits::for_joint(j);
            let clamped = limits.clamp_position(raw);
            assert_eq!(
                clamped, raw,
                "walkReady {:?} raw {} clamped to {}",
                j, raw, clamped
            );
        }
    }

    #[test]
    fn neutral_is_all_2048() {
        for (_, raw) in neutral_targets() {
            assert_eq!(raw, 2048);
        }
    }

    #[test]
    fn interpolate_endpoints() {
        let from = neutral_targets();
        let to = op2_manager_ini_pose_targets();
        let at_zero = interpolate(&from, &to, 0.0);
        assert_eq!(at_zero, from);
        let at_one = interpolate(&from, &to, 1.0);
        assert_eq!(at_one, to);
    }

    #[test]
    fn interpolate_midpoint_is_average() {
        let from = neutral_targets();
        let to = op2_manager_ini_pose_targets();
        let mid = interpolate(&from, &to, 0.5);
        for i in 0..20 {
            let avg = ((from[i].1 as u32 + to[i].1 as u32) / 2) as u16;
            // 반올림으로 ±1 허용.
            let diff = (mid[i].1 as i32 - avg as i32).abs();
            assert!(diff <= 1, "mid[{}] = {} vs avg {}", i, mid[i].1, avg);
        }
    }
}
