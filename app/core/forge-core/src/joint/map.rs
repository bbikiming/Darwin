//! 캐논 [`JointId`] → wire(실 모터) ID 매핑.
//!
//! ROBOTIS 공식 ROBOTIS-OP2 펌웨어는 ID 1..=20을 그대로 쓴다 (`OP2.robot:10-29`).
//! 일부 오래된 1세대 미러(`darwinop-ens/darwin-op` 등)가 ID 11..=18로 다리를 매핑한
//! 흔적이 있어, fallback 트랙을 함께 제공한다. 첫 연결 시 PING sweep 결과로 자동 선택.
//!
//! 사용자는 OP1(CM-730)과 OP2(CM-740)를 둘 다 보유. 두 매핑 모두 안전하게 동작.
//!
//! # 디자인 노트
//!
//! - `Official` (default): 캐논 ID 그대로 — `JointId as u8`.
//! - `LegacyOp1`: 다리 6관절이 11..=16, 무릎 17..=18, 발목 4개는 사용자 입력 또는
//!   비활성. 발목 ID가 미정이면 발목 명령은 발행되지 않고 경고 로그.
//!
//! 두 트랙 모두 어깨 1..=6, 머리 19..=20은 동일.

use serde::{Deserialize, Serialize};

use super::JointId;

/// 매핑 종류.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum JointMapKind {
    /// 공식 ROBOTIS-OP2 (= ROBOTIS-OP 공식 펌웨어) 매핑. ID 1..=20.
    Official,
    /// `darwinop-ens` 류 1세대 변형. 다리 11..=18, 발목 ID 별도 지정.
    LegacyOp1,
}

/// 캐논 → wire ID 매핑.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct JointMap {
    /// 어떤 변형인가.
    pub kind: JointMapKind,
    /// LegacyOp1에서 발목 4개의 wire ID. `None`이면 발목 명령 미발행.
    pub legacy_ankle_ids: Option<LegacyAnkleIds>,
}

/// LegacyOp1 fallback에서 발목 4개의 wire ID. 사용자 입력 또는 자동 detect.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LegacyAnkleIds {
    /// 우 발목 pitch.
    pub r_ank_pitch: u8,
    /// 좌 발목 pitch.
    pub l_ank_pitch: u8,
    /// 우 발목 roll.
    pub r_ank_roll: u8,
    /// 좌 발목 roll.
    pub l_ank_roll: u8,
}

impl Default for JointMap {
    fn default() -> Self {
        Self::official()
    }
}

impl JointMap {
    /// 공식 매핑 (대부분의 사용자).
    pub fn official() -> Self {
        Self {
            kind: JointMapKind::Official,
            legacy_ankle_ids: None,
        }
    }

    /// Legacy OP1 매핑 — 발목 ID는 별도 입력 필요. 발목 없이도 동작은 하나
    /// 워크는 안 됨.
    pub fn legacy_op1(ankle: Option<LegacyAnkleIds>) -> Self {
        Self {
            kind: JointMapKind::LegacyOp1,
            legacy_ankle_ids: ankle,
        }
    }

    /// 캐논 → wire u8. 발목이 LegacyOp1 + 미정의이면 `None`.
    pub fn resolve(&self, joint: JointId) -> Option<u8> {
        match self.kind {
            JointMapKind::Official => Some(joint as u8),
            JointMapKind::LegacyOp1 => match joint {
                // 어깨·팔꿈치·머리: 공식과 동일.
                JointId::RShoulderPitch
                | JointId::LShoulderPitch
                | JointId::RShoulderRoll
                | JointId::LShoulderRoll
                | JointId::RElbow
                | JointId::LElbow
                | JointId::HeadPan
                | JointId::HeadTilt => Some(joint as u8),
                // 다리: 11..=18로 재매핑.
                JointId::RHipYaw => Some(11),
                JointId::LHipYaw => Some(12),
                JointId::RHipRoll => Some(13),
                JointId::LHipRoll => Some(14),
                JointId::RHipPitch => Some(15),
                JointId::LHipPitch => Some(16),
                JointId::RKnee => Some(17),
                JointId::LKnee => Some(18),
                // 발목: 사용자 입력.
                JointId::RAnklePitch => self.legacy_ankle_ids.map(|a| a.r_ank_pitch),
                JointId::LAnklePitch => self.legacy_ankle_ids.map(|a| a.l_ank_pitch),
                JointId::RAnkleRoll => self.legacy_ankle_ids.map(|a| a.r_ank_roll),
                JointId::LAnkleRoll => self.legacy_ankle_ids.map(|a| a.l_ank_roll),
            },
        }
    }

    /// 이 매핑이 발목 제어를 지원하는가? 워크 활성화 사전 조건.
    pub fn supports_ankles(&self) -> bool {
        match self.kind {
            JointMapKind::Official => true,
            JointMapKind::LegacyOp1 => self.legacy_ankle_ids.is_some(),
        }
    }

    /// PING sweep 결과(응답 ID 집합)로부터 자동 선택. 7..=10이 모두 응답하면
    /// Official, 모두 무응답 + 11..=18 응답 = LegacyOp1.
    pub fn detect_from_ping(responding_ids: &[u8]) -> Self {
        let has = |id: u8| responding_ids.contains(&id);
        let official_hip = has(7) && has(8) && has(9) && has(10);
        if official_hip {
            Self::official()
        } else if has(11) && has(12) && has(13) && has(14) {
            // 발목 ID 자동 detect는 어려움 (어느 ID가 발목인지 모름).
            // 사용자가 마법사에서 지정해야 함.
            Self::legacy_op1(None)
        } else {
            // 둘 다 아닌 비정상 상태 — Official로 가정하되 호출자가 누락 ID 경고.
            Self::official()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn official_resolves_canonical_ids() {
        let m = JointMap::official();
        for j in JointId::ALL {
            assert_eq!(m.resolve(j), Some(j as u8));
        }
        assert!(m.supports_ankles());
    }

    #[test]
    fn legacy_op1_without_ankle_ids_lacks_ankle_support() {
        let m = JointMap::legacy_op1(None);
        // 다리는 11..=18.
        assert_eq!(m.resolve(JointId::RHipYaw), Some(11));
        assert_eq!(m.resolve(JointId::LKnee), Some(18));
        // 발목은 미정의 → None.
        assert_eq!(m.resolve(JointId::RAnklePitch), None);
        assert_eq!(m.resolve(JointId::LAnkleRoll), None);
        assert!(!m.supports_ankles());
    }

    #[test]
    fn legacy_op1_with_ankle_ids_resolves_all() {
        let m = JointMap::legacy_op1(Some(LegacyAnkleIds {
            r_ank_pitch: 19,
            l_ank_pitch: 20,
            r_ank_roll: 21,
            l_ank_roll: 22,
        }));
        assert_eq!(m.resolve(JointId::RAnklePitch), Some(19));
        assert_eq!(m.resolve(JointId::LAnkleRoll), Some(22));
        // 머리·어깨는 캐논과 동일.
        assert_eq!(m.resolve(JointId::HeadPan), Some(19)); // 충돌! 사용자 책임
                                                           // 위 충돌은 사용자가 발목 ID를 잘못 입력한 경우의 가능성을 그대로 반영.
        assert!(m.supports_ankles());
    }

    #[test]
    fn detect_from_ping_recognises_official_layout() {
        // ID 7..=10 모두 응답 = Official.
        let resp: Vec<u8> = (1..=20).collect();
        let m = JointMap::detect_from_ping(&resp);
        assert_eq!(m.kind, JointMapKind::Official);
    }

    #[test]
    fn detect_from_ping_recognises_legacy_layout() {
        // 7..=10 무응답, 11..=18 응답 = LegacyOp1 (발목은 미정).
        let resp: Vec<u8> = vec![1, 2, 3, 4, 5, 6, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20];
        let m = JointMap::detect_from_ping(&resp);
        assert_eq!(m.kind, JointMapKind::LegacyOp1);
        assert!(m.legacy_ankle_ids.is_none());
        assert!(!m.supports_ankles());
    }

    #[test]
    fn default_is_official() {
        assert_eq!(JointMap::default().kind, JointMapKind::Official);
    }
}
