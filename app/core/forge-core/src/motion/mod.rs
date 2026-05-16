//! 모션 데이터 모델 + RoboPlus Action `.mtn` ↔ 내부 JSON.
//!
//! Sprint 3.

pub mod bin4096;
pub mod library;
pub mod page;
pub mod parser;
pub mod player;
pub mod timeline;
pub mod walkready;
pub mod writer;

pub use bin4096::{parse_bin4096, read_bin4096_file, write_bin4096, RawPage, FILE_SIZE_BYTES};
pub use library::{Library, MotionId, MotionRecord, OfficialCatalogEntry, OFFICIAL_CATALOG};
pub use page::{Motion, MotionPage, MotionStep, SafetyClass, NUM_JOINTS_IN_STEP};
pub use parser::{parse_mtn, ParseError};
pub use player::{step_to_targets, CancelHandle, MotionPlayer};
pub use timeline::{interpolate, sample_at_ms, Easing};
pub use walkready::{
    action_page9_walkready_step, is_walkready_anchor, rms_distance_from_walkready,
    ACTION_PAGE9_WALKREADY_RAW,
};
pub use writer::write_mtn;
