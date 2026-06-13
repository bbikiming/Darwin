//! 세션 상태·전이 — §7 시퀀스의 순수 결정 로직 (소켓/SSH 없음, 테스트 가능).
//!
//! 실제 I/O(프로브·SSH·UDP)는 `ssh`/`udp` 모듈이, 스레드 구동은 darwin-fpv(W1)가
//! 소유한다. 여기는 "지금 어떤 경로/전송이어야 하는가"만 판정한다.

use crate::{ACK_PROBE_MS, WIRED_HOST, WIRELESS_HOST};

/// 로봇 도달 경로 — 유선 우선, 무선 폴백 (§7-1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Path {
    /// USB-C LAN 직결 192.168.123.1 — 무선 대비 ~166배.
    Wired,
    /// 공유 AP 192.168.0.33.
    Wireless,
    /// 미연결.
    None,
}

impl Path {
    /// 경로의 로봇 호스트 IP. `None` 은 호스트 없음.
    pub fn host(self) -> Option<&'static str> {
        match self {
            Path::Wired => Some(WIRED_HOST),
            Path::Wireless => Some(WIRELESS_HOST),
            Path::None => None,
        }
    }

    /// UI `conn.path` 문자열 (§3 state 스키마).
    pub fn as_str(self) -> &'static str {
        match self {
            Path::Wired => "wired",
            Path::Wireless => "wireless",
            Path::None => "none",
        }
    }
}

/// 활성 명령 전송 경로 (§7-6 폴백 표기).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    /// 20Hz DFCMD UDP (주 경로).
    Udp,
    /// 5Hz SSH 파일 (/tmp/df-walklab-cmd) — ACK 침묵 시 폴백.
    SshFile,
}

impl Transport {
    /// UI `conn.transport` 문자열.
    pub fn as_str(self) -> &'static str {
        match self {
            Transport::Udp => "udp",
            Transport::SshFile => "ssh_file",
        }
    }
}

/// §7-6 폴백 판정: ACK 마지막 수신 후 경과로 UDP↔SSH파일 결정.
///
/// - ACK 한 번이라도 신선(≤ACK_PROBE_MS)하면 UDP 유지.
/// - ACK_PROBE_MS 초과(또는 ACK 전무) → SSH 파일 폴백.
///
/// 히스테리시스 없음(단조 판정) — 호출자가 전환 시 토큰 철회/복원을 책임진다(§7).
pub fn decide_transport(ack_age_ms: Option<i64>) -> Transport {
    match ack_age_ms {
        Some(age) if age <= ACK_PROBE_MS as i64 => Transport::Udp,
        _ => Transport::SshFile,
    }
}

/// 선호 경로 → 프로브 시도 순서 (§7-1: 유선 우선이 기본, 명시 무선 선호도 허용).
pub fn probe_order(prefer: Path) -> [Path; 2] {
    match prefer {
        Path::Wireless => [Path::Wireless, Path::Wired],
        // Wired 또는 None(기본) → 유선 우선.
        _ => [Path::Wired, Path::Wireless],
    }
}

/// 연결 상태 스냅샷 — §3 `state.conn` 부분집합. darwin-fpv 가 StateHub 로 확장한다.
#[derive(Debug, Clone, PartialEq)]
pub struct LinkSnapshot {
    pub path: Path,
    pub transport: Transport,
    pub rtt_ms: Option<f64>,
    pub eff_hz: f64,
    /// 마지막 TEL2 경과(ms) — None 이면 아직 수신 전. >1500 이면 UI 채도 저하.
    pub tel_age_ms: Option<i64>,
    /// 마지막 ACK 경과(ms).
    pub ack_age_ms: Option<i64>,
    pub connected: bool,
}

impl LinkSnapshot {
    pub fn disconnected() -> Self {
        LinkSnapshot {
            path: Path::None,
            transport: Transport::Udp,
            rtt_ms: None,
            eff_hz: 0.0,
            tel_age_ms: None,
            ack_age_ms: None,
            connected: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_hosts() {
        assert_eq!(Path::Wired.host(), Some(WIRED_HOST));
        assert_eq!(Path::Wireless.host(), Some(WIRELESS_HOST));
        assert_eq!(Path::None.host(), None);
        assert_eq!(Path::Wired.as_str(), "wired");
    }

    #[test]
    fn probe_prefers_wired_by_default() {
        assert_eq!(probe_order(Path::None), [Path::Wired, Path::Wireless]);
        assert_eq!(probe_order(Path::Wired), [Path::Wired, Path::Wireless]);
        assert_eq!(probe_order(Path::Wireless), [Path::Wireless, Path::Wired]);
    }

    #[test]
    fn transport_falls_back_on_ack_silence() {
        // 신선 → UDP
        assert_eq!(decide_transport(Some(0)), Transport::Udp);
        assert_eq!(decide_transport(Some(ACK_PROBE_MS as i64)), Transport::Udp); // 경계 포함
        // 침묵 초과 → SSH 파일
        assert_eq!(
            decide_transport(Some(ACK_PROBE_MS as i64 + 1)),
            Transport::SshFile
        );
        // ACK 전무 → SSH 파일
        assert_eq!(decide_transport(None), Transport::SshFile);
        assert_eq!(Transport::SshFile.as_str(), "ssh_file");
    }
}
