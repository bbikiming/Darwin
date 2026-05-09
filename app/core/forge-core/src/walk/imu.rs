//! IMU 융합 — gyroscope + accelerometer → roll / pitch.
//!
//! complementary filter (1차). 게인 0.98 = 자이로 weight, 0.02 = 가속도.

use std::time::Duration;

/// 한 IMU 샘플 (CM 보드에서 BULK_READ).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ImuSample {
    /// 자이로 (rad/s).
    pub gyro: [f64; 3],
    /// 가속도 (m/s²).
    pub accel: [f64; 3],
}

/// complementary filter 상태.
#[derive(Debug, Clone, Copy)]
pub struct ComplementaryFilter {
    /// 자이로 weight 0..1. 보통 0.98.
    pub gyro_weight: f64,
    /// 추정 roll (rad).
    pub roll: f64,
    /// 추정 pitch (rad).
    pub pitch: f64,
}

impl Default for ComplementaryFilter {
    fn default() -> Self {
        Self {
            gyro_weight: 0.98,
            roll: 0.0,
            pitch: 0.0,
        }
    }
}

impl ComplementaryFilter {
    /// 한 샘플 처리. dt는 마지막 update 이후 시간.
    pub fn update(&mut self, sample: ImuSample, dt: Duration) {
        let dt_s = dt.as_secs_f64();

        // accelerometer-derived roll/pitch (정적 가정 — 가속도가 중력만)
        let ax = sample.accel[0];
        let ay = sample.accel[1];
        let az = sample.accel[2];
        let acc_roll = ay.atan2(az);
        let acc_pitch = (-ax).atan2((ay * ay + az * az).sqrt());

        // gyro 적분
        let gx = sample.gyro[0];
        let gy = sample.gyro[1];
        let gyro_roll = self.roll + gx * dt_s;
        let gyro_pitch = self.pitch + gy * dt_s;

        // 가중 평균
        let w = self.gyro_weight;
        self.roll = w * gyro_roll + (1.0 - w) * acc_roll;
        self.pitch = w * gyro_pitch + (1.0 - w) * acc_pitch;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filter_at_rest_converges_to_zero() {
        let mut f = ComplementaryFilter::default();
        // 100 Hz, 1초 동안 정지 (가속도 = -g 만)
        for _ in 0..100 {
            f.update(
                ImuSample {
                    gyro: [0.0; 3],
                    accel: [0.0, 0.0, 9.81],
                },
                Duration::from_millis(10),
            );
        }
        assert!(f.roll.abs() < 0.01); // < 0.5°
        assert!(f.pitch.abs() < 0.01);
    }

    #[test]
    fn filter_responds_to_gyro_rotation() {
        let mut f = ComplementaryFilter {
            gyro_weight: 1.0, // 자이로만 (가속도 무시)
            ..Default::default()
        };
        // x축 자이로 1 rad/s, 0.5초
        for _ in 0..50 {
            f.update(
                ImuSample {
                    gyro: [1.0, 0.0, 0.0],
                    accel: [0.0, 0.0, 9.81],
                },
                Duration::from_millis(10),
            );
        }
        assert!((f.roll - 0.5).abs() < 0.05);
    }
}
