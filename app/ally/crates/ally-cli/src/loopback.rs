//! 로컬 페이크 로봇 — 헤드리스 자기검증(`ally-cli loopback`).
//!
//! 로봇 없이 핸드셰이크→프로브→20Hz→eff_hz→TEL2 수신율→ACK RTT 전 측정
//! 파이프라인을 Ally 에서 돌려 ally-link 스택을 통합 검증한다. cmd 소켓은 DFCMD 에
//! ACK 로 회신하고 같은 송신자에게 TEL2 를 30Hz 로 흘린다(업링크 파일 불요 —
//! 송신 소스 주소로 회신). estop 소켓은 DF-ESTOP 수를 센다.

use std::net::UdpSocket;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// 페이크 로봇 — cmd/estop 소켓 + 응답 스레드.
pub struct FakeRobot {
    pub cmd_port: u16,
    pub estop_port: u16,
    running: Arc<AtomicBool>,
    estop_count: Arc<AtomicI64>,
    handles: Vec<JoinHandle<()>>,
}

impl FakeRobot {
    /// 임의 포트로 기동(127.0.0.1). 반환된 cmd_port/estop_port 를 세션에 넘긴다.
    pub fn spawn() -> std::io::Result<Self> {
        let cmd_sock = UdpSocket::bind(("127.0.0.1", 0))?;
        let estop_sock = UdpSocket::bind(("127.0.0.1", 0))?;
        let cmd_port = cmd_sock.local_addr()?.port();
        let estop_port = estop_sock.local_addr()?.port();
        cmd_sock.set_read_timeout(Some(Duration::from_millis(10)))?;
        estop_sock.set_read_timeout(Some(Duration::from_millis(50)))?;

        let running = Arc::new(AtomicBool::new(true));
        let estop_count = Arc::new(AtomicI64::new(0));

        // cmd 스레드 — DFCMD 수신 시 ACK 회신 + 마지막 송신자에게 TEL2 30Hz 스트림.
        let cmd_running = Arc::clone(&running);
        let cmd_handle = std::thread::spawn(move || {
            let mut buf = [0u8; 2048];
            let mut peer = None;
            let mut last_seq: i64 = 0;
            let mut last_tel = Instant::now();
            while cmd_running.load(Ordering::Relaxed) {
                if let Ok((n, from)) = cmd_sock.recv_from(&mut buf) {
                    let text = String::from_utf8_lossy(&buf[..n]);
                    let tok: Vec<&str> = text.split_whitespace().collect();
                    // "DFCMD {token} {seq} {line...}"
                    if tok.first() == Some(&"DFCMD") {
                        if let Some(seq) = tok.get(2).and_then(|s| s.parse::<i64>().ok()) {
                            last_seq = seq;
                            peer = Some(from);
                            let ack = format!("ACK {seq} {}", unix_millis());
                            let _ = cmd_sock.send_to(ack.as_bytes(), from);
                        }
                    }
                }
                // TEL2 30Hz (33ms) — 무FSR 예시 라인(계약 §A.2-TEL2).
                if last_tel.elapsed() >= Duration::from_millis(33) {
                    last_tel = Instant::now();
                    if let Some(addr) = peer {
                        let line = format!(
                            "TEL2 {} {} 0 0.00 0.00 0.00 600.00 512 512 512 512 512 700 - - -1 - 122 udp 5",
                            unix_millis(),
                            last_seq
                        );
                        let _ = cmd_sock.send_to(line.as_bytes(), addr);
                    }
                }
            }
        });

        // estop 스레드 — DF-ESTOP 수신 수 카운트.
        let estop_running = Arc::clone(&running);
        let estop_counter = Arc::clone(&estop_count);
        let estop_handle = std::thread::spawn(move || {
            let mut buf = [0u8; 2048];
            while estop_running.load(Ordering::Relaxed) {
                if let Ok((n, _)) = estop_sock.recv_from(&mut buf) {
                    if buf[..n].starts_with(b"DF-ESTOP") {
                        estop_counter.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
        });

        Ok(FakeRobot {
            cmd_port,
            estop_port,
            running,
            estop_count,
            handles: vec![cmd_handle, estop_handle],
        })
    }

    /// 지금까지 수신한 DF-ESTOP 데이터그램 수.
    pub fn estop_count(&self) -> i64 {
        self.estop_count.load(Ordering::Relaxed)
    }

    /// 스레드 정지 + 합류.
    pub fn stop(mut self) {
        self.running.store(false, Ordering::Relaxed);
        for h in self.handles.drain(..) {
            let _ = h.join();
        }
    }
}

fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ally_link::UdpControlTransport;

    /// 페이크 로봇과 전송의 왕복 — ACK·TEL2·E-STOP 데이터그램이 닿는지(로봇 불요).
    #[test]
    fn fake_robot_round_trip() {
        let robot = FakeRobot::spawn().unwrap();
        let mut tx = UdpControlTransport::new(
            "127.0.0.1",
            robot.cmd_port,
            robot.estop_port,
            "looptoken1234567".into(),
        )
        .unwrap();

        // ~300ms 동안 20Hz 송신 + 1ms 슬라이스 pump → ACK/TEL2 수신.
        let start = Instant::now();
        let mut last_send = Instant::now();
        while start.elapsed() < Duration::from_millis(400) {
            if last_send.elapsed() >= Duration::from_millis(50) {
                tx.send_command("id 0 0.00 0.00 0.00 600 40 13 1.0 0 2 0.00 0.00 0");
                last_send = Instant::now();
            }
            tx.pump();
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(tx.ack_total() > 0, "ACK 수신 (got {})", tx.ack_total());
        assert!(tx.tel_total() > 0, "TEL2 수신 (got {})", tx.tel_total());
        assert!(!tx.rtt_samples().is_empty(), "RTT 표본 누적");

        // E-STOP — 즉시 동기 + 50/100ms 보조 → 3발 도달.
        tx.send_estop().unwrap();
        std::thread::sleep(Duration::from_millis(200));
        assert!(
            robot.estop_count() >= 1,
            "estop 데이터그램 도달 (got {})",
            robot.estop_count()
        );

        robot.stop();
    }
}
