//! darwin-fpv 바이너리 — 헤드리스 진입점. (Tauri 셸 = Phase 3.)
//!
//!   darwin-fpv [trace]               합성 입력 시퀀스를 TX 파이프라인에 흘려 안전 거동을
//!                                    보여줌(로봇·스레드·webview 불요).
//!   darwin-fpv selfcheck [--seconds N]
//!                                    6개 백그라운드 스레드(런타임)를 루프백 에코 로봇에
//!                                    물려 기동·ACK·메트릭·이벤트·클린 종료를 검증(로봇 불요).

use std::net::UdpSocket;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use ally_input::{now_ms, ButtonEdges, GilrsAxes, InputFrame};
use darwin_fpv::event::EventSink;
use darwin_fpv::state::Snapshot;
use darwin_fpv::tx::TxPipeline;
use darwin_fpv::{Runtime, RuntimeConfig};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None | Some("trace") => {
            trace();
            ExitCode::SUCCESS
        }
        Some("selfcheck") => {
            let secs = flag(&args, "--seconds").and_then(|s| s.parse().ok()).unwrap_or(2);
            if selfcheck(secs) {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        Some("cockpit") => cockpit_main(),
        Some(other) => {
            eprintln!(
                "알 수 없는 명령: {other}\n사용: darwin-fpv [trace|selfcheck [--seconds N]|cockpit]"
            );
            ExitCode::from(2)
        }
    }
}

/// Tauri 콕핏 셸 실행(feature="cockpit"). 미활성 빌드면 안내 후 종료.
fn cockpit_main() -> ExitCode {
    #[cfg(feature = "cockpit")]
    {
        darwin_fpv::cockpit::shell::run();
        ExitCode::SUCCESS
    }
    #[cfg(not(feature = "cockpit"))]
    {
        eprintln!(
            "cockpit: 'cockpit' feature 가 꺼져 있습니다 — \
             `cargo run -p darwin-fpv --features cockpit -- cockpit` 로 빌드/실행하세요."
        );
        ExitCode::from(2)
    }
}

fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .map(String::as_str)
}

// ── trace: TX 파이프라인 합성 시퀀스 (Phase 2a) ──────────────────────────────
fn trace() {
    println!("▶ darwin-fpv trace — TX 파이프라인 합성 트레이스 (안전 코어, 로봇·스레드 불요)");
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
    let frame = |axes: GilrsAxes, now: i64| InputFrame {
        axes,
        connected: true,
        t_ms: now,
    };
    let edges = |arm, estop, recover| ButtonEdges {
        arm,
        estop,
        recover,
    };

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
        let head: String = out
            .line
            .split_whitespace()
            .take(3)
            .collect::<Vec<_>>()
            .join(" ");
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

// ── selfcheck: 런타임 6스레드를 루프백 에코 로봇으로 검증 (Phase 2b) ──────────

/// 이벤트 발행 횟수만 세는 싱크(표시계층 대역 — emit 이 실제로 도는지 검증).
#[derive(Default)]
struct CountingSink {
    states: AtomicU64,
    sticks: AtomicU64,
}

impl EventSink for CountingSink {
    fn emit_state(&self, _s: &Snapshot) {
        self.states.fetch_add(1, Ordering::Relaxed);
    }
    fn emit_stick(&self, _lx: f64, _ly: f64, _rx: f64, _ry: f64, _lt: f64, _rt: f64) {
        self.sticks.fetch_add(1, Ordering::Relaxed);
    }
}

/// 루프백 "에코 로봇": DFCMD 수신 → "ACK {seq} {now_ms}" 회신(런타임과 동일 시계라 rtt 현실적).
fn spawn_echo_robot(stop: Arc<AtomicBool>) -> std::io::Result<(u16, JoinHandle<()>)> {
    let sock = UdpSocket::bind("127.0.0.1:0")?;
    let port = sock.local_addr()?.port();
    sock.set_read_timeout(Some(Duration::from_millis(50)))?;
    let h = thread::spawn(move || {
        let mut buf = [0u8; 2048];
        while !stop.load(Ordering::Relaxed) {
            let Ok((n, src)) = sock.recv_from(&mut buf) else {
                continue;
            };
            let text = String::from_utf8_lossy(&buf[..n]);
            let mut it = text.split_whitespace();
            if it.next() == Some("DFCMD") {
                let _token = it.next();
                if let Some(seq) = it.next() {
                    let ack = format!("ACK {seq} {}", now_ms());
                    let _ = sock.send_to(ack.as_bytes(), src);
                }
            }
        }
    });
    Ok((port, h))
}

fn selfcheck(seconds: u64) -> bool {
    println!("▶ darwin-fpv selfcheck — 런타임 6스레드 + 루프백 에코 로봇 ({seconds}s, 로봇 불요)");
    let robot_stop = Arc::new(AtomicBool::new(false));
    let (port, robot_join) = match spawn_echo_robot(robot_stop.clone()) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("✗ 에코 로봇 바인드 실패: {e}");
            return false;
        }
    };

    let sink = Arc::new(CountingSink::default());
    let rt = match Runtime::start(RuntimeConfig::loopback(port), sink.clone()) {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("✗ 런타임 기동 실패: {e}");
            robot_stop.store(true, Ordering::Relaxed);
            let _ = robot_join.join();
            return false;
        }
    };
    let state = rt.state();

    let t0 = Instant::now();
    thread::sleep(Duration::from_secs(seconds));
    let elapsed = t0.elapsed().as_secs_f64();
    let snap = state.read();

    rt.shutdown();
    robot_stop.store(true, Ordering::Relaxed);
    let _ = robot_join.join();

    let states = sink.states.load(Ordering::Relaxed);
    let sticks = sink.sticks.load(Ordering::Relaxed);
    println!(
        "  결과 — eff_hz {:.1} · rtt {} ms · state 이벤트 {} · stick 이벤트 {} ({:.1}s)",
        snap.conn.eff_hz,
        snap.conn
            .rtt_ms
            .map(|v| format!("{v:.2}"))
            .unwrap_or_else(|| "—".into()),
        states,
        sticks,
        elapsed,
    );

    // 게이트: 6스레드가 살아 ACK 가 ~20Hz 로 돌고 표시 이벤트가 발행됐는가.
    let mut ok = true;
    if snap.conn.eff_hz < 15.0 {
        eprintln!("✗ eff_hz {:.1} < 15 — TX↔RX 제어경로 결함", snap.conn.eff_hz);
        ok = false;
    }
    if states == 0 {
        eprintln!("✗ state 이벤트 0 — RX→표시 경로 미동작");
        ok = false;
    }
    if sticks == 0 {
        eprintln!("✗ stick 이벤트 0 — TX→표시 경로 미동작");
        ok = false;
    }
    if ok {
        println!("✓ selfcheck PASS — 런타임 6스레드 기동·ACK·메트릭·이벤트·클린 종료 정상.");
    }
    ok
}
