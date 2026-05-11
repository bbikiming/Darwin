//! Motion Synthesis MCP 서버 — stdio JSON-RPC 기반.
//!
//! Sprint 10 (S10-5 ~ S10-7). PRD §5.5 / §9.2 명세 그대로.
//!
//! # 프로토콜
//!
//! - JSON-RPC 2.0 over stdio.
//! - MCP 표준 메서드: `initialize`, `tools/list`, `tools/call`.
//! - Notification: `notifications/initialized` 무시 (silently ack).
//!
//! # 도구 (11개)
//!
//! 1. `library_search` — 페이지 검색 (query / tag / safety)
//! 2. `library_get` — 특정 페이지 + 메타데이터 조회
//! 3. `synth_sequence` — 페이지 시퀀스 연결
//! 4. `synth_layer` — 부위별 동시 합성
//! 5. `synth_morph` — 두 페이지 가중 평균
//! 6. `synth_mutate` — 단일 페이지 변형
//! 7. `synth_mirror` — 좌우 반전
//! 8. `synth_procedural` — 궤적 함수로 step 생성
//! 9. `validate` — 4-stage validator 실행
//! 10. `commit` — bin 슬롯에 기록 + 자동 백업
//! 11. `preview` — ASCII timeline (gif/3d-trace 후속)
//!
//! # 안전
//!
//! `commit` 도구는 V1/V2/V3/V4 통과 후에만 실행. validator FAIL 이면 거부.
//! PRD §12.3 R6 충돌 회피.

#![warn(missing_docs)]
#![warn(rust_2018_idioms)]

pub mod engine;
pub mod protocol;
pub mod tools;

pub use engine::Engine;
pub use protocol::{handle_line, JsonRpcError, JsonRpcRequest, JsonRpcResponse};
pub use tools::{tool_definitions, ToolError};

/// MCP 프로토콜 버전 — 클라이언트와 협상.
pub const MCP_PROTOCOL_VERSION: &str = "2024-11-05";

/// 본 MCP 서버의 식별자.
pub const SERVER_NAME: &str = "forge-motion-synth";

/// 본 MCP 서버의 버전.
pub const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");
