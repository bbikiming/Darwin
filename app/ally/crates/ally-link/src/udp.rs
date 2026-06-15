//! UDP 제어 전송 — `df_udp.py::UdpControlTransport` 의 Rust 포팅.
//!
//! 단일 소켓: DFCMD 송신(seq 단조) + ACK/TEL2 수신. df-wire 의 순함수로 데이터그램을
//! 조립/파싱하고, 여기서는 소켓 I/O 와 `local_ip_toward` 만 다룬다.

use std::io;
use std::net::{IpAddr, UdpSocket};
use std::time::Duration;

use df_wire::Tel2;

/// 로봇으로 가는 송신 인터페이스의 로컬 IP 산출 — `df_udp.local_ip_toward` 1:1.
///
/// connected-UDP 소켓은 패킷을 보내지 않고 egress 인터페이스만 결정한다 — getsockname
/// 으로 로봇이 보게 될 내 IP 를 얻는다(업링크 등록값). 포트 9(discard)는 임의.
pub fn local_ip_toward(host: &str) -> io::Result<IpAddr> {
    let probe = UdpSocket::bind("0.0.0.0:0")?;
    probe.connect((host, 9))?;
    Ok(probe.local_addr()?.ip())
}

/// 수신 데이터그램 분류.
#[derive(Debug, Clone, PartialEq)]
pub enum Inbound {
    /// "ACK {seq} {t_rx}".
    Ack { seq: i64, t_rx: i64 },
    /// "TEL2 …" 텔레메트리(크기 큼 → Box).
    Telemetry(Box<Tel2>),
    /// 알 수 없는 데이터그램(무시 대상).
    Other,
}

/// UDP 명령 전송. host:cmd_port 로 DFCMD, host:estop_port 로 DF-ESTOP 를 보낸다.
pub struct UdpControlTransport {
    sock: UdpSocket,
    host: String,
    token: String,
    cmd_port: u16,
    estop_port: u16,
}

impl UdpControlTransport {
    /// 0.0.0.0:0 바인드. read timeout 으로 `recv` 가 블로킹하지 않게 한다.
    pub fn bind(
        host: impl Into<String>,
        token: impl Into<String>,
        cmd_port: u16,
        estop_port: u16,
        read_timeout: Duration,
    ) -> io::Result<Self> {
        let sock = UdpSocket::bind("0.0.0.0:0")?;
        sock.set_read_timeout(Some(read_timeout))?;
        Ok(UdpControlTransport {
            sock,
            host: host.into(),
            token: token.into(),
            cmd_port,
            estop_port,
        })
    }

    /// 바인드된 로컬 포트(업링크 등록값 :port 에 사용).
    pub fn local_port(&self) -> io::Result<u16> {
        Ok(self.sock.local_addr()?.port())
    }

    /// §G.3 명령 데이터그램 송신. 반환 = 보낸 바이트수.
    pub fn send_cmd(&self, seq: u64, line: &str) -> io::Result<usize> {
        let dgram = df_wire::cmd_datagram(&self.token, seq, line);
        self.sock
            .send_to(&dgram, (self.host.as_str(), self.cmd_port))
    }

    /// §G.2 E-STOP 데이터그램 1발 송신. 버스트(0/50/100ms)는 E-STOP 스레드가
    /// `df_wire::ESTOP_BURST_OFFSETS_MS` 로 이 함수를 3회 호출해 구성한다.
    pub fn send_estop(&self, ts_ms: i64) -> io::Result<usize> {
        let dgram = df_wire::estop_datagram(&self.token, ts_ms);
        self.sock
            .send_to(&dgram, (self.host.as_str(), self.estop_port))
    }

    /// 데이터그램 1개 수신·분류. 타임아웃/무수신 → Ok(None).
    pub fn recv(&self) -> io::Result<Option<Inbound>> {
        let mut buf = [0u8; 2048];
        match self.sock.recv_from(&mut buf) {
            Ok((n, _src)) => Ok(Some(classify(&buf[..n]))),
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut =>
            {
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }
}

/// 데이터그램 → Inbound. ACK 우선 시도, 아니면 TEL2, 둘 다 아니면 Other.
fn classify(data: &[u8]) -> Inbound {
    if let Some((seq, t_rx)) = df_wire::parse_ack(data) {
        return Inbound::Ack { seq, t_rx };
    }
    if let Some(tel) = df_wire::parse_tel2(data) {
        return Inbound::Telemetry(Box::new(tel));
    }
    Inbound::Other
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_ip_toward_loopback_is_loopback() {
        let ip = local_ip_toward("127.0.0.1").expect("egress ip");
        assert_eq!(ip, IpAddr::from([127, 0, 0, 1]));
    }

    #[test]
    fn classify_ack_tel_other() {
        match classify(b"ACK 42 99999") {
            Inbound::Ack { seq, t_rx } => {
                assert_eq!(seq, 42);
                assert_eq!(t_rx, 99999);
            }
            other => panic!("expected Ack, got {other:?}"),
        }
        assert_eq!(classify(b"garbage frame"), Inbound::Other);
    }

    #[test]
    fn loopback_cmd_roundtrip() {
        // 가짜 "로봇" 수신 소켓.
        let robot = UdpSocket::bind("127.0.0.1:0").unwrap();
        robot
            .set_read_timeout(Some(Duration::from_millis(500)))
            .unwrap();
        let cmd_port = robot.local_addr().unwrap().port();

        let tx = UdpControlTransport::bind(
            "127.0.0.1",
            "tok123",
            cmd_port,
            cmd_port + 1, // estop (미사용)
            Duration::from_millis(200),
        )
        .unwrap();

        let n = tx
            .send_cmd(7, "id0 0 0.00 0.00 0.00 600 40 13 1.0 0 2 0.00 0.00 0")
            .unwrap();
        assert!(n > 0);

        let mut buf = [0u8; 2048];
        let (rn, _) = robot.recv_from(&mut buf).expect("robot rx");
        let got = std::str::from_utf8(&buf[..rn]).unwrap();
        // df-wire cmd_datagram 포맷 그대로.
        assert!(got.starts_with("DFCMD tok123 7 id0 0 "));
    }

    #[test]
    fn recv_times_out_to_none() {
        let tx =
            UdpControlTransport::bind("127.0.0.1", "tok", 40000, 40001, Duration::from_millis(50))
                .unwrap();
        // 아무도 안 보냄 → 타임아웃 → None (블로킹 안 함).
        assert_eq!(tx.recv().unwrap(), None);
    }
}
