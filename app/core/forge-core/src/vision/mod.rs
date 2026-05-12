//! 비전 파이프라인 — Sprint 6 MVP.
//!
//! 카메라 캡처는 Mac AVFoundation에서 이뤄지므로 우리 Rust 코어는
//! **이미지 처리 알고리즘만** 담당. RGBA → HSV 변환, 색 segmentation,
//! 단순 blob detection.

pub mod frame;
pub mod segmentation;

pub use frame::{Frame, Pixel};
pub use segmentation::{detect_blob, BlobResult, HsvRange};
