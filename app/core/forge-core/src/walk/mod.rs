//! Walking engine — DARwIn-OP / OP2.
//!
//! Sprint 5 MVP. 1차 출처: ROBOTIS-OP2/op2_walking_module (Apache 2.0).
//! 자세한 명세: `docs/architecture/walking-engine.md`.
//!
//! 본 sprint는 *데이터 모델 + 시간 진행 로직*까지. 실 IK · IMU 닫힌 루프
//! · 실기기 검증은 후속 사이클 / Mac 검증.

pub mod engine;
pub mod imu;
pub mod ini_pose;
pub mod params;
pub mod preset;

pub use engine::{WalkCommand, WalkEngine, WalkPhase};
pub use imu::{ComplementaryFilter, ImuSample};
pub use ini_pose::{walk_ready_targets, WALK_READY_DEGREES};
pub use params::WalkParams;
pub use preset::{WalkPreset, WalkSafety};
