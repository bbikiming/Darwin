//! 모터 토크 / 위치 명령 + 한계 강제 + 8 ms tick 컨트롤 루프.
//!
//! Sprint 2 핵심. Phase A에서 20 DOF + JointMap + 부위별 한계로 갱신.

use std::collections::HashMap;

use crate::controller::mx28_register;
use crate::dynamixel::{Bus, SyncWriteEntry};
use crate::error::{Error, Result};
use crate::joint::{JointId, JointLimits, JointMap, JointState};
use crate::motion::{MotionPage, SafetyClass};
use crate::safety::{check_page, CollisionError};
use crate::serial::SerialPort;

/// 모션 실행 옵션.
#[derive(Debug, Clone, Copy, Default)]
pub struct ExecuteOptions {
    /// HighRisk 분류 모션 실행 confirm. 사용자가 명시 확인했음을 표시.
    pub confirm_risk: bool,
}

/// 관절 컨트롤러 — 한계 등록 + 안전 강제 + JointMap 해석.
pub struct JointController<'a, P: SerialPort> {
    bus: &'a mut Bus<P>,
    limits: HashMap<JointId, JointLimits>,
    map: JointMap,
}

impl<'a, P: SerialPort> JointController<'a, P> {
    /// 모든 관절에 부위별 default 한계로 초기화. JointMap은 공식 매핑.
    pub fn new(bus: &'a mut Bus<P>) -> Self {
        Self::with_map(bus, JointMap::official())
    }

    /// 사용자 지정 JointMap으로 초기화 (LegacyOp1 등).
    pub fn with_map(bus: &'a mut Bus<P>, map: JointMap) -> Self {
        let mut limits = HashMap::new();
        for j in JointId::ALL {
            limits.insert(j, JointLimits::for_joint(j));
        }
        Self { bus, limits, map }
    }

    /// 현재 매핑.
    pub fn joint_map(&self) -> JointMap {
        self.map
    }

    /// 매핑 교체 (연결 후 detect 결과 반영용).
    pub fn set_joint_map(&mut self, map: JointMap) {
        self.map = map;
    }

    /// 특정 관절의 한계 override.
    pub fn set_limits(&mut self, joint: JointId, limits: JointLimits) {
        self.limits.insert(joint, limits);
    }

    /// 캐논 JointId → wire u8 (현재 매핑 기준). 매핑되지 않으면 `None`.
    fn wire(&self, joint: JointId) -> Option<u8> {
        self.map.resolve(joint)
    }

    /// 토크 enable/disable 한 관절.
    pub fn set_torque(&mut self, joint: JointId, enable: bool) -> Result<()> {
        let Some(id) = self.wire(joint) else {
            tracing::warn!("set_torque: joint {:?} not mapped — skip", joint);
            return Ok(());
        };
        self.bus
            .write(id, mx28_register::TORQUE_ENABLE, &[enable as u8])
    }

    /// 다중 관절 토크 (한 패킷 SYNC_WRITE).
    pub fn set_torque_many(&mut self, joints: &[JointId], enable: bool) -> Result<()> {
        let entries: Vec<SyncWriteEntry> = joints
            .iter()
            .filter_map(|j| {
                self.wire(*j).map(|id| SyncWriteEntry {
                    id,
                    data: vec![enable as u8],
                })
            })
            .collect();
        if entries.is_empty() {
            return Ok(());
        }
        self.bus
            .sync_write(mx28_register::TORQUE_ENABLE, 1, &entries)
    }

    /// 다중 관절 P_GAIN (단계별 ramp용).
    pub fn set_p_gain_many(&mut self, joints: &[JointId], p_gain: u8) -> Result<()> {
        let entries: Vec<SyncWriteEntry> = joints
            .iter()
            .filter_map(|j| {
                self.wire(*j).map(|id| SyncWriteEntry {
                    id,
                    data: vec![p_gain],
                })
            })
            .collect();
        if entries.is_empty() {
            return Ok(());
        }
        self.bus.sync_write(mx28_register::P_GAIN, 1, &entries)
    }

    /// 한 관절 goal position. 한계 강제로 clamp.
    pub fn set_position(&mut self, joint: JointId, raw: u16) -> Result<u16> {
        let Some(id) = self.wire(joint) else {
            tracing::warn!("set_position: joint {:?} not mapped — skip", joint);
            return Ok(raw);
        };
        let l = self.limits.get(&joint).copied().unwrap_or_default();
        let clamped = l.clamp_position(raw);
        let bytes = clamped.to_le_bytes();
        self.bus.write(id, mx28_register::GOAL_POSITION, &bytes)?;
        Ok(clamped)
    }

    /// 다중 관절 동시 명령 (SYNC_WRITE). 모든 위치는 clamp 후 전송.
    pub fn set_positions_many(&mut self, targets: &[(JointId, u16)]) -> Result<Vec<u16>> {
        let mut clamped_out = Vec::with_capacity(targets.len());
        let entries: Vec<SyncWriteEntry> = targets
            .iter()
            .filter_map(|(j, raw)| {
                let id = self.wire(*j)?;
                let l = self.limits.get(j).copied().unwrap_or_default();
                let clamped = l.clamp_position(*raw);
                clamped_out.push(clamped);
                Some(SyncWriteEntry {
                    id,
                    data: clamped.to_le_bytes().to_vec(),
                })
            })
            .collect();
        if entries.is_empty() {
            return Ok(clamped_out);
        }
        self.bus
            .sync_write(mx28_register::GOAL_POSITION, 2, &entries)?;
        Ok(clamped_out)
    }

    /// 한 관절 현재 상태 (per-joint READ).
    ///
    /// 다중 관절 동시 read는 추후 BULK_READ로 확장 (Sprint 5 walk loop에서).
    pub fn read_state(&mut self, joint: JointId) -> Result<JointState> {
        let id = self
            .wire(joint)
            .ok_or_else(|| crate::error::Error::Other(format!("joint {:?} not mapped", joint)))?;
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

    /// 모션 페이지 실행 사전 게이트 — 안전 분류 + self-collision 검사.
    ///
    /// 통과 시 호출자가 `set_positions_many` 로 step 을 순차 적용. 실패 시
    /// `Error::Other` 로 차단 이유 반환.
    ///
    /// - `HighRisk` + `!options.confirm_risk` → 거부.
    /// - `self_collision::check_page` 실패 → 거부 (분류 무관).
    pub fn precheck_motion(&self, page: &MotionPage, options: ExecuteOptions) -> Result<()> {
        if page.safety_class == SafetyClass::HighRisk && !options.confirm_risk {
            return Err(Error::Other(format!(
                "motion '{}' is HighRisk — pass confirm_risk=true to execute",
                page.name
            )));
        }
        if let Err(step_errs) = check_page(page) {
            let summary: Vec<String> = step_errs
                .iter()
                .map(|(i, errs)| {
                    let labels: Vec<String> = errs.iter().map(CollisionError::to_string).collect();
                    format!("step {}: {}", i, labels.join("; "))
                })
                .collect();
            return Err(Error::Other(format!(
                "self-collision detected: {}",
                summary.join(" | ")
            )));
        }
        Ok(())
    }

    /// 모든 관절 토크 즉시 OFF — 소프트 e-stop. P_GAIN도 0으로 떨어뜨려 차후 ON
    /// 시 다시 ramp.
    pub fn emergency_stop(&mut self) -> Result<()> {
        let all: Vec<JointId> = JointId::ALL.to_vec();
        self.set_torque_many(&all, false)?;
        self.set_p_gain_many(&all, 0)?;
        Ok(())
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
    fn set_position_clamps_to_joint_limits() {
        let mut bus = Bus::new(LoopbackBus::default());
        bus.port_mut().queue_read(&status_bytes(19, 0, &[]));
        let mut jc = JointController::new(&mut bus);
        // HeadPan ±90° = 1024..3072. raw 5000 → 3072으로 clamp.
        let clamped = jc.set_position(JointId::HeadPan, 5000).unwrap();
        assert_eq!(clamped, 3072);
        let w = bus.port_mut().written.clone();
        assert_eq!(&w[5..8], &[30, 0x00, 0x0C]);
    }

    #[test]
    fn set_position_allows_walk_ready_knee() {
        let mut bus = Bus::new(LoopbackBus::default());
        bus.port_mut().queue_read(&status_bytes(13, 0, &[]));
        let mut jc = JointController::new(&mut bus);
        // r_knee 130° ≈ raw 3528 — 이전 ±90° default였다면 clamp되었을 것.
        let raw_130 = crate::joint::degrees_to_position(130.0);
        let clamped = jc.set_position(JointId::RKnee, raw_130).unwrap();
        assert_eq!(clamped, raw_130, "knee 130° must not be clamped");
    }

    #[test]
    fn set_torque_many_uses_sync_write() {
        let mut bus = Bus::new(LoopbackBus::default());
        let mut jc = JointController::new(&mut bus);
        jc.set_torque_many(&[JointId::HeadPan, JointId::HeadTilt], true)
            .unwrap();
        let w = bus.port_mut().written.clone();
        assert_eq!(&w[..6], &[0xFF, 0xFF, 0xFE, 0x08, 0x83, 24]);
        assert_eq!(w[6], 1); // length per device
        assert_eq!(&w[7..9], &[19, 1]); // HeadPan, torque on
        assert_eq!(&w[9..11], &[20, 1]); // HeadTilt, torque on
    }

    #[test]
    fn set_p_gain_many_uses_sync_write_to_address_28() {
        let mut bus = Bus::new(LoopbackBus::default());
        let mut jc = JointController::new(&mut bus);
        jc.set_p_gain_many(&[JointId::HeadPan], 16).unwrap();
        let w = bus.port_mut().written.clone();
        // SYNC_WRITE: FF FF FE LEN 0x83 ADDR LENGTH (ID DATA)+
        assert_eq!(w[5], mx28_register::P_GAIN); // 28
        assert_eq!(w[6], 1); // 1 byte per device
        assert_eq!(w[7], 19); // HeadPan wire id
        assert_eq!(w[8], 16); // p_gain
    }

    #[test]
    fn emergency_stop_writes_torque_off_and_p_gain_zero() {
        let mut bus = Bus::new(LoopbackBus::default());
        let mut jc = JointController::new(&mut bus);
        jc.emergency_stop().unwrap();
        let w = bus.port_mut().written.clone();
        // 두 SYNC_WRITE: torque off + p_gain 0. 첫 패킷이 TORQUE_ENABLE.
        assert_eq!(w[5], mx28_register::TORQUE_ENABLE);
        // 20 관절 모두 한 패킷에 들어감 (20 × 2 = 40 byte payload + 6 byte header).
        // 첫 패킷 길이 byte (offset 3)는 4 + 20*2 = 44.
        assert_eq!(w[3], 44);
    }

    #[test]
    fn legacy_op1_map_resolves_ankle_via_user_input() {
        use crate::joint::{JointMap, LegacyAnkleIds};
        let mut bus = Bus::new(LoopbackBus::default());
        bus.port_mut().queue_read(&status_bytes(31, 0, &[]));
        let map = JointMap::legacy_op1(Some(LegacyAnkleIds {
            r_ank_pitch: 31,
            l_ank_pitch: 32,
            r_ank_roll: 33,
            l_ank_roll: 34,
        }));
        let mut jc = JointController::with_map(&mut bus, map);
        // RAnklePitch는 wire ID 31로 발사돼야 함.
        let _ = jc.set_position(JointId::RAnklePitch, 2048).unwrap();
        let w = bus.port_mut().written.clone();
        assert_eq!(w[2], 31, "wire ID should be 31 from LegacyAnkleIds");
    }

    #[test]
    fn legacy_op1_without_ankle_ids_skips_ankle_writes() {
        let mut bus = Bus::new(LoopbackBus::default());
        let map = JointMap::legacy_op1(None);
        let mut jc = JointController::with_map(&mut bus, map);
        // 발목 명령 — wire 매핑이 없으므로 패킷 미발행, no error.
        let result = jc.set_position(JointId::RAnklePitch, 2048).unwrap();
        // 매핑이 없으면 raw 그대로 반환 (clamp 미적용).
        assert_eq!(result, 2048);
        assert!(bus.port_mut().written.is_empty());
    }

    #[test]
    fn precheck_high_risk_blocked_without_confirm() {
        let mut bus = Bus::new(LoopbackBus::default());
        let jc = JointController::new(&mut bus);
        let page = MotionPage {
            id: 17,
            name: "Hand Standing".to_string(),
            safety_class: SafetyClass::HighRisk,
            ..Default::default()
        };
        let err = jc
            .precheck_motion(&page, ExecuteOptions::default())
            .unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("HighRisk"), "expected HighRisk in {}", msg);
    }

    #[test]
    fn precheck_high_risk_passes_with_confirm() {
        let mut bus = Bus::new(LoopbackBus::default());
        let jc = JointController::new(&mut bus);
        let page = MotionPage {
            id: 17,
            name: "Hand Standing".to_string(),
            safety_class: SafetyClass::HighRisk,
            ..Default::default()
        };
        let result = jc.precheck_motion(&page, ExecuteOptions { confirm_risk: true });
        assert!(result.is_ok(), "expected ok, got {:?}", result);
    }

    #[test]
    fn precheck_self_collision_blocked_regardless_of_class() {
        use crate::joint::degrees_to_position;
        use crate::motion::MotionStep;
        let mut bus = Bus::new(LoopbackBus::default());
        let jc = JointController::new(&mut bus);
        let mut step = MotionStep::default();
        // 위험 자세 — shoulder_roll 120° (한계 90° 초과).
        step.positions[JointId::LShoulderRoll as usize] = degrees_to_position(120.0);
        let page = MotionPage {
            id: 99,
            name: "Bogus".to_string(),
            safety_class: SafetyClass::Safe, // Safe 분류여도 자가 충돌은 차단.
            steps: vec![step],
            ..Default::default()
        };
        let err = jc
            .precheck_motion(&page, ExecuteOptions { confirm_risk: true })
            .unwrap_err();
        assert!(
            err.to_string().contains("self-collision"),
            "expected self-collision, got {}",
            err
        );
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
