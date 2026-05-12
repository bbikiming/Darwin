//! 안전 게이트 — 토크 ramp · 자가 충돌 검사 · 위험 모션 분류.
//!
//! Phase A: 토크 ramp만. Phase B에서 self_collision + catalog 분류 추가.

pub mod self_collision;
pub mod torque_ramp;

pub use self_collision::{check_page, check_step, CollisionError};
pub use torque_ramp::{TorqueRampProfile, TorqueRamper};
