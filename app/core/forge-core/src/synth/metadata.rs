//! 페이지 시맨틱 메타데이터.
//!
//! PRD §7.2 — sidecar TOML로 보관되는 라벨링 정보의 in-memory 표현.

use serde::{Deserialize, Serialize};

/// 페이지가 영향을 주는 신체 부위.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum BodyRegion {
    /// 상체 (관절 ID 1..=6).
    UpperBody,
    /// 하체 (관절 ID 7..=18).
    LowerBody,
    /// 머리 (관절 ID 19..=20).
    Head,
}

/// 페이지 태그 — 의미 단위 카테고리.
///
/// 예: "greeting", "kick", "soccer", "balance_critical".
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Tag(pub String);

/// 페이지의 시맨틱 메타데이터.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PageMetadata {
    /// 표시용 이름 (헤더 name과 별도, 자유 형식).
    pub display_name: Option<String>,
    /// 태그 목록.
    pub tags: Vec<Tag>,
    /// 영향 신체 부위.
    pub body_regions: Vec<BodyRegion>,
    /// 전체 재생 시간(ms) — step의 play_time 합으로 추정.
    pub duration_ms: Option<u32>,
    /// 좌우 미러링 페어 페이지 ID (있다면).
    pub mirror_pair: Option<u16>,
    /// V4 정적 안정성 검증을 단일발 지지로 완화 허용.
    pub single_foot_ok: bool,
}
