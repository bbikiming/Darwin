//! 공식 walkReady 자세 — ROBOTIS-OP2 `op2_manager/config/ini_pose.yaml` 1:1.
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

/// 공식 walkReady 자세. 20관절 도 단위.
///
/// 각 entry는 `ini_pose.yaml` 의 `tar_pose:` 와 같은 순서·값.
pub const WALK_READY_DEGREES: [(JointId, f64); 20] = [
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

/// walkReady의 raw 위치 — `(JointId, raw u16)` 20개.
pub fn walk_ready_targets() -> [(JointId, u16); 20] {
    let mut out = [(JointId::HeadPan, 2048u16); 20];
    for (i, (j, deg)) in WALK_READY_DEGREES.iter().enumerate() {
        out[i] = (*j, degrees_to_position(*deg));
    }
    out
}

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

/// 공식 mov_time 6.0 s 기준 — 보간 step 개수 (control_cycle 8 ms 기준).
pub const WALK_READY_MOV_STEPS: usize = 750; // 6000 ms / 8 ms

/// via_time 4.0 s — via_pose(중립)에서 walkReady로 가는 후반 ratio.
pub const VIA_TIME_RATIO: f64 = 4.0 / 6.0;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn walk_ready_has_20_joints() {
        assert_eq!(WALK_READY_DEGREES.len(), 20);
        assert_eq!(walk_ready_targets().len(), 20);
    }

    #[test]
    fn walk_ready_joint_order_matches_official() {
        // ini_pose.yaml 의 1..20 순서 그대로.
        let expected_order: [JointId; 20] = JointId::ALL;
        for (i, (j, _)) in WALK_READY_DEGREES.iter().enumerate() {
            assert_eq!(*j, expected_order[i]);
        }
    }

    #[test]
    fn walk_ready_critical_angles_match_yaml() {
        let map: std::collections::HashMap<JointId, f64> =
            WALK_READY_DEGREES.iter().copied().collect();
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
        for (j, raw) in walk_ready_targets() {
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
        let to = walk_ready_targets();
        let at_zero = interpolate(&from, &to, 0.0);
        assert_eq!(at_zero, from);
        let at_one = interpolate(&from, &to, 1.0);
        assert_eq!(at_one, to);
    }

    #[test]
    fn interpolate_midpoint_is_average() {
        let from = neutral_targets();
        let to = walk_ready_targets();
        let mid = interpolate(&from, &to, 0.5);
        for i in 0..20 {
            let avg = ((from[i].1 as u32 + to[i].1 as u32) / 2) as u16;
            // 반올림으로 ±1 허용.
            let diff = (mid[i].1 as i32 - avg as i32).abs();
            assert!(diff <= 1, "mid[{}] = {} vs avg {}", i, mid[i].1, avg);
        }
    }
}
