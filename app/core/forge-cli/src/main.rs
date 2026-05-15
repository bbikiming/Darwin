//! `forge` — DarwinForge headless CLI.
//!
//! Sprint 1: ping/scan 실 작동.

mod motion_play;
mod synth;

use std::time::Duration;

use clap::{Parser, Subcommand};
use forge_core::control::JointController;
use forge_core::controller::CmController;
use forge_core::dynamixel::Bus;
use forge_core::joint::{JointId, JointState};
use forge_core::motion::{parse_mtn, write_mtn, Motion};
use forge_core::serial::{PosixSerial, TcpBus};
use forge_core::strategy::{StrategyInput, StrategyState};
use forge_core::vision::{detect_blob, BlobResult, Frame, HsvRange, Pixel};
use forge_core::walk::{WalkCommand, WalkEngine};

/// USB 또는 TCP backend wrapping enum — 모든 명령 핸들러가 endpoint 무관하게 동작.
enum AnyBus {
    Posix(Bus<PosixSerial>),
    Tcp(Bus<TcpBus>),
}

impl AnyBus {
    /// `--port` 또는 `--remote` 중 하나를 받아 적절한 Bus 생성.
    fn open(
        port: Option<&str>,
        remote: Option<&str>,
        baud: u32,
        timeout_ms: u64,
    ) -> anyhow::Result<Self> {
        match (port, remote) {
            (_, Some(addr)) => {
                let tcp = TcpBus::connect(addr, Duration::from_millis(3000))
                    .map_err(|e| anyhow::anyhow!("TCP connect {}: {}", addr, e))?;
                let bus = Bus::new(tcp).with_timeout(Duration::from_millis(timeout_ms));
                Ok(AnyBus::Tcp(bus))
            }
            (Some(p), None) => {
                let posix = PosixSerial::open(p, baud)
                    .map_err(|e| anyhow::anyhow!("USB open {}: {}", p, e))?;
                let bus = Bus::new(posix).with_timeout(Duration::from_millis(timeout_ms));
                Ok(AnyBus::Posix(bus))
            }
            (None, None) => {
                anyhow::bail!("--port (USB) 또는 --remote (host:port) 중 하나가 필요해요")
            }
        }
    }

    fn ping(&mut self, id: u8) -> Result<forge_core::dynamixel::StatusPacket, forge_core::Error> {
        match self {
            AnyBus::Posix(b) => b.ping(id),
            AnyBus::Tcp(b) => b.ping(id),
        }
    }

    fn scan(&mut self, range: std::ops::RangeInclusive<u8>) -> Vec<u8> {
        match self {
            AnyBus::Posix(b) => b.scan(range),
            AnyBus::Tcp(b) => b.scan(range),
        }
    }

    fn board_snapshot(
        &mut self,
    ) -> Result<forge_core::controller::cm::BoardSnapshot, forge_core::Error> {
        match self {
            AnyBus::Posix(b) => CmController::new(b).snapshot(),
            AnyBus::Tcp(b) => CmController::new(b).snapshot(),
        }
    }

    fn joint_set_position(
        &mut self,
        joint: JointId,
        position: u16,
    ) -> Result<u16, forge_core::Error> {
        match self {
            AnyBus::Posix(b) => JointController::new(b).set_position(joint, position),
            AnyBus::Tcp(b) => JointController::new(b).set_position(joint, position),
        }
    }

    fn joint_read_state(&mut self, joint: JointId) -> Result<JointState, forge_core::Error> {
        match self {
            AnyBus::Posix(b) => JointController::new(b).read_state(joint),
            AnyBus::Tcp(b) => JointController::new(b).read_state(joint),
        }
    }

    fn joint_set_torque(&mut self, joint: JointId, on: bool) -> Result<(), forge_core::Error> {
        match self {
            AnyBus::Posix(b) => JointController::new(b).set_torque(joint, on),
            AnyBus::Tcp(b) => JointController::new(b).set_torque(joint, on),
        }
    }

    fn joint_set_torque_many(
        &mut self,
        joints: &[JointId],
        on: bool,
    ) -> Result<(), forge_core::Error> {
        match self {
            AnyBus::Posix(b) => JointController::new(b).set_torque_many(joints, on),
            AnyBus::Tcp(b) => JointController::new(b).set_torque_many(joints, on),
        }
    }

    fn emergency_stop(&mut self) -> Result<(), forge_core::Error> {
        match self {
            AnyBus::Posix(b) => JointController::new(b).emergency_stop(),
            AnyBus::Tcp(b) => JointController::new(b).emergency_stop(),
        }
    }
}

#[derive(Parser, Debug)]
#[command(
    name = "forge",
    version,
    about = "DarwinForge CLI for ROBOTIS DARwIn-OP / OP2"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// 사용 가능한 USB 직렬 포트 나열.
    Ports,

    /// 컨트롤러 또는 모터 ID에 PING 인스트럭션 전송.
    Ping {
        /// USB 직렬 포트 경로 (예: /dev/cu.usbserial-A1B2). `--remote`와 양자택일.
        #[arg(short, long)]
        port: Option<String>,
        /// 원격 forge serve 주소 (예: `10.0.0.42:5530` 또는 `op2.local:5530`).
        #[arg(short = 'r', long)]
        remote: Option<String>,
        /// 대상 ID (기본: 200 = 컨트롤러).
        #[arg(short, long, default_value_t = 200)]
        id: u8,
        /// baud rate (USB 시 적용).
        #[arg(short, long, default_value_t = 1_000_000)]
        baud: u32,
        /// 응답 timeout (ms).
        #[arg(short, long, default_value_t = 200)]
        timeout: u64,
    },

    /// 모터 ID 범위 스캔.
    Scan {
        /// USB 직렬 포트.
        #[arg(short, long)]
        port: Option<String>,
        /// 원격 forge serve 주소.
        #[arg(short = 'r', long)]
        remote: Option<String>,
        /// 스캔 범위.
        #[arg(short, long, default_value = "1-20")]
        range: String,
        #[arg(short, long, default_value_t = 1_000_000)]
        baud: u32,
        #[arg(short, long, default_value_t = 50)]
        timeout: u64,
    },

    /// CM-730/CM-740 보드 상태.
    Board {
        #[arg(short, long)]
        port: Option<String>,
        #[arg(short = 'r', long)]
        remote: Option<String>,
        #[arg(short, long, default_value_t = 1_000_000)]
        baud: u32,
        #[arg(short, long, default_value_t = 200)]
        timeout: u64,
    },

    /// 캐논 20-DOF 관절 매핑 표 출력.
    ListJoints,

    /// 관절 제어 (set/state/torque/estop).
    Joint {
        #[command(subcommand)]
        action: JointAction,
    },

    /// 모션 import/export (.mtn ↔ JSON).
    Motion {
        #[command(subcommand)]
        action: MotionAction,
    },

    /// 워크 엔진 시뮬레이션 (실기기 명령 X — Mac에서 향후 활성화).
    Walk {
        /// 전후 보폭 (m / cycle).
        #[arg(short, long, default_value_t = 0.0)]
        x: f64,
        /// 좌우 보폭 (m / cycle).
        #[arg(short, long, default_value_t = 0.0)]
        y: f64,
        /// 회전 (rad / cycle).
        #[arg(short, long, default_value_t = 0.0)]
        a: f64,
        /// 시뮬레이션 사이클 수.
        #[arg(short, long, default_value_t = 1)]
        cycles: u32,
    },

    /// 전략 FSM 한 사이클 시뮬레이션 (가짜 frame).
    Strategy {
        /// "found" | "none".
        #[arg(short, long, default_value = "found")]
        ball: String,
    },

    /// USB ↔ TCP 양방향 브리지 데몬.
    Serve {
        #[arg(short, long)]
        port: String,
        #[arg(short, long, default_value = "0.0.0.0:5530")]
        bind: String,
        #[arg(long, default_value_t = 1_000_000)]
        baud: u32,
        #[arg(long, default_value_t = 30)]
        usb_timeout: u64,
        #[arg(long, default_value_t = 1)]
        max_connections: u32,
        /// 같은 네트워크에 mDNS / Bonjour로 자동 광고 (`_forge._tcp`).
        /// 인자는 service 이름 (예: "OP2-A1"). 클라이언트 측 자동 검색 가능.
        #[arg(long)]
        advertise: Option<String>,
    },

    /// 첫 연결 진단 — CM 보드 + 모터 ID sweep + JointMap 자동 감지.
    ///
    /// CM 모델 번호로 OP1 / OP2 판별 + ID 1..=20 sweep 으로 누락 모터 보고 +
    /// 공식 매핑 vs LegacyOp1 fallback 자동 선택. 모터 명령은 발행 안 함.
    Connect {
        /// 직렬 포트.
        #[arg(short, long)]
        port: String,
        /// baud rate.
        #[arg(short, long, default_value_t = 1_000_000)]
        baud: u32,
        /// 각 PING 의 timeout (ms).
        #[arg(short, long, default_value_t = 50)]
        timeout: u64,
    },

    /// 공식 walkReady 자세로 안전하게 이동 — 토크 ramp + 자세 보간.
    ///
    /// `ini_pose.yaml` 의 공식 20관절 자세를 부드럽게 적용. 토크는 P_GAIN
    /// 0→8→16→32 4단계 ramp로 깨워 "둠칫" 현상 방지. `--dry-run` 으로 실
    /// 명령 발사 없이 발사될 SYNC_WRITE 시퀀스만 출력 가능.
    WalkReady {
        /// 직렬 포트 (예: /dev/cu.usbserial-A1B2).
        #[arg(short, long)]
        port: String,
        /// baud rate.
        #[arg(short, long, default_value_t = 1_000_000)]
        baud: u32,
        /// 자세 보간 step 수 (mov_time = step × period). 기본 60 step ≈ 480 ms.
        #[arg(long, default_value_t = 60)]
        interp_steps: u32,
        /// step 사이 period (ms).
        #[arg(long, default_value_t = 8)]
        step_period_ms: u32,
        /// 명령 발사 없이 시퀀스만 stdout으로 출력.
        #[arg(long)]
        dry_run: bool,
        /// 매핑 종류 — "official" (기본) 또는 "legacy-op1".
        #[arg(long, default_value = "official")]
        joint_map: String,
    },

    /// Motion Synthesis — `library`, `sequence`, `layer`, `morph`, `mutate`,
    /// `mirror`, `procedural`, `validate`, `commit`, `simulate`. (Sprint 10)
    Synth {
        #[command(subcommand)]
        action: synth::SynthCmd,
    },
}

#[derive(Subcommand, Debug)]
enum MotionAction {
    /// `.mtn` → `.json` 변환.
    Import {
        /// 입력 .mtn 경로.
        input: std::path::PathBuf,
        /// 출력 .json 경로.
        #[arg(short, long)]
        output: Option<std::path::PathBuf>,
        /// 대상 로봇 generation (op | op2).
        #[arg(short, long, default_value = "op2")]
        generation: String,
    },
    /// `.json` → `.mtn` 변환.
    Export {
        /// 입력 .json 경로.
        input: std::path::PathBuf,
        /// 출력 .mtn 경로.
        #[arg(short, long)]
        output: Option<std::path::PathBuf>,
    },
    /// `.mtn` 또는 `.json`을 읽어 페이지 요약만 출력.
    Inspect {
        /// 입력 파일.
        input: std::path::PathBuf,
    },
    /// **Sprint 13** — 모션 페이지를 실 robot 에 송출 (기본 dry-run).
    ///
    /// `--from-json <path>` 또는 `--slot <n>` 으로 페이지 source 지정.
    /// 기본은 `--dry-run` (패킷 출력만). 실 송출은 `--engage` 명시 필요.
    /// HARDWARE_VERIFICATION_PROTOCOL.md G3 단계 — 사용자 사전점검 필수.
    Play(motion_play::PlayArgs),
    /// 공식 ROBOTIS-OP2 카탈로그 (16개 모션 + 안전 분류) 표시.
    ///
    /// `motion_4096.bin` + `gui_motion.yaml` 기반 — Safe / Caution / HighRisk.
    Catalog {
        /// `motion_4096.bin` 경로 (기본: research/robotis-official/ 내).
        #[arg(short, long)]
        bin: Option<std::path::PathBuf>,
    },
}

#[derive(Subcommand, Debug)]
enum JointAction {
    /// 한 관절의 goal position 설정.
    Set {
        #[arg(short, long)]
        port: Option<String>,
        #[arg(short = 'r', long)]
        remote: Option<String>,
        #[arg(short, long)]
        id: u8,
        position: u16,
        #[arg(long, default_value_t = 1_000_000)]
        baud: u32,
    },
    /// 한 관절의 현재 상태 출력.
    State {
        #[arg(short, long)]
        port: Option<String>,
        #[arg(short = 'r', long)]
        remote: Option<String>,
        #[arg(short, long)]
        id: u8,
        #[arg(long, default_value_t = 1_000_000)]
        baud: u32,
    },
    /// 한 관절 또는 전체 관절의 토크 enable/disable.
    Torque {
        #[arg(short, long)]
        port: Option<String>,
        #[arg(short = 'r', long)]
        remote: Option<String>,
        /// "all" 또는 ID 숫자.
        #[arg(short, long)]
        target: String,
        /// "on" 또는 "off".
        #[arg(short = 'e', long)]
        enable: String,
        #[arg(long, default_value_t = 1_000_000)]
        baud: u32,
    },
    /// 비상 정지 — 모든 관절 토크 OFF.
    Estop {
        #[arg(short, long)]
        port: Option<String>,
        #[arg(short = 'r', long)]
        remote: Option<String>,
        #[arg(long, default_value_t = 1_000_000)]
        baud: u32,
    },
}

fn parse_range(s: &str) -> anyhow::Result<std::ops::RangeInclusive<u8>> {
    let parts: Vec<&str> = s.split('-').collect();
    if parts.len() != 2 {
        anyhow::bail!("range는 'A-B' 형식: {}", s);
    }
    let a: u8 = parts[0].parse()?;
    let b: u8 = parts[1].parse()?;
    Ok(a..=b)
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let cli = Cli::parse();
    match cli.command {
        Command::Ports => {
            let ports =
                PosixSerial::list_ports().map_err(|e| anyhow::anyhow!("list_ports: {}", e))?;
            if ports.is_empty() {
                println!("(USB 직렬 포트 없음 — 케이블 또는 전원 확인)");
            } else {
                for p in ports {
                    println!("{}", p);
                }
            }
        }

        Command::Ping {
            port,
            remote,
            id,
            baud,
            timeout,
        } => {
            let mut bus = AnyBus::open(port.as_deref(), remote.as_deref(), baud, timeout)?;
            match bus.ping(id) {
                Ok(s) => println!(
                    "PING ID {} OK (error_byte=0x{:02X}, params={:?})",
                    s.id, s.error.0, s.parameters
                ),
                Err(e) => {
                    println!("PING ID {} FAIL: {}", id, e);
                    std::process::exit(1);
                }
            }
        }

        Command::Scan {
            port,
            remote,
            range,
            baud,
            timeout,
        } => {
            let r = parse_range(&range)?;
            let mut bus = AnyBus::open(port.as_deref(), remote.as_deref(), baud, timeout)?;
            let found = bus.scan(r);
            if found.is_empty() {
                println!("(범위 내 응답한 ID 없음)");
            } else {
                println!(
                    "응답한 ID: {}",
                    found
                        .iter()
                        .map(u8::to_string)
                        .collect::<Vec<_>>()
                        .join(", ")
                );
                println!("총 {}개", found.len());
            }
        }

        Command::Board {
            port,
            remote,
            baud,
            timeout,
        } => {
            let mut bus = AnyBus::open(port.as_deref(), remote.as_deref(), baud, timeout)?;
            let snap = bus.board_snapshot()?;
            println!("== CM Board 상태 ==");
            println!("  Model    : {}", snap.model_number);
            println!("  Version  : {}", snap.version);
            println!(
                "  Voltage  : {:.1} V (raw {})",
                snap.voltage_volts(),
                snap.voltage_raw
            );
            println!("  Button   : 0x{:02X}", snap.button);
            if snap.voltage_volts() < 9.5 {
                println!("  ⚠️  배터리 전압 낮음 (9.5 V 이하). 충전 권장.");
            }
        }

        Command::ListJoints => {
            println!("ID\tName\t\t\tBody Part");
            println!("--\t----\t\t\t---------");
            for j in JointId::ALL {
                println!("{}\t{:?}\t\t{:?}", j as u8, j, j.body_part());
            }
        }

        Command::Joint { action } => handle_joint(action)?,

        Command::Motion { action } => handle_motion(action)?,

        Command::Walk { x, y, a, cycles } => handle_walk(x, y, a, cycles)?,

        Command::Strategy { ball } => handle_strategy(&ball)?,

        Command::Serve {
            port,
            bind,
            baud,
            usb_timeout,
            max_connections,
            advertise,
        } => handle_serve(
            &port,
            &bind,
            baud,
            usb_timeout,
            max_connections,
            advertise.as_deref(),
        )?,

        Command::Connect {
            port,
            baud,
            timeout,
        } => handle_connect(&port, baud, timeout)?,

        Command::WalkReady {
            port,
            baud,
            interp_steps,
            step_period_ms,
            dry_run,
            joint_map,
        } => handle_walk_ready(
            &port,
            baud,
            interp_steps,
            step_period_ms,
            dry_run,
            &joint_map,
        )?,

        Command::Synth { action } => synth::handle(action)?,
    }
    Ok(())
}

fn handle_serve(
    port: &str,
    bind: &str,
    baud: u32,
    usb_timeout_ms: u64,
    max_connections: u32,
    advertise_name: Option<&str>,
) -> anyhow::Result<()> {
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc;
    use std::thread;

    let listener = TcpListener::bind(bind).map_err(|e| anyhow::anyhow!("bind {}: {}", bind, e))?;
    println!(
        "▶ forge serve (USB↔TCP bridge)\n  USB    : {} @ {} baud\n  Listen : {}\n  Max    : {} concurrent",
        port, baud, bind, max_connections
    );

    // Bonjour / mDNS 자동 광고 (선택). 데몬은 함수 끝까지 살아있어야 ServiceInfo가 유지됨.
    let _mdns_keepalive = if let Some(name) = advertise_name {
        match start_mdns_advertise(name, &listener) {
            Ok(d) => {
                println!("  Bonjour: _forge._tcp / {} (자동 광고 활성)", name);
                Some(d)
            }
            Err(e) => {
                eprintln!("  ⚠ mDNS 광고 실패 (계속 진행): {}", e);
                None
            }
        }
    } else {
        None
    };
    println!("  Press Ctrl-C to stop.");
    let active = Arc::new(AtomicU32::new(0));

    for incoming in listener.incoming() {
        let stream = match incoming {
            Ok(s) => s,
            Err(e) => {
                eprintln!("accept error: {}", e);
                continue;
            }
        };
        let peer = stream
            .peer_addr()
            .map(|a| a.to_string())
            .unwrap_or_else(|_| "?".into());

        if active.load(Ordering::SeqCst) >= max_connections {
            eprintln!(
                "[{}] 거부 — 동시 연결 제한 도달 ({} / {})",
                peer,
                active.load(Ordering::SeqCst),
                max_connections
            );
            // 클라이언트가 명확히 알 수 있도록 짧은 메시지 후 종료.
            let _ = stream.shutdown(std::net::Shutdown::Both);
            continue;
        }

        let port = port.to_string();
        let active = Arc::clone(&active);
        thread::spawn(move || {
            active.fetch_add(1, Ordering::SeqCst);
            println!("[{}] 연결 — bridge 시작", peer);
            if let Err(e) = bridge_one_session(&port, baud, usb_timeout_ms, stream) {
                eprintln!("[{}] bridge 종료: {}", peer, e);
            } else {
                println!("[{}] bridge 정상 종료", peer);
            }
            active.fetch_sub(1, Ordering::SeqCst);
        });
    }
    Ok(())
}

/// mDNS / Bonjour `_forge._tcp` advertise. 데몬을 반환 — drop되면 광고 종료.
fn start_mdns_advertise(
    name: &str,
    listener: &std::net::TcpListener,
) -> anyhow::Result<mdns_sd::ServiceDaemon> {
    use mdns_sd::{ServiceDaemon, ServiceInfo};

    let local_addr = listener
        .local_addr()
        .map_err(|e| anyhow::anyhow!("local_addr: {}", e))?;
    let port = local_addr.port();

    let daemon = ServiceDaemon::new().map_err(|e| anyhow::anyhow!("ServiceDaemon::new: {}", e))?;

    let host_name = format!("{}.local.", name);
    let service_type = "_forge._tcp.local.";
    // ip = "" + enable_addr_auto() → 모든 인터페이스 IP를 자동 publish.
    let info = ServiceInfo::new(service_type, name, &host_name, "", port, None)
        .map_err(|e| anyhow::anyhow!("ServiceInfo::new: {}", e))?
        .enable_addr_auto();

    daemon
        .register(info)
        .map_err(|e| anyhow::anyhow!("daemon.register: {}", e))?;
    Ok(daemon)
}

/// USB ↔ TCP 한 세션 양방향 byte pump.
fn bridge_one_session(
    port: &str,
    baud: u32,
    usb_timeout_ms: u64,
    stream: std::net::TcpStream,
) -> anyhow::Result<()> {
    use std::io::{Read, Write};
    use std::thread;

    // 작은 read poll timeout — TCP 측 종료 감지 latency 최소화.
    let serial_read = serialport::new(port, baud)
        .data_bits(serialport::DataBits::Eight)
        .parity(serialport::Parity::None)
        .stop_bits(serialport::StopBits::One)
        .flow_control(serialport::FlowControl::None)
        .timeout(Duration::from_millis(usb_timeout_ms))
        .open()
        .map_err(|e| anyhow::anyhow!("open {}: {}", port, e))?;
    let serial_write = serial_read
        .try_clone()
        .map_err(|e| anyhow::anyhow!("clone serial: {}", e))?;

    let stream_to_serial = stream
        .try_clone()
        .map_err(|e| anyhow::anyhow!("clone tcp: {}", e))?;
    let stream_from_serial = stream;

    // Thread A: serial → stream
    let h_a = thread::spawn(move || -> std::io::Result<()> {
        let mut serial = serial_read;
        let mut sink = stream_from_serial;
        let mut buf = [0u8; 1024];
        loop {
            match serial.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => sink.write_all(&buf[..n])?,
                Err(e) if e.kind() == std::io::ErrorKind::TimedOut => continue,
                Err(e) => return Err(e),
            }
        }
        Ok(())
    });

    // Thread B: stream → serial (현재 thread)
    let mut source = stream_to_serial;
    let mut sink = serial_write;
    let mut buf = [0u8; 1024];
    let result = loop {
        match source.read(&mut buf) {
            Ok(0) => break Ok(()),
            Ok(n) => {
                if let Err(e) = sink.write_all(&buf[..n]) {
                    break Err(e);
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => continue,
            Err(e) => break Err(e),
        }
    };

    // 한쪽 종료 시 다른 쪽도 닫고 thread join.
    let _ = source.shutdown(std::net::Shutdown::Both);
    let _ = h_a.join();
    result.map_err(|e| anyhow::anyhow!("stream→serial: {}", e))?;
    Ok(())
}

fn handle_strategy(ball_arg: &str) -> anyhow::Result<()> {
    // 가짜 frame
    let frame = if ball_arg == "found" {
        let mut f = Frame::solid(64, 48, Pixel::rgb(0, 0, 0));
        // 큰 주황 영역 (충분히 가까이 보이는 공)
        for y in 10..38 {
            for x in 20..60 {
                f.set_pixel(x, y, Pixel::rgb(255, 100, 0));
            }
        }
        f
    } else {
        Frame::solid(64, 48, Pixel::rgb(0, 0, 0))
    };

    let ball = detect_blob(&frame, HsvRange::ROBOCUP_BALL);
    println!("== Strategy FSM 시뮬레이션 ==");
    println!(
        "  ball: pixel_count={}  centroid=({:.1},{:.1})",
        ball.pixel_count, ball.centroid_x, ball.centroid_y
    );

    let mut state = StrategyState::Idle;
    for step in 0..6 {
        let input = StrategyInput {
            ball: if step == 0 { BlobResult::NONE } else { ball },
            since_kick_ms: if matches!(state, StrategyState::Cooldown) {
                2000
            } else {
                0
            },
            abort: false,
        };
        let next = state.next(input);
        println!("  step {}  {:20} → {}", step, state.label(), next.label());
        state = next;
    }
    Ok(())
}

fn handle_walk(x: f64, y: f64, a: f64, cycles: u32) -> anyhow::Result<()> {
    let mut e = WalkEngine::new();
    e.command = WalkCommand {
        x_amplitude: x,
        y_amplitude: y,
        a_amplitude: a,
        enabled: true,
    };
    let dt = Duration::from_millis(100);
    println!("== walk 시뮬레이션 (실기기 명령 안 보냄) ==");
    println!("  command: x={} y={} a={} (m/cycle, rad/cycle)", x, y, a);
    println!(
        "  period: {} ms, cycles: {}",
        e.params.period_time_ms, cycles
    );
    println!("  tick   phase    left(x,y,z)            right(x,y,z)");
    let total_ticks = (e.params.period_time_ms / 100.0).ceil() as u32 * cycles;
    for tick in 0..total_ticks {
        let f = e.foot_targets();
        if tick % 2 == 0 {
            println!(
                "  {:4}  {:?}  ({:+.3} {:+.3} {:+.3})  ({:+.3} {:+.3} {:+.3})",
                tick,
                e.phase(),
                f.left[0],
                f.left[1],
                f.left[2],
                f.right[0],
                f.right[1],
                f.right[2]
            );
        }
        e.tick(dt);
    }
    Ok(())
}

fn handle_motion(action: MotionAction) -> anyhow::Result<()> {
    use std::fs;
    match action {
        MotionAction::Import {
            input,
            output,
            generation,
        } => {
            let text = fs::read_to_string(&input)?;
            let mut motion = parse_mtn(&text)?;
            motion.robot_generation = generation;
            let json = motion.to_json_pretty()?;
            let out_path = output.unwrap_or_else(|| input.with_extension("json"));
            fs::write(&out_path, json)?;
            println!(
                "imported {} → {} ({} pages)",
                input.display(),
                out_path.display(),
                motion.pages.len()
            );
        }
        MotionAction::Export { input, output } => {
            let text = fs::read_to_string(&input)?;
            let motion = Motion::from_json(&text)?;
            let mtn = write_mtn(&motion);
            let out_path = output.unwrap_or_else(|| input.with_extension("mtn"));
            fs::write(&out_path, mtn)?;
            println!(
                "exported {} → {} ({} pages)",
                input.display(),
                out_path.display(),
                motion.pages.len()
            );
        }
        MotionAction::Inspect { input } => {
            let text = fs::read_to_string(&input)?;
            let motion = if input.extension().and_then(|e| e.to_str()) == Some("json") {
                Motion::from_json(&text)?
            } else {
                parse_mtn(&text)?
            };
            println!("== {} ==", input.display());
            println!("  version            : {}", motion.version);
            println!("  robot_generation   : {}", motion.robot_generation);
            println!("  pages              : {}", motion.pages.len());
            println!("---");
            for p in &motion.pages {
                println!(
                    "  page id={:3} name={:20} steps={} next={} exit={} repeat={} speed={} safety={:?}",
                    p.id,
                    p.name,
                    p.steps.len(),
                    p.next_page,
                    p.exit_page,
                    p.repeat,
                    p.speed,
                    p.safety_class,
                );
            }
        }
        MotionAction::Play(args) => motion_play::handle(args)?,
        MotionAction::Catalog { bin } => {
            use forge_core::motion::library::OFFICIAL_CATALOG;
            use forge_core::motion::{parse_bin4096, Library, SafetyClass};

            let bin_path = bin.unwrap_or_else(|| {
                std::path::PathBuf::from(
                    "research/robotis-official/ROBOTIS-OP2/op2_manager/config/motion_4096.bin",
                )
            });
            println!("== ROBOTIS-OP2 공식 모션 카탈로그 ==");
            println!("  출처   : {}", bin_path.display());
            println!("  참조   : gui_motion.yaml + motion_4096.bin (Apache 2.0)\n");

            let safe_label = |c: &SafetyClass| match c {
                SafetyClass::Safe => "Safe     ",
                SafetyClass::Caution => "Caution  ",
                SafetyClass::HighRisk => "HighRisk ",
            };

            println!("   ID  Name            Safety");
            println!("   --  ----            ------");
            for entry in OFFICIAL_CATALOG {
                println!(
                    "  {:>3}  {:<14}  {}",
                    entry.id,
                    entry.display_name,
                    safe_label(&entry.safety),
                );
            }

            // bin 이 있으면 매칭 검증.
            if let Ok(bytes) = std::fs::read(&bin_path) {
                if let Ok(raw_pages) = parse_bin4096(&bytes) {
                    let lib = Library::with_official_catalog(&raw_pages);
                    println!(
                        "\n  ✓ {} 페이지가 motion_4096.bin 에서 import 됨",
                        lib.len()
                    );
                } else {
                    println!("\n  ⚠️  motion_4096.bin 파싱 실패 — 카탈로그 ID 표시만 제공");
                }
            } else {
                println!(
                    "\n  ℹ  motion_4096.bin 미발견 (--bin 으로 경로 지정) — 카탈로그 ID 표시만"
                );
            }

            println!("\n실행 가이드:");
            println!("  Safe     : 평지에서 안전 실행 가능.");
            println!("  Caution  : 평지·관찰 환경에서만 (Get up 류).");
            println!("  HighRisk : 사용자 confirmation 필수 (Kick/Hand Standing).");
        }
    }
    Ok(())
}

fn handle_joint(action: JointAction) -> anyhow::Result<()> {
    match action {
        JointAction::Set {
            port,
            remote,
            id,
            position,
            baud,
        } => {
            let joint = JointId::from_byte(id)
                .ok_or_else(|| anyhow::anyhow!("invalid JointId raw {}", id))?;
            let mut bus = AnyBus::open(port.as_deref(), remote.as_deref(), baud, 200)?;
            let clamped = bus.joint_set_position(joint, position)?;
            println!(
                "SET {:?} (ID {}): goal_position={} (clamped from {})",
                joint, id, clamped, position
            );
        }
        JointAction::State {
            port,
            remote,
            id,
            baud,
        } => {
            let joint = JointId::from_byte(id)
                .ok_or_else(|| anyhow::anyhow!("invalid JointId raw {}", id))?;
            let mut bus = AnyBus::open(port.as_deref(), remote.as_deref(), baud, 200)?;
            let s = bus.joint_read_state(joint)?;
            println!("== {:?} (ID {}) 상태 ==", joint, id);
            println!("  Goal Position    : {}", s.goal_position);
            println!("  Present Position : {}", s.present_position);
            println!("  Present Speed    : {}", s.present_speed);
            println!("  Present Load     : {}", s.present_load);
            println!("  Voltage          : {:.1} V", s.voltage_volts());
            println!("  Temperature      : {} °C", s.present_temperature);
            println!("  Torque Enabled   : {}", s.torque_enabled);
        }
        JointAction::Torque {
            port,
            remote,
            target,
            enable,
            baud,
        } => {
            let on = match enable.as_str() {
                "on" | "true" | "1" => true,
                "off" | "false" | "0" => false,
                _ => anyhow::bail!("--enable는 on/off"),
            };
            let mut bus = AnyBus::open(port.as_deref(), remote.as_deref(), baud, 200)?;
            if target == "all" {
                let all: Vec<JointId> = JointId::ALL.to_vec();
                bus.joint_set_torque_many(&all, on)?;
                println!("TORQUE all = {}", on);
            } else {
                let raw: u8 = target.parse()?;
                let joint = JointId::from_byte(raw)
                    .ok_or_else(|| anyhow::anyhow!("invalid JointId raw {}", raw))?;
                bus.joint_set_torque(joint, on)?;
                println!("TORQUE {:?} (ID {}) = {}", joint, raw, on);
            }
        }
        JointAction::Estop { port, remote, baud } => {
            let mut bus = AnyBus::open(port.as_deref(), remote.as_deref(), baud, 200)?;
            bus.emergency_stop()?;
            println!("⚠️  E-STOP triggered — all torque OFF");
        }
    }
    Ok(())
}

fn handle_connect(port: &str, baud: u32, timeout: u64) -> anyhow::Result<()> {
    use forge_core::joint::JointMapKind;

    let p = PosixSerial::open(port, baud).map_err(|e| anyhow::anyhow!("open {}: {}", port, e))?;
    let mut bus = Bus::new(p).with_timeout(Duration::from_millis(timeout));

    println!("== DarwinForge 연결 진단 ==");
    println!("  포트  : {}", port);
    println!("  baud  : {}", baud);

    // 1) CM 보드
    {
        let mut cm = CmController::new(&mut bus);
        match cm.snapshot() {
            Ok(snap) => {
                println!("\n[1/2] CM 보드");
                println!(
                    "  모델    : {} ({})",
                    snap.model_number,
                    snap.controller_label()
                );
                println!("  Version : {}", snap.version);
                println!(
                    "  Voltage : {:.1} V (raw {})",
                    snap.voltage_volts(),
                    snap.voltage_raw
                );
                if snap.voltage_volts() < 9.5 {
                    println!("  ⚠️  배터리 전압 낮음 (9.5 V 이하). 충전 후 진행 권장.");
                }
            }
            Err(e) => {
                println!("\n[1/2] CM 보드 — 응답 없음 ({})", e);
                println!("  ▷ ID 200 응답이 없습니다. 직렬 케이블 / 전원 확인.");
            }
        }
    }

    // 2) 모터 매핑 detect
    {
        let mut cm = CmController::new(&mut bus);
        let result = cm.detect_joint_map();
        println!("\n[2/2] 모터 ID sweep (1..=20)");
        println!(
            "  응답 ID  : {:?} ({}/20)",
            result.responding_ids,
            result.responding_ids.len()
        );
        if !result.missing_ids.is_empty() {
            println!("  누락 ID  : {:?}", result.missing_ids);
        }
        println!("  매핑     : {:?}", result.map.kind);
        match result.map.kind {
            JointMapKind::Official => {
                println!("  ✓ 공식 ROBOTIS-OP2 매핑 — `forge walk-ready` 사용 가능.");
            }
            JointMapKind::LegacyOp1 => {
                println!("  ⚠️  Legacy OP1 매핑 감지. 발목 모터 ID 가 미지정 — 발목 명령은 미발행됩니다.");
                println!("       발목 모터를 별도 마법사로 지정한 후 `--joint-map legacy-op1` 으로 사용 가능.");
            }
        }
        if !result.map.supports_ankles() {
            println!(
                "  ⚠️  발목 4개 (RAnk Pitch/Roll, LAnk Pitch/Roll) 매핑 미정 — 안정 직립 위험."
            );
        }
    }

    println!("\n다음 단계 권장:");
    println!(
        "  forge walk-ready --port {} --dry-run    # 명령 사전 확인",
        port
    );
    println!(
        "  forge walk-ready --port {}              # 실 적용 (둠칫 없는 토크 ramp)",
        port
    );
    println!("  forge motion catalog                    # 안전 카탈로그 16개 모션");
    println!("\n비상 시: forge joint estop --port {}", port);
    Ok(())
}

fn handle_walk_ready(
    port: &str,
    baud: u32,
    interp_steps: u32,
    step_period_ms: u32,
    dry_run: bool,
    joint_map_kind: &str,
) -> anyhow::Result<()> {
    use forge_core::joint::JointMap;
    use forge_core::safety::{TorqueRampProfile, TorqueRamper};
    use forge_core::walk::ini_pose::{interpolate, neutral_targets, op2_manager_ini_pose_targets};

    let map = match joint_map_kind {
        "official" => JointMap::official(),
        "legacy-op1" => JointMap::legacy_op1(None),
        other => anyhow::bail!(
            "joint_map: 'official' 또는 'legacy-op1' 만 지원 (받음: {})",
            other
        ),
    };

    let ramp_profile = TorqueRampProfile::gentle();
    let target = op2_manager_ini_pose_targets();
    let start = neutral_targets();

    println!("== walkReady 자세 적용 ==");
    println!("  매핑       : {:?}", map.kind);
    println!("  발목 지원  : {}", map.supports_ankles());
    println!(
        "  토크 ramp  : P_GAIN {:?} × {:?} step",
        ramp_profile.p_gain_steps, ramp_profile.step_period
    );
    println!(
        "  자세 보간  : {} step × {} ms = {} ms",
        interp_steps,
        step_period_ms,
        interp_steps * step_period_ms
    );
    println!("  대상 자세  : ini_pose.yaml (공식 OP2 walkReady)");
    if !map.supports_ankles() {
        println!("  ⚠️  발목 매핑 없음 — 발목 4개 명령 생략됨. 안정 직립 위험.");
    }

    if dry_run {
        println!("\n[DRY RUN] 실 명령 미발사. 발사될 자세 시퀀스:");
        for (j, raw) in target {
            println!("  {:?}\t→ raw {}", j, raw);
        }
        return Ok(());
    }

    let p = PosixSerial::open(port, baud).map_err(|e| anyhow::anyhow!("open {}: {}", port, e))?;
    let mut bus = Bus::new(p);
    let mut jc = JointController::with_map(&mut bus, map);

    // 1) Torque ramp 시작 — P=0 + torque on.
    let mut ramper = TorqueRamper::new(&JointId::ALL, ramp_profile);
    ramper.enable_torque(&mut jc)?;
    println!("  [1/3] 토크 깨우기 (P_GAIN=0, torque on)");

    // 2) ramp P_GAIN 단계와 자세 보간을 동시 진행 — 모터 P가 올라가면서 자세도 부드럽게 이동.
    let total_steps = interp_steps.max(ramp_profile.p_gain_steps.len() as u32);
    for step in 0..total_steps {
        let t = (step + 1) as f64 / total_steps as f64;
        let blend = interpolate(&start, &target, t);
        jc.set_positions_many(&blend)?;

        // ramp P_GAIN — interp step 균등 분배.
        if step > 0 && step as usize <= ramp_profile.p_gain_steps.len() {
            let _ = ramper.next_step(&mut jc)?;
        }

        std::thread::sleep(Duration::from_millis(step_period_ms as u64));
    }
    println!("  [2/3] 자세 보간 + P_GAIN ramp 완료");

    // 3) 최종 P_GAIN (32) 확실히.
    while ramper.remaining() > 0 {
        ramper.next_step(&mut jc)?;
        std::thread::sleep(ramp_profile.step_period);
    }
    println!(
        "  [3/3] 최종 P_GAIN={} 적용. walkReady 안정 직립.",
        ramper.final_p_gain()
    );
    println!(
        "\n안전 권장: 60초 후 모터 온도 확인. 비상 시 'forge joint estop --port {}'",
        port
    );
    Ok(())
}
