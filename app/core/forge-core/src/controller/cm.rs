//! CM-730 / CM-740 sub-controller 고수준 wrapper.
//!
//! ID 200 쳐서 board state 읽고 LED 토글.

use crate::controller::cm_register;
use crate::dynamixel::Bus;
use crate::error::Result;
use crate::joint::special::CONTROLLER;
use crate::serial::SerialPort;

/// CM-730/740 보드 상태 스냅샷.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BoardSnapshot {
    /// EEPROM model number raw (730 또는 740 추정).
    pub model_number: u16,
    /// 펌웨어 version.
    pub version: u8,
    /// 배터리 전압 (raw, 0.1 V 단위 — `voltage_volts()` 사용).
    pub voltage_raw: u8,
    /// 버튼 비트.
    pub button: u8,
}

impl BoardSnapshot {
    /// 배터리 전압을 V 단위로 환산.
    pub fn voltage_volts(&self) -> f32 {
        self.voltage_raw as f32 / 10.0
    }
}

/// CM-730/740 wrapper. 내부적으로 `Bus`를 빌려 ID 200으로 통신.
pub struct CmController<'a, P: SerialPort> {
    bus: &'a mut Bus<P>,
}

impl<'a, P: SerialPort> CmController<'a, P> {
    /// 기존 Bus를 빌려 wrapper 생성.
    pub fn new(bus: &'a mut Bus<P>) -> Self {
        Self { bus }
    }

    /// ID 200에 PING. 응답 없으면 Err.
    pub fn ping(&mut self) -> Result<()> {
        self.bus.ping(CONTROLLER).map(|_| ())
    }

    /// 보드 상태 스냅샷 — 모델 번호, 버전, 전압, 버튼.
    pub fn snapshot(&mut self) -> Result<BoardSnapshot> {
        let mn = self.bus.read(CONTROLLER, cm_register::MODEL_NUMBER, 2)?;
        let model_number = u16::from_le_bytes([mn[0], mn[1]]);
        let v = self.bus.read(CONTROLLER, cm_register::VERSION, 1)?;
        let version = v[0];
        let vt = self.bus.read(CONTROLLER, cm_register::VOLTAGE, 1)?;
        let voltage_raw = vt[0];
        let bt = self.bus.read(CONTROLLER, cm_register::BUTTON, 1)?;
        let button = bt[0];
        Ok(BoardSnapshot {
            model_number,
            version,
            voltage_raw,
            button,
        })
    }

    /// Dynamixel 전원 게이트 (모터 rail).
    pub fn set_dxl_power(&mut self, on: bool) -> Result<()> {
        self.bus
            .write(CONTROLLER, cm_register::DXL_POWER, &[on as u8])
    }

    /// 가슴 LED 비트 (3개).
    pub fn set_chest_led(&mut self, bits: u8) -> Result<()> {
        self.bus.write(CONTROLLER, cm_register::LED_PANEL, &[bits])
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
    fn cm_ping_calls_id_200() {
        let mut bus = Bus::new(LoopbackBus::default());
        bus.port_mut().queue_read(&status_bytes(200, 0, &[]));
        let mut cm = CmController::new(&mut bus);
        cm.ping().unwrap();
        // 첫 5바이트가 PING ID=200
        assert_eq!(
            &bus.port_mut().written[..5],
            &[0xFF, 0xFF, 0xC8, 0x02, 0x01]
        );
    }

    #[test]
    fn cm_snapshot_returns_decoded_state() {
        let mut bus = Bus::new(LoopbackBus::default());
        let port = bus.port_mut();
        // model = 730 (LE: DA 02), version = 1, voltage_raw = 118 (11.8V), button = 2 (START)
        port.queue_read(&status_bytes(200, 0, &[0xDA, 0x02])); // model
        port.queue_read(&status_bytes(200, 0, &[1])); // version
        port.queue_read(&status_bytes(200, 0, &[118])); // voltage
        port.queue_read(&status_bytes(200, 0, &[2])); // button

        let mut cm = CmController::new(&mut bus);
        let snap = cm.snapshot().unwrap();
        assert_eq!(snap.model_number, 730);
        assert_eq!(snap.version, 1);
        assert_eq!(snap.voltage_raw, 118);
        assert!((snap.voltage_volts() - 11.8).abs() < 1e-3);
        assert_eq!(snap.button, 2);
    }

    #[test]
    fn cm_set_dxl_power_writes_correct_packet() {
        let mut bus = Bus::new(LoopbackBus::default());
        bus.port_mut().queue_read(&status_bytes(200, 0, &[]));
        let mut cm = CmController::new(&mut bus);
        cm.set_dxl_power(true).unwrap();
        // WRITE ID=200 ADDR=24 VAL=1 → FF FF C8 04 03 18 01 CSUM
        let w = bus.port_mut().written.clone();
        assert_eq!(&w[..7], &[0xFF, 0xFF, 0xC8, 0x04, 0x03, 0x18, 0x01]);
    }
}
