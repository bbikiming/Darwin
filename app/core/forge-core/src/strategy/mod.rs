//! 전략 FSM — Sprint 6 MVP.
//!
//! Look → Approach → Kick → Look 의 단순 사이클. 사용자가 GUI 또는
//! 새 전략을 선언적으로 추가할 수 있도록 enum 기반.

use serde::{Deserialize, Serialize};

use crate::vision::BlobResult;

/// FSM 상태.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum StrategyState {
    /// 공을 찾는 중 (head pan/tilt 회전).
    LookingForBall,
    /// 공이 보임 → 다가가는 중 (walk start).
    ApproachingBall,
    /// 공 앞 → 차기.
    Kicking,
    /// 차고 나서 잠깐 정지.
    Cooldown,
    /// 정지 / 일시정지.
    Idle,
}

/// FSM 입력 (관찰).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StrategyInput {
    /// 비전 모듈에서 받은 공 검출 결과.
    pub ball: BlobResult,
    /// 마지막 차기로부터 경과 시간 (ms).
    pub since_kick_ms: u32,
    /// 사용자 또는 안전 모듈이 강제 정지 요청?
    pub abort: bool,
}

impl StrategyState {
    /// 다음 상태 결정. 같은 상태 유지 가능.
    pub fn next(self, input: StrategyInput) -> StrategyState {
        if input.abort {
            return StrategyState::Idle;
        }
        match self {
            StrategyState::Idle => {
                if !input.abort {
                    StrategyState::LookingForBall
                } else {
                    StrategyState::Idle
                }
            }
            StrategyState::LookingForBall => {
                if input.ball.found() {
                    StrategyState::ApproachingBall
                } else {
                    StrategyState::LookingForBall
                }
            }
            StrategyState::ApproachingBall => {
                if !input.ball.found() {
                    StrategyState::LookingForBall
                } else if is_close_enough(input.ball) {
                    StrategyState::Kicking
                } else {
                    StrategyState::ApproachingBall
                }
            }
            StrategyState::Kicking => StrategyState::Cooldown,
            StrategyState::Cooldown => {
                if input.since_kick_ms > 1500 {
                    StrategyState::LookingForBall
                } else {
                    StrategyState::Cooldown
                }
            }
        }
    }

    /// 사람이 읽는 라벨 (UI/CLI용).
    pub fn label(self) -> &'static str {
        match self {
            StrategyState::Idle => "Idle",
            StrategyState::LookingForBall => "Looking for Ball",
            StrategyState::ApproachingBall => "Approaching Ball",
            StrategyState::Kicking => "Kicking",
            StrategyState::Cooldown => "Cooldown",
        }
    }
}

/// "충분히 가까움" 판정 — blob의 픽셀 수가 frame 면적의 5% 이상이면 가깝다고 간주.
///
/// > MVP: 카메라 calibration 없이 단순 픽셀 카운트. 실제 거리 추정은 후속.
fn is_close_enough(ball: BlobResult) -> bool {
    ball.pixel_count > 1000 // 320x240 프레임 기준 약 1.3%
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_ball() -> StrategyInput {
        StrategyInput {
            ball: BlobResult::NONE,
            since_kick_ms: 0,
            abort: false,
        }
    }

    fn small_ball() -> StrategyInput {
        StrategyInput {
            ball: BlobResult {
                pixel_count: 50,
                centroid_x: 100.0,
                centroid_y: 80.0,
            },
            since_kick_ms: 0,
            abort: false,
        }
    }

    fn big_ball() -> StrategyInput {
        StrategyInput {
            ball: BlobResult {
                pixel_count: 2000,
                centroid_x: 100.0,
                centroid_y: 80.0,
            },
            since_kick_ms: 0,
            abort: false,
        }
    }

    #[test]
    fn idle_to_looking_when_active() {
        assert_eq!(
            StrategyState::Idle.next(no_ball()),
            StrategyState::LookingForBall
        );
    }

    #[test]
    fn looking_stays_until_ball_found() {
        let s = StrategyState::LookingForBall;
        assert_eq!(s.next(no_ball()), StrategyState::LookingForBall);
        assert_eq!(s.next(small_ball()), StrategyState::ApproachingBall);
    }

    #[test]
    fn approaching_kicks_when_close() {
        let s = StrategyState::ApproachingBall;
        assert_eq!(s.next(big_ball()), StrategyState::Kicking);
        assert_eq!(s.next(small_ball()), StrategyState::ApproachingBall);
    }

    #[test]
    fn approaching_returns_to_looking_when_lost() {
        assert_eq!(
            StrategyState::ApproachingBall.next(no_ball()),
            StrategyState::LookingForBall
        );
    }

    #[test]
    fn kicking_to_cooldown_then_to_looking() {
        let s = StrategyState::Kicking.next(no_ball());
        assert_eq!(s, StrategyState::Cooldown);
        // 짧은 시간 → 여전히 cooldown
        assert_eq!(s.next(no_ball()), StrategyState::Cooldown);
        // 1500 ms 경과 → looking
        let mut input = no_ball();
        input.since_kick_ms = 1600;
        assert_eq!(s.next(input), StrategyState::LookingForBall);
    }

    #[test]
    fn abort_forces_idle() {
        let mut input = big_ball();
        input.abort = true;
        for s in [
            StrategyState::Idle,
            StrategyState::LookingForBall,
            StrategyState::ApproachingBall,
            StrategyState::Kicking,
            StrategyState::Cooldown,
        ] {
            assert_eq!(s.next(input), StrategyState::Idle);
        }
    }
}
