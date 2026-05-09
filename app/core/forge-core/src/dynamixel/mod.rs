//! Dynamixel Protocol 1.0 코덱 — Sprint 1.
//!
//! 출처: `docs/protocols/dynamixel-1.0.md`.
//! ROBOTIS-GIT/DynamixelSDK (Apache 2.0)을 1차 참조.

pub mod v1;
pub mod v2;

pub use v1::{Codec, CodecError, ErrorFlags, Instruction, InstructionPacket, StatusPacket};
