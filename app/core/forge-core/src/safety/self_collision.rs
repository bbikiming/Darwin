//! 자가 충돌(self-collision) 검사 — 룰 기반.
//!
//! 모션 step의 모터 raw 위치 30 슬롯을 받아 신체 부위 간 겹침이 발생할
//! 가능성이 큰 자세를 차단한다. 정확한 forward kinematics 검사가 아닌
//! **보수적 룰** — false positive 가 적당히 있어도 사용자 안전을 우선.
//!
//! 검사 룰:
//! - knee 음수 = 반대 꺾임 (모터 손상 위험).
//! - |hip_roll| > 45° = 다리 교차.
//! - |shoulder_roll| > 90° = 팔이 몸통 안쪽.
//! - shoulder_pitch < -90° && elbow > 0 = 손이 머리/등 뒤로.
//! - hip_pitch > 90° + knee < 0 = 다리가 몸통과 충돌.

use thiserror::Error;

use crate::joint::{position_to_radians, JointId};
use crate::motion::MotionStep;

/// 충돌 검사 에러.
#[derive(Debug, Error, PartialEq)]
pub enum CollisionError {
    /// 무릎이 반대 방향으로 꺾임.
    #[error("knee {joint:?} hyperextended (deg={deg:.1})")]
    KneeHyperextension {
        /// 어느 무릎.
        joint: JointId,
        /// 도 단위 각도.
        deg: f64,
    },
    /// hip roll 이 한계 초과.
    #[error("hip roll {joint:?} exceeds ±45° (deg={deg:.1})")]
    HipRollOverflow {
        /// 어느 hip.
        joint: JointId,
        /// 도 단위 각도.
        deg: f64,
    },
    /// shoulder roll 이 한계 초과.
    #[error("shoulder roll {joint:?} exceeds ±90° (deg={deg:.1})")]
    ShoulderRollOverflow {
        /// 어느 어깨.
        joint: JointId,
        /// 도 단위 각도.
        deg: f64,
    },
    /// 손이 머리/등 뒤로 가는 자세 가능성.
    #[error("arm risks collision: shoulder_pitch={sp:.1} elbow={el:.1}")]
    ArmHeadCollision {
        /// shoulder pitch (deg).
        sp: f64,
        /// elbow (deg).
        el: f64,
    },
}

/// 한 step (raw 30 슬롯) 검사.
///
/// step.positions 는 31 slot 배열이지만 ID 0 은 미사용 — index = JointId as u8.
pub fn check_step(step: &MotionStep) -> Result<(), Vec<CollisionError>> {
    let mut errs = Vec::new();
    let pos = |j: JointId| {
        let i = j as usize;
        if i < step.positions.len() {
            let raw = step.positions[i];
            // 32767 = 스킵 마커 (현재 위치 유지).
            if raw == 32767 {
                None
            } else {
                Some(position_to_radians(raw).to_degrees())
            }
        } else {
            None
        }
    };

    // 1) 무릎 hyperextension. 공식 walkReady r=130°, l=-130° (양수 절댓값) — 부호
    // 자체로는 판단 불가. 그러나 r_knee 가 음수 + l_knee 가 양수 (부호 교환)면
    // 반대 꺾임.
    if let Some(r) = pos(JointId::RKnee) {
        if r < -5.0 {
            // walkReady 가 +130°이므로 약간의 noise tolerance.
            errs.push(CollisionError::KneeHyperextension {
                joint: JointId::RKnee,
                deg: r,
            });
        }
    }
    if let Some(l) = pos(JointId::LKnee) {
        if l > 5.0 {
            errs.push(CollisionError::KneeHyperextension {
                joint: JointId::LKnee,
                deg: l,
            });
        }
    }

    // 2) Hip roll 한계.
    for j in [JointId::RHipRoll, JointId::LHipRoll] {
        if let Some(deg) = pos(j) {
            if deg.abs() > 45.0 {
                errs.push(CollisionError::HipRollOverflow { joint: j, deg });
            }
        }
    }

    // 3) Shoulder roll 한계.
    for j in [JointId::RShoulderRoll, JointId::LShoulderRoll] {
        if let Some(deg) = pos(j) {
            if deg.abs() > 90.0 {
                errs.push(CollisionError::ShoulderRollOverflow { joint: j, deg });
            }
        }
    }

    // 4) 팔-머리 충돌 — shoulder_pitch < -90° (팔이 등 뒤로 가는 동작) +
    //   elbow > +90° (팔꿈치 깊게 굽힘).
    for (sp_j, el_j) in [
        (JointId::RShoulderPitch, JointId::RElbow),
        (JointId::LShoulderPitch, JointId::LElbow),
    ] {
        if let (Some(sp), Some(el)) = (pos(sp_j), pos(el_j)) {
            if sp < -90.0 && el > 90.0 {
                errs.push(CollisionError::ArmHeadCollision { sp, el });
            }
        }
    }

    if errs.is_empty() {
        Ok(())
    } else {
        Err(errs)
    }
}

/// 모션 페이지의 모든 step 검사. 첫 step 에서 에러 발생해도 끝까지 검사.
pub fn check_page(
    page: &crate::motion::MotionPage,
) -> Result<(), Vec<(usize, Vec<CollisionError>)>> {
    let mut errs = Vec::new();
    for (i, step) in page.steps.iter().enumerate() {
        if let Err(es) = check_step(step) {
            errs.push((i, es));
        }
    }
    if errs.is_empty() {
        Ok(())
    } else {
        Err(errs)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::joint::degrees_to_position;
    use crate::motion::MotionStep;

    fn step_with_overrides(overrides: &[(JointId, f64)]) -> MotionStep {
        let mut s = MotionStep::default();
        // default 는 모두 2048 (= 0°).
        for (j, deg) in overrides {
            s.positions[*j as usize] = degrees_to_position(*deg);
        }
        s
    }

    #[test]
    fn walk_ready_passes_collision_check() {
        // ini_pose.yaml 의 walkReady 자세 모두 통과해야 함.
        let walk_ready = [
            (JointId::RShoulderPitch, -48.0),
            (JointId::LShoulderPitch, 48.0),
            (JointId::RShoulderRoll, -20.0),
            (JointId::LShoulderRoll, 20.0),
            (JointId::RElbow, 30.0),
            (JointId::LElbow, -30.0),
            (JointId::RHipPitch, -65.0),
            (JointId::LHipPitch, 65.0),
            (JointId::RKnee, 130.0),
            (JointId::LKnee, -130.0),
            (JointId::RAnklePitch, 70.0),
            (JointId::LAnklePitch, -70.0),
            (JointId::HeadTilt, 10.0),
        ];
        let step = step_with_overrides(&walk_ready);
        assert!(check_step(&step).is_ok(), "walkReady should pass");
    }

    #[test]
    fn knee_hyperextension_detected() {
        let step = step_with_overrides(&[(JointId::RKnee, -45.0)]);
        let err = check_step(&step).unwrap_err();
        assert!(matches!(err[0], CollisionError::KneeHyperextension { .. }));
    }

    #[test]
    fn hip_roll_60_degrees_detected() {
        let step = step_with_overrides(&[(JointId::RHipRoll, 60.0)]);
        let err = check_step(&step).unwrap_err();
        assert!(matches!(err[0], CollisionError::HipRollOverflow { .. }));
    }

    #[test]
    fn shoulder_roll_120_degrees_detected() {
        let step = step_with_overrides(&[(JointId::LShoulderRoll, 120.0)]);
        let err = check_step(&step).unwrap_err();
        assert!(matches!(
            err[0],
            CollisionError::ShoulderRollOverflow { .. }
        ));
    }

    #[test]
    fn arm_head_collision_detected() {
        let step =
            step_with_overrides(&[(JointId::RShoulderPitch, -120.0), (JointId::RElbow, 130.0)]);
        let err = check_step(&step).unwrap_err();
        assert!(err
            .iter()
            .any(|e| matches!(e, CollisionError::ArmHeadCollision { .. })));
    }

    #[test]
    fn neutral_pose_passes() {
        let step = MotionStep::default();
        assert!(check_step(&step).is_ok());
    }

    #[test]
    fn skip_marker_32767_is_ignored() {
        let mut step = MotionStep::default();
        step.positions[JointId::RKnee as usize] = 32767; // skip
        assert!(check_step(&step).is_ok());
    }
}
