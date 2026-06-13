//! ally-link — 소켓·세션 계층 (W1).
//!
//! §7 세션 시퀀스(docs/03_ARCHITECTURE.md)의 I/O 빌딩블록을 제공한다:
//! - [`ssh`] : subprocess-ssh 세션(핸드셰이크·업링크·파일 폴백·E-STOP 병행) — ssh2
//!   네이티브 미사용으로 OpenSSH 5.9 협상 리스크 회피, df-wire 외 의존 0.
//! - [`udp`] : DFCMD 송신 + ACK/TEL2 수신 단일 소켓 + `local_ip_toward`.
//! - [`metrics`] : RTT EMA(α=0.3) + effective_hz(1s 윈도).
//! - [`session`] : 경로(유선/무선)·전송(UDP/SSH파일) 결정 순함수.
//!
//! 7-스레드 구동(입력·TX·E-STOP·RX·SSH·수퍼바이저)은 darwin-fpv.exe 가 이 계층 위에
//! 올린다(§2). ally-cli 는 헤드리스로 동일 빌딩블록을 구동한다.

pub mod metrics;
pub mod session;
pub mod ssh;
pub mod udp;

use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

pub use session::{decide_transport, probe_order, LinkSnapshot, Path, Transport};

/// 유선 직결 경로 (USB-C LAN 어댑터) — 무선 대비 ~166배 빠름 (CLAUDE.md).
pub const WIRED_HOST: &str = "192.168.123.1";
/// 무선 경로 (공유 AP).
pub const WIRELESS_HOST: &str = "192.168.0.33";
/// 로봇 SSH 계정 (OpenSSH 5.9 — RSA identity 필수, ed25519 불가).
pub const ROBOT_USER: &str = "robotis";

/// UDP 명령 송신율 (§G.4 — 로봇 워치독 티어가 패킷 손실을 빨리 잡도록 연속 스트림).
pub const UDP_SEND_HZ: f64 = 20.0;
/// SSH 파일 폴백 송신율 (검증된 5Hz).
pub const SSH_SEND_HZ: f64 = 5.0;
/// 핸드셰이크 후 첫 ACK 대기 (§G.1 — 로봇은 ≤1s 내 채택, 1.5s 면 유실 몇 발 커버).
pub const ACK_PROBE_MS: u64 = 1500;

// 재노출: 송신 계층 사용자는 df-wire 를 직접 의존하지 않아도 된다.
pub use df_wire::{gen_cmd_id, gen_token, WireRng};
pub use df_wire::{DEFAULT_CMD_PORT, DEFAULT_ESTOP_PORT, DEFAULT_TELEMETRY_PORT};

/// §7-1 경로 프로브 — 호스트의 TCP :22 에 timeout 내 connect 되면 도달 가능.
/// (실제 SSH 핸드셰이크 전 빠른 가용성 판정 — df_udp 의 connect 트릭과 별개.)
pub fn probe_tcp22(host: &str, timeout: Duration) -> bool {
    probe_tcp(host, 22, timeout)
}

fn probe_tcp(host: &str, port: u16, timeout: Duration) -> bool {
    let Ok(addrs) = (host, port).to_socket_addrs() else {
        return false;
    };
    for addr in addrs {
        if TcpStream::connect_timeout(&addr, timeout).is_ok() {
            return true;
        }
    }
    false
}

/// §7-1 유선 우선(또는 선호 경로) 프로브 → 처음 도달한 [`Path`]. 둘 다 실패면 `Path::None`.
pub fn probe_path(prefer: Path, timeout: Duration) -> Path {
    for p in probe_order(prefer) {
        if let Some(host) = p.host() {
            if probe_tcp22(host, timeout) {
                return p;
            }
        }
    }
    Path::None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn probe_tcp_true_when_listener_present() {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        assert!(probe_tcp("127.0.0.1", port, Duration::from_millis(200)));
    }

    #[test]
    fn probe_tcp_false_when_nothing_listening() {
        // 닫힌 포트(아무도 안 들음) → connect 거부 → false.
        assert!(!probe_tcp("127.0.0.1", 1, Duration::from_millis(150)));
    }

    #[test]
    fn probe_path_returns_a_valid_variant() {
        // 호스트에 실로봇이 없으면 보통 None — 같은 서브넷이면 달라질 수 있어 약단언.
        let p = probe_path(Path::Wired, Duration::from_millis(120));
        assert!(matches!(p, Path::None | Path::Wired | Path::Wireless));
    }
}
