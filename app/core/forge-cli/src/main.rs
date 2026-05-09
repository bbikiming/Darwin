//! `forge` — DarwinForge headless CLI.
//!
//! Sprint 1: ping/scan 실 작동.

use std::time::Duration;

use clap::{Parser, Subcommand};
use forge_core::control::JointController;
use forge_core::controller::CmController;
use forge_core::dynamixel::Bus;
use forge_core::joint::JointId;
use forge_core::motion::{parse_mtn, write_mtn, Motion};
use forge_core::serial::PosixSerial;
use forge_core::strategy::{StrategyInput, StrategyState};
use forge_core::vision::{detect_blob, BlobResult, Frame, HsvRange, Pixel};
use forge_core::walk::{WalkCommand, WalkEngine};

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
        /// 직렬 포트 경로 (예: /dev/cu.usbserial-A1B2).
        #[arg(short, long)]
        port: String,
        /// 대상 ID (기본: 200 = 컨트롤러).
        #[arg(short, long, default_value_t = 200)]
        id: u8,
        /// baud rate (기본 1 Mbps).
        #[arg(short, long, default_value_t = 1_000_000)]
        baud: u32,
        /// 응답 timeout (ms).
        #[arg(short, long, default_value_t = 200)]
        timeout: u64,
    },

    /// 모터 ID 1..253을 스캔.
    Scan {
        /// 직렬 포트 경로.
        #[arg(short, long)]
        port: String,
        /// 스캔 범위 ("1-20" 또는 "1-253").
        #[arg(short, long, default_value = "1-20")]
        range: String,
        /// baud rate.
        #[arg(short, long, default_value_t = 1_000_000)]
        baud: u32,
        /// 각 PING의 timeout (ms).
        #[arg(short, long, default_value_t = 50)]
        timeout: u64,
    },

    /// CM-730/CM-740 sub-controller 보드 상태 출력.
    Board {
        /// 직렬 포트 경로.
        #[arg(short, long)]
        port: String,
        /// baud rate.
        #[arg(short, long, default_value_t = 1_000_000)]
        baud: u32,
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
}

#[derive(Subcommand, Debug)]
enum JointAction {
    /// 한 관절의 goal position 설정 (raw 0..4095, default limits로 clamp).
    Set {
        /// 직렬 포트.
        #[arg(short, long)]
        port: String,
        /// JointId raw u8 (1..6, 11..20).
        #[arg(short, long)]
        id: u8,
        /// goal position raw 0..4095.
        position: u16,
        #[arg(long, default_value_t = 1_000_000)]
        baud: u32,
    },
    /// 한 관절의 현재 상태 출력.
    State {
        #[arg(short, long)]
        port: String,
        #[arg(short, long)]
        id: u8,
        #[arg(long, default_value_t = 1_000_000)]
        baud: u32,
    },
    /// 한 관절 또는 전체 관절의 토크 enable/disable.
    Torque {
        #[arg(short, long)]
        port: String,
        /// "all" 또는 ID 숫자.
        #[arg(short, long)]
        target: String,
        /// "on" 또는 "off".
        #[arg(short = 'e', long)]
        enable: String,
        #[arg(long, default_value_t = 1_000_000)]
        baud: u32,
    },
    /// 비상 정지 — 모든 관절 토크 OFF (소프트 e-stop, ⌘⇧. 대응).
    Estop {
        #[arg(short, long)]
        port: String,
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
            id,
            baud,
            timeout,
        } => {
            let p = PosixSerial::open(&port, baud)
                .map_err(|e| anyhow::anyhow!("open {}: {}", port, e))?;
            let mut bus = Bus::new(p).with_timeout(Duration::from_millis(timeout));
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
            range,
            baud,
            timeout,
        } => {
            let r = parse_range(&range)?;
            let p = PosixSerial::open(&port, baud)
                .map_err(|e| anyhow::anyhow!("open {}: {}", port, e))?;
            let mut bus = Bus::new(p).with_timeout(Duration::from_millis(timeout));
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

        Command::Board { port, baud } => {
            let p = PosixSerial::open(&port, baud)
                .map_err(|e| anyhow::anyhow!("open {}: {}", port, e))?;
            let mut bus = Bus::new(p);
            let mut cm = CmController::new(&mut bus);
            let snap = cm.snapshot()?;
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
    }
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
                    "  page id={:3} name={:20} steps={} next={} exit={} repeat={} speed={}",
                    p.id,
                    p.name,
                    p.steps.len(),
                    p.next_page,
                    p.exit_page,
                    p.repeat,
                    p.speed
                );
            }
        }
    }
    Ok(())
}

fn handle_joint(action: JointAction) -> anyhow::Result<()> {
    match action {
        JointAction::Set {
            port,
            id,
            position,
            baud,
        } => {
            let joint = JointId::from_byte(id)
                .ok_or_else(|| anyhow::anyhow!("invalid JointId raw {}", id))?;
            let p = PosixSerial::open(&port, baud)
                .map_err(|e| anyhow::anyhow!("open {}: {}", port, e))?;
            let mut bus = Bus::new(p);
            let mut jc = JointController::new(&mut bus);
            let clamped = jc.set_position(joint, position)?;
            println!(
                "SET {:?} (ID {}): goal_position={} (clamped from {})",
                joint, id, clamped, position
            );
        }
        JointAction::State { port, id, baud } => {
            let joint = JointId::from_byte(id)
                .ok_or_else(|| anyhow::anyhow!("invalid JointId raw {}", id))?;
            let p = PosixSerial::open(&port, baud)
                .map_err(|e| anyhow::anyhow!("open {}: {}", port, e))?;
            let mut bus = Bus::new(p);
            let mut jc = JointController::new(&mut bus);
            let s = jc.read_state(joint)?;
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
            target,
            enable,
            baud,
        } => {
            let on = match enable.as_str() {
                "on" | "true" | "1" => true,
                "off" | "false" | "0" => false,
                _ => anyhow::bail!("--enable는 on/off"),
            };
            let p = PosixSerial::open(&port, baud)
                .map_err(|e| anyhow::anyhow!("open {}: {}", port, e))?;
            let mut bus = Bus::new(p);
            let mut jc = JointController::new(&mut bus);
            if target == "all" {
                let all: Vec<JointId> = JointId::ALL.to_vec();
                jc.set_torque_many(&all, on)?;
                println!("TORQUE all = {}", on);
            } else {
                let raw: u8 = target.parse()?;
                let joint = JointId::from_byte(raw)
                    .ok_or_else(|| anyhow::anyhow!("invalid JointId raw {}", raw))?;
                jc.set_torque(joint, on)?;
                println!("TORQUE {:?} (ID {}) = {}", joint, raw, on);
            }
        }
        JointAction::Estop { port, baud } => {
            let p = PosixSerial::open(&port, baud)
                .map_err(|e| anyhow::anyhow!("open {}: {}", port, e))?;
            let mut bus = Bus::new(p);
            let mut jc = JointController::new(&mut bus);
            jc.emergency_stop()?;
            println!("⚠️  E-STOP triggered — all torque OFF");
        }
    }
    Ok(())
}
