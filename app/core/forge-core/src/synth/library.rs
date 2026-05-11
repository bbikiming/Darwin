//! Reference 모션 페이지 라이브러리.
//!
//! Sprint 9-2 본구현: `motion_4096.bin` 의 raw 페이지를 디코드해서 의미 있는
//! `MotionPage` + sidecar `PageMetadata` 로 저장.
//!
//! # 디자인
//!
//! - `decode_raw_page()` — 512 byte `RawPage` → `MotionPage` (header 64 byte +
//!   7 × step 64 byte).
//! - `PageLibrary::from_official_bin()` — `motion_4096.bin` 로드 +
//!   `motion::OFFICIAL_CATALOG` 16개 페이지만 등록 + 자동 `PageMetadata` 생성.
//! - `PageLibrary::by_tag`, `by_region`, `by_safety` — 필터.
//!
//! # 포맷 출처
//!
//! - `motion/bin4096.rs:20-26` — `PAGE_SIZE_BYTES = 512`, `NAME_LEN = 14`,
//!   `NUM_PAGES = 256`.
//! - 공식 RoboPlus Action `PAGEHEADER` 구조 (64 byte):
//!   `name[14]`, `reserved1`, `repeat`, `schedule`, `reserved2[3]`, `stepnum`,
//!   `reserved3`, `speed`, `reserved4`, `accel`, `next`, `exit`, `reserved5[2]`,
//!   `slope[31]`, `checksum`.
//! - `STEP` 구조 (64 byte): `position[31] (uint16 LE)`, `pause`, `time`.

use std::collections::HashMap;
use std::path::Path;

use crate::motion::bin4096::{read_bin4096_file, RawPage, PAGE_SIZE_BYTES};
use crate::motion::page::NUM_JOINTS_IN_STEP;
use crate::motion::{
    MotionPage, MotionStep, OfficialCatalogEntry, SafetyClass, OFFICIAL_CATALOG,
};

use super::error::{Result, SynthError};
use super::metadata::{BodyRegion, PageMetadata, Tag};

const HEADER_OFFSET_REPEAT: usize = 15;
const HEADER_OFFSET_STEPNUM: usize = 19;
const HEADER_OFFSET_SPEED: usize = 21;
const HEADER_OFFSET_ACCEL: usize = 23;
const HEADER_OFFSET_NEXT: usize = 24;
const HEADER_OFFSET_EXIT: usize = 25;
const HEADER_OFFSET_SLOPE: usize = 28;
const HEADER_SIZE: usize = 64;
const STEP_SIZE: usize = 64;
const MAX_STEPS: usize = 7;

/// 한 `RawPage` (512 byte) → 의미 있는 `MotionPage`.
///
/// 헤더 64 byte 디코드 + stepnum 만큼의 step (각 64 byte) 디코드.
pub fn decode_raw_page(raw: &RawPage, default_safety: SafetyClass) -> Result<MotionPage> {
    if raw.raw.len() != PAGE_SIZE_BYTES {
        return Err(SynthError::Decode(format!(
            "RawPage length {} != {}",
            raw.raw.len(),
            PAGE_SIZE_BYTES
        )));
    }
    let bytes = &raw.raw;

    let repeat = bytes[HEADER_OFFSET_REPEAT];
    let stepnum = bytes[HEADER_OFFSET_STEPNUM] as usize;
    let speed = bytes[HEADER_OFFSET_SPEED];
    let accel = bytes[HEADER_OFFSET_ACCEL];
    let next_page = bytes[HEADER_OFFSET_NEXT];
    let exit_page = bytes[HEADER_OFFSET_EXIT];

    let mut compliance = [5u8; NUM_JOINTS_IN_STEP];
    for (i, slot) in compliance.iter_mut().enumerate() {
        *slot = bytes[HEADER_OFFSET_SLOPE + i];
    }

    let step_count = stepnum.min(MAX_STEPS);

    let mut steps = Vec::with_capacity(step_count);
    for s in 0..step_count {
        let offset = HEADER_SIZE + s * STEP_SIZE;
        if offset + STEP_SIZE > PAGE_SIZE_BYTES {
            break;
        }
        let mut positions = [2048u16; NUM_JOINTS_IN_STEP];
        for (i, slot) in positions.iter_mut().enumerate() {
            let lo = bytes[offset + i * 2] as u16;
            let hi = bytes[offset + i * 2 + 1] as u16;
            *slot = lo | (hi << 8);
        }
        let pause_time = bytes[offset + 62];
        let play_time = bytes[offset + 63];
        steps.push(MotionStep {
            positions,
            pause_time,
            play_time,
        });
    }

    Ok(MotionPage {
        id: raw.index,
        name: raw.name.clone(),
        compliance,
        next_page,
        exit_page,
        repeat,
        speed,
        accel,
        steps,
        safety_class: default_safety,
    })
}

/// 페이지 ID로 reference 페이지를 조회하는 라이브러리.
///
/// `MotionPage` (의미 디코드된) + sidecar `PageMetadata` (태그·부위·미러쌍 등)
/// 함께 저장.
#[derive(Debug, Default, Clone)]
pub struct PageLibrary {
    pages: HashMap<u16, MotionPage>,
    metadata: HashMap<u16, PageMetadata>,
}

impl PageLibrary {
    /// 빈 라이브러리 생성.
    pub fn new() -> Self {
        Self {
            pages: HashMap::new(),
            metadata: HashMap::new(),
        }
    }

    /// 페이지 + 메타데이터 함께 추가. 동일 ID가 이미 있으면 덮어쓴다.
    pub fn insert(&mut self, id: u16, page: MotionPage, metadata: PageMetadata) {
        self.pages.insert(id, page);
        self.metadata.insert(id, metadata);
    }

    /// 페이지만 추가 (메타데이터 default).
    pub fn insert_page(&mut self, id: u16, page: MotionPage) {
        self.pages.insert(id, page);
        self.metadata.entry(id).or_default();
    }

    /// ID로 페이지 조회.
    pub fn get(&self, id: u16) -> Option<&MotionPage> {
        self.pages.get(&id)
    }

    /// ID로 메타데이터 조회.
    pub fn metadata(&self, id: u16) -> Option<&PageMetadata> {
        self.metadata.get(&id)
    }

    /// 저장된 페이지 수.
    pub fn len(&self) -> usize {
        self.pages.len()
    }

    /// 비어 있는지 여부.
    pub fn is_empty(&self) -> bool {
        self.pages.is_empty()
    }

    /// 모든 페이지 ID (정렬됨).
    pub fn ids(&self) -> Vec<u16> {
        let mut v: Vec<u16> = self.pages.keys().copied().collect();
        v.sort_unstable();
        v
    }

    /// 안전 분류로 필터링.
    pub fn by_safety(&self, safety: SafetyClass) -> Vec<u16> {
        let mut ids: Vec<u16> = self
            .pages
            .iter()
            .filter(|(_, p)| p.safety_class == safety)
            .map(|(id, _)| *id)
            .collect();
        ids.sort_unstable();
        ids
    }

    /// 태그로 필터링.
    pub fn by_tag(&self, tag: &Tag) -> Vec<u16> {
        let mut ids: Vec<u16> = self
            .metadata
            .iter()
            .filter(|(_, m)| m.tags.contains(tag))
            .map(|(id, _)| *id)
            .collect();
        ids.sort_unstable();
        ids
    }

    /// 부위로 필터링.
    pub fn by_region(&self, region: BodyRegion) -> Vec<u16> {
        let mut ids: Vec<u16> = self
            .metadata
            .iter()
            .filter(|(_, m)| m.body_regions.contains(&region))
            .map(|(id, _)| *id)
            .collect();
        ids.sort_unstable();
        ids
    }

    /// `motion_4096.bin` 로드 + `OFFICIAL_CATALOG` 16개 페이지만 디코드 + 자동 메타데이터.
    ///
    /// # PRD §17.5 매핑
    /// - S9-2a: `decode_raw_page` (위)
    /// - S9-2b: `OFFICIAL_CATALOG` 교차 참조
    /// - S9-2c: `SafetyClass` → `PageMetadata.single_foot_ok` 등
    /// - S9-2d: 검색용 in-memory 저장 (`self.pages`, `self.metadata`)
    pub fn from_official_bin(path: &Path) -> Result<Self> {
        let raw_pages =
            read_bin4096_file(path).map_err(|e| SynthError::Decode(e.to_string()))?;
        let mut lib = Self::new();
        for entry in OFFICIAL_CATALOG {
            let Some(raw) = raw_pages.iter().find(|p| p.index as u16 == entry.id) else {
                continue;
            };
            let page = decode_raw_page(raw, entry.safety)?;
            let metadata = auto_metadata(entry, &page);
            lib.insert(entry.id, page, metadata);
        }
        Ok(lib)
    }
}

/// `OfficialCatalogEntry` + 디코드된 페이지 → 자동 메타데이터.
///
/// 휴리스틱:
/// - `display_name` = catalog entry의 표시명
/// - `tags`: 이름에서 키워드 추출 (kick, get_up, sit_down, ...)
/// - `body_regions`: 페이지의 step 차이로 추론
/// - `duration_ms`: step의 (`pause` + `play`) × 8 합
/// - `mirror_pair`: 알려진 좌·우 페어 (Right Kick=12 ↔ Left Kick=13)
/// - `single_foot_ok`: `Safe` / `Caution` 만 true (HighRisk는 한발 지지 검증 엄격)
pub fn auto_metadata(entry: &OfficialCatalogEntry, page: &MotionPage) -> PageMetadata {
    let display_name = Some(entry.display_name.to_string());

    let lower = entry.display_name.to_lowercase();
    let mut tags: Vec<Tag> = Vec::new();
    if lower.contains("kick") {
        tags.push(Tag("kick".into()));
        tags.push(Tag("balance_critical".into()));
    }
    if lower.contains("get up") || lower.contains("getup") {
        tags.push(Tag("recovery".into()));
        tags.push(Tag("balance_critical".into()));
    }
    if lower.contains("sit") {
        tags.push(Tag("posture".into()));
    }
    if lower.contains("stand") {
        tags.push(Tag("posture".into()));
    }
    if lower.contains("walk") {
        tags.push(Tag("locomotion".into()));
    }
    if lower.contains("yes")
        || lower.contains("no")
        || lower.contains("thank")
        || lower.contains("bye")
        || lower.contains("clap")
        || lower.contains("oops")
        || lower.contains("wow")
    {
        tags.push(Tag("gesture".into()));
    }
    if lower.contains("hand standing") {
        tags.push(Tag("acrobatics".into()));
        tags.push(Tag("balance_critical".into()));
    }

    let body_regions = infer_body_regions(page);

    let duration_ms: u32 = page
        .steps
        .iter()
        .map(|s| s.play_ms() as u32 + s.pause_ms() as u32)
        .sum();

    let mirror_pair = match entry.id {
        12 => Some(13), // Right Kick ↔ Left Kick
        13 => Some(12),
        _ => None,
    };

    let single_foot_ok = matches!(entry.safety, SafetyClass::Safe | SafetyClass::Caution);

    PageMetadata {
        display_name,
        tags,
        body_regions,
        duration_ms: Some(duration_ms),
        mirror_pair,
        single_foot_ok,
    }
}

/// 페이지의 step 들을 보고 영향 신체 부위 추론.
///
/// 휴리스틱: 각 joint 의 첫·마지막 step 차이가 일정 threshold 이상이면 그 부위가
/// "활성".
fn infer_body_regions(page: &MotionPage) -> Vec<BodyRegion> {
    if page.steps.is_empty() {
        return Vec::new();
    }
    let first = &page.steps[0];
    let last = page.steps.last().unwrap();

    let mut upper = false;
    let mut lower = false;
    let mut head = false;

    const THRESHOLD: i32 = 50; // raw 50 ≈ 4.4° at MX-28 4096

    for i in 0..NUM_JOINTS_IN_STEP {
        let diff = (last.positions[i] as i32 - first.positions[i] as i32).abs();
        if diff < THRESHOLD {
            continue;
        }
        let id = (i + 1) as u8;
        match id {
            1..=6 => upper = true,
            7..=18 => lower = true,
            19..=20 => head = true,
            _ => {}
        }
    }

    let mut regions = Vec::new();
    if upper {
        regions.push(BodyRegion::UpperBody);
    }
    if lower {
        regions.push(BodyRegion::LowerBody);
    }
    if head {
        regions.push(BodyRegion::Head);
    }
    regions
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn official_bin_path() -> PathBuf {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.push("../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin");
        p
    }

    #[test]
    fn empty_library_is_empty() {
        let lib = PageLibrary::new();
        assert!(lib.is_empty());
        assert_eq!(lib.len(), 0);
    }

    #[test]
    fn decode_walks_through_header_and_steps() {
        let mut raw_bytes = vec![0u8; PAGE_SIZE_BYTES];
        raw_bytes[..4].copy_from_slice(b"test");
        raw_bytes[HEADER_OFFSET_REPEAT] = 2;
        raw_bytes[HEADER_OFFSET_STEPNUM] = 3;
        raw_bytes[HEADER_OFFSET_SPEED] = 32;
        raw_bytes[HEADER_OFFSET_NEXT] = 5;
        raw_bytes[HEADER_OFFSET_EXIT] = 6;
        // 첫 step joint 0 = 1234 (LE)
        raw_bytes[HEADER_SIZE] = 0xD2;
        raw_bytes[HEADER_SIZE + 1] = 0x04;
        raw_bytes[HEADER_SIZE + 63] = 16;

        let raw = RawPage {
            index: 42,
            name: "test".into(),
            raw: raw_bytes,
        };
        let page = decode_raw_page(&raw, SafetyClass::Safe).unwrap();
        assert_eq!(page.id, 42);
        assert_eq!(page.name, "test");
        assert_eq!(page.repeat, 2);
        assert_eq!(page.steps.len(), 3);
        assert_eq!(page.speed, 32);
        assert_eq!(page.next_page, 5);
        assert_eq!(page.exit_page, 6);
        assert_eq!(page.steps[0].positions[0], 1234);
        assert_eq!(page.steps[0].play_time, 16);
        assert_eq!(page.safety_class, SafetyClass::Safe);
    }

    #[test]
    fn decode_rejects_wrong_size() {
        let raw = RawPage {
            index: 0,
            name: String::new(),
            raw: vec![0u8; 100],
        };
        assert!(decode_raw_page(&raw, SafetyClass::Safe).is_err());
    }

    #[test]
    fn from_official_bin_loads_16_catalog_pages() {
        let path = official_bin_path();
        if !path.exists() {
            eprintln!("skip: {} not present", path.display());
            return;
        }
        let lib = PageLibrary::from_official_bin(&path).expect("load");
        assert_eq!(lib.len(), OFFICIAL_CATALOG.len(), "expect 16 entries");
        let page1 = lib.get(1).expect("Stand Up page 1");
        assert!(
            page1.name.to_lowercase().contains("stand"),
            "page 1 name = {:?}",
            page1.name
        );
        let safe = lib.by_safety(SafetyClass::Safe).len();
        let caution = lib.by_safety(SafetyClass::Caution).len();
        let high_risk = lib.by_safety(SafetyClass::HighRisk).len();
        assert_eq!(safe + caution + high_risk, OFFICIAL_CATALOG.len());
        assert!(high_risk >= 2, "HighRisk count {}", high_risk);
    }

    #[test]
    fn kick_pages_have_kick_tag_and_mirror_pair() {
        let path = official_bin_path();
        if !path.exists() {
            return;
        }
        let lib = PageLibrary::from_official_bin(&path).expect("load");
        let kicks = lib.by_tag(&Tag("kick".into()));
        assert_eq!(kicks.len(), 2, "expect Right Kick + Left Kick");
        let m12 = lib.metadata(12).expect("page 12 metadata");
        let m13 = lib.metadata(13).expect("page 13 metadata");
        assert_eq!(m12.mirror_pair, Some(13));
        assert_eq!(m13.mirror_pair, Some(12));
    }

    #[test]
    fn high_risk_pages_have_single_foot_ok_false() {
        let path = official_bin_path();
        if !path.exists() {
            return;
        }
        let lib = PageLibrary::from_official_bin(&path).expect("load");
        for id in lib.by_safety(SafetyClass::HighRisk) {
            let m = lib.metadata(id).unwrap();
            assert!(
                !m.single_foot_ok,
                "HighRisk page {} should disallow single_foot_ok",
                id
            );
        }
    }

    #[test]
    fn auto_metadata_sets_duration_from_steps() {
        let mut page = MotionPage::default();
        page.steps.clear(); // default 1 step 제거
        page.steps.push(MotionStep {
            positions: [2048u16; NUM_JOINTS_IN_STEP],
            pause_time: 1,
            play_time: 4,
        });
        page.steps.push(MotionStep {
            positions: [2048u16; NUM_JOINTS_IN_STEP],
            pause_time: 2,
            play_time: 8,
        });
        let entry = OfficialCatalogEntry {
            id: 99,
            display_name: "Sample",
            safety: SafetyClass::Safe,
        };
        let m = auto_metadata(&entry, &page);
        // (1+4)*8 + (2+8)*8 = 40 + 80 = 120
        assert_eq!(m.duration_ms, Some(120));
        assert!(m.single_foot_ok);
    }

    #[test]
    fn insert_and_filter_round_trip() {
        let mut lib = PageLibrary::new();
        let page = MotionPage::default();
        let meta = PageMetadata {
            tags: vec![Tag("locomotion".into())],
            body_regions: vec![BodyRegion::LowerBody],
            ..Default::default()
        };
        lib.insert(7, page, meta);
        assert_eq!(lib.len(), 1);
        assert_eq!(lib.by_tag(&Tag("locomotion".into())), vec![7]);
        assert_eq!(lib.by_region(BodyRegion::LowerBody), vec![7]);
        assert!(lib.by_region(BodyRegion::Head).is_empty());
    }
}
