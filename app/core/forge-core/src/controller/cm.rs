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

/// CM-730/740 의 IMU raw — gyro X/Y/Z + accel X/Y/Z (10-bit ADC, unsigned).
///
/// **Sprint 18 v1.7 (2026-05-17) 정정**: ROBOTIS-OP2 v1.6.0 공식 펌웨어 oracle 확인 결과,
///   - `CM730::MakeWord` (CM730.cpp:666-675) — unsigned u16 zero-extend.
///   - `MotionManager` (MotionManager.cpp:73-74) — m_FBGyroCenter = 512, m_RLGyroCenter = 512.
///   - `MotionStatus` (MotionStatus.h:27-28) — FALLEN_F_LIMIT = 390, FALLEN_B_LIMIT = 580 → 10-bit (0-1023) 범위.
///   - 우리 종전 i16 signed + ±32767 scaling 가정은 **잘못**. raw 512 - 0 = 512 → atan2(512,512) ≈ 45° false tilt.
///
/// **공식 register 매핑** (ROBOTIS-OP2 CM730.h:105-116):
///   - 38 (GYRO_Z), 40 (GYRO_Y), 42 (GYRO_X) — gyro 6 byte 연속.
///   - 44 (ACCEL_X), 46 (ACCEL_Y), 48 (ACCEL_Z) — accel 6 byte 연속.
///
/// **Axis convention** (MotionManager.cpp:246-249):
///   - `RL_ACCEL = ReadWord(P_ACCEL_X_L)` — Roll(좌우) 축 = X.
///   - `FB_ACCEL = ReadWord(P_ACCEL_Y_L)` — Forward/Back(앞뒤) 축 = Y.
///   - `RL_GYRO = ReadWord(P_GYRO_X_L) - m_RLGyroCenter` (512).
///   - `FB_GYRO = ReadWord(P_GYRO_Y_L) - m_FBGyroCenter` (512).
///
/// **Tilt 근사**: roll = atan2(ax_centered, ‖(ay,az)‖), pitch = atan2(ay_centered, ‖(ax,az)‖).
/// atan2 비율은 LSB scale 에 무관 → centered 값으로 그대로 사용 가능.
///
/// # 부호 컨벤션 주의 (v1.11.3, 2026-05-18)
///
/// `pitch_degrees()` / `roll_degrees()` 의 단위 테스트는 가공된 raw 값 (예: `accel_y=612,
/// accel_z=685`) 으로 "+30° = 앞기울" 을 가정 (cm.rs line 426~449). 그러나 **실 robot
/// 의 IMU 마운트 방향 / firmware ADC 변환 / Swift 측 polling 단계**에서 부호가 반대로
/// 나올 수 있음.
///
/// **2026-05-18 실 robot 데이터 (Swift `imuPitchDeg`)**: 앞기울 자세에서 `imuPitchDeg`
/// 가 100% 음수로 관찰됨 (`-10°` 안정, `-31°` fall 시도). 즉 Swift 단에서 보는 부호는
/// "음수 = 앞기울" — 본 Rust 단위 테스트의 컨벤션 (`+30°` = 앞기울) 과 반대.
///
/// **정합 책임**: Rust 단계의 부호 변환 (있다면) 또는 Swift 단계의 정규화 변수
/// (`BalancePitchInputConvention.negateForwardIsNegative`) 둘 중 한 곳에서 정합 시킴.
/// 현재 (v1.11.3) 는 Swift 측 opt-in 정규화 — `BalanceExperimentConfig.pitchInputConvention`
/// 으로 사용자가 P1.0 정적 캘리브레이션 결과 보고 명시 선택.
///
/// **본 단위 테스트 (line 426~449) 는 raw axis convention 의 기준점 유지용**이고,
/// 실 robot 보정의 부호 정합 책임은 Swift 측에 있음.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImuRaw {
    /// Gyro X 10-bit ADC raw (0..1023, center 512). RL_GYRO (roll-rate).
    pub gyro_x: u16,
    /// Gyro Y 10-bit ADC raw. FB_GYRO (pitch-rate).
    pub gyro_y: u16,
    /// Gyro Z 10-bit ADC raw. Yaw-rate.
    pub gyro_z: u16,
    /// Accel X 10-bit ADC raw. RL_ACCEL (lateral / roll axis).
    pub accel_x: u16,
    /// Accel Y 10-bit ADC raw. FB_ACCEL (sagittal / pitch axis).
    pub accel_y: u16,
    /// Accel Z 10-bit ADC raw. Up axis (1g 직립 시 ~512+offset).
    pub accel_z: u16,
}

impl ImuRaw {
    /// CM-730/740 IMU ADC center (10-bit). ROBOTIS-OP2 MotionManager.cpp:73-74 = 512.
    pub const ADC_CENTER: u16 = 512;

    /// L3G4200D 계열 ±2000dps (CM-740 IMU 일반적 chip). 10-bit ADC → ±512 LSB span → ±2000°/s.
    /// → 1 LSB ≈ 3.91 °/s. **Note**: bench-calibration 전 provisional.
    pub const GYRO_DPS_PER_LSB: f32 = 2000.0 / 512.0;

    /// ADXL345 계열 ±4g 또는 ±2g (chip variant 따라 다름). 10-bit ADC center 512.
    /// 1g ≈ 256 LSB (ROBOTIS legacy code 의 1g offset 약 200 ~ 256 관찰). provisional.
    pub const ACCEL_G_PER_LSB: f32 = 1.0 / 256.0;

    /// Gyro X centered (raw - 512). NaN 없이 안전.
    pub fn gyro_x_centered(&self) -> f32 {
        self.gyro_x as f32 - Self::ADC_CENTER as f32
    }
    /// Gyro Y centered.
    pub fn gyro_y_centered(&self) -> f32 {
        self.gyro_y as f32 - Self::ADC_CENTER as f32
    }
    /// Gyro Z centered.
    pub fn gyro_z_centered(&self) -> f32 {
        self.gyro_z as f32 - Self::ADC_CENTER as f32
    }
    /// Accel X centered.
    pub fn accel_x_centered(&self) -> f32 {
        self.accel_x as f32 - Self::ADC_CENTER as f32
    }
    /// Accel Y centered.
    pub fn accel_y_centered(&self) -> f32 {
        self.accel_y as f32 - Self::ADC_CENTER as f32
    }
    /// Accel Z centered.
    pub fn accel_z_centered(&self) -> f32 {
        self.accel_z as f32 - Self::ADC_CENTER as f32
    }

    /// Gyro X (°/s) — provisional. Use `gyro_x_centered()` for ratio-based logic.
    pub fn gyro_x_dps(&self) -> f32 {
        self.gyro_x_centered() * Self::GYRO_DPS_PER_LSB
    }
    /// Gyro Y (°/s).
    pub fn gyro_y_dps(&self) -> f32 {
        self.gyro_y_centered() * Self::GYRO_DPS_PER_LSB
    }
    /// Gyro Z (°/s).
    pub fn gyro_z_dps(&self) -> f32 {
        self.gyro_z_centered() * Self::GYRO_DPS_PER_LSB
    }
    /// Accel X (g).
    pub fn accel_x_g(&self) -> f32 {
        self.accel_x_centered() * Self::ACCEL_G_PER_LSB
    }
    /// Accel Y (g).
    pub fn accel_y_g(&self) -> f32 {
        self.accel_y_centered() * Self::ACCEL_G_PER_LSB
    }
    /// Accel Z (g).
    pub fn accel_z_g(&self) -> f32 {
        self.accel_z_centered() * Self::ACCEL_G_PER_LSB
    }

    /// Roll (도) — 좌우 기울기. ROBOTIS RL = X axis.
    ///
    /// Formula: `atan2(ax_centered, sqrt(ay² + az²))`. atan2 비율 → LSB scale 무관.
    /// 직립 시 (ax≈0, ay≈0, az≈+offset) → atan2(0, offset) = 0°. ✓
    pub fn roll_degrees(&self) -> f32 {
        let ax = self.accel_x_centered();
        let ay = self.accel_y_centered();
        let az = self.accel_z_centered();
        let denom = (ay.powi(2) + az.powi(2)).sqrt();
        if denom < 1.0 {
            0.0
        } else {
            ax.atan2(denom) * 180.0 / std::f32::consts::PI
        }
    }

    /// Pitch (도) — 앞뒤 기울기. ROBOTIS FB = Y axis.
    ///
    /// Formula: `atan2(ay_centered, sqrt(ax² + az²))`.
    pub fn pitch_degrees(&self) -> f32 {
        let ax = self.accel_x_centered();
        let ay = self.accel_y_centered();
        let az = self.accel_z_centered();
        let denom = (ax.powi(2) + az.powi(2)).sqrt();
        if denom < 1.0 {
            0.0
        } else {
            ay.atan2(denom) * 180.0 / std::f32::consts::PI
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

    /// IMU raw 6 channels read — Phase D3 (Sprint 18) → v1.7 정정 (2026-05-17).
    ///
    /// CM-730/740 의 register 38 (GYRO_Z low) 부터 12 byte 연속 read.
    /// 순서: GYRO_Z, GYRO_Y, GYRO_X, ACCEL_X, ACCEL_Y, ACCEL_Z (각 2 byte little-endian).
    /// 단일 burst read 라 forge-bridge ~1ms 응답.
    ///
    /// # Word composition — unsigned u16 (ROBOTIS CM730::MakeWord 일치)
    ///
    /// CM730.cpp:666-675 의 `MakeWord` 는 `(highbyte << 8) | lowbyte` 를 unsigned short 로
    /// 합성 후 int 로 zero-extend. 우리 종전 `i16::from_le_bytes` 는 sign-extend 라 같은
    /// 비트 패턴이라도 의미적으로 다름. 10-bit ADC 결과(0..1023)는 bit-15=0 이라 수치는
    /// 동일하지만 타입 안전성 차원에서 u16 으로 통일.
    pub fn read_imu(&mut self) -> Result<ImuRaw> {
        // 12 byte 한 번 — GYRO_Z(38) → ACCEL_Z(48)+1.
        let buf = self.bus.read(CONTROLLER, cm_register::GYRO_Z, 12)?;
        if buf.len() < 12 {
            return Err(crate::error::Error::Other(
                "IMU read returned fewer than 12 bytes".into(),
            ));
        }
        Ok(ImuRaw {
            gyro_z: u16::from_le_bytes([buf[0], buf[1]]),
            gyro_y: u16::from_le_bytes([buf[2], buf[3]]),
            gyro_x: u16::from_le_bytes([buf[4], buf[5]]),
            accel_x: u16::from_le_bytes([buf[6], buf[7]]),
            accel_y: u16::from_le_bytes([buf[8], buf[9]]),
            accel_z: u16::from_le_bytes([buf[10], buf[11]]),
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
    fn imu_raw_centered_subtracts_512_per_robotis_convention() {
        // ROBOTIS-OP2 MotionManager.cpp:73 → m_FBGyroCenter = 512.
        let imu = ImuRaw {
            gyro_z: 512,
            gyro_y: 512,
            gyro_x: 512,
            accel_x: 512,
            accel_y: 512,
            accel_z: 512,
        };
        assert!(imu.gyro_x_centered().abs() < 1e-3);
        assert!(imu.gyro_y_centered().abs() < 1e-3);
        assert!(imu.accel_x_centered().abs() < 1e-3);
        assert!(imu.accel_z_centered().abs() < 1e-3);
    }

    #[test]
    fn imu_raw_standing_upright_returns_zero_tilt() {
        // 직립: ax=512, ay=512, az=712 (1g 다운 = +200 LSB offset from 512 center).
        // 기존 i16-signed 가정 시 atan2(512,512) ≈ 45° false tilt 발생했었음.
        let imu = ImuRaw {
            gyro_z: 512,
            gyro_y: 512,
            gyro_x: 512,
            accel_x: 512,
            accel_y: 512,
            accel_z: 712,
        };
        assert!(
            imu.roll_degrees().abs() < 0.5,
            "roll should be ~0° upright, got {}",
            imu.roll_degrees()
        );
        assert!(
            imu.pitch_degrees().abs() < 0.5,
            "pitch should be ~0° upright, got {}",
            imu.pitch_degrees()
        );
    }

    #[test]
    fn imu_raw_roll_uses_x_axis_per_robotis_rl_accel() {
        // ROBOTIS: RL_ACCEL = P_ACCEL_X_L → Roll uses X axis (NOT Y as in old code).
        // 좌로 30° 기울임: ax = 512 + 200*sin(30°) ≈ 612, az = 512 + 200*cos(30°) ≈ 685
        let imu = ImuRaw {
            gyro_z: 512,
            gyro_y: 512,
            gyro_x: 512,
            accel_x: 612, // +100 LSB
            accel_y: 512,
            accel_z: 685, // +173 LSB
        };
        let r = imu.roll_degrees();
        assert!(
            (r - 30.0).abs() < 1.5,
            "roll for 30° left-tilt should be ~30°, got {}",
            r
        );
        // Pitch 는 변화 없어야 함.
        assert!(
            imu.pitch_degrees().abs() < 1.0,
            "pitch should stay 0° during pure roll, got {}",
            imu.pitch_degrees()
        );
    }

    #[test]
    fn imu_raw_pitch_uses_y_axis_per_robotis_fb_accel() {
        // ROBOTIS: FB_ACCEL = P_ACCEL_Y_L → Pitch uses Y axis.
        // 앞으로 30° 기울임: ay = +100 LSB, az = +173 LSB.
        let imu = ImuRaw {
            gyro_z: 512,
            gyro_y: 512,
            gyro_x: 512,
            accel_x: 512,
            accel_y: 612,
            accel_z: 685,
        };
        let p = imu.pitch_degrees();
        assert!(
            (p - 30.0).abs() < 1.5,
            "pitch for 30° forward-tilt should be ~30°, got {}",
            p
        );
        assert!(
            imu.roll_degrees().abs() < 1.0,
            "roll should stay 0° during pure pitch, got {}",
            imu.roll_degrees()
        );
    }

    #[test]
    fn imu_raw_zero_input_does_not_nan() {
        // All raw zero (uninitialized / pre-boot) → centered (-512, -512, -512).
        // sqrt(ay²+az²) = sqrt(262144+262144) > 1.0 → no div-by-zero.
        let imu = ImuRaw {
            gyro_z: 0,
            gyro_y: 0,
            gyro_x: 0,
            accel_x: 0,
            accel_y: 0,
            accel_z: 0,
        };
        assert!(imu.roll_degrees().is_finite());
        assert!(imu.pitch_degrees().is_finite());
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
