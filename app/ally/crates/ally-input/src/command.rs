//! 틱 통합 — `InputFrame` × [`SafetyGate`] × [`HeadHold`] → df-wire [`MotionCommand`].
//!
//! `GamepadPilot::ProcessEvent` + `OfferCurrentLocked` 의 커밋 경로를 프레임 기반으로 옮긴 것.
//! [`Pilot`] 은 **입력 레이트(250Hz/이벤트당)** 로 호출되어야 한다 — TX 20Hz 가 아니라:
//! 그래야 B E-STOP disarm 이 다음 송신 전에 즉시 반영된다(INV-1). 실제 정지 신호(UDP 버스트·
//! touch flag)의 즉시 발화는 어댑터([`crate::source`])가 B rising 이벤트에서 직접 하고,
//! 여기 `TickOutput::estop_fired` 는 멱등 백스톱이다.
//!
//! **ally 콕핏 의미론**(온보드 GamepadPilot 과 분기): A=ARM · B=E-STOP · Y=복구 · RB=터보 ·
//! 우스틱=헤드 레이트 · LT/RT=턴. 킥/D-패드/볼-추종은 온보드 전용 — W1 범위 아님.

use df_wire::{GaitConfig, MotionCommand};

use crate::frame::InputFrame;
use crate::g01;
use crate::gate::SafetyGate;
use crate::head::HeadHold;
use crate::shape;

/// G01 콕핏 gait 설정 — df-wire `gait_params` 가 intensity^0.7 보간할 **끝점**(period 560–700ms·
/// foot 18–40mm). 온보드와 같은 끝점이나 결합(max-of-axes vs L2)·side 정규화는 단순화됨
/// (체감 미세 차이, 진폭 불변 — [`g01::GAIT_PERIOD_MAX_MS`] 주석 MEDIUM-1 참조).
pub fn g01_gait_config() -> GaitConfig {
    GaitConfig {
        period_ms: g01::GAIT_PERIOD_DEFAULT_MS,
        foot_mm: g01::GAIT_FOOT_MAX_MM,
        hip_deg: g01::HIP_DEG,
        min_period_ms: g01::GAIT_PERIOD_MIN_MS,
        max_period_ms: g01::GAIT_PERIOD_MAX_MS,
        min_foot_mm: g01::GAIT_FOOT_MIN_MM,
        stride_ref_mm: g01::STRIDE_MAX_MM,
        turn_ref_deg: g01::TURN_MAX_DEG,
    }
}

/// rising edge — 직전→현재 버튼 전이. `arm` 은 A 또는 Y(복구는 ARM 의도 포함).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ButtonEdges {
    pub arm: bool,
    pub estop: bool,
    pub recover: bool,
}

/// 직전/현재 프레임에서 rising edge 검출. `arm` 은 A·Y(복구) 모두 ARM 의도로 묶는다.
pub fn detect_edges(prev: &InputFrame, cur: &InputFrame) -> ButtonEdges {
    let a_rise = cur.btn_a && !prev.btn_a;
    let y_rise = cur.btn_y && !prev.btn_y;
    let b_rise = cur.btn_b && !prev.btn_b;
    ButtonEdges {
        arm: a_rise || y_rise,
        estop: b_rise,
        recover: y_rise,
    }
}

/// "의도적 입력" — idle-timeout 활동 판정(스틱 데드존 노이즈 제외, B 제외). `ProcessEvent` B3.
/// `moving_intent` 가 트리거(LT/RT 턴)를 포함하므로 트리거도 활동으로 친다. C++ 의 `dpad_active`
/// 분기는 의도적 제외(ally 는 D-패드 미매핑) — D-패드만 만지면 idle 이 안 풀려 over-disarm 될 수
/// 있으나 정지 측 편향이라 안전(검증 HIGH 수용).
fn is_intentional(f: &InputFrame) -> bool {
    let head_active = shape::apply_deadzone(f.rx) != 0.0 || shape::apply_deadzone(f.ry) != 0.0;
    // B(E-STOP)는 조종 의도가 아니므로 활동에서 제외.
    let btn_active = f.btn_a || f.btn_x || f.btn_y || f.btn_lb || f.btn_rb;
    shape::moving_intent(f) || head_active || btn_active
}

/// 한 틱 이동 매핑 — `MapGamepad` 등가. `eff_armed` 는 중립 게이트 반영 후 유효 ARM.
/// 터보(RB)는 ally 만 유지(온보드 F12 제거) — 이동 성분만, 정규화 후 ±1 클램프(엔벨로프 불변;
/// 최종 클램프는 로봇 거버너 INV-5). 머리는 비게이트라 항상 적분된다.
pub fn map_frame(
    f: &InputFrame,
    eff_armed: bool,
    dt_ms: f64,
    hold: &mut HeadHold,
) -> MotionCommand {
    let mut fwd = g01::SIGN_STRIDE * shape::shape_drive_axis(f.ly);
    let mut side = g01::SIGN_SIDE * shape::shape_drive_axis(f.lx);
    let turn = g01::SIGN_TURN * shape::shape_turn(shape::trigger_diff(f.rt, f.lt));
    if f.btn_rb {
        fwd = (fwd * g01::TURBO_SCALE).clamp(-1.0, 1.0);
        side = (side * g01::TURBO_SCALE).clamp(-1.0, 1.0);
    }
    let moving = fwd != 0.0 || side != 0.0 || turn != 0.0;
    let enabled = eff_armed && moving;

    // 머리 — 비게이트 레이트 적분(우스틱).
    hold.integrate(f.rx, f.ry, dt_ms);

    MotionCommand {
        enabled,
        stride_mm: if enabled {
            fwd * g01::STRIDE_MAX_MM
        } else {
            0.0
        },
        side_mm: if enabled {
            side * g01::SIDE_MAX_MM
        } else {
            0.0
        },
        turn_deg: if enabled {
            turn * g01::TURN_MAX_DEG
        } else {
            0.0
        },
        head_pan_deg: hold.pan,
        head_tilt_deg: hold.tilt,
    }
}

/// 한 틱의 결과 — 매핑된 명령 + 안전 신호(호출자가 송출/발화).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TickOutput {
    pub command: MotionCommand,
    /// 래치된 ARM(중립 게이트 적용 전 — HUD 표시·TEL2 armed).
    pub armed: bool,
    /// 이번 틱 B rising — 호출자가 E-STOP 신호(UDP 버스트+touch)를 발화(멱등 백스톱).
    pub estop_fired: bool,
    /// 이번 틱 Y rising(E-STOP 동률 아님) — 호출자가 로봇 estop flag 해제(복구).
    pub recover_fired: bool,
}

/// 입력 레이트로 구동되는 파일럿 — 게이트·헤드 hold·dt 를 소유하고 매 프레임 명령을 만든다.
#[derive(Debug, Clone, Default)]
pub struct Pilot {
    gate: SafetyGate,
    hold: HeadHold,
    prev: InputFrame,
    have_prev: bool,
    last_map_ms: i64,
}

impl Pilot {
    pub fn new() -> Self {
        Self::default()
    }

    /// 노드 (재)획득 — disarm·중립게이트 해제·dt/hold 기준 리셋.
    pub fn on_adopt(&mut self, now_ms: i64) {
        self.gate.on_adopt(now_ms);
        self.have_prev = false;
        self.last_map_ms = 0;
        self.hold = HeadHold::default();
    }

    /// 외부 E-STOP(UDP/Mac/Switch flag) — latch-disarm + 중립 게이트.
    pub fn force_disarm(&mut self) {
        self.gate.force_disarm();
    }

    /// 래치된 ARM(HUD/TEL2 관찰용).
    pub fn armed(&self) -> bool {
        self.gate.armed()
    }

    /// 콕핏 gait 설정(df-wire build_line 에 주입).
    pub fn gait_config(&self) -> GaitConfig {
        g01_gait_config()
    }

    /// 한 입력 프레임 처리 → 매핑된 명령 + 안전 신호.
    ///
    /// **호출 계약**: (1) **입력 레이트(≈250Hz)로 호출** — TX 20Hz 에 묶으면 B E-STOP disarm 이
    /// 최대 한 틱 늦어 명령이 누수된다(INV-1). 즉시 정지 발화는 [`crate::source`] 의 estop_edge 가
    /// 별도 경로로 책임진다. (2) **`now_ms ≥ 1` 단조 클럭** — 0 은 "미설정" sentinel 이라 dt/idle 이
    /// 무력화된다(에폭 ms 권장).
    pub fn tick(&mut self, frame: InputFrame, now_ms: i64) -> TickOutput {
        let f = frame.clamped();
        let edges = if self.have_prev {
            detect_edges(&self.prev, &f)
        } else {
            // 첫 프레임 — 중립 직전 가정(눌린 채 시작해도 rising 으로 잡지 않음=안전 편향).
            detect_edges(&InputFrame::neutral(f.ts_ms), &f)
        };

        // settle — E-STOP 이 ARM 을 이긴다. B 는 중립 게이트도 세운다.
        self.gate.apply_edges(edges.arm, edges.estop);
        let estop_fired = edges.estop;
        let recover_fired = edges.recover && !edges.estop;

        // 활동 → idle-timeout 리셋(의도적 입력만). 그 뒤 idle 검사.
        if is_intentional(&f) {
            self.gate.note_activity(now_ms);
        }
        self.gate.check_idle_timeout(now_ms);

        // 중립 게이트 적용한 유효 ARM.
        let moving = shape::moving_intent(&f);
        let eff_armed = self.gate.effective_armed(moving);

        // 머리 적분 dt — 첫 매핑/리셋 직후는 0(점프 방지).
        let dt_ms = if self.last_map_ms > 0 && now_ms > self.last_map_ms {
            (now_ms - self.last_map_ms) as f64
        } else {
            0.0
        };
        self.last_map_ms = now_ms;

        let command = map_frame(&f, eff_armed, dt_ms, &mut self.hold);

        self.prev = f;
        self.have_prev = true;

        TickOutput {
            command,
            armed: self.gate.armed(),
            estop_fired,
            recover_fired,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arm_frame(ts: i64) -> InputFrame {
        InputFrame {
            btn_a: true,
            ts_ms: ts,
            ..Default::default()
        }
    }

    #[test]
    fn gait_config_uses_g01_endpoints() {
        let c = g01_gait_config();
        assert_eq!(c.min_period_ms, g01::GAIT_PERIOD_MIN_MS);
        assert_eq!(c.max_period_ms, g01::GAIT_PERIOD_MAX_MS);
        assert_eq!(c.min_foot_mm, g01::GAIT_FOOT_MIN_MM);
        assert_eq!(c.foot_mm, g01::GAIT_FOOT_MAX_MM);
        assert_eq!(c.hip_deg, g01::HIP_DEG);
    }

    #[test]
    fn detect_edges_rising_only() {
        let prev = InputFrame::default();
        let cur = InputFrame {
            btn_a: true,
            btn_b: true,
            ..Default::default()
        };
        let e = detect_edges(&prev, &cur);
        assert!(e.arm && e.estop && !e.recover);
        // held(직전도 눌림) → edge 아님.
        assert_eq!(detect_edges(&cur, &cur), ButtonEdges::default());
        // Y → arm 의도 + recover.
        let y = InputFrame {
            btn_y: true,
            ..Default::default()
        };
        let e2 = detect_edges(&prev, &y);
        assert!(e2.arm && e2.recover && !e2.estop);
    }

    #[test]
    fn disarmed_stick_produces_zero_command() {
        let mut p = Pilot::new();
        // ARM 안 함 + 풀스틱 전진 → enabled=0, 전축 0.
        let out = p.tick(
            InputFrame {
                ly: 1.0,
                ts_ms: 0,
                ..Default::default()
            },
            0,
        );
        assert!(!out.command.enabled);
        assert_eq!(out.command.stride_mm, 0.0);
    }

    #[test]
    fn armed_then_stick_drives_forward() {
        let mut p = Pilot::new();
        p.tick(arm_frame(0), 0); // A rising → armed
        assert!(p.armed());
        // 풀스틱 전진(ly=1, SIGN_STRIDE=−1 → 후진? 부호는 로봇좌표 X+=전진, ly raw 아래=+).
        let out = p.tick(
            InputFrame {
                ly: -1.0, // 스틱 위(전진)
                ts_ms: 50,
                ..Default::default()
            },
            50,
        );
        assert!(out.command.enabled);
        assert!(out.command.stride_mm > 0.0); // 전진(+X)
        assert!((out.command.stride_mm - g01::STRIDE_MAX_MM).abs() < 1e-9);
    }

    #[test]
    fn estop_edge_disarms_and_zeros_same_tick() {
        let mut p = Pilot::new();
        p.tick(arm_frame(0), 0);
        // 같은 틱에 B + 전진 스틱 → estop 승, enabled=0.
        let out = p.tick(
            InputFrame {
                btn_b: true,
                ly: -1.0,
                ts_ms: 50,
                ..Default::default()
            },
            50,
        );
        assert!(out.estop_fired);
        assert!(!out.armed);
        assert!(!out.command.enabled);
        assert_eq!(out.command.stride_mm, 0.0);
    }

    #[test]
    fn rearm_requires_neutral_after_estop() {
        // 현실 시나리오: 스틱을 민 채로 보행 중 B(E-STOP). 잔여 스틱이 즉시 재보행하지
        // 않도록, 재 ARM 후에도 중립을 한 번 거쳐야 enabled=1 (reset≠restart).
        let mut p = Pilot::new();
        p.tick(arm_frame(0), 0); // A → armed
        p.tick(
            InputFrame {
                ly: -1.0,
                ts_ms: 10,
                ..Default::default()
            },
            10,
        ); // 전진 보행 중
           // 스틱 민 채로 B(E-STOP).
        let estop = p.tick(
            InputFrame {
                btn_b: true,
                ly: -1.0,
                ts_ms: 20,
                ..Default::default()
            },
            20,
        );
        assert!(estop.estop_fired && !estop.armed);
        // 재 ARM(A) 하되 스틱 여전히 민 상태 → 중립 게이트가 억제.
        let out = p.tick(
            InputFrame {
                btn_a: true,
                ly: -1.0,
                ts_ms: 30,
                ..Default::default()
            },
            30,
        );
        assert!(!out.command.enabled); // 잔여 스틱 즉시 재보행 차단
                                       // 중립을 한 번 거친다.
        p.tick(InputFrame::neutral(40), 40);
        // 이제 전진 가능.
        let out2 = p.tick(
            InputFrame {
                ly: -1.0,
                ts_ms: 50,
                ..Default::default()
            },
            50,
        );
        assert!(out2.command.enabled);
    }

    #[test]
    fn turbo_scales_translation_within_envelope() {
        let mut p = Pilot::new();
        p.tick(arm_frame(0), 0);
        // 중간 전진 + 터보: 진폭이 비터보보다 크되 MAX 를 넘지 않는다.
        let half = InputFrame {
            ly: -0.5,
            ts_ms: 10,
            ..Default::default()
        };
        let no_turbo = p.tick(half, 10).command.stride_mm;
        let with_turbo = p
            .tick(
                InputFrame {
                    btn_rb: true,
                    ..half
                },
                20,
            )
            .command
            .stride_mm;
        assert!(with_turbo > no_turbo);
        assert!(with_turbo <= g01::STRIDE_MAX_MM + 1e-9);
    }

    #[test]
    fn head_is_ungated_by_arm() {
        let mut p = Pilot::new();
        // ARM 안 했어도 우스틱 → 머리 적분(비게이트). dt 위해 두 틱(클럭 >0 — 0은 sentinel).
        p.tick(InputFrame::neutral(10), 10);
        let out = p.tick(
            InputFrame {
                rx: 1.0,
                ts_ms: 110,
                ..Default::default()
            },
            110,
        );
        assert!(!out.command.enabled);
        assert!(out.command.head_pan_deg != 0.0); // 머리는 움직였다
    }
}
