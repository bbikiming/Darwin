//! 모션 라이브러리 — in-memory + (Sprint 4 이후 SQLite) 백엔드.
//!
//! 현재는 in-memory만. SQLite 백엔드는 Sprint 4 후속에서 추가
//! (`forge-core::db`, ADR-012).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::page::Motion;

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
}

#[cfg(test)]
mod tests {
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
}
