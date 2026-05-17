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
use crate::motion::{MotionPage, MotionStep, OfficialCatalogEntry, SafetyClass, OFFICIAL_CATALOG};

use super::error::{Result, SynthError};
use super::metadata::{BodyRegion, PageMetadata, Tag};

// PAGEHEADER offsets — ROBOTIS `Framework/include/Action.h` line 41-59 정의 그대로.
// name[14]=0..13, reserved1=14, repeat=15, schedule=16, reserved2[3]=17..19,
// stepnum=20, reserved3=21, speed=22, reserved4=23, accel=24, next=25, exit=26,
// reserved5[4]=27..30, checksum=31, slope[31]=32..62, reserved6=63.
//
// `pub` 노출 이유 — `forge-cli::synth::encode_page_to_raw` / MCP encoder 가 encode 시에도
// 동일 offset 을 써야 raw round-trip 이 보장됨 (Codex audit P0-1, 2026-05-14).

/// 1 byte — page repeat count.
pub const HEADER_OFFSET_REPEAT: usize = 15;
/// 1 byte — schedule (`SPEED_BASE_SCHEDULE=0` or `TIME_BASE_SCHEDULE=0x0A`).
/// **Phase G8 (Codex audit follow-up, 2026-05-15)** — 모든 공식 페이지는 0x0A.
pub const HEADER_OFFSET_SCHEDULE: usize = 16;
/// 1 byte — number of valid steps (1..=7).
pub const HEADER_OFFSET_STEPNUM: usize = 20;
/// 1 byte — speed (0..32, 32 = 1.0× rate).
pub const HEADER_OFFSET_SPEED: usize = 22;
/// 1 byte — acceleration (raw frames).
pub const HEADER_OFFSET_ACCEL: usize = 24;
/// 1 byte — link to next page (0 = end of chain).
pub const HEADER_OFFSET_NEXT: usize = 25;
/// 1 byte — link to exit page (0 = none).
pub const HEADER_OFFSET_EXIT: usize = 26;
/// 1 byte — checksum so that total 512 byte sum == 0xff (mod 256).
/// **Phase G8** — 누락 시 `Action::LoadPage` 가 `VerifyChecksum` (line 30-44) 에서 false
/// → `ResetPage` (Action.cpp:249-250) 가 페이지를 0 으로 wipe 한다. 데이터 손실 P0.
pub const HEADER_OFFSET_CHECKSUM: usize = 31;
/// 31 byte — CW/CCW slope nibble pair per joint slot 0..30.
pub const HEADER_OFFSET_SLOPE: usize = 32;
/// 64 byte — page header size.
pub const HEADER_SIZE: usize = 64;
/// 64 byte — single step record size.
pub const STEP_SIZE: usize = 64;
/// 7 — max step count per page.
pub const MAX_STEPS: usize = 7;

/// ROBOTIS `Action.h:31` — speed-base 스케줄 (`PRE/MAIN/POST` timing 을 speed/angle 로 계산).
pub const SPEED_BASE_SCHEDULE: u8 = 0;
/// ROBOTIS `Action.h:32` — time-base 스케줄. **공식 motion_4096.bin 의 모든 페이지가 이 모드**
/// (`docs/motion-format/page-catalog-motion4096.md:175` 의 schedule=10 검증).
/// PRE/MAIN/POST timing 을 step.time 만으로 계산 — 사용자가 의도한 정확한 ms 가 보존됨.
pub const TIME_BASE_SCHEDULE: u8 = 0x0A;

/// **Phase G8 (Codex audit follow-up, 2026-05-15)**: ROBOTIS `Action.cpp:47-61 SetChecksum`
/// 재현. 512 byte 페이지 buffer 의 마지막 byte (offset 31) 를 계산해서 set 한다.
///
/// 동작:
///   1. checksum byte 를 0 으로 zero.
///   2. 전체 512 byte sum (mod 256) 계산.
///   3. `checksum = 0xff - sum` 으로 set → 그러면 최종 total sum == 0xff.
///
/// 호출 순서 — 항상 **모든 헤더/step 필드를 set 한 마지막 단계** 에서 호출.
/// 누락 시 `Action::LoadPage` (Action.cpp:239-253) 가 페이지를 reset 으로 wipe.
pub fn set_action_checksum(buf: &mut [u8; 512]) {
    buf[HEADER_OFFSET_CHECKSUM] = 0;
    let sum: u8 = buf.iter().fold(0u8, |a, b| a.wrapping_add(*b));
    buf[HEADER_OFFSET_CHECKSUM] = 0xff_u8.wrapping_sub(sum);
}

/// **Phase G8**: 페이지 buffer 의 byte sum 이 ROBOTIS `VerifyChecksum` (Action.cpp:30-44)
/// 와 같은 식으로 0xff 와 일치하는지 검증.
pub fn verify_action_checksum(buf: &[u8; 512]) -> bool {
    let sum: u8 = buf.iter().fold(0u8, |a, b| a.wrapping_add(*b));
    sum == 0xff
}

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
        let raw_pages = read_bin4096_file(path).map_err(|e| SynthError::Decode(e.to_string()))?;
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
///
/// # 인덱싱 규약
///
/// `positions[i]` 는 JointId `i` 와 1:1 (slot 0 미사용). 따라서 ID 1..=20 만
/// 순회한다. (BLOCKER C2 — 2026-05-12 정정.)
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

    for id in 1u8..=20 {
        let i = id as usize;
        let diff = (last.positions[i] as i32 - first.positions[i] as i32).abs();
        if diff < THRESHOLD {
            continue;
        }
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

    /// **Phase G8 (Codex audit follow-up, 2026-05-15)**: `set_action_checksum` 가
    /// ROBOTIS `Action.cpp:47-61` 와 동일한 byte sum == 0xff 조건을 만든다.
    #[test]
    fn set_action_checksum_produces_total_sum_0xff() {
        let mut buf = [0u8; 512];
        // 임의 데이터로 채움.
        for (i, b) in buf.iter_mut().enumerate() {
            *b = (i % 251) as u8;
        }
        set_action_checksum(&mut buf);
        let sum: u8 = buf.iter().fold(0u8, |a, b| a.wrapping_add(*b));
        assert_eq!(
            sum, 0xff,
            "Action.cpp VerifyChecksum requires total sum == 0xff"
        );
        assert!(verify_action_checksum(&buf));
    }

    /// 빈 페이지 (모든 byte 0) 에도 정확히 checksum 적용.
    #[test]
    fn set_action_checksum_on_zero_buffer() {
        let mut buf = [0u8; 512];
        set_action_checksum(&mut buf);
        // 0 으로 채운 buf 의 sum 은 0 — checksum byte 만 0xff 가 되어야 함.
        assert_eq!(buf[HEADER_OFFSET_CHECKSUM], 0xff);
        assert!(verify_action_checksum(&buf));
    }

    /// 공식 raw page 를 디코드 → 다시 encode 후 checksum 이 ROBOTIS verifier 통과.
    /// `Action::LoadPage` (Action.cpp:239-253) 가 reject 하지 않는 buffer 인지 검증.
    #[test]
    fn encoded_official_page_passes_robotis_verify_checksum() {
        let path = official_bin_path();
        if !path.exists() {
            return;
        }
        let raw_pages = read_bin4096_file(&path).expect("read");
        // 공식 page 9 (walkready) 를 원본으로.
        let original = raw_pages.iter().find(|r| r.index == 9).expect("page 9");
        // raw 전체 (header + checksum 포함) 를 새 buffer 에 그대로 복사 후 byte sum 검증.
        let mut buf = [0u8; 512];
        buf.copy_from_slice(&original.raw);
        assert!(
            verify_action_checksum(&buf),
            "ROBOTIS 공식 page 9 의 raw checksum 이 0xff 검증 실패 — 파일 손상?"
        );
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
