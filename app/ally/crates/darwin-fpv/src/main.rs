//! darwin-fpv 바이너리 — Phase 2a 에서는 헤드리스 파이프라인 트레이스만 제공한다.
//! (스레드 런타임 = Phase 2b, Tauri 셸 = Phase 3.)
//!
//! `darwin-fpv` (인자 없음) — 합성 입력 시퀀스를 TX 파이프라인에 흘려 안전 거동
//! (무장→주행→정지→E-STOP→복구)을 stdout 으로 보여준다. 로봇·스레드·webview 불요.

use ally_input::{ButtonEdges, GilrsAxes, InputFrame};
use darwin_fpv::tx::TxPipeline;

fn frame(axes: GilrsAxes, now_ms: i64) -> InputFrame {
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

fn main() {
    println!("▶ darwin-fpv — TX 파이프라인 합성 트레이스 (Phase 2a: 안전 코어, 로봇·스레드 불요)");
    println!(
        "  {:<28} {:<11} {:>3} {:>8} {:>7}  line[0..3]",
        "단계", "state", "arm", "stride", "side"
    );

    let mut tx = TxPipeline::new();
    let up = GilrsAxes {
        left_y: 1.0,
        ..Default::default()
    };
    let neutral = GilrsAxes::default();

    // (라벨, 축, 에지, now_ms)
    let script: &[(&str, GilrsAxes, ButtonEdges, i64)] = &[
        ("부팅 직후(무장 전 스틱 위)", up, edges(false, false, false), 0),
        ("A 무장", neutral, edges(true, false, false), 50),
        ("스틱 위 → 주행", up, edges(false, false, false), 100),
        ("스틱 위 유지(EMA 상승)", up, edges(false, false, false), 150),
        ("스틱 놓음 → 크리스프 정지", neutral, edges(false, false, false), 200),
        ("B → E-STOP 래치", neutral, edges(false, true, false), 250),
        ("래치 중 스틱 위(차단)", up, edges(false, false, false), 300),
        ("A 만(래치 안 풀림)", neutral, edges(true, false, false), 350),
        ("Y 복구 시작(램프 보류)", neutral, edges(false, false, true), 400),
        ("복구 램프 경과 후", up, edges(false, false, false), 1300),
    ];

    for (label, axes, e, now) in script {
        let out = tx.step(&frame(*axes, *now), *e, *now);
        let head: String = out.line.split_whitespace().take(3).collect::<Vec<_>>().join(" ");
        println!(
            "  {:<28} {:<11?} {:>3} {:>8.2} {:>7.2}  {head}",
            label,
            tx.state(),
            if out.armed { "Y" } else { "·" },
            out.cmd.stride_mm,
            out.cmd.side_mm,
        );
    }
    println!("✓ 트레이스 완료 — 안전 거동(무장 게이트·stale·estop 래치·복구)은 단위테스트가 검증.");
}
