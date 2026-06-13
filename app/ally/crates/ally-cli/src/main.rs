//! ally-cli — W1 헤드리스 수용시험 러너 + 축 덤프.
//!
//! 04 §2 W1 게이트의 UI 없는 통과 수단: 핸드셰이크→20Hz 영명령 스트림(eff_hz)→
//! TEL2 수신율→ACK RTT p50/p95→B E-STOP 내부 지연→패드 단절 시나리오를 측정치와
//! 함께 stdout 으로 보고한다. 게이트 판정은 ACK 가 아니라 **물리 거동**이다(F9 교훈) —
//! 본 도구는 와이어·안전 코어의 측정·회귀 가드이고, 정지 계약 ≤320ms 는 물리 입회로
//! 판정한다(§4.2). 회귀 검증 도구로 영구 보존.
//!
//! 모드:
//!   ally-cli accept   [--host IP|--wireless] [--duration S] [--estop] [--disconnect] [--no-multiplex]
//!   ally-cli loopback [--duration S]      — 로봇/패드 없이 측정 파이프라인 자기검증
//!   ally-cli axis-dump [--seconds N]      — XInput 트리거/축 매핑 현장 확인

use std::time::{Duration, Instant};

use ally_input::{g01_gait_config, now_ms, InputService};
use ally_link::{ControlSession, RobotShell, ShellResult, SshConfig, SshShell, TransportState};
use df_wire::MotionCommand;

mod loopback;
mod report;

use loopback::FakeRobot;

const STEP: Duration = Duration::from_millis(50); // 20Hz 송신 틱

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("accept") => run_accept(&args[1..]),
        Some("loopback") => run_loopback(&args[1..]),
        Some("axis-dump") => run_axis_dump(&args[1..]),
        Some("-h") | Some("--help") | None => {
            print_help();
            0
        }
        Some(other) => {
            eprintln!("알 수 없는 모드: {other}\n");
            print_help();
            2
        }
    };
    std::process::exit(code);
}

fn print_help() {
    println!(
        "ally-cli — DARwIn FPV W1 헤드리스 수용시험\n\n\
         모드:\n\
         \x20 accept    [--host IP | --wireless] [--duration S] [--estop] [--disconnect] [--no-multiplex]\n\
         \x20           유선 실기 게이트 측정(핸드셰이크·20Hz·eff_hz·TEL2·RTT·E-STOP).\n\
         \x20 loopback  [--duration S]   로봇/패드 없이 측정 파이프라인 자기검증(페이크 로봇).\n\
         \x20 axis-dump [--seconds N]    XInput 트리거/축 매핑 현장 확인.\n\n\
         예: ally-cli accept --host 192.168.123.1 --duration 60 --estop\n\
         \x20   ally-cli loopback --duration 10\n\
         \x20   ally-cli axis-dump --seconds 20"
    );
}

// ── 인자 헬퍼 ────────────────────────────────────────────────────────────────

fn flag_present(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

fn flag_value<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .map(String::as_str)
}

// ── 측정 결과 ────────────────────────────────────────────────────────────────

struct StreamMetrics {
    tx_count: u64,
    ack_total: u64,
    tel_total: u64,
    duration_s: f64,
    rtt_p50: Option<f64>,
    rtt_p95: Option<f64>,
    rtt_ema: Option<f64>,
    adoption_ms: Option<i64>,
}

impl StreamMetrics {
    fn mean_eff_hz(&self) -> f64 {
        if self.duration_s <= 0.0 {
            0.0
        } else {
            self.ack_total as f64 / self.duration_s
        }
    }
    fn mean_tel_hz(&self) -> f64 {
        if self.duration_s <= 0.0 {
            0.0
        } else {
            self.tel_total as f64 / self.duration_s
        }
    }
}

/// 20Hz 영명령 스트림 + 측정. 핸드셰이크 채택(state→Udp) 시각도 함께 잡는다.
fn stream_and_measure<S: RobotShell>(
    session: &mut ControlSession<S>,
    duration: Duration,
) -> StreamMetrics {
    let start = Instant::now();
    let mut next = start;
    let mut tx_count = 0u64;
    let mut adoption_ms: Option<i64> = None;
    let adopt_ref = now_ms();

    while start.elapsed() < duration {
        session.send_command(&MotionCommand::zero());
        tx_count += 1;
        next += STEP;

        // 다음 틱까지 1ms 슬라이스로 pump — ACK 를 도착 즉시 흡수해 RTT 를 정확히
        // 잡는다(틱당 한 번만 pump 하면 RTT 가 틱 간격으로 양자화됨).
        loop {
            session.pump();
            if adoption_ms.is_none() && session.state() == TransportState::Udp {
                adoption_ms = Some(now_ms() - adopt_ref);
            }
            let now = Instant::now();
            if now >= next {
                break;
            }
            std::thread::sleep((next - now).min(Duration::from_millis(1)));
        }
        if Instant::now() > next + STEP {
            next = Instant::now(); // 크게 밀리면 재기준(드리프트 방지).
        }
    }

    let (ack_total, tel_total, rtt_p50, rtt_p95, rtt_ema) = match session.transport() {
        Some(t) => (
            t.ack_total(),
            t.tel_total(),
            report::percentile_of(t.rtt_samples(), 50.0),
            report::percentile_of(t.rtt_samples(), 95.0),
            t.last_rtt_ms(),
        ),
        None => (0, 0, None, None, None),
    };

    StreamMetrics {
        tx_count,
        ack_total,
        tel_total,
        duration_s: start.elapsed().as_secs_f64(),
        rtt_p50,
        rtt_p95,
        rtt_ema,
        adoption_ms,
    }
}

fn print_stream_report(m: &StreamMetrics, transport_label: &str) {
    let eff = m.mean_eff_hz();
    println!("── 측정 결과 ───────────────────────────────");
    println!("  전송 경로            : {transport_label}");
    match m.adoption_ms {
        Some(ms) => println!(
            "  핸드셰이크 채택      : {ms}ms (첫 ACK, ≤1s 기대) [{}]",
            report::verdict(ms <= 1000)
        ),
        None => println!("  핸드셰이크 채택      : 미채택(ACK 무수신 — UDP 미승격)"),
    }
    println!(
        "  송신 틱 수           : {} ({:.1}s)",
        m.tx_count, m.duration_s
    );
    println!(
        "  평균 eff_hz          : {:.2} Hz (ACK {}) [{}]",
        eff,
        m.ack_total,
        report::verdict(report::eff_hz_pass(eff))
    );
    println!(
        "  TEL2 수신율          : {:.2} Hz (TEL2 {})",
        m.mean_tel_hz(),
        m.tel_total
    );
    match (m.rtt_p50, m.rtt_p95) {
        (Some(p50), Some(p95)) => println!(
            "  ACK RTT p50/p95      : {p50:.2} / {p95:.2} ms (EMA {:.2})",
            m.rtt_ema.unwrap_or(0.0)
        ),
        _ => println!("  ACK RTT p50/p95      : (표본 없음)"),
    }
}

// ── accept: 유선 실기 게이트 ─────────────────────────────────────────────────

fn run_accept(args: &[String]) -> i32 {
    let wireless = flag_present(args, "--wireless");
    let mut cfg = if wireless {
        SshConfig::wireless()
    } else {
        SshConfig::wired()
    };
    if let Some(h) = flag_value(args, "--host") {
        cfg.host = h.to_string();
    }
    if flag_present(args, "--no-multiplex") {
        cfg.multiplex = false;
    }
    let host = cfg.host.clone();
    let duration = Duration::from_secs(
        flag_value(args, "--duration")
            .and_then(|s| s.parse().ok())
            .unwrap_or(60),
    );

    println!("=== ally-cli accept — 유선 실기 게이트 ===");
    println!("대상: {host} (user {}) · 송신 {duration:?}", cfg.user);
    println!("주의: 측정 중 Mac DarwinForge 앱 종료(connectOnboard 가 시험 상태 파괴 — 04 §4.4)\n");

    let shell = SshShell::new(cfg);
    let mut session = match ControlSession::start(shell, &host, g01_gait_config()) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("✗ 세션 개시 실패: {e}");
            eprintln!(
                "  → SSH 도달성/협상 점검: ssh.exe 가 OpenSSH 5.9(+ssh-rsa)와 협상하는지,\n\
                 \x20   RSA 키(~/.ssh/id_rsa_darwin)가 로봇에 등록됐는지, 유선 192.168.123.1 도달성.\n\
                 \x20   협상 자체가 실패하면 게이트 항목대로 russh/plink 분기를 결정한다(03 §9)."
            );
            return 1;
        }
    };
    println!("✓ 세션 개시 — 핸드셰이크 기록, UDP 프로브 시작\n");

    let metrics = stream_and_measure(&mut session, duration);
    let label = transport_label(session.state());
    print_stream_report(&metrics, label);

    if flag_present(args, "--estop") {
        run_estop_phase(&mut session);
    }
    if flag_present(args, "--disconnect") {
        run_disconnect_phase();
    }

    println!("\n── 물리 거동 게이트(수동 입회 — 본 도구 자동 판정 아님) ──");
    println!("  정지 계약 ≤320ms · 워치독 600ms/2.5s 트립 · 서보 물리 정지는 §4.2 절차로 입회.");
    println!("  \"ACK enabled=1 ≠ 서보 기록\"(F9) — 판정은 물리 거동.");

    session.close();
    println!("\n✓ 세션 종료 — 핸드셰이크 제거(스테일 토큰 금지 §G.1)");
    0
}

fn run_estop_phase<S: RobotShell + Clone + Send + 'static>(session: &mut ControlSession<S>) {
    println!("\n── B E-STOP 내부 지연 측정 ──");
    let (input, estop_rx) = match InputService::spawn() {
        Ok((svc, estop_rx, _edge_rx)) => (svc, estop_rx),
        Err(e) => {
            eprintln!("  ✗ 입력 서비스 기동 실패({e}) — E-STOP 단계 건너뜀");
            return;
        }
    };
    println!("  10초 내 패드 B 를 누르세요(물리 정지 입회 — ACK 동결 + 서보 정지 §4.2)...");
    match estop_rx.recv_timeout(Duration::from_secs(10)) {
        Ok(sig) => {
            session.estop(); // UDP ×3연발 즉시(INV-1) + SSH touch 병행
            let t_write = now_ms();
            let latency = t_write - sig.t_ms;
            println!(
                "  입력→소켓 write 내부 지연: {latency}ms [{}] (상한 {:.0}ms — 회귀 가드)",
                report::verdict(report::estop_internal_pass(latency as f64)),
                report::ESTOP_INTERNAL_MAX_MS
            );
            println!("  → 물리 정지·ACK 동결을 입회로 확인할 것(자동 판정 아님).");
            std::thread::sleep(Duration::from_millis(500));
            if session.recover() {
                println!("  복구(estop flag rm) 완료 — 재무장 가능.");
            }
        }
        Err(_) => println!("  (10초 내 B 입력 없음 — 단계 건너뜀)"),
    }
    input.stop();
}

fn run_disconnect_phase() {
    println!("\n── 패드 단절 시나리오 ──");
    let (input, _estop_rx, _edge_rx) = match InputService::spawn() {
        Ok(t) => t,
        Err(e) => {
            eprintln!("  ✗ 입력 서비스 기동 실패({e}) — 단계 건너뜀");
            return;
        }
    };
    // 연결 확인 후 단절 관측.
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(2) && !input.latest().connected {
        std::thread::sleep(Duration::from_millis(50));
    }
    if !input.latest().connected {
        println!("  (패드 미연결 — 단절 관측 불가, 단계 건너뜀)");
        input.stop();
        return;
    }
    println!("  10초 내 패드를 분리(동글 뽑기)하세요...");
    let mut transitioned = None;
    let watch = Instant::now();
    while watch.elapsed() < Duration::from_secs(10) {
        if !input.latest().connected {
            transitioned = Some(watch.elapsed());
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    match transitioned {
        Some(_) => {
            println!("  ✓ 단절 감지 → frame.connected=false (TX 루프가 zero+disarm, 재 ARM 요구)")
        }
        None => println!("  (10초 내 단절 없음 — 단계 건너뜀)"),
    }
    input.stop();
}

// ── loopback: 헤드리스 자기검증 ──────────────────────────────────────────────

fn run_loopback(args: &[String]) -> i32 {
    let duration = Duration::from_secs(
        flag_value(args, "--duration")
            .and_then(|s| s.parse().ok())
            .unwrap_or(10),
    );
    println!("=== ally-cli loopback — 페이크 로봇 자기검증(로봇·패드 불요) ===");

    let robot = match FakeRobot::spawn() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("✗ 페이크 로봇 기동 실패: {e}");
            return 1;
        }
    };
    println!(
        "페이크 로봇: 127.0.0.1 cmd:{} estop:{}\n",
        robot.cmd_port, robot.estop_port
    );

    let shell = LoopbackShell;
    let mut session = match ControlSession::start_with_ports(
        shell,
        "127.0.0.1",
        g01_gait_config(),
        robot.cmd_port,
        robot.estop_port,
    ) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("✗ 세션 개시 실패: {e}");
            robot.stop();
            return 1;
        }
    };

    let metrics = stream_and_measure(&mut session, duration);
    print_stream_report(&metrics, transport_label(session.state()));

    // E-STOP 경로 — UDP 데이터그램이 페이크 로봇 estop 소켓에 닿는지.
    session.estop();
    std::thread::sleep(Duration::from_millis(200));
    let estop_n = robot.estop_count();
    println!(
        "  E-STOP 데이터그램 도달    : {estop_n}발 [{}] (×3연발 0/50/100ms 기대)",
        report::verdict(estop_n >= 1)
    );

    session.close();
    robot.stop();

    // 자기검증 합격 판정 — eff_hz·채택·estop 도달.
    let ok = report::eff_hz_pass(metrics.mean_eff_hz())
        && metrics.adoption_ms.is_some_and(|ms| ms <= 1000)
        && estop_n >= 1;
    println!("\n자기검증: {}", report::verdict(ok));
    i32::from(!ok)
}

// ── axis-dump: XInput 매핑 확인 ──────────────────────────────────────────────

fn run_axis_dump(args: &[String]) -> i32 {
    let secs = flag_value(args, "--seconds")
        .and_then(|s| s.parse().ok())
        .unwrap_or(20);
    match ally_input::dump_events(Duration::from_secs(secs)) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("✗ 축 덤프 실패: {e}");
            1
        }
    }
}

fn transport_label(state: TransportState) -> &'static str {
    match state {
        TransportState::Udp => "UDP (활성)",
        TransportState::Probing => "UDP (프로브 — ACK 미수신)",
        TransportState::Ssh => "SSH 파일 폴백 (5Hz)",
    }
}

/// loopback 용 무동작 셸 — SSH 없이 도달성·핸드셰이크를 성공으로 흉내낸다.
#[derive(Clone)]
struct LoopbackShell;

impl RobotShell for LoopbackShell {
    fn run(&self, _command: &str, _input: Option<&[u8]>) -> ShellResult {
        ShellResult {
            code: Some(0),
            stdout: "ok".into(),
            stderr: String::new(),
            timed_out: false,
        }
    }
}
