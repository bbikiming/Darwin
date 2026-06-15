//! ally-input — 게임패드 입력·G01 매핑·안전 게이트 (W1).
//!
//! 실기 검증된 `firmware-patches/walklab-brokerage/GamepadPilot.{h,cpp}` 의 **순수 로직을
//! Rust 로 번역**한 것이다(발명 아님 — 매핑 수치는 [`g01`] 에 동결, INV-4). 장치 I/O 만
//! 새로 쓴다(evdev → gilrs/XInput).
//!
//! 계층(전부 순수 → 호스트 테스트):
//! - [`frame`]  : `InputFrame` 정규화 스냅샷(gilrs 비의존)
//! - [`shape`]  : 데드존·곡선·턴 성형 순함수(`Gp*` 1:1)
//! - [`head`]   : 우스틱 헤드 레이트 적분(hold)
//! - [`gate`]   : ARM/E-STOP/복구 settle + failsafe 3티어 + idle/중립 게이트
//! - [`command`]: 틱 통합([`Pilot`]) → df-wire `MotionCommand`
//! - [`source`] : gilrs 어댑터(feature `device` — OS 장치 폴링; 안전 로직 비관여)
//!
//! **ally 콕핏 의미론**(온보드 GamepadPilot 과 분기): A=ARM·B=E-STOP·Y=복구·X=볼트랙(W1 미배선)
//! ·RB=터보·우스틱=헤드 레이트·LT/RT=턴. 킥/D-패드/볼-추종은 온보드 전용 — W1 범위 아님.
//!
//! 7-스레드 구동(입력 250Hz·TX 20Hz·E-STOP·RX·SSH·수퍼바이저)은 darwin-fpv(W2)가 이 위에
//! 올린다. [`Pilot`] 은 **입력 레이트**로 구동되어야 B E-STOP disarm 이 즉시 반영된다(INV-1).

pub mod command;
pub mod frame;
pub mod g01;
pub mod gate;
pub mod head;
pub mod shape;

#[cfg(feature = "device")]
pub mod source;

pub use command::{g01_gait_config, map_frame, ButtonEdges, Pilot, TickOutput};
pub use frame::{clamp_stick, clamp_trigger, InputFrame};
pub use gate::{failsafe_decision, settle_armed, Failsafe, SafetyGate};
pub use head::HeadHold;
pub use shape::moving_intent;
