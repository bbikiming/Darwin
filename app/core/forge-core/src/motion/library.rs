//! 모션 라이브러리 — in-memory + (Sprint 4 이후 SQLite) 백엔드.
//!
//! 현재는 in-memory만. SQLite 백엔드는 Sprint 4 후속에서 추가
//! (`forge-core::db`, ADR-012).
//!
//! `with_official_catalog` 가 ROBOTIS-OP2 `motion_4096.bin` + `gui_motion.yaml`
//! 의 안전 분류를 한꺼번에 등록.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::bin4096::RawPage;
use super::page::{Motion, MotionPage, SafetyClass, NUM_JOINTS_IN_STEP};

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

    /// ROBOTIS-OP2 공식 카탈로그 import (**legacy stub** — placeholder steps).
    ///
    /// ## ⚠️ Phase G7 (Codex audit P2-9, 2026-05-14): legacy / placeholder path
    ///
    /// 이 함수는 **raw page 의 step 본문을 디코드하지 않는다** — `steps: Vec::new()`
    /// 빈 벡터와 placeholder header (compliance=[5;31], accel=0) 만 등록한다.
    /// `MotionRecord` 의 이름/안전 분류 검색용 인덱스로만 의미가 있다.
    ///
    /// **실 raw step 이 필요하면** [`crate::synth::library::PageLibrary::from_official_bin`]
    /// 사용. 그쪽은 `decode_raw_page` 로 31 슬롯 position + 7 step 모두 복원한다.
    ///
    /// 두 경로의 차이:
    ///
    /// | 함수 | steps 본문 | header (slope/accel) | metadata |
    /// |---|---|---|---|
    /// | `with_official_catalog` (이 함수) | 비어있음 | placeholder | display_name + safety |
    /// | `PageLibrary::from_official_bin` | 7 step 모두 디코드 | 공식 raw 그대로 | tags + body_regions + duration |
    ///
    /// 등록되는 모션:
    /// - **Safe** (11개): Stand up, Walk ready, Yes, No, Thank you, Sit down,
    ///   Yes Go!, Wow!, Oops, Clap please, Bye bye.
    /// - **Caution** (2개): Get up (Front), Get up (Back).
    /// - **HighRisk** (3개): Right Kick, Left Kick, Hand Standing — 사용자
    ///   confirmation 후에만 실행.
    #[deprecated(since = "0.2.0", note = "Use synth::library::PageLibrary::from_official_bin for full raw page decode")]
    pub fn with_official_catalog(raw_pages: &[RawPage]) -> Self {
        let mut lib = Self::new();
        for entry in OFFICIAL_CATALOG {
            let Some(raw) = raw_pages.iter().find(|p| p.index as u16 == entry.id) else {
                continue;
            };
            let motion = Motion {
                version: 1,
                robot_generation: "op2".to_string(),
                pages: vec![MotionPage {
                    id: entry.id as u8,
                    name: entry.display_name.to_string(),
                    compliance: [5u8; NUM_JOINTS_IN_STEP],
                    next_page: 0,
                    exit_page: 0,
                    repeat: 1,
                    speed: 32,
                    accel: 0,
                    steps: Vec::new(), // raw payload는 별도 보존 — Phase B2 의미 해석
                    safety_class: entry.safety,
                }],
            };
            lib.upsert(MotionRecord {
                id: format!("op2-page-{:03}", entry.id),
                name: entry.display_name.to_string(),
                motion,
                source_mtn: Some(format!("motion_4096.bin#page={}", entry.id)),
            });
            // raw page payload 도 메타로 보존하고 싶다면 추후 별도 필드.
            let _ = raw; // borrow checker 만족
        }
        lib
    }
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
    use super::super::bin4096::parse_bin4096;
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

    const OFFICIAL_BIN: &[u8] = include_bytes!(
        "../../../../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin"
    );

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

    #[test]
    fn with_official_catalog_imports_from_bin4096() {
        let raw_pages = parse_bin4096(OFFICIAL_BIN).unwrap();
        let lib = Library::with_official_catalog(&raw_pages);
        // 카탈로그의 모든 엔트리가 bin 의 해당 페이지에 있어야 함 — bin 이
        // 페이지 0..=255 모두 가지므로 16개 모두 등록.
        assert_eq!(lib.len(), 16);
        // 라벨 확인.
        let stand_up = lib.get("op2-page-001").unwrap();
        assert_eq!(stand_up.name, "Stand Up");
        assert_eq!(stand_up.motion.pages[0].safety_class, SafetyClass::Safe);
        let hand_standing = lib.get("op2-page-017").unwrap();
        assert_eq!(hand_standing.name, "Hand Standing");
        assert_eq!(
            hand_standing.motion.pages[0].safety_class,
            SafetyClass::HighRisk
        );
    }
}
