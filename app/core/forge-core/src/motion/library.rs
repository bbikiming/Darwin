//! 모션 라이브러리 — in-memory + (Sprint 4 이후 SQLite) 백엔드.
//!
//! 현재는 in-memory만. SQLite 백엔드는 Sprint 4 후속에서 추가
//! (`forge-core::db`, ADR-012).
//!
//! `with_official_catalog` 가 ROBOTIS-OP2 `motion_4096.bin` + `gui_motion.yaml`
//! 의 안전 분류를 한꺼번에 등록.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

// 2026-05-17 cleanup: with_official_catalog 제거 후 RawPage / MotionPage /
// NUM_JOINTS_IN_STEP import unused. Motion / SafetyClass 는 MotionRecord 와
// OFFICIAL_CATALOG 에서 사용.
use super::page::{Motion, SafetyClass};

/// 모션 레코드 식별자 (UUID 대신 단순 문자열로 시작 — DB 스키마와 매칭).
pub type MotionId = String;

/// 라이브러리 엔트리 — Motion + 메타데이터.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MotionRecord {
    /// 식별자.
    pub id: MotionId,
    /// 사람이 읽는 이름.
    pub name: String,
    /// 본문.
    pub motion: Motion,
    /// 원본 .mtn 파일 경로 (있으면).
    pub source_mtn: Option<String>,
}

/// In-memory 라이브러리. 추후 SQLite 어댑터가 동일 trait을 구현.
#[derive(Default, Debug)]
pub struct Library {
    by_id: HashMap<MotionId, MotionRecord>,
}

impl Library {
    /// 새 빈 라이브러리.
    pub fn new() -> Self {
        Self::default()
    }

    /// 등록. 이미 같은 id 있으면 덮어씀.
    pub fn upsert(&mut self, record: MotionRecord) {
        self.by_id.insert(record.id.clone(), record);
    }

    /// 검색.
    pub fn get(&self, id: &str) -> Option<&MotionRecord> {
        self.by_id.get(id)
    }

    /// 삭제.
    pub fn remove(&mut self, id: &str) -> Option<MotionRecord> {
        self.by_id.remove(id)
    }

    /// 전체 레코드 (id 알파벳 순).
    pub fn list(&self) -> Vec<&MotionRecord> {
        let mut v: Vec<&MotionRecord> = self.by_id.values().collect();
        v.sort_by(|a, b| a.id.cmp(&b.id));
        v
    }

    /// 갯수.
    pub fn len(&self) -> usize {
        self.by_id.len()
    }

    /// 비었나?
    pub fn is_empty(&self) -> bool {
        self.by_id.is_empty()
    }

    // 2026-05-17 cleanup: `with_official_catalog` legacy stub 함수 제거.
    // - 외부 caller 0 (test 1건만 호출 → 본 cleanup 에서 함께 제거).
    // - 후속 API: `synth::library::PageLibrary::from_official_bin` (full raw decode).
    // - `OFFICIAL_CATALOG` 데이터는 그대로 유지 — `PageLibrary` 가 활용.
}

/// 공식 카탈로그 엔트리.
#[derive(Debug, Clone, Copy)]
pub struct OfficialCatalogEntry {
    /// `motion_4096.bin` 페이지 ID.
    pub id: u16,
    /// 사용자에게 보이는 이름.
    pub display_name: &'static str,
    /// 안전 분류.
    pub safety: SafetyClass,
}

/// ROBOTIS-OP2 `gui_motion.yaml` 기준 안전 카탈로그 — 16개 모션.
///
/// 출처:
/// `research/robotis-official/ROBOTIS-OP2/op2_gui_demo/config/gui_motion.yaml:1-23`.
pub const OFFICIAL_CATALOG: &[OfficialCatalogEntry] = &[
    // Safe — 일상 데모 + 자세 변화 작음.
    OfficialCatalogEntry {
        id: 1,
        display_name: "Stand Up",
        safety: SafetyClass::Safe,
    },
    OfficialCatalogEntry {
        id: 2,
        display_name: "Yes",
        safety: SafetyClass::Safe,
    },
    OfficialCatalogEntry {
        id: 3,
        display_name: "No",
        safety: SafetyClass::Safe,
    },
    OfficialCatalogEntry {
        id: 4,
        display_name: "Thank You",
        safety: SafetyClass::Safe,
    },
    OfficialCatalogEntry {
        id: 9,
        display_name: "Walk Ready",
        safety: SafetyClass::Safe,
    },
    OfficialCatalogEntry {
        id: 15,
        display_name: "Sit Down",
        safety: SafetyClass::Safe,
    },
    OfficialCatalogEntry {
        id: 23,
        display_name: "Yes Go!",
        safety: SafetyClass::Safe,
    },
    OfficialCatalogEntry {
        id: 24,
        display_name: "Wow!",
        safety: SafetyClass::Safe,
    },
    OfficialCatalogEntry {
        id: 27,
        display_name: "Oops",
        safety: SafetyClass::Safe,
    },
    OfficialCatalogEntry {
        id: 38,
        display_name: "Bye Bye",
        safety: SafetyClass::Safe,
    },
    OfficialCatalogEntry {
        id: 54,
        display_name: "Clap Please",
        safety: SafetyClass::Safe,
    },
    // Caution — 평지·관찰 환경에서만.
    OfficialCatalogEntry {
        id: 10,
        display_name: "Get Up (Front)",
        safety: SafetyClass::Caution,
    },
    OfficialCatalogEntry {
        id: 11,
        display_name: "Get Up (Back)",
        safety: SafetyClass::Caution,
    },
    // HighRisk — 낙상/충돌 위험, confirmation 후 실행.
    OfficialCatalogEntry {
        id: 12,
        display_name: "Right Kick",
        safety: SafetyClass::HighRisk,
    },
    OfficialCatalogEntry {
        id: 13,
        display_name: "Left Kick",
        safety: SafetyClass::HighRisk,
    },
    OfficialCatalogEntry {
        id: 17,
        display_name: "Hand Standing",
        safety: SafetyClass::HighRisk,
    },
];

#[cfg(test)]
mod tests {
    // 2026-05-17 cleanup: parse_bin4096 import 제거 (with_official_catalog test 삭제 후).
    use super::super::page::*;
    use super::*;

    #[test]
    fn upsert_and_get() {
        let mut lib = Library::new();
        let rec = MotionRecord {
            id: "stand-up-v1".to_string(),
            name: "Stand Up v1".to_string(),
            motion: Motion {
                pages: vec![MotionPage {
                    id: 1,
                    name: "Stand Up".to_string(),
                    ..Default::default()
                }],
                ..Default::default()
            },
            source_mtn: None,
        };
        lib.upsert(rec.clone());
        assert_eq!(lib.len(), 1);
        assert_eq!(lib.get("stand-up-v1"), Some(&rec));
    }

    #[test]
    fn list_returns_sorted() {
        let mut lib = Library::new();
        for id in ["c", "a", "b"] {
            lib.upsert(MotionRecord {
                id: id.to_string(),
                name: id.to_string(),
                motion: Motion::default(),
                source_mtn: None,
            });
        }
        let names: Vec<&str> = lib.list().iter().map(|r| r.id.as_str()).collect();
        assert_eq!(names, vec!["a", "b", "c"]);
    }

    // 2026-05-17 cleanup: OFFICIAL_BIN const 제거 — with_official_catalog test 삭제 후 미사용.
    // motion_4096.bin 실 파싱은 `synth::library::PageLibrary::from_official_bin` 의 별도 테스트.

    #[test]
    fn official_catalog_has_16_entries() {
        // 11 Safe + 2 Caution + 3 HighRisk = 16.
        assert_eq!(OFFICIAL_CATALOG.len(), 16);
        let safe_count = OFFICIAL_CATALOG
            .iter()
            .filter(|e| e.safety == SafetyClass::Safe)
            .count();
        let caution_count = OFFICIAL_CATALOG
            .iter()
            .filter(|e| e.safety == SafetyClass::Caution)
            .count();
        let risk_count = OFFICIAL_CATALOG
            .iter()
            .filter(|e| e.safety == SafetyClass::HighRisk)
            .count();
        assert_eq!(safe_count, 11);
        assert_eq!(caution_count, 2);
        assert_eq!(risk_count, 3);
    }

    #[test]
    fn high_risk_entries_match_gui_motion_yaml() {
        // gui_motion.yaml:12-23 의 ID 12, 13, 17.
        let risk_ids: Vec<u16> = OFFICIAL_CATALOG
            .iter()
            .filter(|e| e.safety == SafetyClass::HighRisk)
            .map(|e| e.id)
            .collect();
        assert!(risk_ids.contains(&12)); // Right Kick
        assert!(risk_ids.contains(&13)); // Left Kick
        assert!(risk_ids.contains(&17)); // Hand Standing
    }

    // 2026-05-17 cleanup: with_official_catalog 함수 제거와 함께 본 test 도 제거.
    // 검증되던 invariant: bin → catalog 매핑 16건. 후속 API
    // `PageLibrary::from_official_bin` 의 별도 테스트가 동일 invariant 커버.
}
