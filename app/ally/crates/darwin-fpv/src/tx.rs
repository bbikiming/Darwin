//! 제어 TX 파이프라인 — §2 "제어 TX 스레드"의 순수(부수효과 없는) 한 틱.
//!
//! 신선도 검사 → G01 매핑(GamepadPilot.h 동결) → 안전 게이트(ARM/ESTOP/복구) →
//! 명령 스무더(EMA α + snap-to-zero) → df-wire 14-token line. 소켓·시계·스레드는 여기
//! 없다 — 호출부(runtime TX 스레드)가 20Hz 데드라인 스케줄로 `step` 을 돌리고 결과 line 을
//! UDP 송신한다. 순수 함수라 합성 프레임으로 안전 거동(무장/정지/래치)을 단위검증한다.

use ally_input::{
    g01_gait_config, map_gamepad, to_evdev, ButtonEdges, CommandSmoother, GateEvents, HeadHold,
    InputFrame, SafetyGate, SafetyState,
};
use df_wire::{build_line, gen_cmd_id, GaitConfig, MotionCommand};

/// 입력 프레임 신선도 임계 — §2: >150ms → zero+disarm.
pub const STALE_MS: i64 = 150;

/// 한 TX 틱의 결과 — 송신할 line + 표시/상태 투영 + 게이트 발화 이벤트.
#[derive(Debug, Clone)]
pub struct TxOutcome {
    /// UDP 로 보낼 14-token DFCMD line(`build_line` 산출).
    pub line: String,
    /// 스무딩·게이트 적용 후 명령(StateHub `cmd.*` 투영용).
    pub cmd: MotionCommand,
    /// 게이트 발화(복구 rm-estop·재무장 등 호출부 부수효과 지시).
    pub events: GateEvents,
    pub armed: bool,
    pub estop_latched: bool,
    pub recovering: bool,
    /// 이번 틱이 신선도 미달/단절로 정지 처리됐는지(진단).
    pub stale: bool,
}

/// TX 파이프라인 상태 — 게이트·스무더·머리 적분 hold·직전 틱 시각.
#[derive(Debug, Clone)]
pub struct TxPipeline {
    gate: SafetyGate,
    smoother: CommandSmoother,
    hold: HeadHold,
    cfg: GaitConfig,
    last_ms: Option<i64>,
}

impl Default for TxPipeline {
    fn default() -> Self {
        TxPipeline {
            gate: SafetyGate::new(),
            smoother: CommandSmoother::new(),
            hold: HeadHold::default(),
            cfg: g01_gait_config(),
            last_ms: None,
        }
    }
}

impl TxPipeline {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn state(&self) -> SafetyState {
        self.gate.state()
    }

    /// 한 틱. `edges` = 이번 틱에 누적된 버튼 rising edge(여러 ButtonEdges 는 OR 합성),
    /// `now_ms` = 단조 시계. 게이트 전이 → 신선도 → 매핑 → 스무딩 → line 을 산출한다.
    ///
    /// 신선/단절 처리: 단절이면 `on_device_lost`, stale 이면 `on_stale`(둘 다 disarm —
    /// E-STOP 래치는 유지). stale 일 땐 dt=0 으로 머리 적분을 멈춰(공백 점프 방지) 머리는
    /// 마지막 각을 유지하고, 이동은 미무장이라 zero 가 된다.
    pub fn step(&mut self, frame: &InputFrame, edges: ButtonEdges, now_ms: i64) -> TxOutcome {
        // 1. 버튼 에지 적용(settle: E-STOP 이 ARM/복구를 이김) + 복구 램프 완료 전이.
        let events = self.gate.apply_edges(edges, now_ms);
        self.gate.tick(now_ms);

        // 2. 신선도/연결 — 안전 측으로 disarm.
        let stale = frame.is_stale(now_ms, STALE_MS);
        if !frame.connected {
            self.gate.on_device_lost();
        } else if stale {
            self.gate.on_stale();
        }
        let stop = stale || !frame.connected;

        // 3. G01 매핑 — armed 는 게이트가 결정(ARMED 단일). stop 이면 dt=0(머리 적분 정지).
        let armed = self.gate.movement_allowed();
        let dt_ms = if stop {
            0.0
        } else {
            self.last_ms.map_or(0.0, |p| (now_ms - p).max(0) as f64)
        };
        self.last_ms = Some(now_ms);
        let raw = map_gamepad(&to_evdev(&frame.axes), armed, dt_ms, &mut self.hold);

        // 4. 스무딩(EMA + snap-to-zero / 비활성은 크리스프 정지) → 5. 14-token line.
        let cmd = self.smoother.smooth(raw);
        let line = build_line(&gen_cmd_id(), &self.cfg, &cmd);

        let state = self.gate.state();
        TxOutcome {
            line,
            cmd,
            events,
            armed,
            estop_latched: state == SafetyState::EstopLatched,
            recovering: state == SafetyState::Recovering,
            stale: stop,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ally_input::GilrsAxes;

    /// 신선한 프레임(now 기준) 헬퍼.
    fn fresh(axes: GilrsAxes, now_ms: i64) -> InputFrame {
        InputFrame {
            axes,
            connected: true,
            t_ms: now_ms,
        }
    }

    fn edges(arm: bool, estop: bool, recover: bool) -> ButtonEdges {
        ButtonEdges {
            arm,
            estop,
            recover,
        }
    }

    #[test]
    fn disarmed_until_armed_then_stick_forward_drives() {
        let mut tx = TxPipeline::new();
        // 무장 전: 스틱 위여도 이동 명령 없음.
        let stick_up = GilrsAxes {
            left_y: 1.0,
            ..Default::default()
        };
        let out = tx.step(&fresh(stick_up, 0), edges(false, false, false), 0);
        assert!(!out.armed, "무장 전 — 이동 잠금");
        assert!(!out.cmd.enabled);

        // A 로 무장(중립 프레임).
        tx.step(&fresh(GilrsAxes::default(), 10), edges(true, false, false), 10);

        // 무장 후 스틱 위 → 전진(+stride).
        let out = tx.step(&fresh(stick_up, 20), edges(false, false, false), 20);
        assert!(out.armed);
        assert!(out.cmd.enabled);
        assert!(out.cmd.stride_mm > 0.0, "스틱 위 → 전진(+stride)");
    }

    #[test]
    fn stale_frame_disarms_and_zeros() {
        let mut tx = TxPipeline::new();
        tx.step(&fresh(GilrsAxes::default(), 0), edges(true, false, false), 0); // ARM
        let stick_up = GilrsAxes {
            left_y: 1.0,
            ..Default::default()
        };
        // t_ms=20 이지만 now=300 → 280ms 경과 > 150ms stale.
        let stale = InputFrame {
            axes: stick_up,
            connected: true,
            t_ms: 20,
        };
        let out = tx.step(&stale, edges(false, false, false), 300);
        assert!(out.stale);
        assert!(!out.armed, "stale → disarm");
        assert!(!out.cmd.enabled, "stale → zero 이동");
        assert_eq!(out.cmd.stride_mm, 0.0);
    }

    #[test]
    fn estop_edge_latches_and_blocks_movement() {
        let mut tx = TxPipeline::new();
        tx.step(&fresh(GilrsAxes::default(), 0), edges(true, false, false), 0); // ARM
        // B → 래치.
        let out = tx.step(&fresh(GilrsAxes::default(), 10), edges(false, true, false), 10);
        assert!(out.estop_latched);
        assert!(out.events.fire_estop, "B → estop 발화 신호");

        // 래치 상태에서 스틱 위 → 여전히 zero(이동 차단).
        let stick_up = GilrsAxes {
            left_y: 1.0,
            ..Default::default()
        };
        let out = tx.step(&fresh(stick_up, 20), edges(false, false, false), 20);
        assert!(!out.armed);
        assert!(!out.cmd.enabled);

        // A 만으로는 래치 안 풀림(Y 복구만).
        let out = tx.step(&fresh(stick_up, 30), edges(true, false, false), 30);
        assert!(out.estop_latched, "EstopLatched 는 A 로 안 풀림");
    }

    #[test]
    fn disconnected_pad_zeros() {
        let mut tx = TxPipeline::new();
        tx.step(&fresh(GilrsAxes::default(), 0), edges(true, false, false), 0); // ARM
        let stick_up = GilrsAxes {
            left_y: 1.0,
            ..Default::default()
        };
        let lost = InputFrame {
            axes: stick_up,
            connected: false,
            t_ms: 10,
        };
        let out = tx.step(&lost, edges(false, false, false), 10);
        assert!(out.stale, "단절 → 정지 처리");
        assert!(!out.cmd.enabled);
    }

    #[test]
    fn line_is_always_14_tokens() {
        // df-wire 계약: build_line 은 항상 14토큰. 어떤 상태든 깨지지 않는다.
        let mut tx = TxPipeline::new();
        let out = tx.step(&fresh(GilrsAxes::default(), 0), edges(false, false, false), 0);
        assert_eq!(out.line.split_whitespace().count(), 14);
    }
}
