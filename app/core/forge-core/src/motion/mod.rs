//! 모션 데이터 모델 + RoboPlus Action `.mtn` ↔ 내부 JSON.
//!
//! Sprint 3.

pub mod library;
pub mod page;
pub mod parser;
pub mod timeline;
pub mod writer;

pub use library::{Library, MotionId, MotionRecord};
pub use page::{Motion, MotionPage, MotionStep, NUM_JOINTS_IN_STEP};
pub use parser::{parse_mtn, ParseError};
pub use timeline::{interpolate, sample_at_ms, Easing};
pub use writer::write_mtn;
