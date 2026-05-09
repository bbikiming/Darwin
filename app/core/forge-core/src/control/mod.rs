//! 모터 토크 / 위치 명령 + 한계 강제 + 8 ms tick 컨트롤 루프.
//!
//! Sprint 2 핵심.

use std::collections::HashMap;

use crate::controller::mx28_register;
use crate::dynamixel::{Bus, SyncWriteEntry};
use crate::error::Result;
use crate::joint::{JointId, JointLimits, JointState};
use crate::serial::SerialPort;

/// 관절 컨트롤러 — 한계 등록 + 안전 강제.
pub struct JointController<'a, P: SerialPort> {
    bus: &'a mut Bus<P>,
    limits: HashMap<JointId, JointLimits>,
}

impl<'a, P: SerialPort> JointController<'a, P> {
    /// 모든 관절에 default 한계로 초기화.
    pub fn new(bus: &'a mut Bus<P>) -> Self {
        let mut limits = HashMap::new();
        for j in JointId::ALL {
            limits.insert(j, JointLimits::default());
        }
        Self { bus, limits }
    }

    /// 특정 관절의 한계 override.
    pub fn set_limits(&mut self, joint: JointId, limits: JointLimits) {
        self.limits.insert(joint, limits);
    }

    /// 토크 enable/disable 한 관절.
    pub fn set_torque(&mut self, joint: JointId, enable: bool) -> Result<()> {
        self.bus
            .write(joint as u8, mx28_register::TORQUE_ENABLE, &[enable as u8])
    }

    /// 다중 관절 토크 (한 패킷 SYNC_WRITE).
    pub fn set_torque_many(&mut self, joints: &[JointId], enable: bool) -> Result<()> {
        let entries: Vec<SyncWriteEntry> = joints
            .iter()
            .map(|j| SyncWriteEntry {
                id: *j as u8,
                data: vec![enable as u8],
            })
            .collect();
        self.bus
            .sync_write(mx28_register::TORQUE_ENABLE, 1, &entries)
    }

    /// 한 관절 goal position. 한계 강제로 clamp.
    pub fn set_position(&mut self, joint: JointId, raw: u16) -> Result<u16> {
        let l = self.limits.get(&joint).copied().unwrap_or_default();
        let clamped = l.clamp_position(raw);
        let bytes = clamped.to_le_bytes();
        self.bus
            .write(joint as u8, mx28_register::GOAL_POSITION, &bytes)?;
        Ok(clamped)
    }

    /// 다중 관절 동시 명령 (SYNC_WRITE). 모든 위치는 clamp 후 전송.
    pub fn set_positions_many(&mut self, targets: &[(JointId, u16)]) -> Result<Vec<u16>> {
        let mut clamped_out = Vec::with_capacity(targets.len());
        let entries: Vec<SyncWriteEntry> = targets
            .iter()
            .map(|(j, raw)| {
                let l = self.limits.get(j).copied().unwrap_or_default();
                let clamped = l.clamp_position(*raw);
                clamped_out.push(clamped);
                SyncWriteEntry {
                    id: *j as u8,
                    data: clamped.to_le_bytes().to_vec(),
                }
            })
            .collect();
        self.bus
            .sync_write(mx28_register::GOAL_POSITION, 2, &entries)?;
        Ok(clamped_out)
    }

    /// 한 관절 현재 상태 (per-joint READ).
    ///
    /// 다중 관절 동시 read는 추후 BULK_READ로 확장 (Sprint 5 walk loop에서).
    pub fn read_state(&mut self, joint: JointId) -> Result<JointState> {
        let id = joint as u8;
        // Goal Position (30..31)
        let g = self.bus.read(id, mx28_register::GOAL_POSITION, 2)?;
        let goal_position = u16::from_le_bytes([g[0], g[1]]);
        // Present Position..Temperature (36..43, 8 bytes)
        let p = self.bus.read(id, mx28_register::PRESENT_POSITION, 8)?;
        let present_position = u16::from_le_bytes([p[0], p[1]]);
        let present_speed = u16::from_le_bytes([p[2], p[3]]);
        let present_load = u16::from_le_bytes([p[4], p[5]]);
        let present_voltage = p[6];
        let present_temperature = p[7];
        // Torque Enable (24, 1 byte)
        let t = self.bus.read(id, mx28_register::TORQUE_ENABLE, 1)?;
        let torque_enabled = t[0] != 0;

        Ok(JointState {
            id: joint,
            goal_position,
            present_position,
            present_speed,
            present_load,
            present_voltage,
            present_temperature,
            torque_enabled,
        })
    }

    /// 모든 관절 토크 즉시 OFF — 소프트 e-stop.
    pub fn emergency_stop(&mut self) -> Result<()> {
        let all: Vec<JointId> = JointId::ALL.to_vec();
        self.set_torque_many(&all, false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dynamixel::v1::Codec;
    use crate::serial::LoopbackBus;

    fn status_bytes(id: u8, error: u8, params: &[u8]) -> Vec<u8> {
        let length = (params.len() + 2) as u8;
        let mut out = vec![0xFF, 0xFF, id, length, error];
        out.extend_from_slice(params);
        out.push(Codec::checksum(id, length, error, params));
        out
    }

    #[test]
    fn set_position_clamps_to_limits() {
        let mut bus = Bus::new(LoopbackBus::default());
        bus.port_mut().queue_read(&status_bytes(19, 0, &[]));
        let mut jc = JointController::new(&mut bus);
        // default limits = 1024..3072. raw 5000 → 3072으로 clamp.
        let clamped = jc.set_position(JointId::HeadPan, 5000).unwrap();
        assert_eq!(clamped, 3072);
        // 패킷에 3072(0x0C00 LE → 0x00 0x0C)이 실렸나?
        let w = bus.port_mut().written.clone();
        // WRITE ID=19 ADDR=30 VAL_LO=0x00 VAL_HI=0x0C → ... 30 00 0C
        assert_eq!(&w[5..8], &[30, 0x00, 0x0C]);
    }

    #[test]
    fn set_torque_many_uses_sync_write() {
        let mut bus = Bus::new(LoopbackBus::default());
        let mut jc = JointController::new(&mut bus);
        jc.set_torque_many(&[JointId::HeadPan, JointId::HeadTilt], true)
            .unwrap();
        let w = bus.port_mut().written.clone();
        // SYNC_WRITE: FF FF FE LEN 0x83 ADDR LENGTH (ID DATA)+
        assert_eq!(&w[..6], &[0xFF, 0xFF, 0xFE, 0x08, 0x83, 24]);
        assert_eq!(w[6], 1); // length per device
        assert_eq!(&w[7..9], &[19, 1]); // HeadPan, torque on
        assert_eq!(&w[9..11], &[20, 1]); // HeadTilt, torque on
    }

    #[test]
    fn emergency_stop_sets_all_off() {
        let mut bus = Bus::new(LoopbackBus::default());
        let mut jc = JointController::new(&mut bus);
        jc.emergency_stop().unwrap();
        let w = bus.port_mut().written.clone();
        // SYNC_WRITE에 16개 관절 모두 들어가야 함
        // 시작 헤더만 검증
        assert_eq!(&w[..5], &[0xFF, 0xFF, 0xFE, w[3], 0x83]);
        // ADDR = TORQUE_ENABLE (24), LENGTH = 1
        assert_eq!(w[5], 24);
        assert_eq!(w[6], 1);
    }

    #[test]
    fn read_state_assembles_from_three_reads() {
        let mut bus = Bus::new(LoopbackBus::default());
        let port = bus.port_mut();
        // goal_position = 2048 (0x0800 LE → 0x00 0x08)
        port.queue_read(&status_bytes(19, 0, &[0x00, 0x08]));
        // present_position..temperature (8 bytes):
        //   pos=2050, speed=0, load=10, voltage=118, temp=35
        port.queue_read(&status_bytes(
            19,
            0,
            &[0x02, 0x08, 0x00, 0x00, 0x0A, 0x00, 118, 35],
        ));
        // torque_enable = 1
        port.queue_read(&status_bytes(19, 0, &[1]));

        let mut jc = JointController::new(&mut bus);
        let s = jc.read_state(JointId::HeadPan).unwrap();
        assert_eq!(s.id, JointId::HeadPan);
        assert_eq!(s.goal_position, 2048);
        assert_eq!(s.present_position, 2050);
        assert_eq!(s.present_speed, 0);
        assert_eq!(s.present_load, 10);
        assert_eq!(s.present_voltage, 118);
        assert_eq!(s.present_temperature, 35);
        assert!(s.torque_enabled);
    }
}
