//! 20-DOF 관절 ID 매핑 + 상태.
//!
//! ROBOTIS-OP2 e-Manual 표준 actuator ID:
//!   팔   ID 1..6   (어깨 pitch/roll, 팔꿈치 — 한쪽 3 joint)
//!   다리 ID 7..18  (hip yaw/roll/pitch, 무릎, 발목 pitch/roll — 한쪽 6 joint)
//!   머리 ID 19,20  (pan/tilt)
//!
//! 출처: <https://emanual.robotis.com/docs/en/platform/op2/getting_started/>

mod state;
pub use state::{JointLimits, JointState};

use serde::{Deserialize, Serialize};

/// 캐논 관절 ID. ROBOTIS-OP2 e-Manual standard actuator ID 와 1:1 매핑.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum JointId {
    /// 우 어깨 pitch.
    RShoulderPitch = 1,
    /// 좌 어깨 pitch.
    LShoulderPitch = 2,
    /// 우 어깨 roll.
    RShoulderRoll = 3,
    /// 좌 어깨 roll.
    LShoulderRoll = 4,
    /// 우 팔꿈치.
    RElbow = 5,
    /// 좌 팔꿈치.
    LElbow = 6,
    /// 우 hip yaw.
    RHipYaw = 7,
    /// 좌 hip yaw.
    LHipYaw = 8,
    /// 우 hip roll.
    RHipRoll = 9,
    /// 좌 hip roll.
    LHipRoll = 10,
    /// 우 hip pitch.
    RHipPitch = 11,
    /// 좌 hip pitch.
    LHipPitch = 12,
    /// 우 무릎.
    RKnee = 13,
    /// 좌 무릎.
    LKnee = 14,
    /// 우 발목 pitch.
    RAnklePitch = 15,
    /// 좌 발목 pitch.
    LAnklePitch = 16,
    /// 우 발목 roll.
    RAnkleRoll = 17,
    /// 좌 발목 roll.
    LAnkleRoll = 18,
    /// 머리 pan.
    HeadPan = 19,
    /// 머리 tilt.
    HeadTilt = 20,
}

impl JointId {
    /// 모든 관절 ID 순회 — 20 DOF.
    pub const ALL: [JointId; 20] = [
        JointId::RShoulderPitch,
        JointId::LShoulderPitch,
        JointId::RShoulderRoll,
        JointId::LShoulderRoll,
        JointId::RElbow,
        JointId::LElbow,
        JointId::RHipYaw,
        JointId::LHipYaw,
        JointId::RHipRoll,
        JointId::LHipRoll,
        JointId::RHipPitch,
        JointId::LHipPitch,
        JointId::RKnee,
        JointId::LKnee,
        JointId::RAnklePitch,
        JointId::LAnklePitch,
        JointId::RAnkleRoll,
        JointId::LAnkleRoll,
        JointId::HeadPan,
        JointId::HeadTilt,
    ];

    /// raw u8 → enum.
    pub fn from_byte(b: u8) -> Option<Self> {
        Self::ALL.iter().copied().find(|j| *j as u8 == b)
    }

    /// 부위 분류.
    pub fn body_part(self) -> BodyPart {
        match self {
            JointId::RShoulderPitch | JointId::RShoulderRoll | JointId::RElbow => {
                BodyPart::RightArm
            }
            JointId::LShoulderPitch | JointId::LShoulderRoll | JointId::LElbow => BodyPart::LeftArm,
            JointId::RHipYaw
            | JointId::RHipRoll
            | JointId::RHipPitch
            | JointId::RKnee
            | JointId::RAnklePitch
            | JointId::RAnkleRoll => BodyPart::RightLeg,
            JointId::LHipYaw
            | JointId::LHipRoll
            | JointId::LHipPitch
            | JointId::LKnee
            | JointId::LAnklePitch
            | JointId::LAnkleRoll => BodyPart::LeftLeg,
            JointId::HeadPan | JointId::HeadTilt => BodyPart::Head,
        }
    }
}

/// 신체 부위.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum BodyPart {
    /// 우측 팔.
    RightArm,
    /// 좌측 팔.
    LeftArm,
    /// 우측 다리.
    RightLeg,
    /// 좌측 다리.
    LeftLeg,
    /// 머리.
    Head,
}

/// 특수 ID.
pub mod special {
    /// CM-730 / CM-740 sub-controller.
    pub const CONTROLLER: u8 = 200;
    /// 브로드캐스트.
    pub const BROADCAST: u8 = 254;
    /// 우측 발 FSR.
    pub const FSR_RIGHT: u8 = 111;
    /// 좌측 발 FSR.
    pub const FSR_LEFT: u8 = 112;
}

/// MX-28T position raw → 라디안 (4096-step, 0..4095, 2048 = 0 rad).
pub fn position_to_radians(raw: u16) -> f64 {
    use std::f64::consts::PI;
    (raw as i32 - 2048) as f64 * (PI / 2048.0)
}

/// 라디안 → MX-28T position raw. -π..π를 0..4095로 매핑, 한계 clamp.
pub fn radians_to_position(rad: f64) -> u16 {
    use std::f64::consts::PI;
    let raw = (rad * (2048.0 / PI)) + 2048.0;
    raw.clamp(0.0, 4095.0) as u16
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    #[test]
    fn twenty_joints_total() {
        // ROBOTIS-OP2 e-Manual: 팔 6 + 다리 12 + 머리 2 = 20 DOF.
        assert_eq!(JointId::ALL.len(), 20);
    }

    #[test]
    fn body_part_grouping() {
        assert_eq!(JointId::RShoulderPitch.body_part(), BodyPart::RightArm);
        assert_eq!(JointId::LKnee.body_part(), BodyPart::LeftLeg);
        assert_eq!(JointId::RAnklePitch.body_part(), BodyPart::RightLeg);
        assert_eq!(JointId::LAnkleRoll.body_part(), BodyPart::LeftLeg);
        assert_eq!(JointId::HeadTilt.body_part(), BodyPart::Head);
    }

    #[test]
    fn from_byte_round_trip() {
        for j in JointId::ALL {
            assert_eq!(JointId::from_byte(j as u8), Some(j));
        }
        // 0, 21..199, 200 (controller), 201..253, 254 (broadcast) 는 관절 ID 아님.
        assert_eq!(JointId::from_byte(0), None);
        assert_eq!(JointId::from_byte(21), None);
        assert_eq!(JointId::from_byte(200), None); // CONTROLLER는 별도
    }

    #[test]
    fn each_leg_has_six_joints() {
        let r_leg: Vec<JointId> = JointId::ALL
            .iter()
            .copied()
            .filter(|j| j.body_part() == BodyPart::RightLeg)
            .collect();
        let l_leg: Vec<JointId> = JointId::ALL
            .iter()
            .copied()
            .filter(|j| j.body_part() == BodyPart::LeftLeg)
            .collect();
        assert_eq!(r_leg.len(), 6, "한 다리는 6 DOF (yaw/roll/pitch/knee/ankle pitch/ankle roll)");
        assert_eq!(l_leg.len(), 6);
    }

    #[test]
    fn position_radians_round_trip() {
        let raw = 2048;
        assert!((position_to_radians(raw) - 0.0).abs() < 1e-9);
        let raw = 1024;
        assert!((position_to_radians(raw) + PI / 2.0).abs() < 1e-3);

        assert_eq!(radians_to_position(0.0), 2048);
        assert_eq!(radians_to_position(PI / 2.0), 3072);
        assert_eq!(radians_to_position(-PI / 2.0), 1024);
    }

    #[test]
    fn radians_to_position_clamps() {
        assert_eq!(radians_to_position(10.0), 4095);
        assert_eq!(radians_to_position(-10.0), 0);
    }
}
