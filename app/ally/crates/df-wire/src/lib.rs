//! df-wire — WalkLab 브로커리지 와이어 계약의 순함수 계층.
//!
//! `docs/ssh-parity-contract.md`(§G UDP·§C 14-token·§A.2-TEL2)가 단일 진실원이고,
//! 구현은 실기 검증된 Python 원본
//! `tools/switch-pilot/src/darwin_switch_agent/df_udp.py` 와
//! `ssh_control_client.py::_build_line/_gait_params` 를 1:1 포팅한 것이다.
//! 여기서 와이어 포맷을 발명하지 않는다 — 계약 위반은 곧 로봇 오동작이다.
//!
//! 패리티 보증: `scripts/gen-golden-vectors.py` 가 Python 원본을 실행해 만든
//! 골든 벡터(`tests/fixtures/`)를 `tests/parity.rs` 가 바이트/캐노니컬 동일성으로
//! 검증한다. 이 크레이트를 수정하면 반드시 패리티 테스트가 통과해야 한다.
//!
//! 소켓·스레드·시계는 이 크레이트에 없다 — 그건 ally-link(W1)의 책임이다.

pub mod line;
pub mod tel2;
pub mod token;
pub mod wire;

pub use line::{build_line, gait_params, GaitConfig, MotionCommand};
pub use tel2::{battery_from_dv, parse_tel2, Tel2, BATTERY_MAX_V, BATTERY_MIN_V};
pub use token::{gen_cmd_id, gen_token, WireRng, CMD_ID_LENGTH, TOKEN_LENGTH};
pub use wire::{
    cmd_datagram, estop_datagram, handshake_line, parse_ack, DEFAULT_CMD_PORT, DEFAULT_ESTOP_PORT,
    DEFAULT_TELEMETRY_PORT, ESTOP_BURST_OFFSETS_MS,
};
