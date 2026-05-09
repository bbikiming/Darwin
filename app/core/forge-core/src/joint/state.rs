//! 관절 실시간 상태.

use serde::{Deserialize, Serialize};

use super::JointId;

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

/// MX-28T의 안전 한계 (보수적). docs/architecture/joint-conventions.md.
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
        // ±90°: 1024..3072 (2048 ± 1024). 보수적 default.
        Self {
            position_min: 1024,
            position_max: 3072,
            max_speed_raw: 200, // ~0.6 의 모터 사이클 — 충분히 안전
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
    fn limits_clamp_position() {
        let l = JointLimits::default();
        assert_eq!(l.clamp_position(0), 1024);
        assert_eq!(l.clamp_position(4095), 3072);
        assert_eq!(l.clamp_position(2048), 2048);
    }

    #[test]
    fn limits_clamp_speed() {
        let l = JointLimits::default();
        assert_eq!(l.clamp_speed(50), 50);
        assert_eq!(l.clamp_speed(1023), 200);
    }
}
