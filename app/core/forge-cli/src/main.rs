//! `forge` — DarwinForge headless CLI.
//!
//! Sprint 1: ping/scan 실 작동.

use std::time::Duration;

use clap::{Parser, Subcommand};
use forge_core::controller::CmController;
use forge_core::dynamixel::Bus;
use forge_core::joint::JointId;
use forge_core::serial::PosixSerial;

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
    }
    Ok(())
}
