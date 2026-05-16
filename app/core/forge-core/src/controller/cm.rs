//! CM-730 / CM-740 sub-controller 고수준 wrapper.
//!
//! ID 200 쳐서 board state 읽고 LED 토글.

use crate::controller::cm_register;
use crate::dynamixel::Bus;
use crate::error::Result;
use crate::joint::special::CONTROLLER;
use crate::joint::JointMap;
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

    /// 모델 번호로 컨트롤러 라벨 판단. CM-730 / CM-740 / 미상.
    pub fn controller_label(&self) -> &'static str {
        match self.model_number {
            730 => "CM-730 (DARwIn-OP 1세대)",
            740 => "CM-740 (DARwIn-OP 2세대 / ROBOTIS-OP2)",
            _ => "Unknown CM controller",
        }
    }
}

/// PING sweep + JointMap auto-detect 결과.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetectResult {
    /// 응답한 모터 ID (1..=20).
    pub responding_ids: Vec<u8>,
    /// 누락된 캐논 ID (공식 매핑 기준 미응답).
    pub missing_ids: Vec<u8>,
    /// 자동 선택된 매핑.
    pub map: JointMap,
}

/// CM-730/740 의 IMU raw — gyro X/Y/Z + accel X/Y/Z (16-bit signed).
///
/// **공식 매핑** (ROBOTIS-OP2 LinuxCM730.cpp 기준):
///   - 38 (Z low), 40 (Y low), 42 (X low) — gyro 6 byte 연속.
///   - 44 (X low), 46 (Y low), 48 (Z low) — accel 6 byte 연속.
///
/// **변환** (CM-730 / MPU-9150 datasheet):
///   - Gyro: full-scale ±2000°/s → 32767 LSB = 2000°/s. raw × 2000.0 / 32767 = °/s.
///   - Accel: full-scale ±2g → 32767 LSB = 2g. raw × 2.0 / 32767 = g.
///   - Tilt 근사: atan2(accel_y, accel_z) = roll, atan2(-accel_x, sqrt(y²+z²)) = pitch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImuRaw {
    /// Gyro X 16-bit raw (LSB). 변환 `× 2000/32767 = °/s`.
    pub gyro_x: i16,
    /// Gyro Y 16-bit raw (LSB).
    pub gyro_y: i16,
    /// Gyro Z 16-bit raw (LSB).
    pub gyro_z: i16,
    /// Accel X 16-bit raw (LSB). 변환 `× 2/32767 = g`.
    pub accel_x: i16,
    /// Accel Y 16-bit raw (LSB).
    pub accel_y: i16,
    /// Accel Z 16-bit raw (LSB).
    pub accel_z: i16,
}

impl ImuRaw {
    /// Gyro X (°/s).
    pub fn gyro_x_dps(&self) -> f32 {
        self.gyro_x as f32 * 2000.0 / 32767.0
    }
    /// Gyro Y (°/s).
    pub fn gyro_y_dps(&self) -> f32 {
        self.gyro_y as f32 * 2000.0 / 32767.0
    }
    /// Gyro Z (°/s).
    pub fn gyro_z_dps(&self) -> f32 {
        self.gyro_z as f32 * 2000.0 / 32767.0
    }
    /// Accel X (g).
    pub fn accel_x_g(&self) -> f32 {
        self.accel_x as f32 * 2.0 / 32767.0
    }
    /// Accel Y (g).
    pub fn accel_y_g(&self) -> f32 {
        self.accel_y as f32 * 2.0 / 32767.0
    }
    /// Accel Z (g).
    pub fn accel_z_g(&self) -> f32 {
        self.accel_z as f32 * 2.0 / 32767.0
    }
    /// Roll (도) — accelerometer 기반 정적 tilt.
    pub fn roll_degrees(&self) -> f32 {
        let ay = self.accel_y as f32;
        let az = self.accel_z as f32;
        if az == 0.0 && ay == 0.0 {
            0.0
        } else {
            ay.atan2(az) * 180.0 / std::f32::consts::PI
        }
    }
    /// Pitch (도) — accelerometer 기반 정적 tilt.
    pub fn pitch_degrees(&self) -> f32 {
        let ax = self.accel_x as f32;
        let ay = self.accel_y as f32;
        let az = self.accel_z as f32;
        let denom = (ay.powi(2) + az.powi(2)).sqrt();
        if denom == 0.0 {
            0.0
        } else {
            (-ax).atan2(denom) * 180.0 / std::f32::consts::PI
        }
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

    /// IMU raw 6 channels read — Phase D3 (Sprint 18).
    ///
    /// CM-730/740 의 register 38 (GYRO_Z low) 부터 12 byte 연속 read.
    /// 순서: GYRO_Z, GYRO_Y, GYRO_X, ACCEL_X, ACCEL_Y, ACCEL_Z (각 2 byte little-endian).
    /// 단일 burst read 라 forge-bridge ~1ms 응답.
    ///
    /// # Scale 변환의 정직성 (Codex 잔여 2 분석)
    ///
    /// 현재 `ImuRaw::gyro_x_dps()` 등은 MPU-6050 ±2000dps / ±2g full scale 을 가정:
    ///     raw × 2000.0 / 32767 = °/s
    ///     raw × 2.0  / 32767 = g
    ///
    /// **하지만 ROBOTIS-OP2 legacy code 와 차이 가능**:
    ///   - `Framework/src/motion/MotionStatus.cpp` 의 `FB_GYRO`, `FB_ACCEL` 은
    ///     `(BulkRead[H] << 8) | BulkRead[L]` — unsigned 16-bit composition.
    ///   - MotionStatus 가 그 raw word 를 그대로 사용 (보통 512 center, 즉 10-bit ADC 결과).
    ///   - 만약 CM-730/740 펌웨어가 10-bit ADC 결과를 register 에 그대로 쓴다면,
    ///     우리 i16 ±32767 가정은 wrong → 변환식이 ÷ 32 만큼 부정확.
    ///
    /// **검증 방법**: Mac UI 의 `PilotImuRawDiagnosticsSheet` 의 "정지 측정" 으로
    /// accel Z 가 ~1.0g (raw ~16384 if 16-bit, ~512 if 10-bit) 인지 확인.
    /// - raw ~16384 → 16-bit signed 가정 OK. 변경 불필요.
    /// - raw ~512   → 10-bit ADC. 변환식 정정 필요 (raw - 512) × scale.
    ///
    /// 실 로봇에서 측정 전까지 이 코드는 "추정 변환" 이며 사용자에게도 "정적 tilt"
    /// 로 표시. v1.6 의 검증 결과에 따라 변환식 정정 예정.
    pub fn read_imu(&mut self) -> Result<ImuRaw> {
        // 12 byte 한 번 — GYRO_Z(38) → ACCEL_Z(48)+1.
        let buf = self.bus.read(CONTROLLER, cm_register::GYRO_Z, 12)?;
        if buf.len() < 12 {
            return Err(crate::error::Error::Other(
                "IMU read returned fewer than 12 bytes".into(),
            ));
        }
        Ok(ImuRaw {
            gyro_z: i16::from_le_bytes([buf[0], buf[1]]),
            gyro_y: i16::from_le_bytes([buf[2], buf[3]]),
            gyro_x: i16::from_le_bytes([buf[4], buf[5]]),
            accel_x: i16::from_le_bytes([buf[6], buf[7]]),
            accel_y: i16::from_le_bytes([buf[8], buf[9]]),
            accel_z: i16::from_le_bytes([buf[10], buf[11]]),
        })
    }

    /// 가슴 LED 비트 (3개).
    pub fn set_chest_led(&mut self, bits: u8) -> Result<()> {
        self.bus.write(CONTROLLER, cm_register::LED_PANEL, &[bits])
    }

    /// ID 1..=20 PING sweep + JointMap 자동 선택.
    ///
    /// 공식 매핑(`OP2.robot`): ID 7~20 모두 응답이어야 함.
    /// LegacyOp1: 7..=10 무응답 + 11..=18 응답 (발목 ID 미정).
    /// 누락 ID가 있으면 `missing_ids` 로 보고 — 사용자에게 마법사·경고 노출.
    pub fn detect_joint_map(&mut self) -> DetectResult {
        let mut responding = Vec::new();
        for id in 1..=20u8 {
            if self.bus.ping(id).is_ok() {
                responding.push(id);
            }
        }
        let map = JointMap::detect_from_ping(&responding);
        let expected_canonical: Vec<u8> = (1..=20).collect();
        let missing: Vec<u8> = expected_canonical
            .into_iter()
            .filter(|id| !responding.contains(id))
            .collect();
        DetectResult {
            responding_ids: responding,
            missing_ids: missing,
            map,
        }
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

    #[test]
    fn controller_label_recognises_cm730_and_cm740() {
        let snap_730 = BoardSnapshot {
            model_number: 730,
            version: 1,
            voltage_raw: 118,
            button: 0,
        };
        assert!(snap_730.controller_label().contains("CM-730"));

        let snap_740 = BoardSnapshot {
            model_number: 740,
            version: 1,
            voltage_raw: 118,
            button: 0,
        };
        assert!(snap_740.controller_label().contains("CM-740"));
    }

    #[test]
    fn detect_joint_map_recognises_official_layout() {
        use crate::joint::JointMapKind;
        let mut bus = Bus::new(LoopbackBus::default());
        // ID 1..=20 모두 응답하도록 큐.
        for id in 1..=20u8 {
            bus.port_mut().queue_read(&status_bytes(id, 0, &[]));
        }
        let mut cm = CmController::new(&mut bus);
        let result = cm.detect_joint_map();
        // 응답 ID는 캐논 매핑 detect 로직에 따라 Official 판정.
        assert_eq!(result.map.kind, JointMapKind::Official);
        // 응답 ID 수 ≥ 1 (LoopbackBus 의 단순 FIFO 특성으로 매칭 부정확하지만
        // 적어도 detect가 panic 없이 동작하는지 확인).
        assert!(!result.responding_ids.is_empty());
    }
}
