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

use std::collections::HashMap;
use std::io;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
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

/// ssh-session 워커로 보내는 블로킹 SSH 부수효과 작업. 제어 TX·E-STOP 스레드는 이걸
/// 채널로 비차단 송신만 하고, 워커가 자기 속도로 실행한다 — 핫패스가 SSH 지연에 막히지
/// 않게(워치독 오발 E-STOP·정지 버스트 직렬 지연 방지).
enum SshJob {
    /// 폴백 명령 파일 기록(5Hz). 워커가 버스트를 최신승으로 합쳐 스테일 프레임은 버린다.
    Cmd(String),
    /// 복구 — 로봇 estop flag 제거(rm).
    Recover,
    /// E-STOP 병행 경로 — `touch /tmp/df-walklab-estop`(빠른 UDP 버스트와 별개로).
    EstopTouch,
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
    estop: EstopBus,
    /// 외부 버튼 에지 주입단(콕핏 터치 ARM/복구/E-STOP). control-tx 가 게임패드 edge_rx
    /// 와 함께 매 틱 드레인·OR 한다 — 게이트엔 추가 발원일 뿐(안전 모델 불변).
    inject: Sender<ButtonEdges>,
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

        // 외부 버튼 에지 주입(콕핏 터치 ARM/복구/E-STOP) — control-tx 가 단일 소비하며
        // 게임패드 edge_rx 와 함께 OR 한다. inject_tx 는 Runtime 핸들이 보관.
        let (inject_tx, inject_rx) = std::sync::mpsc::channel::<ButtonEdges>();

        let (bus, bus_rx) = EstopBus::channel();
        let heartbeat = Heartbeat::new();
        let last_ack = Arc::new(AtomicI64::new(0));
        // seq → 로컬 송신 시각(ms). RTT = ACK 수신 - 이 송신시각(같은 단조 시계).
        // 로봇의 t_rx(CLOCK_REALTIME epoch ms)는 시계 도메인이 달라 빼면 garbage → 무시.
        let sent_at: Arc<Mutex<HashMap<i64, i64>>> = Arc::new(Mutex::new(HashMap::new()));
        let mut threads: Vec<JoinHandle<()>> = Vec::new();

        // ── ssh-session: 블로킹 SSH 부수효과(폴백 cmd 파일·복구 rm·estop touch)를 제어
        //    스레드 밖에서 처리. 제어 TX 의 20Hz 하트비트와 E-STOP 의 빠른 UDP 버스트가
        //    SSH 지연(무선 OpenSSH 5.9, ControlMaster off)에 막히지 않게 한다 — 안 그러면
        //    느린 SSH 가 하트비트를 정체시켜 수퍼바이저가 오발 TxStall E-STOP 을 던지거나
        //    후속 정지 버스트를 직렬 지연시킨다. Robot 만 기동. §2 "SSH 세션 스레드".
        let ssh_jobs: Option<Sender<SshJob>> = if let Some(c) = &ssh {
            let (job_tx, job_rx) = std::sync::mpsc::channel::<SshJob>();
            let worker_ssh = c.clone();
            let worker_stop = stop.clone();
            threads.push(spawn_named("ssh-session", move || {
                ssh_worker(worker_ssh, job_rx, worker_stop)
            }));
            Some(job_tx)
        } else {
            None
        };

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
            let sent_at = sent_at.clone();
            let ssh_jobs = ssh_jobs.clone();
            let sink = sink.clone();
            let tick = cfg.tick;
            threads.push(spawn_named("control-tx", move || {
                let mut pipe = TxPipeline::new();
                // seq base = epoch ms — 로봇 m_cmd_slot 누적(새 세션 미리셋) 우회(ally-cli
                // connect 와 동일 근거·실기 확인). 데드라인 틱은 seq 와 분리(epoch base 라
                // `tick*(seq as u32)` 가 wrap 돼 장시간 sleep 으로 행되는 것 방지).
                let mut seq: u64 = session_seq_base();
                let mut tick_n: u32 = 0;
                let start = Instant::now();
                while !stop.load(Ordering::Relaxed) {
                    let t = now_ms();
                    seq += 1;
                    tick_n += 1;
                    let deadline = start + tick * tick_n;

                    // 이번 틱 버튼 에지 누적(OR) — 게임패드 + 외부 주입(콕핏 터치).
                    let mut e = ButtonEdges::default();
                    while let Ok(be) = edge_rx.try_recv() {
                        e.arm |= be.arm;
                        e.estop |= be.estop;
                        e.recover |= be.recover;
                    }
                    while let Ok(be) = inject_rx.try_recv() {
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
                            if udp.send_cmd(seq, &out.line).is_ok() {
                                // RTT 산출용 로컬 송신시각 기록(seq별). 유실 ACK 누적 방지로
                                // 256 초과 시 오래된 seq 정리.
                                if let Ok(mut m) = sent_at.lock() {
                                    m.insert(seq as i64, t);
                                    if m.len() > 256 {
                                        let cut = seq as i64 - 256;
                                        m.retain(|&k, _| k >= cut);
                                    }
                                }
                            }
                        }
                        Transport::SshFile => {
                            // 비차단 위임 — 워커가 최신승으로 5Hz 기록(블로킹은 워커에서).
                            if let (Some(j), true) = (&ssh_jobs, seq.is_multiple_of(4)) {
                                let _ = j.send(SshJob::Cmd(out.line.clone()));
                            }
                        }
                    }
                    hb.beat(t);

                    // 복구 발화 → 로봇 estop flag 제거(rm) — 비차단 위임(블로킹 SSH 가
                    // 하트비트를 막아 오발 TxStall 로 복구를 되-래치시키지 않게).
                    if out.events.fire_recover {
                        if let Some(j) = &ssh_jobs {
                            let _ = j.send(SshJob::Recover);
                        }
                    }

                    state.write(|s| {
                        s.cmd.x = out.cmd.stride_mm;
                        s.cmd.y = out.cmd.side_mm;
                        s.cmd.a = out.cmd.turn_deg;
                        s.cmd.head_pan = out.cmd.head_pan_deg;
                        s.cmd.head_tilt = out.cmd.head_tilt_deg;
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
            let sent_at = sent_at.clone();
            let sink = sink.clone();
            threads.push(spawn_named("udp-rx", move || {
                let mut rtt = RttEma::new();
                let mut eff = EffHz::new();
                let mut last_emit = 0i64;
                while !stop.load(Ordering::Relaxed) {
                    match udp.recv() {
                        Ok(Some(Inbound::Ack { seq, .. })) => {
                            let t = now_ms();
                            // RTT = 수신 - 로컬 송신시각(같은 단조 시계). 로봇 t_rx 무시.
                            if let Some(s) = sent_at.lock().ok().and_then(|mut m| m.remove(&seq)) {
                                rtt.update((t - s).max(0) as f64);
                            }
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

        // ── estop: 무손실 버스 수신 → UDP ×3연발(빠른 경로) + SSH touch 위임 ─────
        {
            let udp = udp.clone();
            let ssh_jobs = ssh_jobs.clone();
            let stop = stop.clone();
            let state = state.clone();
            threads.push(spawn_named("estop", move || loop {
                match bus_rx.recv_timeout(Duration::from_millis(100)) {
                    Ok(_ev) => {
                        // 큐에 실린 건 전부 진짜 estop 이다 — 발원은 물리 B(estop-fwd)·
                        // 패드단절·TX행(supervisor)뿐이고 클린 disconnect 는 버스에 안
                        // 실린다. 그러니 종료 중이라도 대기 중 estop 은 발화한다(비유실).
                        // §G.2: 0/50/100ms ×3 UDP(빠른 경로). SSH touch 는 ssh-session
                        // 워커로 위임 — 직렬 블로킹이 후속 정지 버스트를 지연시키지 않게.
                        let es = Instant::now();
                        for off in ESTOP_BURST_OFFSETS_MS {
                            if let Some(w) = (es + Duration::from_millis(off))
                                .checked_duration_since(Instant::now())
                            {
                                thread::sleep(w);
                            }
                            let _ = udp.send_estop(now_ms());
                        }
                        if let Some(j) = &ssh_jobs {
                            let _ = j.send(SshJob::EstopTouch);
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
            estop: bus,
            inject: inject_tx,
        })
    }

    /// StateHub 핸들(표시계층·셀프체크가 스냅샷 읽기).
    pub fn state(&self) -> Arc<StateHub> {
        self.state.clone()
    }

    /// E-STOP 버스 핸들 — 터치 E-STOP(보조 경로, §3) 등 외부 발원이 합류한다.
    pub fn estop_handle(&self) -> EstopBus {
        self.estop.clone()
    }

    /// 외부 버튼 에지 주입단(콕핏 터치 ARM/복구/E-STOP). 반환한 `Sender` 로 보낸
    /// `ButtonEdges` 는 control-tx 가 게임패드 에지와 함께 게이트에 OR 한다 — 추가 발원일
    /// 뿐 안전 모델 불변(E-STOP 의 빠른 UDP 버스트는 별도 `estop_handle` 경로가 담당).
    pub fn edge_injector(&self) -> Sender<ButtonEdges> {
        self.inject.clone()
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

/// 세션 시작 seq base — 벽시계 epoch ms. 로봇 WalkLabBrokerage::m_cmd_slot 이 새 토큰/
/// transport 에도 리셋되지 않아 seq 0 재시작 시 누적 slot 이하로 거부되는 펌웨어 버그
/// 대응(ally-cli `session_seq_base` 와 동일·실기 확인 2026-06-13). loopback 셀프체크는
/// 매번 새 에코로봇(slot 없음)이라 무해.
fn session_seq_base() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(1, |d| d.as_millis() as u64)
}

/// ssh-session 워커 — 블로킹 SSH 부수효과를 제어/E-STOP 스레드 밖에서 실행한다.
/// 한 번에 대기 중 job 을 모아(버스트 합치기) **최신 Cmd 만** 기록하고(스테일 폴백
/// 프레임은 버림·큐 무한 증가 방지), EstopTouch/Recover 는 안전 우선순위로 실행한다.
/// stop 플래그로 종료(센서 채널 Disconnected 도 종료). SSH 가 수 초 막혀도 제어·정지
/// 핫패스는 영향 없다 — 이 워커만 느려질 뿐.
fn ssh_worker(ssh: Arc<SshClient>, rx: Receiver<SshJob>, stop: Arc<AtomicBool>) {
    while !stop.load(Ordering::Relaxed) {
        let first = match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(j) => j,
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => break,
        };
        // 대기 중 job 합치기: 최신 Cmd 만 남기고 touch/recover 는 OR.
        let mut jobs = vec![first];
        while let Ok(j) = rx.try_recv() {
            jobs.push(j);
        }
        let mut latest_cmd: Option<String> = None;
        let mut recover = false;
        let mut touch = false;
        for j in jobs {
            match j {
                SshJob::Cmd(l) => latest_cmd = Some(l),
                SshJob::Recover => recover = true,
                SshJob::EstopTouch => touch = true,
            }
        }
        // 안전 우선: touch → recover → 최신 cmd.
        if touch {
            let _ = ssh.touch_estop();
        }
        if recover {
            let _ = ssh.run(&format!("rm -f {ESTOP_PATH}"));
        }
        if let Some(l) = latest_cmd {
            let _ = ssh.write_cmd_file(&l);
        }
    }
}
