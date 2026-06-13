//! ally-cli — 헤드리스 수용시험 (W1).
//!
//! switch-pilot `native_acceptance.py` 의 Rust 판. 하위 명령:
//!   - `selftest`           : 루프백 에코 로봇으로 UDP 제어경로+메트릭 검증(로봇 불요).
//!   - `probe [--prefer …]` : §7-1 TCP :22 경로 프로브(유선/무선).
//!   - `connect …`          : §7 전체 시퀀스 — 핸드셰이크→20Hz 스트림→메트릭(실로봇).
//!
//! W1 게이트(docs/04_ACCEPTANCE_ROADMAP.md §2): 핸드셰이크 → 20Hz 영명령(eff_hz ≥19)
//! → E-STOP 버스트 → 메트릭 덤프. `selftest` 는 그 파이프라인을 소프트웨어로 회귀 검증한다.

use std::io;
use std::net::UdpSocket;
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use ally_link::metrics::{EffHz, RttEma};
use ally_link::session::{decide_transport, Path, Transport};
use ally_link::ssh::SshClient;
use ally_link::udp::{local_ip_toward, Inbound, UdpControlTransport};
use ally_link::{probe_path, DEFAULT_CMD_PORT, DEFAULT_ESTOP_PORT};
use df_wire::{build_line, gen_cmd_id, gen_token, GaitConfig, MotionCommand};

const TICK_HZ: f64 = ally_link::UDP_SEND_HZ; // 20
/// 송신 틱 간격 (20Hz → 50ms). const 부동소수 캐스트 회피 위해 런타임 산출.
fn tick() -> Duration {
    Duration::from_secs_f64(1.0 / TICK_HZ)
}
/// 틱당 ACK/TEL2 드레인 상한 — `df_udp.py::pump(max_datagrams=64)` 등가(폭주 방어).
const MAX_DRAIN: usize = 64;

/// 핸드셰이크 RAII 가드 — 정상·에러·조기복귀 모든 경로에서 채널 토큰을 철회한다
/// (§G.1 MUST: 스테일 토큰은 다음 세션을 죽인다). `rm -f` 라 멱등 — 중복 철회 무해.
struct HandshakeGuard<'a> {
    ssh: &'a SshClient,
    active: bool,
}

impl<'a> HandshakeGuard<'a> {
    fn new(ssh: &'a SshClient) -> Self {
        HandshakeGuard { ssh, active: true }
    }
    /// 즉시 철회(멱등). 폴백 전환·정상 종료에서 명시 호출.
    fn retract(&mut self) {
        if self.active {
            let _ = self.ssh.retract_handshake();
            self.active = false;
        }
    }
}

impl Drop for HandshakeGuard<'_> {
    fn drop(&mut self) {
        // 에러 ?-전파로 빠져나가도 채널을 남기지 않는다.
        if self.active {
            let _ = self.ssh.retract_handshake();
        }
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("help");
    let rest = &args[args.len().min(1)..];

    let result = match cmd {
        "selftest" => selftest(),
        "probe" => probe(rest),
        "connect" => connect(rest),
        "help" | "-h" | "--help" => {
            usage();
            Ok(())
        }
        other => {
            eprintln!("알 수 없는 명령: {other}\n");
            usage();
            return ExitCode::from(2);
        }
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("✗ {e}");
            ExitCode::FAILURE
        }
    }
}

fn usage() {
    eprintln!(
        "ally-cli — DARwIn FPV 헤드리스 수용시험\n\
         \n\
         사용:\n\
         \x20 ally-cli selftest                      루프백으로 UDP 제어경로+메트릭 검증(로봇 불요)\n\
         \x20 ally-cli probe   [--prefer wired|wireless]\n\
         \x20 ally-cli connect --identity <키경로> [--prefer wired|wireless] [--seconds N]\n"
    );
}

// ── --flag 값 파서 (clap 의존 회피) ─────────────────────────────────────────
fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .map(String::as_str)
}

fn prefer_from(args: &[String]) -> Path {
    match flag(args, "--prefer") {
        Some("wireless") => Path::Wireless,
        _ => Path::Wired, // 기본 유선 우선
    }
}

// ── selftest: 루프백 에코 로봇 ──────────────────────────────────────────────
fn selftest() -> io::Result<()> {
    println!("▶ selftest — 루프백 에코 로봇으로 20Hz 제어경로 검증");
    let stop = Arc::new(AtomicBool::new(false));
    let (robot_port, join) = spawn_echo_robot(stop.clone())?;

    let token = gen_token();
    let tx = UdpControlTransport::bind(
        "127.0.0.1",
        token,
        robot_port,
        robot_port + 1,
        Duration::from_millis(3),
    )?;
    // local_ip_toward 도 함께 검증(업링크 산출).
    let local_ip = local_ip_toward("127.0.0.1")?;
    println!("  local_ip_toward(127.0.0.1) = {local_ip}");

    let mut rtt = RttEma::new();
    let mut eff = EffHz::new();
    let cfg = GaitConfig::default();
    let start = Instant::now();
    let mut seq: u64 = 0;
    let mut acks = 0u64;
    let tick_dur = tick();

    // ~2s 동안 20Hz 영명령 스트림 + ACK 드레인 (데드라인 스케줄·틱당 상한).
    while start.elapsed() < Duration::from_millis(2000) {
        let now_ms = start.elapsed().as_millis() as i64;
        seq += 1;
        let deadline = start + tick_dur * (seq as u32);
        let line = build_line(&gen_cmd_id(), &cfg, &MotionCommand::zero());
        if let Err(e) = tx.send_cmd(seq, &line) {
            eprintln!("⚠ UDP 송신 실패(seq {seq}): {e}");
        }
        // 이번 틱에 도착한 ACK 드레인 (상한 MAX_DRAIN).
        for _ in 0..MAX_DRAIN {
            match tx.recv()? {
                Some(Inbound::Ack { t_rx, .. }) => {
                    rtt.update((now_ms - t_rx).max(0) as f64); // 루프백이라 ~0(합성)
                    eff.record(now_ms);
                    acks += 1;
                }
                Some(_) => {}
                None => break,
            }
        }
        if let Some(rem) = deadline.checked_duration_since(Instant::now()) {
            thread::sleep(rem);
        }
    }

    let final_ms = start.elapsed().as_millis() as i64;
    let eff_hz = eff.rate(final_ms);
    stop.store(true, Ordering::Relaxed); // 에코 로봇 스레드 정지 신호 → 즉시 join.
    let _ = join.join();
    println!(
        "  결과 — 송신 {seq} · ACK {acks} · eff_hz {:.1} · rtt_ema {} ms (루프백 합성)",
        eff_hz,
        rtt.value().map(|v| format!("{v:.2}")).unwrap_or_else(|| "—".into())
    );

    // 소프트웨어 게이트: 파이프라인이 살아 있는가(실기 ≥19 은 connect 의 몫).
    if acks == 0 {
        return Err(io::Error::other("ACK 미수신 — UDP 왕복 실패"));
    }
    if rtt.value().is_none() {
        return Err(io::Error::other("RTT 미산출"));
    }
    if eff_hz < 10.0 {
        return Err(io::Error::other(format!(
            "eff_hz {eff_hz:.1} < 10 — 케이던스/드레인 결함"
        )));
    }
    println!("✓ selftest PASS (제어경로·메트릭 정상). 실기 eff_hz ≥19 게이트는 `connect`.");
    Ok(())
}

/// 가짜 "로봇": DFCMD 수신 → "ACK {seq} {t_rx}" 회신. stop 신호 또는 5s 후 종료.
fn spawn_echo_robot(stop: Arc<AtomicBool>) -> io::Result<(u16, thread::JoinHandle<()>)> {
    let sock = UdpSocket::bind("127.0.0.1:0")?;
    let port = sock.local_addr()?.port();
    sock.set_read_timeout(Some(Duration::from_millis(50)))?;
    let start = Instant::now();
    let h = thread::spawn(move || {
        let mut buf = [0u8; 2048];
        while !stop.load(Ordering::Relaxed) && start.elapsed() < Duration::from_secs(5) {
            let Ok((n, src)) = sock.recv_from(&mut buf) else {
                continue;
            };
            let text = String::from_utf8_lossy(&buf[..n]);
            let mut it = text.split_whitespace();
            if it.next() == Some("DFCMD") {
                let _token = it.next();
                if let Some(seq) = it.next() {
                    let t_rx = start.elapsed().as_millis() as i64;
                    let ack = format!("ACK {seq} {t_rx}");
                    let _ = sock.send_to(ack.as_bytes(), src);
                }
            }
        }
    });
    Ok((port, h))
}

// ── probe ───────────────────────────────────────────────────────────────────
fn probe(args: &[String]) -> io::Result<()> {
    let prefer = prefer_from(args);
    println!("▶ probe — TCP :22 (유선 우선={})", prefer == Path::Wired);
    let path = probe_path(prefer, Duration::from_millis(600));
    match path {
        Path::None => Err(io::Error::other(
            "로봇 미도달 — 유선(192.168.123.1)·무선(192.168.0.33) 둘 다 :22 응답 없음",
        )),
        p => {
            println!("✓ 도달: {} ({})", p.as_str(), p.host().unwrap_or("?"));
            Ok(())
        }
    }
}

// ── connect: §7 전체 시퀀스 (실로봇) ────────────────────────────────────────
fn connect(args: &[String]) -> io::Result<()> {
    let prefer = prefer_from(args);
    let identity = flag(args, "--identity").map(str::to_string);
    let seconds: u64 = flag(args, "--seconds").and_then(|s| s.parse().ok()).unwrap_or(5);
    let force = args.iter().any(|a| a == "--force");
    let estop_test = args.iter().any(|a| a == "--estop-test");

    // §7-1 경로 프로브.
    let path = probe_path(prefer, Duration::from_millis(800));
    let host = path
        .host()
        .ok_or_else(|| io::Error::other("로봇 미도달(유선·무선 :22 무응답)"))?;
    println!("▶ 경로 {} ({host})", path.as_str());

    // §7-2/3 SSH + 브로커리지 모드 확인 (미실행 vs 다른 모드 구분).
    let ssh = SshClient::new(host, identity);
    let mode = ssh.pilot_mode()?;
    if mode.is_empty() {
        return Err(io::Error::other(
            "브로커리지 미실행(df-pilot-mode 없음) — DarwinForge '조종기 데모 시작' 또는 robot_ready start-walklab 후 재시도",
        ));
    }
    if mode != "walklab" {
        return Err(io::Error::other(format!(
            "브로커리지가 walklab 아닌 '{mode}' 모드 — 데모를 walklab 으로 재시작 후 재시도"
        )));
    }
    println!("  브로커리지 walklab 확인");

    // 단일 세션 가드 — 기존 핸드셰이크가 있으면 이 connect 가 토큰을 회전시켜 그 세션을
    // 끊는다(§G.1). --force 없으면 중단(Mac/Switch/타 Ally 와의 동시 제어 사고 방지).
    let incumbent = ssh
        .run(&format!(
            "cat {} 2>/dev/null || true",
            ally_link::ssh::CHANNEL_PATH
        ))?
        .trim()
        .to_string();
    if !incumbent.is_empty() {
        eprintln!("⚠ 활성 세션 감지(채널: {incumbent}) — 핸드셰이크 시 기존 제어가 끊깁니다.");
        if !force {
            return Err(io::Error::other(
                "다른 세션이 로봇을 제어 중일 수 있음 — 단일 운영자 확인 후 --force 로 강제",
            ));
        }
        eprintln!("  --force — 진행(기존 세션 종료됨).");
    }

    // §7-4 핸드셰이크 + RAII 가드(이후 모든 경로에서 철회 보장).
    let token = gen_token();
    ssh.write_handshake(&token, DEFAULT_ESTOP_PORT, DEFAULT_CMD_PORT)?;
    let mut guard = HandshakeGuard::new(&ssh);
    println!("  핸드셰이크 기록(token {token})");

    // §7-5 업링크 등록.
    let tx = UdpControlTransport::bind(
        host,
        token.clone(),
        DEFAULT_CMD_PORT,
        DEFAULT_ESTOP_PORT,
        Duration::from_millis(3),
    )?;
    let local_ip = local_ip_toward(host)?;
    let local_port = tx.local_port()?;
    ssh.write_uplink(&local_ip.to_string(), local_port)?;
    println!("  업링크 등록 {local_ip}:{local_port}");

    // §7-6 20Hz 영명령 스트림 + ACK/TEL2 드레인 + 폴백 판정.
    let mut rtt = RttEma::new();
    let mut eff = EffHz::new();
    let cfg = GaitConfig::default();
    let start = Instant::now();
    let mut seq: u64 = 0;
    let mut last_ack_ms: Option<i64> = None;
    let mut tel_count = 0u64;
    let mut fell_back = false;
    let tick_dur = tick();

    println!("  20Hz 영명령 스트림 {seconds}s …");
    while start.elapsed() < Duration::from_secs(seconds) {
        let now_ms = start.elapsed().as_millis() as i64;
        seq += 1;
        let deadline = start + tick_dur * (seq as u32); // 데드라인 스케줄(드리프트 방지)
        let line = build_line(&gen_cmd_id(), &cfg, &MotionCommand::zero());

        match decide_transport(last_ack_ms.map(|t| now_ms - t)) {
            Transport::Udp => {
                if let Err(e) = tx.send_cmd(seq, &line) {
                    eprintln!("⚠ UDP 송신 실패(seq {seq}): {e}"); // 한 발 손실 — 계속.
                }
            }
            Transport::SshFile => {
                // §7-6 폴백 진입 시 1회 핸드셰이크 철회(로봇 UDP 리스너 정리).
                if !fell_back {
                    guard.retract();
                    fell_back = true;
                    eprintln!("  ACK 침묵 → SSH 파일 5Hz 폴백(핸드셰이크 철회).");
                }
                if seq.is_multiple_of(4) {
                    if let Err(e) = ssh.write_cmd_file(&line) {
                        eprintln!("⚠ SSH 폴백 기록 실패: {e}");
                    }
                }
            }
        }

        // ACK/TEL2 드레인 — 틱당 상한(폭주 방어, df_udp pump=64).
        for _ in 0..MAX_DRAIN {
            match tx.recv()? {
                Some(Inbound::Ack { t_rx, .. }) => {
                    rtt.update((now_ms - t_rx).max(0) as f64);
                    eff.record(now_ms);
                    last_ack_ms = Some(now_ms);
                }
                Some(Inbound::Telemetry(_)) => tel_count += 1,
                Some(Inbound::Other) => {}
                None => break,
            }
        }

        if let Some(rem) = deadline.checked_duration_since(Instant::now()) {
            thread::sleep(rem);
        }
    }

    let final_ms = start.elapsed().as_millis() as i64;
    let eff_hz = eff.rate(final_ms);
    let transport = decide_transport(last_ack_ms.map(|t| final_ms - t));
    println!(
        "  메트릭 — 전송 {} · eff_hz {:.1} · rtt {} ms · TEL2 {}",
        transport.as_str(),
        eff_hz,
        rtt.value().map(|v| format!("{v:.1}")).unwrap_or_else(|| "—".into()),
        tel_count,
    );

    // §G.2 E-STOP 버스트 검증(옵션 --estop-test) — 0/50/100ms ×3 UDP + SSH touch.
    // 로봇을 estop 래치시키므로 명시 요청 시에만. 정지 와이어아웃 계약 증명.
    if estop_test {
        println!("  E-STOP 버스트(0/50/100ms ×3 + SSH touch)…");
        let es = Instant::now();
        for off in df_wire::ESTOP_BURST_OFFSETS_MS {
            if let Some(w) = (es + Duration::from_millis(off)).checked_duration_since(Instant::now())
            {
                thread::sleep(w);
            }
            let ts = es.elapsed().as_millis() as i64;
            if let Err(e) = tx.send_estop(ts) {
                eprintln!("⚠ E-STOP UDP 송신 실패: {e}");
            }
        }
        let _ = ssh.touch_estop();
        eprintln!("  ⚠ 로봇 E-STOP 래치됨 — 복구(Y) 또는 데모 재시작 필요.");
    }

    // §7-7 종료 — 스테일 토큰 금지(MUST). 가드가 멱등 철회(폴백서 이미 철회됐어도 무해).
    guard.retract();
    println!("  핸드셰이크 철회(rm channel)");

    if eff_hz < 19.0 {
        return Err(io::Error::other(format!(
            "eff_hz {eff_hz:.1} < 19 (W1 게이트 미달) — 경로/로봇 점검"
        )));
    }
    println!("✓ connect W1 게이트 통과 (eff_hz {eff_hz:.1} ≥ 19)");
    Ok(())
}
