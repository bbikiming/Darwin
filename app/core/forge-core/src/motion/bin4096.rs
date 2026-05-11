//! `motion_4096.bin` (RoboPlus Action 페이지 모음) 바이너리 파서.
//!
//! 공식 ROBOTIS-OP2 의 [`motion_4096.bin`] 은 256 페이지 × 512 byte/페이지 =
//! 131 072 byte. 각 페이지의 첫 14 byte는 ASCII name (`0x00` padded).
//!
//! [`motion_4096.bin`]: ../../../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin
//!
//! # 디자인
//!
//! Phase B 1차 목표는 **byte-preserving round-trip** + name 추출. 페이지 내부의
//! step / compliance / play_param 의 정확한 offset 은 RoboPlus Action.cpp
//! (vendor pending) 가 확정될 때까지 raw payload 로 보존한다. 의미 해석은
//! 별도 PR.

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

/// 한 페이지의 byte 크기 (공식 motion_4096.bin 확정).
pub const PAGE_SIZE_BYTES: usize = 512;
/// 한 파일의 페이지 수 (공식 motion_4096.bin 확정).
pub const NUM_PAGES: usize = 256;
/// 전체 파일 크기.
pub const FILE_SIZE_BYTES: usize = PAGE_SIZE_BYTES * NUM_PAGES;
/// Name 필드 크기 (ASCII, null-padded).
pub const NAME_LEN: usize = 14;

/// 페이지 raw — byte-preserving. 의미 해석은 별도.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawPage {
    /// 페이지 ID (1..=255, 0 = 빈 슬롯).
    pub index: u8,
    /// 첫 14 byte에서 추출한 사람-읽는 이름.
    pub name: String,
    /// 전체 512 byte payload (name 포함).
    #[serde(with = "serde_bytes_vec")]
    pub raw: Vec<u8>,
}

impl RawPage {
    /// 이 슬롯이 비어 있는가 (모든 byte 0).
    pub fn is_empty(&self) -> bool {
        self.raw.iter().all(|b| *b == 0)
    }

    /// name 이 비어 있나 (모든 ASCII byte 0).
    pub fn name_is_blank(&self) -> bool {
        self.name.is_empty()
    }
}

mod serde_bytes_vec {
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(v: &[u8], s: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        s.serialize_bytes(v)
    }

    pub fn deserialize<'de, D>(d: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        Vec::<u8>::deserialize(d)
    }
}

/// 파일 또는 메모리 buffer → 256 페이지.
pub fn parse_bin4096(bytes: &[u8]) -> io::Result<Vec<RawPage>> {
    if bytes.len() != FILE_SIZE_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "motion_4096.bin 크기는 {} byte 여야 함 (받음: {})",
                FILE_SIZE_BYTES,
                bytes.len()
            ),
        ));
    }
    let mut pages = Vec::with_capacity(NUM_PAGES);
    for i in 0..NUM_PAGES {
        let start = i * PAGE_SIZE_BYTES;
        let end = start + PAGE_SIZE_BYTES;
        let slice = &bytes[start..end];
        let name = extract_name(&slice[..NAME_LEN]);
        pages.push(RawPage {
            index: i as u8,
            name,
            raw: slice.to_vec(),
        });
    }
    Ok(pages)
}

/// 256 페이지 → 131 072 byte. 입력 페이지 수가 256보다 작으면 나머지 0-fill.
pub fn write_bin4096<W: Write>(pages: &[RawPage], w: &mut W) -> io::Result<()> {
    if pages.len() > NUM_PAGES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("최대 {} 페이지", NUM_PAGES),
        ));
    }
    for page in pages.iter() {
        if page.raw.len() != PAGE_SIZE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!(
                    "페이지 raw 길이는 {} byte 여야 함 (받음 {})",
                    PAGE_SIZE_BYTES,
                    page.raw.len()
                ),
            ));
        }
        w.write_all(&page.raw)?;
    }
    // 나머지 페이지를 0-fill.
    let filler = vec![0u8; PAGE_SIZE_BYTES];
    for _ in pages.len()..NUM_PAGES {
        w.write_all(&filler)?;
    }
    Ok(())
}

/// 처음 14 byte 에서 ASCII name 을 추출. NULL terminator 까지.
fn extract_name(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end])
        .trim_end()
        .to_string()
}

/// 편의 — 파일 경로에서 직접 read.
pub fn read_bin4096_file(path: &std::path::Path) -> io::Result<Vec<RawPage>> {
    let mut bytes = Vec::with_capacity(FILE_SIZE_BYTES);
    std::fs::File::open(path)?.read_to_end(&mut bytes)?;
    parse_bin4096(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    const OFFICIAL_BIN: &[u8] = include_bytes!(
        "../../../../../research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin"
    );

    #[test]
    fn official_bin_is_131072_bytes() {
        assert_eq!(OFFICIAL_BIN.len(), FILE_SIZE_BYTES);
    }

    #[test]
    fn parses_256_pages_from_official_bin() {
        let pages = parse_bin4096(OFFICIAL_BIN).expect("parse");
        assert_eq!(pages.len(), NUM_PAGES);
    }

    #[test]
    fn extracts_known_page_names_from_official_bin() {
        let pages = parse_bin4096(OFFICIAL_BIN).expect("parse");
        // page 0 = empty
        assert!(pages[0].is_empty(), "page 0 should be empty");
        // 이 파일은 페이지 1..부터 실 모션 — name 첫 글자가 ASCII letter 이어야.
        let nonempty: Vec<&RawPage> = pages.iter().filter(|p| !p.is_empty()).collect();
        assert!(
            nonempty.len() > 5,
            "expected several non-empty pages, got {}",
            nonempty.len()
        );
        // 첫 번째 nonempty page name 이 비어있지 않아야.
        let first_named = nonempty
            .iter()
            .find(|p| !p.name_is_blank())
            .expect("at least one named page");
        assert!(!first_named.name.is_empty());
    }

    #[test]
    fn round_trip_official_bin_is_byte_identical() {
        let pages = parse_bin4096(OFFICIAL_BIN).expect("parse");
        let mut out = Vec::with_capacity(FILE_SIZE_BYTES);
        write_bin4096(&pages, &mut out).expect("write");
        assert_eq!(out.len(), OFFICIAL_BIN.len());
        assert_eq!(
            out, OFFICIAL_BIN,
            "round-trip is not byte-identical — parser/writer asymmetric"
        );
    }

    #[test]
    fn detects_size_mismatch() {
        let result = parse_bin4096(&[0u8; 100]);
        assert!(result.is_err());
    }

    #[test]
    fn empty_pages_serialize_to_zeros() {
        let pages = vec![RawPage {
            index: 0,
            name: String::new(),
            raw: vec![0u8; PAGE_SIZE_BYTES],
        }];
        let mut out = Vec::new();
        write_bin4096(&pages, &mut out).unwrap();
        assert_eq!(out.len(), FILE_SIZE_BYTES);
        assert!(out.iter().all(|b| *b == 0));
    }
}
