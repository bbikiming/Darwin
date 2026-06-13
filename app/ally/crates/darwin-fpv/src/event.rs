//! EventSink — 런타임과 표시계층의 경계 (INV-2 의 구조적 강제).
//!
//! 안전·제어 런타임은 webview/Tauri 를 모른다. 표시계층으로의 push 는 전부 이 트레이트를
//! 통한다. Tauri 셸(Phase 3)이 `AppHandle` 을 들고 이 트레이트를 구현해 §3 의 `state`(30Hz)·
//! `stick`(60Hz)·`pose`(30Hz) 이벤트로 변환한다. 런타임 라이브러리에는 그 핸들이 없으므로
//! **표시계층이 멈춰도 안전 경로는 영향받지 않는다** — 컴파일 단위 분리로 INV-2 를 보장한다.

use crate::state::Snapshot;

/// 표시계층 싱크. 모든 메서드는 안전 스레드에서 호출될 수 있으므로 짧고 비차단이어야 한다
/// (구현이 막히면 그 호출 스레드만 느려질 뿐, estop 채널·소켓 송신과는 무관 — INV-2).
pub trait EventSink: Send + Sync + 'static {
    /// §3 `state` — HUD 상태 스냅샷 전체(30Hz 케이던스).
    fn emit_state(&self, snapshot: &Snapshot);

    /// §3 `stick` — 스틱/트리거 readout 오버레이(60Hz, 표시 지연감 제거).
    fn emit_stick(&self, lx: f64, ly: f64, rx: f64, ry: f64, lt: f64, rt: f64);
}

/// 무동작 싱크 — 헤드리스 셀프체크·테스트용(표시계층 없음).
pub struct NullSink;

impl EventSink for NullSink {
    fn emit_state(&self, _snapshot: &Snapshot) {}
    fn emit_stick(&self, _lx: f64, _ly: f64, _rx: f64, _ry: f64, _lt: f64, _rt: f64) {}
}
