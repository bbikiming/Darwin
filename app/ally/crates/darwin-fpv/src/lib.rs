//! darwin-fpv 런타임 — DARwIn FPV 의 안전·제어 코어 (docs/03_ARCHITECTURE.md §2 7스레드 모델).
//!
//! 이 라이브러리는 `ally-input`(게임패드·G01 매핑·안전 게이트)과 `ally-link`(UDP·SSH·
//! 메트릭) 위에 §2 의 스레드 모델·채널 규율·StateHub 를 올린다. `ally-cli connect` 가
//! 단일 스레드로 증명한 §7 세션 시퀀스를, 입력 구동·연속 운전형으로 다중 스레드화한 것.
//!
//! ## 핵심 불변식 — INV-2 (§1)
//!
//! webview 는 어떤 안전 경로에도 없다. 이 크레이트는 **tauri 를 의존하지 않는다** —
//! 표시계층으로의 푸시는 [`event::EventSink`] 트레이트로만 일어난다. Tauri 셸(Phase 3)이
//! 이 트레이트를 구현해 Tauri 이벤트로 변환한다. 안전 스레드(입력·TX·E-STOP)는 표시
//! 객체를 일절 참조하지 않으므로, webview 가 죽어도 입력→TX·입력→E-STOP 은 동작한다.
//!
//! ## 모듈
//!
//! - [`state`] — `StateHub`(RwLock 스냅샷) + §3 상태 스키마.
//! - [`event`] — `EventSink` 트레이트(표시계층 경계) + 무동작 `NullSink`.
//! - [`estop`] — 무손실 E-STOP 채널(디바운스·스로틀·컨플레이션 금지, §2 채널 규율).
//! - [`tx`]    — 제어 TX 파이프라인(신선도→매핑→게이트→스무딩→14-token). 순수·단위검증.
//! - [`supervisor`] — TX 하트비트 워치독(침묵 >300ms → E-STOP). 순수·단위검증.
//! - [`runtime`] — 스레드 기동·배선(Phase 2b).
//!
//! Phase 2a 는 순수 안전 로직(state/event/estop/tx/supervisor)을 단위검증까지 확정한다.
//! 스레드 런타임([`runtime`])과 Tauri 셸은 그 위에 올린다.

pub mod estop;
pub mod event;
pub mod state;
pub mod supervisor;
pub mod tx;

pub use estop::{EstopBus, EstopCause, EstopEvent};
pub use event::{EventSink, NullSink};
pub use state::{ConnPath, ConnState, ConnTransport, Snapshot, StateHub};
pub use supervisor::Heartbeat;
pub use tx::{TxOutcome, TxPipeline};
