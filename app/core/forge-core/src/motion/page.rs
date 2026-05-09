//! Page / Step 데이터 모델.
//!
//! 한 Page = 의미 있는 모션 단위 (예: "인사", "기본자세")
//!         = 최대 7 step + 메타데이터 (compliance, play_param).
//! 한 Step = 20관절 keyframe + pause_time + play_time + option flags.

use serde::{Deserialize, Serialize};

/// 한 Step에 들어가는 관절 슬롯 수. RoboPlus는 항상 31 슬롯이지만 실제로
/// 사용되는 slot은 ID 1..6, 11..18, 19..20 (= 16개). 호환성을 위해
/// 31 slot 모두 보존.
pub const NUM_JOINTS_IN_STEP: usize = 31;

/// 한 Step (keyframe).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MotionStep {
    /// 31개 관절 위치 raw (0..4095). 미사용 슬롯은 보통 32767(스킵).
    pub positions: [u16; NUM_JOINTS_IN_STEP],
    /// 도달 후 정지 시간 (raw 0..255 → ms = raw * 8).
    pub pause_time: u8,
    /// 보간 시간 (raw 0..255 → ms = raw * 8).
    pub play_time: u8,
}

impl Default for MotionStep {
    fn default() -> Self {
        Self {
            positions: [2048u16; NUM_JOINTS_IN_STEP], // 모두 중앙
            pause_time: 0,
            play_time: 32, // ~250 ms
        }
    }
}

impl MotionStep {
    /// pause_time을 ms로 환산.
    pub fn pause_ms(&self) -> u16 {
        self.pause_time as u16 * 8
    }

    /// play_time을 ms로 환산.
    pub fn play_ms(&self) -> u16 {
        self.play_time as u16 * 8
    }
}

/// 한 Page (motion sequence).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MotionPage {
    /// 1..255 — page id. 0은 비활성/미사용.
    pub id: u8,
    /// 사람이 읽는 라벨. 14 bytes max in `.mtn`.
    pub name: String,
    /// 31개 관절의 P-gain compliance 0..7 (보통 5).
    pub compliance: [u8; NUM_JOINTS_IN_STEP],
    /// 다음 자동 재생 페이지. 0 = 없음.
    pub next_page: u8,
    /// 정지 시 재생할 페이지. 0 = 없음.
    pub exit_page: u8,
    /// 페이지 반복 횟수.
    pub repeat: u8,
    /// 재생 속도 (0..32, 32 = 1.0배).
    pub speed: u8,
    /// 가속도 (0..255, 0 = 즉시).
    pub accel: u8,
    /// 1..7 step.
    pub steps: Vec<MotionStep>,
}

impl Default for MotionPage {
    fn default() -> Self {
        Self {
            id: 1,
            name: String::new(),
            compliance: [5u8; NUM_JOINTS_IN_STEP],
            next_page: 0,
            exit_page: 0,
            repeat: 1,
            speed: 32,
            accel: 0,
            steps: vec![MotionStep::default()],
        }
    }
}

/// 모션 라이브러리 — 256 페이지 컨테이너.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Motion {
    /// 포맷 version. 변경 시 migration 필요.
    pub version: u32,
    /// 대상 로봇 generation.
    pub robot_generation: String,
    /// 페이지 목록 (id 순으로 정렬 권장하나 강제 안 함).
    pub pages: Vec<MotionPage>,
}

impl Motion {
    /// 주어진 ID의 페이지 검색.
    pub fn page(&self, id: u8) -> Option<&MotionPage> {
        self.pages.iter().find(|p| p.id == id)
    }

    /// JSON 직렬화 (사람이 읽는 형식).
    pub fn to_json_pretty(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }

    /// JSON 역직렬화.
    pub fn from_json(s: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(s)
    }
}

impl Default for Motion {
    fn default() -> Self {
        Self {
            version: 1,
            robot_generation: "op2".to_string(),
            pages: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn step_time_conversion() {
        let s = MotionStep {
            pause_time: 10,
            play_time: 32,
            ..Default::default()
        };
        assert_eq!(s.pause_ms(), 80);
        assert_eq!(s.play_ms(), 256);
    }

    #[test]
    fn motion_json_round_trip() {
        let m = Motion {
            version: 1,
            robot_generation: "op2".to_string(),
            pages: vec![MotionPage {
                id: 7,
                name: "Hello".to_string(),
                ..Default::default()
            }],
        };
        let json = m.to_json_pretty().unwrap();
        let m2 = Motion::from_json(&json).unwrap();
        assert_eq!(m, m2);
    }

    #[test]
    fn motion_page_lookup() {
        let m = Motion {
            pages: vec![
                MotionPage {
                    id: 1,
                    name: "A".to_string(),
                    ..Default::default()
                },
                MotionPage {
                    id: 5,
                    name: "B".to_string(),
                    ..Default::default()
                },
            ],
            ..Default::default()
        };
        assert_eq!(m.page(5).map(|p| p.name.as_str()), Some("B"));
        assert!(m.page(99).is_none());
    }
}
