//! 안전 게이트 상태기계 — `GamepadPilot` 의 ARM/E-STOP/복구/failsafe 로직을 순수하게 옮긴 것.
//!
//! 불변식(조상 검증, INV-1): **E-STOP 은 같은 틱의 ARM 을 이긴다**(settle). 외부/B E-STOP 은
//! latch-disarm 하고, 재 ARM 후에도 스틱이 **중립을 한 번 거쳐야** 이동을 허용한다
//! (ISO 13850 reset≠restart). 데드맨 미보유 완화책으로 ARM idle-timeout 을 둔다(하드닝 B3).
//!
//! E-STOP 의 **즉시 발화**(touch flag / UDP 버스트)는 이 상태기계가 아니라 입력 어댑터가
//! B rising 즉시 수행한다(스로틀·디바운스 금지) — 여기서는 ARM 래치 전이만 책임진다.

use crate::g01;

/// failsafe 판정 결과 — `GamepadFailsafe`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failsafe {
    /// 정상 — 조치 없음.
    None,
    /// 진폭 제자리 슬루→0 (완만한 정지, cat-1). disarm 아님 — 워치독 Stop 이 이어받는다.
    SlewZero,
}

/// 같은 틱 edge 합성 — `SettleArmed` 1:1. E-STOP 이 ARM 을 이긴다.
pub fn settle_armed(armed: bool, arm_edge: bool, estop_edge: bool) -> bool {
    let mut a = armed;
    if arm_edge {
        a = true;
    }
    if estop_edge {
        a = false;
    }
    a
}

/// failsafe 3티어 중 ②③ 판정 — `GamepadFailsafeDecision` 1:1.
/// ①(버튼 release 합성)은 이벤트 경로(이동 게이트)가 소화하므로 여기 없음.
///
/// `last_alive_ms` = **마지막 *공급(offer)/재공급* 또는 노드 획득 시각의 큰 값**(`now_ms` 와 같은
/// 클럭, ≥1). 호출자는 반드시 `max(last_offer, adopt)` 를 넣어야 한다 — **마지막 *raw 이벤트* 가
/// 아니다**(하드닝-T: LT/RT 풀프레스 정적 홀드는 이벤트가 0 이라, raw-event 기준이면 1.5s 후 거짓
/// 슬루-제로로 회전을 끊는다. 재공급 케이던스가 신선도를 유지해야 한다).
pub fn failsafe_decision(
    now_ms: i64,
    last_alive_ms: i64,
    node_ok: bool,
    had_device: bool,
) -> Failsafe {
    // ② 입력 소스 소실(한 번이라도 있었는데 지금 없음).
    if had_device && !node_ok {
        return Failsafe::SlewZero;
    }
    // ③ 이벤트 침묵 ≥ 임계 = 단절 의심.
    if node_ok && last_alive_ms > 0 && (now_ms - last_alive_ms) >= g01::SILENCE_SLEW_MS as i64 {
        return Failsafe::SlewZero;
    }
    Failsafe::None
}

/// ARM 래치 상태기계 — 한 운영자 세션의 무장/중립게이트/idle 을 소유(순수, 시계 주입).
///
/// **클럭 계약**: 주입하는 `now_ms` 는 **≥ 1 인 단조 클럭**(에폭 ms 권장)이어야 한다. 0 은
/// "미설정" sentinel 로 쓰여 `note_activity(0)` 후 `check_idle_timeout`·`failsafe_decision` 의
/// `>0` 가드가 영구 스킵된다 — idle/침묵 안전 완화책이 조용히 무력화될 수 있다.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SafetyGate {
    armed: bool,
    rearm_requires_neutral: bool,
    last_activity_ms: i64,
}

impl SafetyGate {
    pub fn new() -> Self {
        Self::default()
    }

    /// 래치된 ARM(중립 게이트 적용 전 원시 상태).
    pub fn armed(&self) -> bool {
        self.armed
    }

    /// 재 ARM 후 중립 대기 중인가(잔여 스틱 즉시 재보행 차단 상태).
    pub fn rearm_pending(&self) -> bool {
        self.rearm_requires_neutral
    }

    /// 노드 (재)획득 — `AdoptDevice`: disarm + 깨끗한 슬레이트 + 활동 기준 리셋.
    pub fn on_adopt(&mut self, now_ms: i64) {
        self.armed = false;
        self.rearm_requires_neutral = false;
        self.last_activity_ms = now_ms;
    }

    /// 외부 E-STOP(UDP/Mac/Switch flag) — `ForceDisarm`: latch-disarm + 중립 게이트.
    pub fn force_disarm(&mut self) {
        self.armed = false;
        self.rearm_requires_neutral = true;
    }

    /// 한 틱 버튼 edge 적용(settle). `arm_edge` 는 A 또는 Y(복구)의 ARM 의도 포함.
    /// E-STOP edge 면 ARM 을 끄고 중립 게이트를 세운다(B 도 reset≠restart).
    pub fn apply_edges(&mut self, arm_edge: bool, estop_edge: bool) {
        self.armed = settle_armed(self.armed, arm_edge, estop_edge);
        if estop_edge {
            self.rearm_requires_neutral = true;
        }
    }

    /// 의도적 입력 발생 — idle-timeout 기준 리셋(스틱 데드존 노이즈는 호출자가 제외).
    pub fn note_activity(&mut self, now_ms: i64) {
        self.last_activity_ms = now_ms;
    }

    /// ARM idle timeout — ARM 후 활동 없이 임계 경과면 auto-disarm + 중립 게이트(하드닝 B3).
    pub fn check_idle_timeout(&mut self, now_ms: i64) {
        if self.armed
            && self.last_activity_ms > 0
            && (now_ms - self.last_activity_ms) >= g01::ARM_IDLE_TIMEOUT_MS as i64
        {
            self.armed = false;
            self.rearm_requires_neutral = true;
        }
    }

    /// 이번 프레임의 **유효 ARM** — 중립 게이트 적용(`OfferCurrentLocked` 등가).
    /// 중립 대기 중이면: 이동 의도 없으면 게이트 해제(이후 정상), 있으면 이번 틱 enabled 억제.
    pub fn effective_armed(&mut self, moving_intent: bool) -> bool {
        if self.rearm_requires_neutral {
            if !moving_intent {
                self.rearm_requires_neutral = false;
            } else {
                return false;
            }
        }
        self.armed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settle_estop_beats_arm_same_tick() {
        // 둘 다 같은 틱 → E-STOP 승(disarm).
        assert!(!settle_armed(false, true, true));
        assert!(!settle_armed(true, true, true));
        // ARM 단독 → armed.
        assert!(settle_armed(false, true, false));
        // E-STOP 단독 → disarm.
        assert!(!settle_armed(true, false, true));
        // edge 없음 → 유지.
        assert!(settle_armed(true, false, false));
        assert!(!settle_armed(false, false, false));
    }

    #[test]
    fn arm_then_estop_latches_and_requires_neutral() {
        let mut g = SafetyGate::new();
        g.apply_edges(true, false); // A
        assert!(g.armed());
        assert!(!g.rearm_pending());
        g.apply_edges(false, true); // B
        assert!(!g.armed());
        assert!(g.rearm_pending());
        // 재 ARM 했어도 스틱이 움직이는 동안은 유효 ARM 거부.
        g.apply_edges(true, false);
        assert!(g.armed());
        assert!(!g.effective_armed(true)); // 잔여 이동 입력 → 억제
        assert!(g.rearm_pending());
        // 중립 한 번 → 게이트 해제 → 이후 유효 ARM.
        assert!(g.effective_armed(false));
        assert!(!g.rearm_pending());
        assert!(g.effective_armed(true));
    }

    #[test]
    fn force_disarm_sets_neutral_gate() {
        let mut g = SafetyGate::new();
        g.apply_edges(true, false);
        g.force_disarm();
        assert!(!g.armed());
        assert!(g.rearm_pending());
    }

    #[test]
    fn adopt_clears_arm_and_neutral_gate() {
        let mut g = SafetyGate::new();
        g.apply_edges(true, false);
        g.force_disarm();
        g.on_adopt(1000);
        assert!(!g.armed());
        assert!(!g.rearm_pending()); // 물리 재연결 = 깨끗한 슬레이트
    }

    #[test]
    fn idle_timeout_disarms_after_threshold() {
        // 0 은 "미설정" sentinel 이므로 현실적 클럭(>0) 사용.
        let base = 1_000i64;
        let idle = g01::ARM_IDLE_TIMEOUT_MS as i64;
        let mut g = SafetyGate::new();
        g.apply_edges(true, false);
        g.note_activity(base);
        g.check_idle_timeout(base + idle - 1);
        assert!(g.armed()); // 아직 임계 미만
        g.check_idle_timeout(base + idle);
        assert!(!g.armed()); // 임계 도달 → auto-disarm
        assert!(g.rearm_pending());
    }

    #[test]
    fn idle_timeout_resets_on_activity() {
        let mut g = SafetyGate::new();
        g.apply_edges(true, false);
        g.note_activity(0);
        g.note_activity(10_000); // 활동 → 리셋
        g.check_idle_timeout(20_000); // 10s 경과 < 15s
        assert!(g.armed());
    }

    #[test]
    fn failsafe_tiers() {
        let s = g01::SILENCE_SLEW_MS as i64;
        // ② 노드 소실.
        assert_eq!(failsafe_decision(0, 0, false, true), Failsafe::SlewZero);
        // 한 번도 없던 장치는 ② 아님.
        assert_eq!(failsafe_decision(0, 0, false, false), Failsafe::None);
        // ③ 침묵 임계 도달 — diff(now−last_alive) ≥ s.
        assert_eq!(failsafe_decision(s + 1, 1, true, true), Failsafe::SlewZero); // diff = s
        assert_eq!(
            failsafe_decision(s + 100, 1, true, true),
            Failsafe::SlewZero
        );
        // 신선(침묵 미달, diff < s) → None.
        assert_eq!(failsafe_decision(2, 1, true, true), Failsafe::None);
        // last_alive 0(획득 전) → ③ 즉발 방지.
        assert_eq!(failsafe_decision(99_999, 0, true, true), Failsafe::None);
    }
}
