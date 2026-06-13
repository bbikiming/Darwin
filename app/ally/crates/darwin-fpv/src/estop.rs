//! 무손실 E-STOP 채널 (§2 채널 규율).
//!
//! Mac 콕핏 불변식 그대로 — **디바운스·스로틀·컨플레이션 금지**, rising edge 즉시 발화.
//! 물리 B(입력 스레드)·수퍼바이저(패드단절·포커스상실·절전·TX행)·터치 3계가 같은
//! unbounded mpsc 로 수렴하고, E-STOP 스레드가 선착 수신해 UDP ×3연발 + SSH touch 한다.
//! unbounded 라 송신측이 막히지 않고, 모든 발화가 유실 없이 도착한다(연발/연타 보존).

use std::sync::mpsc::{self, Receiver, Sender};

use ally_input::EstopReason;

/// E-STOP 발원 종류 — 발화 후 진단·로깅용(처리 자체는 종류 무관, 즉시 정지).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EstopCause {
    /// 물리 B 버튼(입력 스레드, 1차 발원).
    Button,
    /// 패드 단절(gilrs Disconnected → 수퍼바이저).
    PadLost,
    /// webview 포커스 상실(Game Bar 오버레이 등 → 수퍼바이저).
    FocusLost,
    /// 절전 진입(WM_POWERBROADCAST PBT_APMSUSPEND → 수퍼바이저).
    Suspend,
    /// TX 틱 하트비트 침묵 >300ms(제어 루프 행 → 수퍼바이저).
    TxStall,
    /// 터치 E-STOP 버튼(보조 경로, webview 경유).
    Touch,
    /// 입력 신선도/슬루 정지 합성(failsafe).
    Stale,
}

impl EstopCause {
    /// ally-input 발원 사유 → 런타임 cause. W1 입력 발원은 B 버튼뿐.
    pub fn from_reason(reason: EstopReason) -> Self {
        match reason {
            EstopReason::PadButtonB => EstopCause::Button,
        }
    }
}

/// 한 건의 E-STOP 발화 — 발원 + monotonic ms(발화→소켓 write 내부 지연 측정용).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EstopEvent {
    pub cause: EstopCause,
    pub t_ms: i64,
}

/// 무손실 E-STOP 송신단(복제 가능 — 다중 발원). 수신단은 E-STOP 스레드 하나뿐.
#[derive(Clone)]
pub struct EstopBus {
    tx: Sender<EstopEvent>,
}

impl EstopBus {
    /// (송신 버스, 수신단) 생성. unbounded — 발화는 절대 차단·유실되지 않는다.
    pub fn channel() -> (EstopBus, Receiver<EstopEvent>) {
        let (tx, rx) = mpsc::channel();
        (EstopBus { tx }, rx)
    }

    /// 즉시 발화(비차단·무손실). 수신단이 사라졌으면 무시(종료 경합 — 무해).
    pub fn fire(&self, cause: EstopCause, t_ms: i64) {
        let _ = self.tx.send(EstopEvent { cause, t_ms });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reason_maps_to_button() {
        assert_eq!(
            EstopCause::from_reason(EstopReason::PadButtonB),
            EstopCause::Button
        );
    }

    #[test]
    fn lossless_no_conflation_under_burst() {
        // 같은 cause 를 연타해도 컨플레이트(병합)되지 않고 전부 도착해야 한다 — INV.
        let (bus, rx) = EstopBus::channel();
        for i in 0..50 {
            bus.fire(EstopCause::Button, i);
        }
        let got: Vec<_> = rx.try_iter().collect();
        assert_eq!(got.len(), 50, "연타 50발 전부 도착(컨플레이션 금지)");
        assert_eq!(got[0].t_ms, 0);
        assert_eq!(got[49].t_ms, 49);
    }

    #[test]
    fn multi_producer_all_delivered() {
        let (bus, rx) = EstopBus::channel();
        let b2 = bus.clone();
        bus.fire(EstopCause::Button, 1);
        b2.fire(EstopCause::TxStall, 2);
        bus.fire(EstopCause::Touch, 3);
        let causes: Vec<_> = rx.try_iter().map(|e| e.cause).collect();
        assert_eq!(
            causes,
            vec![EstopCause::Button, EstopCause::TxStall, EstopCause::Touch]
        );
    }
}
