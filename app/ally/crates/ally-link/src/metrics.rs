//! 연결 품질 메트릭 — `df_udp.py::_on_ack/_trim_rate/effective_hz` 의 순함수 포팅.
//!
//! 시계는 여기 없다 — 호출자가 `now_ms`/`rtt_ms` 를 주입한다(df-wire 와 동일 규율,
//! 테스트 가능성). 실시간 샘플링은 ally-link 의 RX 스레드·ally-cli 가 소유한다.

use std::collections::VecDeque;

/// ACK RTT 의 지수이동평균 — `df_udp.py` α=0.3.
#[derive(Debug, Clone)]
pub struct RttEma {
    alpha: f64,
    value: Option<f64>,
}

impl RttEma {
    /// α=0.3 (검증값). 다른 α 는 `with_alpha`.
    pub fn new() -> Self {
        Self::with_alpha(0.3)
    }

    pub fn with_alpha(alpha: f64) -> Self {
        RttEma {
            alpha: alpha.clamp(0.0, 1.0),
            value: None,
        }
    }

    /// RTT 표본 반영. 첫 표본은 그대로 시드, 이후 EMA.
    pub fn update(&mut self, rtt_ms: f64) {
        if rtt_ms < 0.0 {
            return; // 음수 RTT(시계 역행)는 무시 — 잡음 주입 방지.
        }
        self.value = Some(match self.value {
            None => rtt_ms,
            Some(prev) => self.alpha * rtt_ms + (1.0 - self.alpha) * prev,
        });
    }

    /// 현재 EMA(ms) — 표본 전이면 None.
    pub fn value(&self) -> Option<f64> {
        self.value
    }
}

impl Default for RttEma {
    fn default() -> Self {
        Self::new()
    }
}

/// 슬라이딩 윈도 내 ACK 도착 수 → 유효 명령 도달율(Hz). `df_udp.py::effective_hz` 등가.
/// 윈도 1s 기본 — 20Hz 송신이 무손실이면 ~20을 반환한다.
///
/// **전제**: `record`/`rate` 의 `now_ms` 는 단조 증가해야 한다(실시간 clock 주입).
/// 시계 역행 시 트림이 과도하게 비울 수 있으나 안전 측(저평가)이라 무해하다.
#[derive(Debug, Clone)]
pub struct EffHz {
    window_ms: i64,
    stamps: VecDeque<i64>,
}

impl EffHz {
    pub fn new() -> Self {
        Self::with_window(1000)
    }

    pub fn with_window(window_ms: i64) -> Self {
        EffHz {
            window_ms: window_ms.max(1),
            stamps: VecDeque::new(),
        }
    }

    /// ACK 도착 1건 기록(now_ms) + 윈도 밖 표본 폐기.
    pub fn record(&mut self, now_ms: i64) {
        self.stamps.push_back(now_ms);
        self.trim(now_ms);
    }

    fn trim(&mut self, now_ms: i64) {
        let cutoff = now_ms - self.window_ms;
        while let Some(&front) = self.stamps.front() {
            if front < cutoff {
                self.stamps.pop_front();
            } else {
                break;
            }
        }
    }

    /// 현재 유효 Hz = 윈도 내 표본수 / 윈도(초). now_ms 로 먼저 트림.
    pub fn rate(&mut self, now_ms: i64) -> f64 {
        self.trim(now_ms);
        self.stamps.len() as f64 * 1000.0 / self.window_ms as f64
    }
}

impl Default for EffHz {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rtt_ema_seeds_then_smooths() {
        let mut e = RttEma::with_alpha(0.3);
        assert_eq!(e.value(), None);
        e.update(100.0);
        assert_eq!(e.value(), Some(100.0)); // 첫 표본 = 시드
        e.update(200.0);
        // 0.3*200 + 0.7*100 = 130
        assert!((e.value().unwrap() - 130.0).abs() < 1e-9);
    }

    #[test]
    fn rtt_ema_ignores_negative() {
        let mut e = RttEma::new();
        e.update(50.0);
        e.update(-5.0); // 시계 역행 — 무시
        assert_eq!(e.value(), Some(50.0));
    }

    #[test]
    fn eff_hz_counts_within_window() {
        let mut h = EffHz::with_window(1000);
        for i in 0..20 {
            h.record(i * 50); // 0..950ms, 20건/1s
        }
        // now=950 기준 전부 윈도 내 → 20Hz
        assert!((h.rate(950) - 20.0).abs() < 1e-9);
    }

    #[test]
    fn eff_hz_drops_stale() {
        let mut h = EffHz::with_window(1000);
        h.record(0);
        h.record(100);
        // now=1500 → 0(<500 cutoff)·100(<500) 둘 다 폐기 → 0Hz
        assert!((h.rate(1500) - 0.0).abs() < 1e-9);
    }

    #[test]
    fn eff_hz_half_window() {
        let mut h = EffHz::with_window(2000);
        h.record(0);
        h.record(1000);
        // 윈도 2s 에 2건 → 1Hz
        assert!((h.rate(1000) - 1.0).abs() < 1e-9);
    }
}
