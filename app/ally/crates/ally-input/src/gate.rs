//! 안전 게이트 상태머신 + failsafe 판정 + 명령 스무더.
//!
//! 상태: `DISARMED → ARMED → ESTOP_LATCH → (Y 복구) → ARMED` (03 §6).
//! 이동은 ARMED 단일 게이트(데드맨 해제 — F10). B E-STOP 은 별도 무손실 채널이
//! 1차 발원(INV-1)이지만, 게이트도 같은 edge 를 받아 상태를 래치한다.
//!
//! settle 규율(`SettleArmed` 이식): 같은 틱에서 E-STOP 이 ARM/복구를 이긴다.
//! failsafe 3티어(`GamepadFailsafeDecision` 이식): ②장치 소실 ③이벤트 침묵 1500ms.
//! Ally 는 폴링(250Hz)이라 ③ 침묵보다 InputFrame 신선도(150ms)·gilrs 단절이
//! 1차 트리거이고, 본 판정은 last-입력-변화 기준 백스톱으로 둔다.

use crate::g01;
use df_wire::MotionCommand;

/// 게이트 상태.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SafetyState {
    /// 무장 전 — 이동 잠금. A 로 무장.
    Disarmed,
    /// 무장 — 이동 입력이 명령으로 나간다.
    Armed,
    /// E-STOP 래치 — 정지 유지. Y 로만 해제.
    EstopLatched,
    /// 복구 진행 — 로봇 소프트 토크 램프(~0.6s) 동안 이동 보류.
    Recovering,
}

/// 한 틱의 버튼 rising edge.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ButtonEdges {
    pub arm: bool,     // A
    pub estop: bool,   // B
    pub recover: bool, // Y
}

/// `apply_edges` 가 호출부에 알리는 발화 이벤트(락 밖에서 부수효과 실행).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GateEvents {
    /// E-STOP 발화 — UDP ×3연발 + SSH touch (ally-link).
    pub fire_estop: bool,
    /// 복구 발화 — estop flag 제거(rm) + 재무장 의도 (ally-link).
    pub fire_recover: bool,
}

/// failsafe 판정 — `GamepadFailsafe` 등가.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failsafe {
    None,
    /// 진폭 제자리 슬루→0 (오발 비용 = 완만 정지, 미탐 비용 = 폭주 → 안전 측 편향).
    SlewZero,
}

/// 복구 소프트 토크 램프 총 길이(ms) — 램프 단계 × 간격.
const RECOVER_RAMP_MS: i64 =
    g01::SOFT_TORQUE_RAMP_INTERVAL_MS as i64 * g01::SOFT_TORQUE_RAMP.len() as i64;

/// 안전 게이트 상태머신.
#[derive(Debug, Clone, Copy)]
pub struct SafetyGate {
    state: SafetyState,
    recover_started_ms: i64,
}

impl Default for SafetyGate {
    fn default() -> Self {
        SafetyGate {
            state: SafetyState::Disarmed,
            recover_started_ms: 0,
        }
    }
}

impl SafetyGate {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn state(&self) -> SafetyState {
        self.state
    }

    /// 이동 명령이 허용되는가 — ARMED 일 때만. (DISARMED·ESTOP·RECOVERING 은 정지.)
    pub fn movement_allowed(&self) -> bool {
        self.state == SafetyState::Armed
    }

    /// 버튼 edge 적용(settle — E-STOP 우선). 상태를 갱신하고 발화 이벤트를 반환한다.
    pub fn apply_edges(&mut self, edges: ButtonEdges, now_ms: i64) -> GateEvents {
        let mut ev = GateEvents::default();

        // ARM/복구 의도 — 먼저 적용. (E-STOP 래치는 Y 로만 풀린다; 맨 A 는 무시.)
        if edges.arm || edges.recover {
            match self.state {
                SafetyState::Disarmed => self.state = SafetyState::Armed,
                // E-STOP 래치는 Y(복구)로만 풀린다 — 맨 A 는 무시.
                SafetyState::EstopLatched if edges.recover => {
                    self.state = SafetyState::Recovering;
                    self.recover_started_ms = now_ms;
                }
                // 그 외(EstopLatched+A, Armed, Recovering) — 유지(재무장 무해).
                _ => {}
            }
        }
        // 복구 발화 — E-STOP 과 같은 틱이 아닐 때만(estop 이 이긴다).
        if edges.recover && !edges.estop {
            ev.fire_recover = true;
        }
        // E-STOP — 마지막에 적용해 ARM/복구를 덮는다(settle: estop 승리).
        if edges.estop {
            self.state = SafetyState::EstopLatched;
            ev.fire_estop = true;
            ev.fire_recover = false;
        }
        ev
    }

    /// 시간 경과 처리 — 복구 램프가 끝나면 ARMED 로 전이.
    pub fn tick(&mut self, now_ms: i64) {
        if self.state == SafetyState::Recovering
            && now_ms - self.recover_started_ms >= RECOVER_RAMP_MS
        {
            self.state = SafetyState::Armed;
        }
    }

    /// 입력 프레임이 stale(>150ms) — zero+disarm. E-STOP 래치는 유지(더 강한 상태).
    pub fn on_stale(&mut self) {
        self.disarm_unless_latched();
    }

    /// 장치 소실(gilrs 단절) — zero+disarm + 재 ARM 요구(failure matrix #1).
    pub fn on_device_lost(&mut self) {
        self.disarm_unless_latched();
    }

    /// failsafe SlewZero 관측 — 진폭은 호출부가 zero 로 보내고, 게이트는 disarm.
    pub fn on_failsafe(&mut self, decision: Failsafe) {
        if decision == Failsafe::SlewZero {
            self.disarm_unless_latched();
        }
    }

    fn disarm_unless_latched(&mut self) {
        if self.state != SafetyState::EstopLatched {
            self.state = SafetyState::Disarmed;
        }
    }
}

/// failsafe 3티어 판정 — `GamepadFailsafeDecision` 1:1 포팅.
///
/// - ②티어: 한 번이라도 장치를 잡았는데 지금 노드가 없으면 SlewZero(inputSourceLost).
/// - ③티어: 노드는 있는데 마지막 *유의 입력* 이후 ≥1500ms 침묵 → SlewZero(단절 의심).
pub fn failsafe_decision(
    now_ms: i64,
    last_alive_ms: i64,
    node_ok: bool,
    had_device: bool,
) -> Failsafe {
    if had_device && !node_ok {
        return Failsafe::SlewZero;
    }
    if node_ok && last_alive_ms > 0 && (now_ms - last_alive_ms) >= g01::SILENCE_SLEW_MS as i64 {
        return Failsafe::SlewZero;
    }
    Failsafe::None
}

/// 명령 스무더 — EMA(α=0.5) + snap-to-zero. 이동 진폭(x/y/a)만 완만화하고 머리는
/// 통과(이미 레이트 적분된 절대각). 비활성(정지) 명령은 EMA 를 우회해 **크리스프
/// 정지**(상태 0 리셋) — 출발/변화는 부드럽게, 정지는 즉시. 최종 클램프는 로봇
/// 거버너(INV-5)이고 이건 UX 레이어다(G.8: 가속 제한은 로봇 슬루 소유).
#[derive(Debug, Clone, Copy, Default)]
pub struct CommandSmoother {
    x: f64,
    y: f64,
    a: f64,
}

/// snap-to-zero 임계(mm/deg) — 이하 잔류는 0 으로 끊는다(릴리스 드리프트 제거).
const SNAP_EPS: f64 = 0.5;

impl CommandSmoother {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn smooth(&mut self, cmd: MotionCommand) -> MotionCommand {
        if !cmd.enabled {
            // 정지 — EMA 지연 없이 즉시. 다음 출발이 0 에서 부드럽게 오르도록 리셋.
            self.x = 0.0;
            self.y = 0.0;
            self.a = 0.0;
            return cmd;
        }
        self.x = Self::step(self.x, cmd.stride_mm);
        self.y = Self::step(self.y, cmd.side_mm);
        self.a = Self::step(self.a, cmd.turn_deg);
        MotionCommand {
            stride_mm: self.x,
            side_mm: self.y,
            turn_deg: self.a,
            ..cmd
        }
    }

    fn step(prev: f64, target: f64) -> f64 {
        let next = g01::CMD_EMA_ALPHA * target + (1.0 - g01::CMD_EMA_ALPHA) * prev;
        // target 이 0 이고 잔류가 미세하면 0 으로 snap.
        if target == 0.0 && next.abs() < SNAP_EPS {
            0.0
        } else {
            next
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arm_then_estop_then_recover() {
        let mut g = SafetyGate::new();
        assert_eq!(g.state(), SafetyState::Disarmed);
        assert!(!g.movement_allowed());

        // A → Armed.
        let ev = g.apply_edges(
            ButtonEdges {
                arm: true,
                ..Default::default()
            },
            0,
        );
        assert_eq!(g.state(), SafetyState::Armed);
        assert!(g.movement_allowed());
        assert!(!ev.fire_estop && !ev.fire_recover);

        // B → EstopLatched + fire_estop, 이동 잠금.
        let ev = g.apply_edges(
            ButtonEdges {
                estop: true,
                ..Default::default()
            },
            100,
        );
        assert_eq!(g.state(), SafetyState::EstopLatched);
        assert!(ev.fire_estop);
        assert!(!g.movement_allowed());

        // 래치 중 A 단독 → 무시(여전히 래치).
        g.apply_edges(
            ButtonEdges {
                arm: true,
                ..Default::default()
            },
            150,
        );
        assert_eq!(g.state(), SafetyState::EstopLatched);

        // Y → Recovering + fire_recover, 램프 동안 이동 보류.
        let ev = g.apply_edges(
            ButtonEdges {
                recover: true,
                ..Default::default()
            },
            200,
        );
        assert_eq!(g.state(), SafetyState::Recovering);
        assert!(ev.fire_recover);
        assert!(!g.movement_allowed());

        // 램프 완료 후 → Armed.
        g.tick(200 + RECOVER_RAMP_MS);
        assert_eq!(g.state(), SafetyState::Armed);
        assert!(g.movement_allowed());
    }

    #[test]
    fn estop_wins_same_tick() {
        let mut g = SafetyGate::new();
        // 같은 틱 A+B → estop 승리(무장 안 됨).
        let ev = g.apply_edges(
            ButtonEdges {
                arm: true,
                estop: true,
                ..Default::default()
            },
            0,
        );
        assert_eq!(g.state(), SafetyState::EstopLatched);
        assert!(ev.fire_estop);
        assert!(!ev.fire_recover);
        // 같은 틱 Y+B → estop 승리, 복구 발화 안 함.
        let ev = g.apply_edges(
            ButtonEdges {
                recover: true,
                estop: true,
                ..Default::default()
            },
            10,
        );
        assert_eq!(g.state(), SafetyState::EstopLatched);
        assert!(ev.fire_estop && !ev.fire_recover);
    }

    #[test]
    fn stale_and_device_lost_disarm() {
        let mut g = SafetyGate::new();
        g.apply_edges(
            ButtonEdges {
                arm: true,
                ..Default::default()
            },
            0,
        );
        g.on_stale();
        assert_eq!(g.state(), SafetyState::Disarmed);

        g.apply_edges(
            ButtonEdges {
                arm: true,
                ..Default::default()
            },
            0,
        );
        g.on_device_lost();
        assert_eq!(g.state(), SafetyState::Disarmed);

        // E-STOP 래치는 stale/단절에도 유지.
        g.apply_edges(
            ButtonEdges {
                estop: true,
                ..Default::default()
            },
            0,
        );
        g.on_stale();
        assert_eq!(g.state(), SafetyState::EstopLatched);
    }

    #[test]
    fn failsafe_tiers() {
        // ②티어 — 장치 보유 이력 + 노드 소실.
        assert_eq!(
            failsafe_decision(5000, 4000, false, true),
            Failsafe::SlewZero
        );
        // ③티어 — 노드 있음 + 침묵 ≥1500ms.
        assert_eq!(
            failsafe_decision(5000, 3000, true, true),
            Failsafe::SlewZero
        );
        // 침묵 미만 → None.
        assert_eq!(failsafe_decision(5000, 4000, true, true), Failsafe::None);
        // 장치 미보유 → None(아직 한 번도 못 잡음).
        assert_eq!(failsafe_decision(5000, 0, false, false), Failsafe::None);
    }

    #[test]
    fn smoother_crisp_stop_smooth_start() {
        let mut s = CommandSmoother::new();
        let drive = MotionCommand {
            enabled: true,
            stride_mm: 38.0,
            side_mm: 0.0,
            turn_deg: 0.0,
            head_pan_deg: 0.0,
            head_tilt_deg: 0.0,
        };
        // 0 → 38 한 스텝: α=0.5 → 19.
        let o = s.smooth(drive);
        assert!((o.stride_mm - 19.0).abs() < 1e-9);
        let o = s.smooth(drive);
        assert!((o.stride_mm - 28.5).abs() < 1e-9); // 0.5*38 + 0.5*19
                                                    // 정지(비활성) → 즉시 0 + 상태 리셋(크리스프).
        let o = s.smooth(MotionCommand::zero());
        assert_eq!(o.stride_mm, 0.0);
        // 리셋 확인 — 다시 출발하면 0 에서.
        let o = s.smooth(drive);
        assert!((o.stride_mm - 19.0).abs() < 1e-9);
    }

    #[test]
    fn smoother_snaps_released_axis_to_zero() {
        let mut s = CommandSmoother::new();
        // 측면을 한참 밀다가 측면만 0 으로(전진 유지) — 측면 잔류가 snap 으로 끊긴다.
        let diag = MotionCommand {
            enabled: true,
            stride_mm: 38.0,
            side_mm: 22.0,
            turn_deg: 0.0,
            head_pan_deg: 0.0,
            head_tilt_deg: 0.0,
        };
        for _ in 0..10 {
            s.smooth(diag);
        }
        let fwd_only = MotionCommand {
            side_mm: 0.0,
            ..diag
        };
        let mut last = s.smooth(fwd_only);
        for _ in 0..10 {
            last = s.smooth(fwd_only);
        }
        assert_eq!(last.side_mm, 0.0, "측면 잔류 0 으로 snap");
        assert!(last.stride_mm > 37.0, "전진은 유지");
    }
}
