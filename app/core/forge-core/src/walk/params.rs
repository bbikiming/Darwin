//! Walking parameters — `op2_walking_module/config/param.yaml` 1:1.

use serde::{Deserialize, Serialize};

/// 워크 엔진 파라미터. SI 단위.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct WalkParams {
    /// 전후 오프셋 (m).
    pub x_offset: f64,
    /// 좌우 오프셋 (m).
    pub y_offset: f64,
    /// 직립 시 발 들기 (m).
    pub z_offset: f64,
    /// 자세 보정 roll (rad).
    pub roll_offset: f64,
    /// 자세 보정 pitch (rad).
    pub pitch_offset: f64,
    /// 자세 보정 yaw (rad).
    pub yaw_offset: f64,
    /// 정적 자세 hip pitch 보정 (deg).
    pub hip_pitch_offset_deg: f64,

    /// 한 보행 사이클 (ms).
    pub period_time_ms: f64,
    /// double-support phase 비율 0..1.
    pub dsp_ratio: f64,
    /// 전후 보폭 비율.
    pub step_forward_back_ratio: f64,
    /// 발 들리는 최대 높이 (m).
    pub foot_height: f64,
    /// 좌우 발 흔들림 (m).
    pub swing_right_left: f64,
    /// 상하 본체 흔들림 (m).
    pub swing_top_down: f64,
    /// 골반 보정각 (deg).
    pub pelvis_offset_deg: f64,

    /// 팔이 다리에 비례 흔들리는 게인.
    pub arm_swing_gain: f64,

    /// IMU roll → hip 보정 게인.
    pub balance_hip_roll_gain: f64,
    /// IMU pitch → knee 보정 게인.
    pub balance_knee_gain: f64,
    /// IMU roll → ankle 보정 게인.
    pub balance_ankle_roll_gain: f64,
    /// IMU pitch → ankle 보정 게인.
    pub balance_ankle_pitch_gain: f64,

    /// MX-28 P gain.
    pub p_gain: u8,
    /// MX-28 I gain.
    pub i_gain: u8,
    /// MX-28 D gain.
    pub d_gain: u8,
}

impl Default for WalkParams {
    /// `op2_walking_module/config/param.yaml` 직접 복사.
    fn default() -> Self {
        Self {
            x_offset: -0.010,
            y_offset: 0.005,
            z_offset: 0.020,
            roll_offset: 0.0,
            pitch_offset: 0.0,
            yaw_offset: 0.0,
            hip_pitch_offset_deg: 13.0,
            period_time_ms: 600.0,
            dsp_ratio: 0.1,
            step_forward_back_ratio: 0.28,
            foot_height: 0.04,
            swing_right_left: 0.020,
            swing_top_down: 0.005,
            pelvis_offset_deg: 3.0,
            arm_swing_gain: 1.5,
            balance_hip_roll_gain: 0.5,
            balance_knee_gain: 0.3,
            balance_ankle_roll_gain: 1.0,
            balance_ankle_pitch_gain: 0.9,
            p_gain: 32,
            i_gain: 0,
            d_gain: 0,
        }
    }
}

impl WalkParams {
    /// SSP(single-support phase) 비율.
    pub fn ssp_ratio(&self) -> f64 {
        1.0 - self.dsp_ratio
    }

    /// PHASE1 종료 시점 (ms).
    pub fn phase1_end_ms(&self) -> f64 {
        self.ssp_ratio() * self.period_time_ms / 2.0
    }

    /// PHASE2 종료 시점 (ms).
    pub fn phase2_end_ms(&self) -> f64 {
        self.phase1_end_ms() + self.dsp_ratio * self.period_time_ms
    }

    /// PHASE3 종료 시점 (ms).
    pub fn phase3_end_ms(&self) -> f64 {
        self.phase2_end_ms() + self.ssp_ratio() * self.period_time_ms / 2.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_matches_param_yaml() {
        let p = WalkParams::default();
        assert!((p.period_time_ms - 600.0).abs() < 1e-9);
        assert!((p.dsp_ratio - 0.1).abs() < 1e-9);
        assert!((p.foot_height - 0.04).abs() < 1e-9);
        assert!((p.balance_ankle_pitch_gain - 0.9).abs() < 1e-9);
    }

    #[test]
    fn phase_endpoints_progress_in_order() {
        let p = WalkParams::default();
        assert!(p.phase1_end_ms() < p.phase2_end_ms());
        assert!(p.phase2_end_ms() < p.phase3_end_ms());
        // 마지막은 거의 period_time
        assert!((p.phase3_end_ms() - p.period_time_ms).abs() < 1e-6);
    }

    #[test]
    fn json_round_trip() {
        let p = WalkParams::default();
        let s = serde_json::to_string(&p).unwrap();
        let p2: WalkParams = serde_json::from_str(&s).unwrap();
        assert_eq!(p, p2);
    }
}
