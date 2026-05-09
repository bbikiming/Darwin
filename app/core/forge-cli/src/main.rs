//! `forge` — DarwinForge headless CLI.
//!
//! Phase 4 스캐폴드. Sprint 1에서 ping/scan 본격 구현.

use clap::{Parser, Subcommand};
use forge_core::joint::JointId;

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
    /// 컨트롤러 또는 모터 ID에 PING 인스트럭션 전송.
    Ping {
        /// 직렬 포트 경로 (예: /dev/cu.usbserial-A1B2).
        #[arg(short, long)]
        port: String,
        /// 대상 ID (기본: 200 = 컨트롤러).
        #[arg(short, long, default_value_t = 200)]
        id: u8,
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
        /// 각 PING의 timeout (ms).
        #[arg(short, long, default_value_t = 50)]
        timeout: u64,
    },

    /// 캐논 20-DOF 관절 매핑 표 출력.
    ListJoints,
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let cli = Cli::parse();
    match cli.command {
        Command::Ping { port, id, timeout } => {
            tracing::info!("[stub] ping ID {} on {} (timeout {} ms)", id, port, timeout);
            println!("Phase 4 스캐폴드 — Sprint 1에서 실 구현");
        }
        Command::Scan {
            port,
            range,
            timeout,
        } => {
            tracing::info!("[stub] scan {} on {} (timeout {} ms)", range, port, timeout);
            println!("Phase 4 스캐폴드 — Sprint 1에서 실 구현");
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
