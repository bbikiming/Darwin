//! Motion Synthesis 엔진 — 기존 모션 페이지를 reference로 새 페이지를 합성.
//!
//! **Sprint 9 완료.** S9-2 library, S9-3 sequence, S9-4 layer, S9-5 morph,
//! S9-6 mutate, S9-7 mirror, S9-8 procedural, S9-9 V1+V2 validator,
//! S9-10 V3+V4 validator, S9-12 integration 모두 본구현.
//!
//! 자세한 명세는 [`docs/prd/motion-synthesis-v1.md`] 참조.
//!
//! # 모듈 구성
//! - [`library`] — Reference 모션 라이브러리 (페이지 저장소 + 자동 메타데이터)
//! - [`metadata`] — 페이지 시맨틱 메타데이터 (태그·부위·미러쌍)
//! - [`ops`] — 합성 연산자 (Sequence / Layer / Morph / Mutate / Mirror / Procedural)
//! - [`validator`] — 4-stage 안전 검증 (Joint Limit → Velocity → Collision → Stability)
//! - [`provenance`] — Synthesis provenance manifest
//! - [`error`] — `SynthError`
//!
//! [`docs/prd/motion-synthesis-v1.md`]: ../../../docs/prd/motion-synthesis-v1.md

pub mod error;
pub mod library;
pub mod metadata;
pub mod ops;
pub mod provenance;
pub mod validator;

#[cfg(test)]
mod integration;
#[cfg(test)]
mod test_fixtures;

pub use error::{Result, SynthError};
pub use library::PageLibrary;
pub use metadata::{BodyRegion, PageMetadata, Tag};
pub use ops::SynthOp;
pub use provenance::Manifest;
pub use validator::{Validator, ValidatorReport, ValidatorStage};
