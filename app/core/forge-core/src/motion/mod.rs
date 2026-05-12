//! 모션 데이터 모델 + RoboPlus Action `.mtn` ↔ 내부 JSON.
//!
//! Sprint 3.

pub mod bin4096;
pub mod library;
pub mod page;
pub mod parser;
pub mod timeline;
pub mod writer;

pub use bin4096::{parse_bin4096, read_bin4096_file, write_bin4096, RawPage, FILE_SIZE_BYTES};
pub use library::{Library, MotionId, MotionRecord, OfficialCatalogEntry, OFFICIAL_CATALOG};
pub use page::{Motion, MotionPage, MotionStep, SafetyClass, NUM_JOINTS_IN_STEP};
pub use parser::{parse_mtn, ParseError};
pub use timeline::{interpolate, sample_at_ms, Easing};
pub use writer::write_mtn;
