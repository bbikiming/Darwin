//! TCP-backed `SerialPort` — 네트워크 너머의 robot과 통신.
//!
//! 사용 패턴: 로봇 내장 PC가 `forge serve --port /dev/ttyUSB0 --bind 0.0.0.0:5530`
//! 으로 USB↔TCP 브리지를 띄우면, 외부 (예: Mac)가 `TcpBus::connect("ROBOT:5530")` 로
//! 직접 USB serial을 쓰는 것과 동일한 인터페이스로 통신.
//!
//! 프로토콜은 raw byte stream — Dynamixel packet은 unchanged. forge-cli serve가
//! single-connection 동안 양방향 byte pump 만 한다.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::time::Duration;

use super::SerialPort;
use crate::error::{Error, Result};

/// 네트워크 endpoint를 통해 Dynamixel bus 한 chunk와 통신.
pub struct TcpBus {
    stream: TcpStream,
    label: String,
}

impl TcpBus {
    /// `addr`는 `"host:port"` 형식. 예: `"10.0.0.42:5530"`, `"op2.local:5530"`.
    /// 연결 timeout은 별도 — read/write timeout은 `read_exact` 호출 시 적용.
    pub fn connect(addr: &str, connect_timeout: Duration) -> Result<Self> {
        let sock_addr: SocketAddr = addr
            .to_socket_addrs()
            .map_err(|e| Error::Other(format!("DNS resolve {}: {}", addr, e)))?
            .next()
            .ok_or_else(|| Error::Other(format!("no address for {}", addr)))?;

        let stream = TcpStream::connect_timeout(&sock_addr, connect_timeout).map_err(Error::Io)?;
        // Dynamixel은 작은 패킷의 ping-pong이라 nodelay가 latency에 결정적.
        let _ = stream.set_nodelay(true);
        Ok(Self {
            stream,
            label: addr.to_string(),
        })
    }

    /// 연결된 endpoint label (`host:port`) — 로그 / 디버깅용.
    pub fn label(&self) -> &str {
        &self.label
    }
}

impl SerialPort for TcpBus {
    fn write_all(&mut self, buf: &[u8]) -> Result<()> {
        Write::write_all(&mut self.stream, buf).map_err(Error::Io)
    }

    fn read_exact(&mut self, buf: &mut [u8], timeout: Duration) -> Result<()> {
        self.stream
            .set_read_timeout(Some(timeout))
            .map_err(|e| Error::Other(format!("set_read_timeout: {}", e)))?;
        Read::read_exact(&mut self.stream, buf).map_err(|e| match e.kind() {
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => {
                Error::Timeout(timeout)
            }
            _ => Error::Io(e),
        })
    }

    fn flush(&mut self) -> Result<()> {
        Write::flush(&mut self.stream).map_err(Error::Io)
    }

    fn set_baud(&mut self, _baud: u32) -> Result<()> {
        // TCP에는 baud 개념 없음. 서버 측 USB 포트의 baud는 별도로 설정됨.
        Ok(())
    }

    fn close(&mut self) -> Result<()> {
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
        Ok(())
    }

    /// TCP 측 input buffer 비우기 — 매우 짧은 timeout으로 EOF/blocking까지 read.
    /// socat 의 byte-stream 환경에서 stale byte 누적이 가장 큰 misalignment 원인.
    fn drain_input(&mut self) -> Result<()> {
        // 기존 timeout 백업해뒀다가 복구.
        let prev_timeout = self.stream.read_timeout().ok().flatten();
        let _ = self.stream.set_read_timeout(Some(Duration::from_millis(2)));
        let mut buf = [0u8; 256];
        loop {
            match Read::read(&mut self.stream, &mut buf) {
                Ok(0) => break,
                Ok(_) => continue,
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    break
                }
                Err(_) => break,
            }
        }
        let _ = self.stream.set_read_timeout(prev_timeout);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn connect_succeeds_to_local_listener() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        // 짧게 살아있는 listener — 연결만 확인.
        let h = thread::spawn(move || {
            let _ = listener.accept();
        });
        let bus = TcpBus::connect(&addr.to_string(), Duration::from_millis(500));
        assert!(bus.is_ok());
        h.join().ok();
    }

    #[test]
    fn connect_fails_to_dead_address() {
        // 빈 포트 — connect refused 또는 timeout.
        let result = TcpBus::connect("127.0.0.1:1", Duration::from_millis(200));
        assert!(result.is_err());
    }

    #[test]
    fn write_then_read_round_trip() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        // 서버 측 — 받은 byte 그대로 echo.
        let h = thread::spawn(move || {
            if let Ok((mut s, _)) = listener.accept() {
                let mut buf = [0u8; 4];
                if Read::read_exact(&mut s, &mut buf).is_ok() {
                    let _ = Write::write_all(&mut s, &buf);
                }
            }
        });
        let mut bus = TcpBus::connect(&addr.to_string(), Duration::from_millis(500)).unwrap();
        bus.write_all(&[0xAA, 0xBB, 0xCC, 0xDD]).unwrap();
        let mut buf = [0u8; 4];
        bus.read_exact(&mut buf, Duration::from_millis(500))
            .unwrap();
        assert_eq!(buf, [0xAA, 0xBB, 0xCC, 0xDD]);
        h.join().ok();
    }
}
