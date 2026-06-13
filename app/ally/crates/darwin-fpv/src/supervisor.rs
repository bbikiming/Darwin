//! 수퍼바이저 워치독 — §2 "수퍼바이저 스레드"의 순수 판정 + 공유 하트비트.
//!
//! 수퍼바이저는 100ms 주기로 (1)패드 단절 (2)webview 포커스 상실 (3)절전 진입
//! (4)**TX 틱 하트비트 침묵 >300ms** 를 감시해 E-STOP 채널로 보낸다. (2)(3)은 OS/Tauri
//! 이벤트라 Tauri 셸(Phase 3)이 주입하고, 여기서는 호스트에서 검증 가능한 (1)(4)의 순수
//! 판정과 TX↔수퍼바이저 공유 하트비트 레지스터를 둔다.

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

/// TX 틱 하트비트 침묵 임계 — §2/§8: >300ms → 제어 루프 행으로 보고 E-STOP.
pub const TX_STALL_MS: i64 = 300;

/// 마지막 TX 하트비트(ms) 기준 침묵 판정. `last_hb_ms == 0`(미기동)은 행 아님.
pub fn tx_heartbeat_stalled(last_hb_ms: i64, now_ms: i64) -> bool {
    last_hb_ms > 0 && now_ms.saturating_sub(last_hb_ms) > TX_STALL_MS
}

/// TX 스레드와 수퍼바이저가 공유하는 하트비트 레지스터. TX 가 매 틱 `beat`, 수퍼바이저가
/// `stalled` 로 행 감시. lock-free(AtomicI64) — 워치독 자체가 행에 걸리지 않게.
#[derive(Clone, Default)]
pub struct Heartbeat(Arc<AtomicI64>);

impl Heartbeat {
    pub fn new() -> Self {
        Heartbeat(Arc::new(AtomicI64::new(0)))
    }

    /// TX 스레드: 틱마다 호출(현재 단조 ms 기록).
    pub fn beat(&self, now_ms: i64) {
        self.0.store(now_ms, Ordering::Relaxed);
    }

    /// 마지막 하트비트 ms(0 = 아직 한 번도 안 뜀).
    pub fn last(&self) -> i64 {
        self.0.load(Ordering::Relaxed)
    }

    /// 수퍼바이저: TX 가 >300ms 침묵했는가(행 의심).
    pub fn stalled(&self, now_ms: i64) -> bool {
        tx_heartbeat_stalled(self.last(), now_ms)
    }
}

/// 패드 연결 상태 에지 감지 — connected→disconnected 하강에서 1회 true(단절 발화).
/// 재연결 후 다시 단절하면 또 발화한다(상태 유지형 백스톱).
#[derive(Debug, Clone, Copy, Default)]
pub struct PadWatch {
    was_connected: bool,
}

impl PadWatch {
    pub fn new() -> Self {
        PadWatch::default()
    }

    /// 현재 연결 상태를 관측. 직전이 연결이고 지금 단절이면 true(E-STOP 발화 시점).
    pub fn observe(&mut self, connected: bool) -> bool {
        let lost = self.was_connected && !connected;
        self.was_connected = connected;
        lost
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stall_threshold() {
        assert!(!tx_heartbeat_stalled(0, 10_000), "미기동(0)은 행 아님");
        assert!(!tx_heartbeat_stalled(1000, 1300), "정확히 300ms 는 아직 아님");
        assert!(tx_heartbeat_stalled(1000, 1301), ">300ms → 행");
    }

    #[test]
    fn heartbeat_beat_then_not_stalled() {
        let hb = Heartbeat::new();
        assert!(!hb.stalled(5000), "beat 전엔 행 판정 안 함");
        hb.beat(5000);
        assert!(!hb.stalled(5200));
        assert!(hb.stalled(5400), "마지막 beat 후 >300ms → 행");
    }

    #[test]
    fn pad_watch_fires_only_on_falling_edge() {
        let mut w = PadWatch::new();
        assert!(!w.observe(false), "처음부터 미연결 — 하강 아님");
        assert!(!w.observe(true), "연결 — 발화 아님");
        assert!(!w.observe(true), "연결 유지 — 발화 아님");
        assert!(w.observe(false), "연결→단절 하강 — 발화");
        assert!(!w.observe(false), "단절 유지 — 재발화 안 함");
        assert!(!w.observe(true), "재연결");
        assert!(w.observe(false), "다시 단절 — 또 발화");
    }
}
