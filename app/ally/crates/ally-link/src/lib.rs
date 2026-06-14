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

/// 선행 `~/` · `$HOME/` · `%USERPROFILE%\` 를 실제 홈 경로로 확장한다(순함수).
///
/// **왜 필요한가**: Mac→Ally SSH 명령은 PowerShell single-quote 로 인용되므로 `'$HOME/…'`
/// 의 `$HOME` 이 확장되지 않은 리터럴로 ally-cli 까지 도달한다. ssh 의 `~` 확장에만 기대지
/// 않고 여기서 직접 확장해 키 경로가 어떤 셸을 거쳤든 올바르게 풀리도록 한다(C1 수정).
/// `home` 이 `None`(환경변수 미설정)이면 원본을 그대로 두어 ssh 의 자체 확장에 맡긴다.
pub fn expand_home(path: &str, home: Option<&str>) -> String {
    let Some(home) = home else {
        return path.to_string();
    };
    let home = home.trim_end_matches(['/', '\\']);
    for prefix in [
        "~/",
        "~\\",
        "$HOME/",
        "$HOME\\",
        "%USERPROFILE%/",
        "%USERPROFILE%\\",
    ] {
        if let Some(rest) = path.strip_prefix(prefix) {
            let sep = if prefix.ends_with('\\') { '\\' } else { '/' };
            return format!("{home}{sep}{rest}");
        }
    }
    path.to_string()
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
    fn expand_home_handles_tilde_dollar_and_userprofile() {
        let home = Some("C:\\Users\\kus19");
        // ~/ 와 $HOME/ 둘 다 확장(슬래시 보존).
        assert_eq!(
            expand_home("~/.ssh/id_rsa_darwin", home),
            "C:\\Users\\kus19/.ssh/id_rsa_darwin"
        );
        assert_eq!(
            expand_home("$HOME/.ssh/id_rsa_darwin", home),
            "C:\\Users\\kus19/.ssh/id_rsa_darwin"
        );
        // 백슬래시 변형은 백슬래시 구분자 유지.
        assert_eq!(
            expand_home("%USERPROFILE%\\.ssh\\id_rsa", home),
            "C:\\Users\\kus19\\.ssh\\id_rsa"
        );
        // 홈 말미 구분자는 중복 없이 정규화.
        assert_eq!(expand_home("~/x", Some("/home/rog/")), "/home/rog/x");
        // 절대경로·미해당 접두는 그대로.
        assert_eq!(expand_home("/etc/key", home), "/etc/key");
        // 홈 미설정이면 원본 유지(ssh 자체 확장에 위임).
        assert_eq!(expand_home("~/.ssh/id", None), "~/.ssh/id");
    }

    #[test]
    fn probe_path_returns_a_valid_variant() {
        // 호스트에 실로봇이 없으면 보통 None — 같은 서브넷이면 달라질 수 있어 약단언.
        let p = probe_path(Path::Wired, Duration::from_millis(120));
        assert!(matches!(p, Path::None | Path::Wired | Path::Wireless));
    }
}
