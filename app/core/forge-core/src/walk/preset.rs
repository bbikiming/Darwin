//! Walk Lab — 비전문가용 보행 프리셋.
//!
//! Sprint 14 후보. ROBOTIS-OP2 `op2_walking_module/config/param.yaml`
//! (period_time=600ms, foot_height=0.04m, dsp_ratio=0.1) 기본값을 변형한
//! 8 프리셋. 직관적 한국어 라벨 + 안전 등급 + 자동 stop 시간.
//!
//! 명세: `docs/walk-lab/V1_DESIGN.md`.
//!
//! > ⚠️ BLOCKER C3 (`docs/reports/AUDIT_MOTION_WALK_SYNTH.md`): 본 모듈은
//! > 단순 sin파 stub `WalkEngine` 위에 올라간다. 실 IK 완성 전까지는 시뮬
//! > 결과만 의미 있고, 실 모터 송출은 fastWalk / jog 같은 변형 파라미터에
//! > 대해 검증되지 않았다.
//!
//! 안전 등급:
//! - `Safe`    — period 600 ms 기본, 30~60s 권장
//! - `Caution` — period 단축 또는 회전 — confirm 권고
//! - `HighRisk` — `confirm_risk=true` 필수 + 15s 자동 stop

use serde::{Deserialize, Serialize};

use super::engine::WalkCommand;

/// 보행 안전 등급 — 카탈로그 모션의 `SafetyClass` 와 같은 3-tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum WalkSafety {
    /// 정상 운용 — 사용자 cradle 확인만으로 충분.
    Safe,
    /// 주의 — 노란 외곽선, 30s 자동 stop. confirm 권고.
    Caution,
    /// 위험 — 빨간 외곽선, `confirm_risk=true` 필수, 15s 자동 stop, IMU balance 모니터링 강제.
    HighRisk,
}

impl WalkSafety {
    /// UI sf-symbol 색 힌트 (DarwinForge `StatusPill` 매핑).
    pub fn color_hint(self) -> &'static str {
        match self {
            WalkSafety::Safe => "green",
            WalkSafety::Caution => "yellow",
            WalkSafety::HighRisk => "red",
        }
    }
}

/// 8개 보행 프리셋.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum WalkPreset {
    /// 정지 — 모든 amplitude = 0, enabled = false.
    Idle,
    /// 제자리 걸음 — foot 들기만 (x/y/a = 0, enabled = true).
    March,
    /// 천천히 — 보폭 1.5 cm/cycle. 600 ms 기준 ~2.5 cm/s.
    SlowWalk,
    /// 보통 — 보폭 2.5 cm/cycle.
    NormalWalk,
    /// 빠르게 — 보폭 3.5 cm/cycle, period 500 ms.
    FastWalk,
    /// 달리기 — 보폭 4 cm/cycle, period 450 ms. **HighRisk**.
    Jog,
    /// 좌회전 — 회전 +0.10 rad/cycle.
    TurnLeft,
    /// 우회전 — 회전 -0.10 rad/cycle.
    TurnRight,
}

impl WalkPreset {
    /// 모든 프리셋 — UI iteration 용.
    pub const ALL: [WalkPreset; 8] = [
        WalkPreset::Idle,
        WalkPreset::March,
        WalkPreset::SlowWalk,
        WalkPreset::NormalWalk,
        WalkPreset::FastWalk,
        WalkPreset::Jog,
        WalkPreset::TurnLeft,
        WalkPreset::TurnRight,
    ];

    /// 한국어 라벨 — UI 버튼 텍스트.
    pub fn label_ko(self) -> &'static str {
        match self {
            WalkPreset::Idle => "정지",
            WalkPreset::March => "제자리 걸음",
            WalkPreset::SlowWalk => "천천히 걷기",
            WalkPreset::NormalWalk => "보통 속도",
            WalkPreset::FastWalk => "빠르게 걷기",
            WalkPreset::Jog => "달리기",
            WalkPreset::TurnLeft => "좌회전",
            WalkPreset::TurnRight => "우회전",
        }
    }

    /// SF Symbol 이름 — SwiftUI `Image(systemName:)` 직결.
    pub fn icon(self) -> &'static str {
        match self {
            WalkPreset::Idle => "pause.circle.fill",
            WalkPreset::March => "figure.walk.motion",
            WalkPreset::SlowWalk => "tortoise.fill",
            WalkPreset::NormalWalk => "figure.walk",
            WalkPreset::FastWalk => "hare.fill",
            WalkPreset::Jog => "figure.run",
            WalkPreset::TurnLeft => "arrow.turn.up.left",
            WalkPreset::TurnRight => "arrow.turn.up.right",
        }
    }

    /// 보행 명령 (x/y/a amplitude + enabled).
    pub fn command(self) -> WalkCommand {
        match self {
            WalkPreset::Idle => WalkCommand {
                x_amplitude: 0.0,
                y_amplitude: 0.0,
                a_amplitude: 0.0,
                enabled: false,
            },
            WalkPreset::March => WalkCommand {
                x_amplitude: 0.0,
                y_amplitude: 0.0,
                a_amplitude: 0.0,
                enabled: true,
            },
            WalkPreset::SlowWalk => WalkCommand {
                x_amplitude: 0.015,
                y_amplitude: 0.0,
                a_amplitude: 0.0,
                enabled: true,
            },
            WalkPreset::NormalWalk => WalkCommand {
                x_amplitude: 0.025,
                y_amplitude: 0.0,
                a_amplitude: 0.0,
                enabled: true,
            },
            WalkPreset::FastWalk => WalkCommand {
                x_amplitude: 0.035,
                y_amplitude: 0.0,
                a_amplitude: 0.0,
                enabled: true,
            },
            WalkPreset::Jog => WalkCommand {
                x_amplitude: 0.040,
                y_amplitude: 0.0,
                a_amplitude: 0.0,
                enabled: true,
            },
            WalkPreset::TurnLeft => WalkCommand {
                x_amplitude: 0.010,
                y_amplitude: 0.0,
                a_amplitude: 0.10,
                enabled: true,
            },
            WalkPreset::TurnRight => WalkCommand {
                x_amplitude: 0.010,
                y_amplitude: 0.0,
                a_amplitude: -0.10,
                enabled: true,
            },
        }
    }

    /// 사이클 주기 (ms). ROBOTIS 기본은 600 ms. fast/jog 만 단축.
    pub fn period_ms(self) -> u32 {
        match self {
            WalkPreset::FastWalk => 500,
            WalkPreset::Jog => 450,
            _ => 600,
        }
    }

    /// 안전 등급.
    pub fn safety(self) -> WalkSafety {
        match self {
            WalkPreset::Idle | WalkPreset::March | WalkPreset::SlowWalk | WalkPreset::NormalWalk => {
                WalkSafety::Safe
            }
            WalkPreset::FastWalk | WalkPreset::TurnLeft | WalkPreset::TurnRight => {
                WalkSafety::Caution
            }
            WalkPreset::Jog => WalkSafety::HighRisk,
        }
    }

    /// 자동 stop 시간 (초). Idle은 ∞ (0 으로 표현).
    pub fn max_duration_secs(self) -> u32 {
        match self {
            WalkPreset::Idle => 0, // ∞
            WalkPreset::March => 30,
            WalkPreset::SlowWalk | WalkPreset::NormalWalk => 60,
            WalkPreset::FastWalk | WalkPreset::TurnLeft | WalkPreset::TurnRight => 30,
            WalkPreset::Jog => 15,
        }
    }

    /// UI 경고 메시지 (None이면 경고 없음).
    pub fn warning_ko(self) -> Option<&'static str> {
        match self {
            WalkPreset::FastWalk => {
                Some("ROBOTIS 기본 600 ms를 500 ms로 단축한 변형. 무릎/발목 부하 증가.")
            }
            WalkPreset::Jog => Some(
                "ROBOTIS 원본에 없는 실험 파라미터. 자기충돌·낙상 가능. \
                 정비 스탠드 거치 + 주변 50 cm 빈 공간 필수.",
            ),
            WalkPreset::TurnLeft | WalkPreset::TurnRight => {
                Some("회전 시 좌·우 발 위상 차이로 균형 흔들림 가능.")
            }
            _ => None,
        }
    }

    /// `confirm_risk=true` 필수 여부.
    pub fn requires_risk_confirmation(self) -> bool {
        matches!(self.safety(), WalkSafety::HighRisk)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_eight_presets_unique() {
        let labels: Vec<&'static str> = WalkPreset::ALL.iter().map(|p| p.label_ko()).collect();
        let mut sorted = labels.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(labels.len(), sorted.len(), "labels must be unique");
    }

    #[test]
    fn idle_has_no_command() {
        let cmd = WalkPreset::Idle.command();
        assert_eq!(cmd.x_amplitude, 0.0);
        assert_eq!(cmd.y_amplitude, 0.0);
        assert_eq!(cmd.a_amplitude, 0.0);
        assert!(!cmd.enabled);
    }

    #[test]
    fn march_enabled_but_zero_amplitude() {
        let cmd = WalkPreset::March.command();
        assert!(cmd.enabled);
        assert_eq!(cmd.x_amplitude, 0.0);
        assert_eq!(cmd.y_amplitude, 0.0);
        assert_eq!(cmd.a_amplitude, 0.0);
    }

    #[test]
    fn amplitude_grows_with_speed() {
        let slow = WalkPreset::SlowWalk.command().x_amplitude;
        let normal = WalkPreset::NormalWalk.command().x_amplitude;
        let fast = WalkPreset::FastWalk.command().x_amplitude;
        let jog = WalkPreset::Jog.command().x_amplitude;
        assert!(slow < normal && normal < fast && fast < jog);
    }

    #[test]
    fn period_default_600_except_fast_jog() {
        for p in WalkPreset::ALL {
            let exp = match p {
                WalkPreset::FastWalk => 500,
                WalkPreset::Jog => 450,
                _ => 600,
            };
            assert_eq!(p.period_ms(), exp, "{:?}", p);
        }
    }

    #[test]
    fn safety_class_assignment() {
        assert_eq!(WalkPreset::Idle.safety(), WalkSafety::Safe);
        assert_eq!(WalkPreset::NormalWalk.safety(), WalkSafety::Safe);
        assert_eq!(WalkPreset::FastWalk.safety(), WalkSafety::Caution);
        assert_eq!(WalkPreset::TurnLeft.safety(), WalkSafety::Caution);
        assert_eq!(WalkPreset::Jog.safety(), WalkSafety::HighRisk);
    }

    #[test]
    fn only_jog_requires_risk_confirmation() {
        let confirming: Vec<WalkPreset> = WalkPreset::ALL
            .iter()
            .copied()
            .filter(|p| p.requires_risk_confirmation())
            .collect();
        assert_eq!(confirming, vec![WalkPreset::Jog]);
    }

    #[test]
    fn turn_left_and_right_are_mirror() {
        let l = WalkPreset::TurnLeft.command();
        let r = WalkPreset::TurnRight.command();
        assert!((l.a_amplitude + r.a_amplitude).abs() < 1e-9);
        assert!((l.x_amplitude - r.x_amplitude).abs() < 1e-9);
    }

    #[test]
    fn auto_stop_duration_bounded() {
        for p in WalkPreset::ALL {
            // 모든 프리셋은 ∞ (0) 또는 합리적 상한 (≤ 60s).
            let d = p.max_duration_secs();
            assert!(d == 0 || (5..=60).contains(&d), "{:?} -> {}", p, d);
        }
        // Jog는 15s 이하
        assert!(WalkPreset::Jog.max_duration_secs() <= 15);
    }

    #[test]
    fn icon_and_label_non_empty() {
        for p in WalkPreset::ALL {
            assert!(!p.label_ko().is_empty());
            assert!(!p.icon().is_empty());
        }
    }

    #[test]
    fn warning_only_for_caution_and_highrisk() {
        for p in WalkPreset::ALL {
            match p.safety() {
                WalkSafety::Safe => assert!(p.warning_ko().is_none(), "{:?}", p),
                _ => assert!(p.warning_ko().is_some(), "{:?}", p),
            }
        }
    }

    #[test]
    fn serde_round_trip() {
        let p = WalkPreset::Jog;
        let s = serde_json::to_string(&p).unwrap();
        let p2: WalkPreset = serde_json::from_str(&s).unwrap();
        assert_eq!(p, p2);
    }
}
