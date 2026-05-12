//! `forge-mcp-synth` — Motion Synthesis MCP server (stdio JSON-RPC).
//!
//! 클라이언트 (Claude / agent) 가 stdin 으로 JSON-RPC 요청을 보내면 stdout 으로
//! 응답을 줍니다. 로그는 stderr.
//!
//! 환경 변수:
//! - `FORGE_MOTION_BIN` — `motion_4096.bin` 경로 (없으면 workspace 기본).

use std::io::{self, BufRead, Write};

use forge_mcp_synth::{handle_line, Engine};

fn main() -> anyhow::Result<()> {
    let engine = Engine::new_default();
    if engine.bin_exists() {
        eprintln!(
            "forge-mcp-synth: bin = {:?}",
            engine.bin_path.as_ref().unwrap()
        );
    } else {
        eprintln!("forge-mcp-synth: WARN — no motion_4096.bin found; library tools will error");
    }

    let stdin = io::stdin();
    let mut stdout = io::stdout().lock();

    for line_res in stdin.lock().lines() {
        let line = match line_res {
            Ok(l) => l,
            Err(e) => {
                eprintln!("stdin read error: {e}");
                break;
            }
        };
        if let Some(resp) = handle_line(&line, &engine) {
            writeln!(stdout, "{resp}")?;
            stdout.flush()?;
        }
    }
    Ok(())
}
