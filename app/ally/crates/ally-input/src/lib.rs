//! ally-input — 게임패드 입력·매핑·안전 게이트 (W1 구현 예정).
//!
//! W1 범위 (docs/03_ARCHITECTURE.md §2·§6):
//! - gilrs 250Hz 폴링 스레드, B 버튼 rising edge → 무손실 estop 채널
//! - [`g01`] 동결 매핑 적용 (데드존→곡선→부호→레이트 적분)
//! - 안전 게이트 상태머신: DISARMED → ARMED → ESTOP_LATCH → (Y 복구) → ARMED
//! - EMA(α=0.5) 스무딩 + snap-to-zero + InputFrame 신선도(>150ms → zero+disarm)

pub mod g01;
