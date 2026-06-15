//! 20-DOF 관절 ID 매핑 + 상태 — `docs/architecture/joint-conventions.md`.
//!
//! ID 매핑은 ROBOTIS 공식 ROBOTIS-OP2 `op2_manager/config/OP2.robot` (Apache 2.0)
//! 와 일치한다. DARwIn-OP 1세대(CM-730)와 OP2(CM-740) 모두 같은 매핑.

pub mod fsr;
mod map;
mod state;

pub use map::{JointMap, JointMapKind, LegacyAnkleIds};
pub use state::{JointLimits, JointState};

use serde::{Deserialize, Serialize};

/// 캐논 20-DOF 관절 ID — ROBOTIS-OP2 `OP2.robot` 1:1.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[repr(u8)]
pub enum JointId {
    /// 우 어깨 pitch — `r_sho_pitch`.
    RShoulderPitch = 1,
    /// 좌 어깨 pitch — `l_sho_pitch`.
    LShoulderPitch = 2,
    /// 우 어깨 roll — `r_sho_roll`.
    RShoulderRoll = 3,
    /// 좌 어깨 roll — `l_sho_roll`.
    LShoulderRoll = 4,
    /// 우 팔꿈치 — `r_el`.
    RElbow = 5,
    /// 좌 팔꿈치 — `l_el`.
    LElbow = 6,
    /// 우 hip yaw — `r_hip_yaw`.
    RHipYaw = 7,
    /// 좌 hip yaw — `l_hip_yaw`.
    LHipYaw = 8,
    /// 우 hip roll — `r_hip_roll`.
    RHipRoll = 9,
    /// 좌 hip roll — `l_hip_roll`.
    LHipRoll = 10,
    /// 우 hip pitch — `r_hip_pitch`.
    RHipPitch = 11,
    /// 좌 hip pitch — `l_hip_pitch`.
    LHipPitch = 12,
    /// 우 무릎 — `r_knee`.
    RKnee = 13,
    /// 좌 무릎 — `l_knee`.
    LKnee = 14,
    /// 우 발목 pitch — `r_ank_pitch`.
    RAnklePitch = 15,
    /// 좌 발목 pitch — `l_ank_pitch`.
    LAnklePitch = 16,
    /// 우 발목 roll — `r_ank_roll`.
    RAnkleRoll = 17,
    /// 좌 발목 roll — `l_ank_roll`.
    LAnkleRoll = 18,
    /// 머리 pan — `head_pan`.
    HeadPan = 19,
    /// 머리 tilt — `head_tilt`.
    HeadTilt = 20,
}

impl JointId {
    /// 모든 관절 ID — `OP2.robot` 순서대로 20개.
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

    /// 다리 6개 × 2 = 12개 다리 관절 (워크·IK 대상).
    pub const LEGS: [JointId; 12] = [
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
    ];

    /// raw u8 → enum (캐논 ID 1..=20).
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

    /// `OP2.robot` 라벨 (snake_case). UI · 로그 매칭용.
    pub fn snake_name(self) -> &'static str {
        match self {
            JointId::RShoulderPitch => "r_sho_pitch",
            JointId::LShoulderPitch => "l_sho_pitch",
            JointId::RShoulderRoll => "r_sho_roll",
            JointId::LShoulderRoll => "l_sho_roll",
            JointId::RElbow => "r_el",
            JointId::LElbow => "l_el",
            JointId::RHipYaw => "r_hip_yaw",
            JointId::LHipYaw => "l_hip_yaw",
            JointId::RHipRoll => "r_hip_roll",
            JointId::LHipRoll => "l_hip_roll",
            JointId::RHipPitch => "r_hip_pitch",
            JointId::LHipPitch => "l_hip_pitch",
            JointId::RKnee => "r_knee",
            JointId::LKnee => "l_knee",
            JointId::RAnklePitch => "r_ank_pitch",
            JointId::LAnklePitch => "l_ank_pitch",
            JointId::RAnkleRoll => "r_ank_roll",
            JointId::LAnkleRoll => "l_ank_roll",
            JointId::HeadPan => "head_pan",
            JointId::HeadTilt => "head_tilt",
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

/// 도(degree) → MX-28T position raw.
pub fn degrees_to_position(deg: f64) -> u16 {
    radians_to_position(deg.to_radians())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    #[test]
    fn twenty_joints_total() {
        assert_eq!(JointId::ALL.len(), 20);
    }

    #[test]
    fn twelve_leg_joints() {
        assert_eq!(JointId::LEGS.len(), 12);
        // LEGS는 ALL의 부분집합
        for j in JointId::LEGS {
            assert!(JointId::ALL.contains(&j));
        }
    }

    #[test]
    fn ankle_joints_present() {
        // 발목 4개가 enum에 있어야 보행 가능.
        assert!(JointId::from_byte(15).is_some());
        assert!(JointId::from_byte(16).is_some());
        assert!(JointId::from_byte(17).is_some());
        assert!(JointId::from_byte(18).is_some());
        assert_eq!(JointId::RAnklePitch as u8, 15);
        assert_eq!(JointId::LAnklePitch as u8, 16);
        assert_eq!(JointId::RAnkleRoll as u8, 17);
        assert_eq!(JointId::LAnkleRoll as u8, 18);
    }

    #[test]
    fn hip_ids_match_official() {
        // 공식 OP2.robot ID 7-10이 hip yaw/roll.
        assert_eq!(JointId::RHipYaw as u8, 7);
        assert_eq!(JointId::LHipYaw as u8, 8);
        assert_eq!(JointId::RHipRoll as u8, 9);
        assert_eq!(JointId::LHipRoll as u8, 10);
    }

    #[test]
    fn body_part_grouping() {
        assert_eq!(JointId::RShoulderPitch.body_part(), BodyPart::RightArm);
        assert_eq!(JointId::RAnkleRoll.body_part(), BodyPart::RightLeg);
        assert_eq!(JointId::LAnklePitch.body_part(), BodyPart::LeftLeg);
        assert_eq!(JointId::HeadTilt.body_part(), BodyPart::Head);
    }

    #[test]
    fn from_byte_round_trip() {
        for j in JointId::ALL {
            assert_eq!(JointId::from_byte(j as u8), Some(j));
        }
        // 캐논 ID 외는 None.
        assert_eq!(JointId::from_byte(0), None);
        assert_eq!(JointId::from_byte(21), None);
        assert_eq!(JointId::from_byte(200), None); // CONTROLLER 별도
    }

    #[test]
    fn snake_names_match_official_op2_robot() {
        // 공식 라벨 (`OP2.robot:10-29`) 과 일치.
        assert_eq!(JointId::RShoulderPitch.snake_name(), "r_sho_pitch");
        assert_eq!(JointId::RHipYaw.snake_name(), "r_hip_yaw");
        assert_eq!(JointId::RAnklePitch.snake_name(), "r_ank_pitch");
        assert_eq!(JointId::HeadTilt.snake_name(), "head_tilt");
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

    #[test]
    fn degrees_to_position_examples() {
        assert_eq!(degrees_to_position(0.0), 2048);
        assert_eq!(degrees_to_position(90.0), 3072);
        assert_eq!(degrees_to_position(-90.0), 1024);
        // ini_pose.yaml r_hip_pitch -65° → raw ≈ 2048 - 740 ≈ 1308
        let raw = degrees_to_position(-65.0);
        assert!(
            (1300..=1316).contains(&raw),
            "r_hip_pitch -65° → raw {} (expected ~1308)",
            raw
        );
    }
}
