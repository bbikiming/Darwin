//! `forge-core` — DarwinForge의 Rust 코어.
//!
//! Phase 4 스캐폴드. 모듈 골격만 두고 Sprint 1~6에서 채워진다.
//!
//! # 모듈 구성
//! - [`error`]    — 공통 에러 타입
//! - [`dynamixel`] — Protocol 1.0 패킷 코덱
//! - [`serial`]   — `SerialPort` trait + `LoopbackBus`
//! - [`controller`] — CM-730 / CM-740 추상화
//! - [`joint`]    — 20-DOF 관절 ID 매핑 (Phase 2 docs/architecture/joint-conventions.md)
//! - `motion`     — Sprint 3+
//! - `walk`       — Sprint 5
//! - `vision`     — Sprint 6
//! - `db`         — Sprint 4
//!
//! # 라이선스
//! Apache 2.0. ROBOTIS upstream framework와 호환.

#![warn(missing_docs)]
#![warn(rust_2018_idioms)]

pub mod controller;
pub mod dynamixel;
pub mod error;
pub mod joint;
pub mod serial;

pub use error::Error;
