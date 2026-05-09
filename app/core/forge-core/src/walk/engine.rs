//! Walk engine — phase 진행 + sin파 발 궤적 생성.
//!
//! MVP: 다리 IK는 간단한 mapping. 실 IK는 후속 사이클.

use std::f64::consts::PI;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::params::WalkParams;

/// 워킹 명령.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct WalkCommand {
    /// 전후 보폭 (m / cycle). 양수 = 전진.
    pub x_amplitude: f64,
    /// 좌우 보폭 (m / cycle).
    pub y_amplitude: f64,
    /// 회전 (rad / cycle). 양수 = 좌측.
    pub a_amplitude: f64,
    /// 워킹 활성화.
    pub enabled: bool,
}

impl Default for WalkCommand {
    fn default() -> Self {
        Self {
            x_amplitude: 0.0,
            y_amplitude: 0.0,
            a_amplitude: 0.0,
            enabled: false,
        }
    }
}

/// 워킹의 phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalkPhase {
    /// PHASE0 — 시작 직전 (정지).
    Phase0,
    /// PHASE1 — 첫 발 떼기.
    Phase1,
    /// PHASE2 — 양 발 지지 (DSP).
    Phase2,
    /// PHASE3 — 다음 발 떼기.
    Phase3,
}

/// 한 사이클의 발 궤적 출력.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FootTargets {
    /// 좌측 발 위치 (x, y, z) — 골반 좌표계.
    pub left: [f64; 3],
    /// 우측 발 위치 (x, y, z) — 골반 좌표계.
    pub right: [f64; 3],
}

/// 워크 엔진 상태.
pub struct WalkEngine {
    /// 파라미터.
    pub params: WalkParams,
    /// 현재 명령.
    pub command: WalkCommand,
    /// 사이클 시작부터 누적된 시간 (ms).
    pub elapsed_ms: f64,
}

impl WalkEngine {
    /// 새 엔진. 기본 params, 정지 명령.
    pub fn new() -> Self {
        Self::with_params(WalkParams::default())
    }

    /// 커스텀 params.
    pub fn with_params(params: WalkParams) -> Self {
        Self {
            params,
            command: WalkCommand::default(),
            elapsed_ms: 0.0,
        }
    }

    /// 시간 진행.
    pub fn tick(&mut self, dt: Duration) {
        if !self.command.enabled {
            self.elapsed_ms = 0.0;
            return;
        }
        self.elapsed_ms += dt.as_secs_f64() * 1000.0;
        if self.elapsed_ms >= self.params.period_time_ms {
            self.elapsed_ms -= self.params.period_time_ms;
        }
    }

    /// 현재 phase.
    pub fn phase(&self) -> WalkPhase {
        if !self.command.enabled {
            return WalkPhase::Phase0;
        }
        let p = &self.params;
        if self.elapsed_ms < p.phase1_end_ms() {
            WalkPhase::Phase1
        } else if self.elapsed_ms < p.phase2_end_ms() {
            WalkPhase::Phase2
        } else {
            WalkPhase::Phase3
        }
    }

    /// 현재 시점의 발 궤적.
    ///
    /// MVP: simple sin파. 좌발은 PI offset.
    pub fn foot_targets(&self) -> FootTargets {
        let p = &self.params;
        let cmd = self.command;
        if !cmd.enabled {
            return FootTargets {
                left: [p.x_offset, p.y_offset, -p.z_offset],
                right: [p.x_offset, -p.y_offset, -p.z_offset],
            };
        }
        let t = self.elapsed_ms / p.period_time_ms; // 0..1
        let theta = 2.0 * PI * t;
        let z_swing = p.foot_height * (theta + PI / 2.0).sin().max(0.0); // 위로 들기 절반 사이클
        let x_swing = cmd.x_amplitude * theta.cos();
        let y_swing = cmd.y_amplitude * theta.cos();

        // 좌·우 발은 반대 위상
        FootTargets {
            left: [
                p.x_offset + x_swing,
                p.y_offset + y_swing,
                -p.z_offset + z_swing,
            ],
            right: [
                p.x_offset - x_swing,
                -p.y_offset - y_swing,
                -p.z_offset + p.foot_height * (theta - PI / 2.0).sin().max(0.0),
            ],
        }
    }
}

impl Default for WalkEngine {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_engine_returns_phase0_and_static_feet() {
        let e = WalkEngine::new();
        assert_eq!(e.phase(), WalkPhase::Phase0);
        let f = e.foot_targets();
        // 좌·우 발은 y_offset 부호만 다름
        assert!((f.left[1] - (-f.right[1])).abs() < 1e-9);
    }

    #[test]
    fn enabled_engine_progresses_phase() {
        let mut e = WalkEngine::new();
        e.command.enabled = true;

        // PHASE1 (시작)
        assert_eq!(e.phase(), WalkPhase::Phase1);

        // 사이클의 60%까지 진행
        e.tick(Duration::from_millis(360));
        let phase_after = e.phase();
        // 360 ms / 600 ms = 0.6 → DSP는 0.45..0.55, 그 후 PHASE3
        assert_eq!(phase_after, WalkPhase::Phase3);
    }

    #[test]
    fn elapsed_wraps_at_period_end() {
        let mut e = WalkEngine::new();
        e.command.enabled = true;
        e.tick(Duration::from_millis(600)); // 1 cycle 정확히
                                            // 600 ms 도달 시 wrap
        assert!(e.elapsed_ms < 1.0);
    }

    #[test]
    fn foot_height_within_param_max() {
        let mut e = WalkEngine::new();
        e.command = WalkCommand {
            enabled: true,
            x_amplitude: 0.04,
            y_amplitude: 0.0,
            a_amplitude: 0.0,
        };
        // 사이클 전체에서 z의 최대값이 foot_height를 넘지 않음
        let mut max_z_left = f64::MIN;
        for _ in 0..60 {
            e.tick(Duration::from_millis(10));
            let f = e.foot_targets();
            if f.left[2] > max_z_left {
                max_z_left = f.left[2];
            }
        }
        let p = WalkParams::default();
        // z = -z_offset + foot_height * sin → max = -z_offset + foot_height
        assert!(max_z_left <= -p.z_offset + p.foot_height + 1e-6);
    }
}
