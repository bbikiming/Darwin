//! 20-DOF 관절 ID 매핑 + 상태 — `docs/architecture/joint-conventions.md`.

mod state;
pub use state::{JointLimits, JointState};

use serde::{Deserialize, Serialize};

/// 캐논 관절 ID. `JointData.h`의 enum과 동일 번호.
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
    RHipYaw = 11,
    /// 좌 hip yaw.
    LHipYaw = 12,
    /// 우 hip roll.
    RHipRoll = 13,
    /// 좌 hip roll.
    LHipRoll = 14,
    /// 우 hip pitch.
    RHipPitch = 15,
    /// 좌 hip pitch.
    LHipPitch = 16,
    /// 우 무릎.
    RKnee = 17,
    /// 좌 무릎.
    LKnee = 18,
    /// 머리 pan.
    HeadPan = 19,
    /// 머리 tilt.
    HeadTilt = 20,
}

impl JointId {
    /// 모든 관절 ID 순회.
    pub const ALL: [JointId; 16] = [
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
            JointId::RHipYaw | JointId::RHipRoll | JointId::RHipPitch | JointId::RKnee => {
                BodyPart::RightLeg
            }
            JointId::LHipYaw | JointId::LHipRoll | JointId::LHipPitch | JointId::LKnee => {
                BodyPart::LeftLeg
            }
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
    fn sixteen_joints_total() {
        assert_eq!(JointId::ALL.len(), 16);
    }

    #[test]
    fn body_part_grouping() {
        assert_eq!(JointId::RShoulderPitch.body_part(), BodyPart::RightArm);
        assert_eq!(JointId::LKnee.body_part(), BodyPart::LeftLeg);
        assert_eq!(JointId::HeadTilt.body_part(), BodyPart::Head);
    }

    #[test]
    fn from_byte_round_trip() {
        for j in JointId::ALL {
            assert_eq!(JointId::from_byte(j as u8), Some(j));
        }
        assert_eq!(JointId::from_byte(7), None); // 7..10은 사용 안 함
        assert_eq!(JointId::from_byte(200), None); // CONTROLLER는 별도
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
