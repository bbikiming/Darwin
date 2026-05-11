//! 관절 실시간 상태 + 부위별 안전 한계.

use serde::{Deserialize, Serialize};

use super::{degrees_to_position, JointId};

/// MX-28T의 한 관절에서 BULK_READ로 가져올 수 있는 현재 상태 묶음.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JointState {
    /// 관절 ID.
    pub id: JointId,
    /// Goal Position (raw 0..4095).
    pub goal_position: u16,
    /// Present Position (raw 0..4095).
    pub present_position: u16,
    /// Present Speed (raw, signed magnitude with bit 10 = 방향).
    pub present_speed: u16,
    /// Present Load (raw, signed magnitude).
    pub present_load: u16,
    /// Present Voltage 0.1 V 단위.
    pub present_voltage: u8,
    /// Present Temperature °C.
    pub present_temperature: u8,
    /// Torque enabled?
    pub torque_enabled: bool,
}

impl JointState {
    /// 전압 V.
    pub fn voltage_volts(&self) -> f32 {
        self.present_voltage as f32 / 10.0
    }
}

/// MX-28T의 안전 한계 (보수적, software-only).
///
/// `dxl_init.yaml` 의 모터 EEPROM angle limit은 모든 모터 0..4095(풀 범위)지만,
/// 실제 안전은 여기 software 한계가 강제한다. 부위별 한계는
/// 공식 walkReady (`ini_pose.yaml`) + 데모 모션 카탈로그가 모두 통과하도록 설계.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JointLimits {
    /// 위치 raw 최소.
    pub position_min: u16,
    /// 위치 raw 최대.
    pub position_max: u16,
    /// 한 번에 명령 가능한 최대 속도 (raw).
    pub max_speed_raw: u16,
}

impl Default for JointLimits {
    fn default() -> Self {
        // ±90°: 1024..3072. 일반 보수 default — 부위별 prebuilt가 없는 곳에만.
        Self {
            position_min: 1024,
            position_max: 3072,
            max_speed_raw: 200,
        }
    }
}

impl JointLimits {
    /// 위치 raw를 한계 내로 clamp.
    pub fn clamp_position(&self, raw: u16) -> u16 {
        raw.clamp(self.position_min, self.position_max)
    }

    /// 속도 raw를 한계 내로 clamp (절댓값 기준).
    pub fn clamp_speed(&self, raw: u16) -> u16 {
        raw.min(self.max_speed_raw)
    }

    /// 각도 ±deg 범위로 한계 생성. 양수 deg만 받음.
    pub fn symmetric_deg(deg: f64, max_speed_raw: u16) -> Self {
        let half = deg.abs();
        let lo = degrees_to_position(-half);
        let hi = degrees_to_position(half);
        Self {
            position_min: lo,
            position_max: hi,
            max_speed_raw,
        }
    }

    /// 비대칭 한계 (도). lo_deg ≤ hi_deg.
    pub fn asymmetric_deg(lo_deg: f64, hi_deg: f64, max_speed_raw: u16) -> Self {
        assert!(lo_deg <= hi_deg, "asymmetric_deg: lo > hi");
        Self {
            position_min: degrees_to_position(lo_deg),
            position_max: degrees_to_position(hi_deg),
            max_speed_raw,
        }
    }

    /// 부위별 공식 권장 한계. `joint-conventions.md` + `ini_pose.yaml` 수용.
    ///
    /// 좌·우 회전 방향이 부호 반전인 관절(knee, elbow 등)도 양방향 동일한
    /// 한계로 단순화 — 양쪽 동작이 모두 통과해야 하므로 절댓값 기준 max.
    pub fn for_joint(joint: JointId) -> Self {
        match joint {
            // 어깨 pitch: walkReady r=-48°, l=48° + 손 흔들기 등 ±180° 가능.
            JointId::RShoulderPitch | JointId::LShoulderPitch => Self::symmetric_deg(180.0, 200),
            // 어깨 roll: walkReady r=-20°, l=20° + T-자세 등 ±90°.
            JointId::RShoulderRoll | JointId::LShoulderRoll => Self::symmetric_deg(90.0, 200),
            // 팔꿈치: walkReady r=30°, l=-30° + 좌우 부호 반대 모션 ±150°.
            JointId::RElbow | JointId::LElbow => Self::symmetric_deg(150.0, 200),
            // hip yaw: walkReady 0°, 회전 ±60° 정도.
            JointId::RHipYaw | JointId::LHipYaw => Self::symmetric_deg(90.0, 150),
            // hip roll: walkReady 0°, ±45°.
            JointId::RHipRoll | JointId::LHipRoll => Self::symmetric_deg(45.0, 150),
            // hip pitch: walkReady r=-65°, l=65° → ±90° 수용.
            JointId::RHipPitch | JointId::LHipPitch => Self::symmetric_deg(90.0, 150),
            // knee: walkReady r=130°, l=-130° → ±150° 수용.
            JointId::RKnee | JointId::LKnee => Self::symmetric_deg(150.0, 150),
            // ankle pitch: walkReady r=70°, l=-70° → ±90°.
            JointId::RAnklePitch | JointId::LAnklePitch => Self::symmetric_deg(90.0, 150),
            // ankle roll: walkReady 0°, ±45°.
            JointId::RAnkleRoll | JointId::LAnkleRoll => Self::symmetric_deg(45.0, 150),
            // 머리 pan: ±90° (카메라 시야).
            JointId::HeadPan => Self::symmetric_deg(90.0, 200),
            // 머리 tilt: ±45° (충돌 회피).
            JointId::HeadTilt => Self::symmetric_deg(45.0, 200),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn voltage_volts_conversion() {
        let s = JointState {
            id: JointId::HeadPan,
            goal_position: 2048,
            present_position: 2048,
            present_speed: 0,
            present_load: 0,
            present_voltage: 118,
            present_temperature: 35,
            torque_enabled: true,
        };
        assert!((s.voltage_volts() - 11.8).abs() < 1e-3);
    }

    #[test]
    fn default_limits_clamp_position() {
        let l = JointLimits::default();
        assert_eq!(l.clamp_position(0), 1024);
        assert_eq!(l.clamp_position(4095), 3072);
        assert_eq!(l.clamp_position(2048), 2048);
    }

    #[test]
    fn default_limits_clamp_speed() {
        let l = JointLimits::default();
        assert_eq!(l.clamp_speed(50), 50);
        assert_eq!(l.clamp_speed(1023), 200);
    }

    #[test]
    fn knee_limits_accommodate_walk_ready_130_degrees() {
        // ini_pose.yaml r_knee=130°, l_knee=-130° 모두 안에 들어야 함.
        let l = JointLimits::for_joint(JointId::RKnee);
        let p130 = degrees_to_position(130.0);
        let n130 = degrees_to_position(-130.0);
        assert_eq!(l.clamp_position(p130), p130);
        assert_eq!(l.clamp_position(n130), n130);
        // ±150°는 한계.
        let p150 = degrees_to_position(150.0);
        assert_eq!(l.clamp_position(p150), p150);
    }

    #[test]
    fn hip_pitch_limits_accommodate_walk_ready_65_degrees() {
        // ini_pose.yaml r_hip_pitch=-65°, l_hip_pitch=65°.
        let l = JointLimits::for_joint(JointId::RHipPitch);
        let p65 = degrees_to_position(65.0);
        let n65 = degrees_to_position(-65.0);
        assert_eq!(l.clamp_position(p65), p65);
        assert_eq!(l.clamp_position(n65), n65);
    }

    #[test]
    fn ankle_pitch_limits_accommodate_walk_ready_70_degrees() {
        // ini_pose.yaml r_ank_pitch=70°, l_ank_pitch=-70°.
        let l = JointLimits::for_joint(JointId::RAnklePitch);
        let p70 = degrees_to_position(70.0);
        let n70 = degrees_to_position(-70.0);
        assert_eq!(l.clamp_position(p70), p70);
        assert_eq!(l.clamp_position(n70), n70);
    }

    #[test]
    fn head_tilt_limits_45_degrees() {
        let l = JointLimits::for_joint(JointId::HeadTilt);
        let p46 = degrees_to_position(46.0);
        let p45 = degrees_to_position(45.0);
        // 45°는 통과, 46°는 clamp.
        assert_eq!(l.clamp_position(p45), p45);
        assert!(l.clamp_position(p46) <= p45);
    }

    #[test]
    fn all_walk_ready_positions_within_limits() {
        // 공식 ini_pose.yaml 모든 20관절 각도가 부위별 한계 안에 들어야 함.
        let walk_ready: &[(JointId, f64)] = &[
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
        for (joint, deg) in walk_ready {
            let raw = degrees_to_position(*deg);
            let limits = JointLimits::for_joint(*joint);
            let clamped = limits.clamp_position(raw);
            assert_eq!(
                clamped, raw,
                "joint {:?} deg {} (raw {}) was clamped to {} — limits {:?}",
                joint, deg, raw, clamped, limits
            );
        }
    }

    #[test]
    fn symmetric_deg_helper() {
        let l = JointLimits::symmetric_deg(45.0, 100);
        assert_eq!(l.position_min, degrees_to_position(-45.0));
        assert_eq!(l.position_max, degrees_to_position(45.0));
        assert_eq!(l.max_speed_raw, 100);
    }
}
