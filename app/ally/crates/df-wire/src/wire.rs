//! §G UDP 데이터그램 조립·파싱 — `df_udp.py` 순함수의 1:1 포팅.
//!
//! 포트 상수는 §G.7 계약 고정값이고 핸드셰이크가 로봇에 전달하므로 여기가
//! 클라이언트 측 단일 출처다 — 다른 곳에 하드코딩 금지.

/// E-STOP 리스너 포트 (§G.7).
pub const DEFAULT_ESTOP_PORT: u16 = 17372;
/// 명령 리스너 포트 (§G.7).
pub const DEFAULT_CMD_PORT: u16 = 17374;
/// TEL2 업링크 기본 포트 (§G.7) — 실제 수신 포트는 업링크 파일에 등록한 값.
pub const DEFAULT_TELEMETRY_PORT: u16 = 17371;

/// E-STOP 버스트 스케줄 (§G.2): 0/50/100ms 3연발. SSH/파일 경로와 병행 —
/// 먼저 도착한 쪽이 이긴다. 송신 스레드(ally-link)가 이 간격을 소유한다.
pub const ESTOP_BURST_OFFSETS_MS: [u64; 3] = [0, 50, 100];

/// Python `str.encode("ascii", errors="ignore")` 등가 — 비ASCII 문자 탈락.
/// (UTF-8에서 비ASCII 문자의 모든 바이트는 0x80 이상이므로 바이트 필터와 동치.)
pub(crate) fn ascii_lossy_bytes(s: &str) -> Vec<u8> {
    s.bytes().filter(u8::is_ascii).collect()
}

/// Python `bytes.decode("ascii", errors="ignore")` 등가.
pub(crate) fn ascii_lossy_str(data: &[u8]) -> String {
    data.iter()
        .copied()
        .filter(u8::is_ascii)
        .map(char::from)
        .collect()
}

/// §G.1 채널 핸드셰이크 파일 본문 (개행 포함) — `df_udp.handshake_line` 등가.
pub fn handshake_line(token: &str, estop_port: u16, cmd_port: u16) -> String {
    format!("{token} {estop_port} {cmd_port}\n")
}

/// §G.3 명령 데이터그램 — `line` 은 §C v1 14-token 명령 라인.
pub fn cmd_datagram(token: &str, seq: u64, line: &str) -> Vec<u8> {
    ascii_lossy_bytes(&format!("DFCMD {token} {seq} {line}"))
}

/// §G.2 E-STOP 데이터그램.
pub fn estop_datagram(token: &str, ts_ms: i64) -> Vec<u8> {
    ascii_lossy_bytes(&format!("DF-ESTOP v1 {token} {ts_ms}"))
}

/// "ACK {seq} {t_rx}" 파싱 — (seq, t_rx) 또는 None. 초과 토큰은 무시한다
/// (Python 원본의 `len(tokens) < 3` 검사와 동일 의미론).
///
/// 주의: Python `int()` 는 "1_0" 같은 밑줄 표기를 허용하지만 Rust parse 는
/// 거부한다 — 로봇은 밑줄을 보내지 않으므로 계약상 무의미한 차이다.
pub fn parse_ack(data: &[u8]) -> Option<(i64, i64)> {
    let text = ascii_lossy_str(data);
    let mut tokens = text.split_whitespace();
    if tokens.next()? != "ACK" {
        return None;
    }
    let seq = tokens.next()?.parse::<i64>().ok()?;
    let t_rx = tokens.next()?.parse::<i64>().ok()?;
    Some((seq, t_rx))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cmd_datagram_layout() {
        let dgram = cmd_datagram("tok", 7, "abc 1 2");
        assert_eq!(dgram, b"DFCMD tok 7 abc 1 2");
    }

    #[test]
    fn estop_datagram_layout() {
        assert_eq!(estop_datagram("tok", 123), b"DF-ESTOP v1 tok 123");
    }

    #[test]
    fn ascii_lossy_drops_non_ascii() {
        // Python encode(ascii, ignore) 와 동일하게 멀티바이트 문자가 통째로 빠진다.
        assert_eq!(cmd_datagram("tok", 1, "스트라이드x"), b"DFCMD tok 1 x");
    }

    #[test]
    fn parse_ack_happy_and_malformed() {
        assert_eq!(parse_ack(b"ACK 17 123456"), Some((17, 123456)));
        assert_eq!(parse_ack(b"ACK 17 99 extra"), Some((17, 99)));
        assert_eq!(parse_ack(b"ACK 17"), None);
        assert_eq!(parse_ack(b"NAK 1 2"), None);
        assert_eq!(parse_ack(b"ACK x y"), None);
        assert_eq!(parse_ack(b""), None);
    }
}
