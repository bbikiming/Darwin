//! Runtime — §2 스레드 모델의 기동·배선. INV-2: 이 모듈은 tauri 를 참조하지 않는다
//! (표시계층 push 는 [`EventSink`] 트레이트로만).
//!
//! 스레드(런타임 기동분):
//! - **control-tx** (20Hz 고정틱): `input.latest()` → 신선도/매핑/게이트 → `send_cmd`,
//!   하트비트 갱신, 폴백 판정(ACK 침묵 → SSH 파일 5Hz). StateHub `cmd/safety/pad` 갱신.
//! - **udp-rx** (blocking recv): ACK → RTT·eff_hz, TEL2 → StateHub. 30Hz `emit_state`.
//! - **estop** (park): 무손실 버스 수신 → UDP ×3연발(0/50/100ms) + SSH touch.
//! - **supervisor** (100ms): 패드 단절·TX 하트비트 침묵 >300ms → estop 버스.
//! - **estop-fwd**: 입력 스레드의 무손실 B 채널(`estop_rx`)을 estop 버스로 잇는 글루.
//! - **ssh-session** (Robot 만): §7-4/5 핸드셰이크·uplink 를 start 에서 수립, 종료 시 철회.
//!
//! 입력 250Hz 폴링은 `ally_input::InputService` 내부 스레드가 소유한다(§2 "입력 스레드").
//!
//! 로봇 종단(`Endpoint::Robot`)은 실로봇 경로다 — `ally-cli connect` 로 운영자가 단일
//! 세션·walklab 모드를 선검증한 뒤에만 띄운다(런타임은 mode/incumbent 가드를 반복하지
//! 않는다). 헤드리스 검증은 `Endpoint::Loopback`(에코 로봇, SSH 미기동)으로 한다.

use std::io;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::mpsc::RecvTimeoutError;
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use ally_input::{now_ms, ButtonEdges, InputService};
use ally_link::metrics::{EffHz, RttEma};
use ally_link::session::{decide_transport, Transport};
use ally_link::ssh::{SshClient, ESTOP_PATH};
use ally_link::udp::{local_ip_toward, Inbound, UdpControlTransport};
use ally_link::{DEFAULT_CMD_PORT, DEFAULT_ESTOP_PORT};
use df_wire::{gen_token, ESTOP_BURST_OFFSETS_MS};

use crate::estop::{EstopBus, EstopCause};
use crate::event::EventSink;
use crate::state::{ConnPath, ConnTransport, StateHub};
use crate::supervisor::{Heartbeat, PadWatch};
use crate::tx::TxPipeline;

/// 로봇 종단점.
pub enum Endpoint {
    /// 실로봇: 호스트 + SSH identity + 표시 경로. §7 핸드셰이크/uplink/철회를 수행.
    Robot {
        host: String,
        identity: Option<String>,
        path: ConnPath,
    },
    /// 헤드리스 셀프체크: 루프백 에코 로봇(127.0.0.1:port). SSH 미기동, UDP만.
    Loopback { host: String, cmd_port: u16, estop_port: u16 },
}

/// 런타임 설정.
pub struct RuntimeConfig {
    pub endpoint: Endpoint,
    /// TX 고정틱 (기본 50ms = 20Hz).
    pub tick: Duration,
    /// RX recv 타임아웃 (기본 3ms — 블로킹 회피).
    pub recv_timeout: Duration,
}

impl RuntimeConfig {
    /// 루프백 셀프체크 기본 설정.
    pub fn loopback(cmd_port: u16) -> Self {
        RuntimeConfig {
            endpoint: Endpoint::Loopback {
                host: "127.0.0.1".into(),
                cmd_port,
                estop_port: cmd_port,
            },
            tick: Duration::from_millis(50),
            recv_timeout: Duration::from_millis(3),
        }
    }
}

/// 기동된 런타임 핸들. `shutdown` 으로 정지 + 핸드셰이크 철회(§7-7).
pub struct Runtime {
    stop: Arc<AtomicBool>,
    threads: Vec<JoinHandle<()>>,
    /// RAII 보유 — shutdown 의 스레드 합류 후 마지막으로 드롭되며 gilrs 폴링 스레드를
    /// 합류시킨다(결정적 종료 순서). 직접 읽지 않으므로 dead_code 허용.
    #[allow(dead_code)]
    input: Arc<InputService>,
    state: Arc<StateHub>,
    ssh: Option<Arc<SshClient>>,
}

impl Runtime {
    /// §2 스레드들을 기동한다. Robot 종단이면 핸드셰이크/uplink 를 먼저 수립.
    pub fn start(cfg: RuntimeConfig, sink: Arc<dyn EventSink>) -> io::Result<Runtime> {
        let stop = Arc::new(AtomicBool::new(false));
        let state = Arc::new(StateHub::new());
        let token = gen_token();
        let session_start = now_ms(); // 폴백 시작-유예 기준(첫 ACK 전).

        let (host, cmd_port, estop_port, conn_path, identity, is_robot) = match &cfg.endpoint {
            Endpoint::Robot {
                host,
                identity,
                path,
            } => (
                host.clone(),
                DEFAULT_CMD_PORT,
                DEFAULT_ESTOP_PORT,
                *path,
                identity.clone(),
                true,
            ),
            Endpoint::Loopback {
                host,
                cmd_port,
                estop_port,
            } => (
                host.clone(),
                *cmd_port,
                *estop_port,
                ConnPath::None,
                None,
                false,
            ),
        };

        // 공유 UDP 소켓(단일 소켓 송수신 — §2). TX/ESTOP send, RX recv 가 함께 쓴다.
        let udp = Arc::new(UdpControlTransport::bind(
            host.as_str(),
            token.clone(),
            cmd_port,
            estop_port,
            cfg.recv_timeout,
        )?);

        // Robot: §7-4/5 핸드셰이크 + uplink (connect 와 동일 시퀀스). 철회는 shutdown.
        let ssh = if is_robot {
            let c = Arc::new(SshClient::new(host.as_str(), identity));
            c.write_handshake(&token, estop_port, cmd_port)?;
            let local_ip = local_ip_toward(host.as_str())?;
            let local_port = udp.local_port()?;
            c.write_uplink(&local_ip.to_string(), local_port)?;
            Some(c)
        } else {
            None
        };

        state.write(|s| s.conn.path = conn_path);

        // 입력 서비스(250Hz gilrs 내부 스레드) + 무손실 B 채널 + 버튼 에지.
        let (svc, estop_rx, edge_rx) = InputService::spawn().map_err(io::Error::other)?;
        let input = Arc::new(svc);

        let (bus, bus_rx) = EstopBus::channel();
        let heartbeat = Heartbeat::new();
        let last_ack = Arc::new(AtomicI64::new(0));
        let mut threads: Vec<JoinHandle<()>> = Vec::new();

        // ── estop-fwd: 입력 무손실 B 채널 → estop 버스 ─────────────────────────
        {
            let bus = bus.clone();
            let stop = stop.clone();
            threads.push(spawn_named("estop-fwd", move || loop {
                match estop_rx.recv_timeout(Duration::from_millis(100)) {
                    Ok(sig) => bus.fire(EstopCause::from_reason(sig.reason), sig.t_ms),
                    Err(RecvTimeoutError::Timeout) => {
                        if stop.load(Ordering::Relaxed) {
                            break;
                        }
                    }
                    Err(RecvTimeoutError::Disconnected) => break,
                }
            }));
        }

        // ── control-tx: 20Hz 고정틱 ───────────────────────────────────────────
        {
            let input = input.clone();
            let udp = udp.clone();
            let state = state.clone();
            let stop = stop.clone();
            let hb = heartbeat.clone();
            let last_ack = last_ack.clone();
            let ssh_tx = ssh.clone();
            let sink = sink.clone();
            let tick = cfg.tick;
            threads.push(spawn_named("control-tx", move || {
                let mut pipe = TxPipeline::new();
                let mut seq: u64 = 0;
                let start = Instant::now();
                while !stop.load(Ordering::Relaxed) {
                    let t = now_ms();
                    seq += 1;
                    let deadline = start + tick * (seq as u32);

                    // 이번 틱 버튼 에지 누적(OR).
                    let mut e = ButtonEdges::default();
                    while let Ok(be) = edge_rx.try_recv() {
                        e.arm |= be.arm;
                        e.estop |= be.estop;
                        e.recover |= be.recover;
                    }
                    let frame = input.latest();
                    let out = pipe.step(&frame, e, t);

                    // 폴백 판정(ACK 침묵 → SSH 파일 5Hz). ACK 받았으면 마지막 ACK 후
                    // 경과, 아직이면 세션 시작 후 경과(시작 유예) — decide_transport(None)
                    // →SshFile 함정 회피. 시작부터 ACK_PROBE_MS 동안 UDP 를 시도하고,
                    // 그 이후의 침묵만 폴백으로 본다.
                    let la = last_ack.load(Ordering::Relaxed);
                    let age = Some(t - if la == 0 { session_start } else { la });
                    let transport = decide_transport(age);
                    match transport {
                        Transport::Udp => {
                            let _ = udp.send_cmd(seq, &out.line);
                        }
                        Transport::SshFile => {
                            if let (Some(c), true) = (&ssh_tx, seq.is_multiple_of(4)) {
                                let _ = c.write_cmd_file(&out.line);
                            }
                        }
                    }
                    hb.beat(t);

                    // 복구 발화 → 로봇 estop flag 제거(rm) — Robot 만.
                    if out.events.fire_recover {
                        if let Some(c) = &ssh_tx {
                            let _ = c.run(&format!("rm -f {ESTOP_PATH}"));
                        }
                    }

                    state.write(|s| {
                        s.cmd.x = out.cmd.stride_mm;
                        s.cmd.y = out.cmd.side_mm;
                        s.cmd.a = out.cmd.turn_deg;
                        s.safety.armed = out.armed;
                        s.safety.estop_latched = out.estop_latched;
                        s.safety.recovering = out.recovering;
                        s.pad.connected = frame.connected;
                        s.pad.turbo = frame.axes.btn_rb;
                        s.conn.transport = match transport {
                            Transport::Udp => ConnTransport::Udp,
                            Transport::SshFile => ConnTransport::SshFile,
                        };
                    });
                    // 스틱 오버레이(§3 stick) — 스켈레톤은 TX 틱(20Hz)에서 발행(60Hz 는 Phase 3).
                    let a = &frame.axes;
                    sink.emit_stick(a.left_x, a.left_y, a.right_x, a.right_y, a.lt, a.rt);

                    if let Some(rem) = deadline.checked_duration_since(Instant::now()) {
                        thread::sleep(rem);
                    }
                }
            }));
        }

        // ── udp-rx: blocking recv → 메트릭/TEL2/StateHub + 30Hz emit_state ─────
        {
            let udp = udp.clone();
            let state = state.clone();
            let stop = stop.clone();
            let last_ack = last_ack.clone();
            let sink = sink.clone();
            threads.push(spawn_named("udp-rx", move || {
                let mut rtt = RttEma::new();
                let mut eff = EffHz::new();
                let mut last_emit = 0i64;
                while !stop.load(Ordering::Relaxed) {
                    match udp.recv() {
                        Ok(Some(Inbound::Ack { t_rx, .. })) => {
                            let t = now_ms();
                            rtt.update((t - t_rx).max(0) as f64);
                            eff.record(t);
                            last_ack.store(t, Ordering::Relaxed);
                            let hz = eff.rate(t);
                            let r = rtt.value();
                            state.write(|s| {
                                s.conn.eff_hz = hz;
                                s.conn.rtt_ms = r;
                            });
                        }
                        Ok(Some(Inbound::Telemetry(tel))) => {
                            let t = now_ms();
                            state.write(|s| s.apply_tel2(*tel, t));
                        }
                        Ok(_) | Err(_) => {} // Other/타임아웃/일시 오류 — 계속.
                    }
                    let t = now_ms();
                    if t - last_emit >= 33 {
                        last_emit = t;
                        let snap = state.read();
                        sink.emit_state(&snap);
                    }
                }
            }));
        }

        // ── estop: 무손실 버스 수신 → UDP ×3연발 + SSH touch ───────────────────
        {
            let udp = udp.clone();
            let ssh_es = ssh.clone();
            let stop = stop.clone();
            let state = state.clone();
            threads.push(spawn_named("estop", move || loop {
                match bus_rx.recv_timeout(Duration::from_millis(100)) {
                    Ok(_ev) => {
                        if stop.load(Ordering::Relaxed) {
                            break; // 정상 종료 중 — 발화 억제(클린 disconnect 가 estop 아님).
                        }
                        // §G.2: 0/50/100ms ×3 UDP + SSH touch(병행 경로).
                        let es = Instant::now();
                        for off in ESTOP_BURST_OFFSETS_MS {
                            if let Some(w) = (es + Duration::from_millis(off))
                                .checked_duration_since(Instant::now())
                            {
                                thread::sleep(w);
                            }
                            let _ = udp.send_estop(now_ms());
                        }
                        if let Some(c) = &ssh_es {
                            let _ = c.touch_estop();
                        }
                        state.write(|s| s.safety.estop_latched = true);
                    }
                    Err(RecvTimeoutError::Timeout) => {
                        if stop.load(Ordering::Relaxed) {
                            break;
                        }
                    }
                    Err(RecvTimeoutError::Disconnected) => break,
                }
            }));
        }

        // ── supervisor: 100ms 패드 단절·TX 하트비트 침묵 감시 ──────────────────
        {
            let input = input.clone();
            let hb = heartbeat.clone();
            let bus = bus.clone();
            let stop = stop.clone();
            threads.push(spawn_named("supervisor", move || {
                let mut pad = PadWatch::new();
                while !stop.load(Ordering::Relaxed) {
                    let t = now_ms();
                    let frame = input.latest();
                    if pad.observe(frame.connected) {
                        bus.fire(EstopCause::PadLost, t);
                    }
                    if !stop.load(Ordering::Relaxed) && hb.stalled(t) {
                        bus.fire(EstopCause::TxStall, t);
                    }
                    thread::sleep(Duration::from_millis(100));
                }
            }));
        }

        Ok(Runtime {
            stop,
            threads,
            input,
            state,
            ssh,
        })
    }

    /// StateHub 핸들(표시계층·셀프체크가 스냅샷 읽기).
    pub fn state(&self) -> Arc<StateHub> {
        self.state.clone()
    }

    /// 정지 + 스레드 합류 + 핸드셰이크 철회(§7-7 MUST: 스테일 토큰 금지).
    pub fn shutdown(mut self) {
        self.stop.store(true, Ordering::Relaxed);
        for h in self.threads.drain(..) {
            let _ = h.join();
        }
        if let Some(c) = &self.ssh {
            let _ = c.retract_handshake();
        }
        // self.input(Arc<InputService>) 가 여기서 드롭 → gilrs 폴링 스레드 정지·합류.
    }
}

fn spawn_named(name: &str, f: impl FnOnce() + Send + 'static) -> JoinHandle<()> {
    thread::Builder::new()
        .name(name.into())
        .spawn(f)
        .expect("스레드 생성 실패")
}
