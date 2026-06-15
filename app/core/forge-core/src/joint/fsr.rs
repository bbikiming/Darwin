//! ROBOTIS-OP2 FSR (Force Sensitive Resistor) board reader.
//!
//! 두 개의 FSR board (left foot ID 112, right foot ID 111) 가 발 sole 의 4 cell 압력 +
//! center-of-pressure (X, Y) 를 측정. ZMP-기반 보행 안정성 분석의 객관 지표.
//!
//! Register layout (FSR.h, firmware 0x11):
//! ```text
//! addr  size  field
//! 26..27  2  P_FSR1 (front-left of each foot)  -- 0..1023 ADC
//! 28..29  2  P_FSR2 (front-right)
//! 30..31  2  P_FSR3 (rear-right)
//! 32..33  2  P_FSR4 (rear-left)
//! 34      1  P_FSR_X  (-127..127, 사용자 입장 좌측=음수)
//! 35      1  P_FSR_Y  (-127..127, 앞=음수)
//! ```
//!
//! ID 가 응답 안 하면 board 미장착 (개발용 robot 일부 만). caller 가 fallback 처리.

use crate::dynamixel::Bus;
use crate::error::Result;
use crate::joint::special::{FSR_LEFT, FSR_RIGHT};
use crate::serial::SerialPort;

/// FSR 한 발의 4 cell + center 측정.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FsrReading {
    /// Dynamixel ID (111=right, 112=left).
    pub id: u8,
    /// 4 cell 압력 raw (0..1023). \[front-left, front-right, rear-right, rear-left\].
    /// 큰 값 = 더 큰 압력.
    pub cells: [u16; 4],
    /// 중심점 X (사용자 시점 좌측=음수, -127..127). 0 = 발 중앙.
    pub center_x: i8,
    /// 중심점 Y (앞=음수, -127..127). 0 = 발 중앙.
    pub center_y: i8,
}

impl FsrReading {
    /// 4 cell 합 — 발 total 압력 (raw). higher = robot weight 가 그 발에 더 실림.
    pub fn total_pressure(&self) -> u32 {
        self.cells.iter().map(|&c| c as u32).sum()
    }
}

impl<P: SerialPort> Bus<P> {
    /// 좌측 발 FSR (ID 112) read. board 미장착 또는 timeout 시 `Err`.
    pub fn read_fsr_left(&mut self) -> Result<FsrReading> {
        read_fsr_at(self, FSR_LEFT)
    }

    /// 우측 발 FSR (ID 111) read.
    pub fn read_fsr_right(&mut self) -> Result<FsrReading> {
        read_fsr_at(self, FSR_RIGHT)
    }
}

/// 26..35 (10 bytes) 한 burst read.
fn read_fsr_at<P: SerialPort>(bus: &mut Bus<P>, id: u8) -> Result<FsrReading> {
    let data = bus.read(id, 26, 10)?;
    if data.len() != 10 {
        return Err(crate::error::Error::Other(format!(
            "FSR id={} read short ({} bytes, expected 10)",
            id,
            data.len()
        )));
    }
    let cells = [
        u16::from_le_bytes([data[0], data[1]]),
        u16::from_le_bytes([data[2], data[3]]),
        u16::from_le_bytes([data[4], data[5]]),
        u16::from_le_bytes([data[6], data[7]]),
    ];
    Ok(FsrReading {
        id,
        cells,
        center_x: data[8] as i8,
        center_y: data[9] as i8,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn total_pressure_sums_cells() {
        let r = FsrReading {
            id: 111,
            cells: [100, 200, 300, 400],
            center_x: 0,
            center_y: 0,
        };
        assert_eq!(r.total_pressure(), 1000);
    }

    #[test]
    fn center_x_y_signed_bytes() {
        // raw byte 0x80 (128) → i8 -128 (사용자 시점 좌측 끝).
        let r = FsrReading {
            id: 112,
            cells: [0, 0, 0, 0],
            center_x: -128,
            center_y: 127,
        };
        assert_eq!(r.center_x, -128);
        assert_eq!(r.center_y, 127);
    }
}
