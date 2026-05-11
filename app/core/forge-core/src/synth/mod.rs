//! Motion Synthesis 엔진 — 기존 모션 페이지를 reference로 새 페이지를 합성.
//!
//! **Sprint 9-1 스켈레톤.** 모든 연산자와 validator는 시그니처만 정의되어 있고
//! 본체는 [`todo!()`]이다. 구현은 후속 작업(S9-2 ~ S9-12)에서 채워진다.
//!
//! 자세한 명세는 [`docs/prd/motion-synthesis-v1.md`] 참조.
//!
//! # 모듈 구성
//! - [`library`] — Reference 모션 라이브러리 (페이지 저장소)
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
mod test_fixtures;

pub use error::{Result, SynthError};
pub use library::PageLibrary;
pub use metadata::{BodyRegion, PageMetadata, Tag};
pub use ops::SynthOp;
pub use provenance::Manifest;
pub use validator::{Validator, ValidatorReport, ValidatorStage};
