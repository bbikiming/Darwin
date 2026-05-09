//! CM-730 / CM-740 컨트롤러 추상화.
//!
//! 두 보드는 펌웨어 ABI 호환이라 같은 enum으로 다루되, 분기 사례에서
//! `model()`로 구분.

use serde::{Deserialize, Serialize};

/// 어느 sub-controller PCB냐.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ControllerModel {
    /// OP1 1세대.
    Cm730,
    /// OP2 2세대.
    Cm740,
}

/// 컨트롤 테이블 주소 (CM-730 / CM-740 공통).
pub mod cm_register {
    /// EEPROM
    pub const MODEL_NUMBER: u8 = 0;
    /// EEPROM
    pub const VERSION: u8 = 2;
    /// EEPROM
    pub const ID: u8 = 3;
    /// EEPROM
    pub const BAUD_RATE: u8 = 4;
    /// EEPROM
    pub const RETURN_DELAY_TIME: u8 = 5;

    /// RAM — Dynamixel power gate.
    pub const DXL_POWER: u8 = 24;
    /// RAM — chest panel LED.
    pub const LED_PANEL: u8 = 25;
    /// RAM — head LED RGB565 (low byte).
    pub const LED_HEAD: u8 = 26;
    /// RAM — eye LED RGB565 (low byte).
    pub const LED_EYE: u8 = 28;
    /// RAM — button bits (mode/start).
    pub const BUTTON: u8 = 30;
    /// RAM — gyro Z low.
    pub const GYRO_Z: u8 = 38;
    /// RAM — gyro Y low.
    pub const GYRO_Y: u8 = 40;
    /// RAM — gyro X low.
    pub const GYRO_X: u8 = 42;
    /// RAM — accel X low.
    pub const ACCEL_X: u8 = 44;
    /// RAM — accel Y low.
    pub const ACCEL_Y: u8 = 46;
    /// RAM — accel Z low.
    pub const ACCEL_Z: u8 = 48;
    /// RAM — battery voltage 0.1 V.
    pub const VOLTAGE: u8 = 50;
}

/// MX-28T 컨트롤 테이블 주소.
pub mod mx28_register {
    /// EEPROM
    pub const MODEL_NUMBER: u8 = 0;
    /// EEPROM
    pub const ID: u8 = 3;
    /// EEPROM
    pub const BAUD_RATE: u8 = 4;
    /// EEPROM
    pub const CW_ANGLE_LIMIT: u8 = 6;
    /// EEPROM
    pub const CCW_ANGLE_LIMIT: u8 = 8;

    /// RAM — torque enable.
    pub const TORQUE_ENABLE: u8 = 24;
    /// RAM — LED.
    pub const LED: u8 = 25;
    /// RAM — D gain.
    pub const D_GAIN: u8 = 26;
    /// RAM — I gain.
    pub const I_GAIN: u8 = 27;
    /// RAM — P gain.
    pub const P_GAIN: u8 = 28;
    /// RAM — goal position low.
    pub const GOAL_POSITION: u8 = 30;
    /// RAM — moving speed low.
    pub const MOVING_SPEED: u8 = 32;
    /// RAM — torque limit low.
    pub const TORQUE_LIMIT: u8 = 34;
    /// RAM — present position low (12-bit).
    pub const PRESENT_POSITION: u8 = 36;
    /// RAM — present speed low.
    pub const PRESENT_SPEED: u8 = 38;
    /// RAM — present load low.
    pub const PRESENT_LOAD: u8 = 40;
    /// RAM — present voltage 0.1 V.
    pub const PRESENT_VOLTAGE: u8 = 42;
    /// RAM — present temperature °C.
    pub const PRESENT_TEMPERATURE: u8 = 43;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn controller_model_serde() {
        let m = ControllerModel::Cm740;
        let s = serde_json::to_string(&m).unwrap();
        assert_eq!(s, "\"Cm740\"");
        assert_eq!(serde_json::from_str::<ControllerModel>(&s).unwrap(), m);
    }
}
