//! UDP 제어 전송 — `df_udp.py::UdpControlTransport` 의 1:1 Rust 포팅.
//!
//! 단일 소켓이 DFCMD(:cmd_port)·DF-ESTOP(:estop_port)를 보내고, 로봇은 우리
//! 송신 소스 주소로 ACK 를, 업링크 등록한 IP:port 로 TEL2 를 보낸다 — 그래서 한
//! 소켓의 `pump()` 가 둘 다 흡수한다(df_udp.py 검증 구조). 송수신은 제어 루프에
//! 예외를 던지지 않는다(에러는 로깅 후 falsy). 와이어 포맷은 df-wire 가 단일 출처.
//!
//! E-STOP 즉시 발화(offset 0)는 호출 스레드에서 **동기 송신**한다 — INV-1
//! ("추가 비동기 홉 금지"): 스레드 생성 지연 없이 socket write 가 즉시 일어난다.
//! 50/100ms 반복분만 보조 스레드로 보낸다(먼저 도착한 쪽이 이긴다 — §G.2).

use std::collections::{HashMap, VecDeque};
use std::io;
use std::net::{SocketAddr, ToSocketAddrs, UdpSocket};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use df_wire::{cmd_datagram, estop_datagram, parse_ack, parse_tel2, Tel2, ESTOP_BURST_OFFSETS_MS};

/// ACK RTT EMA 계수 — `df_udp.py` rtt_alpha 기본 0.3.
pub const DEFAULT_RTT_ALPHA: f64 = 0.3;
/// 도달율 윈도 — `df_udp.py` rate_window_s 기본 1.0s.
pub const DEFAULT_RATE_WINDOW_S: f64 = 1.0;

/// pump 한 번이 흡수하는 최대 데이터그램 수(플러드가 제어 루프를 굶기지 않도록).
const PUMP_MAX_DATAGRAMS: usize = 64;
/// 미회신 송신 시각 맵 상한 — ACK 유실 누적 시 무한 성장 방지(Python 256/128).
const SENT_AT_CAP: usize = 256;
const SENT_AT_TRIM_TO: usize = 128;

/// 단일 UDP 소켓 위의 명령/E-STOP 송신 + ACK/TEL2 수신.
pub struct UdpControlTransport {
    sock: Arc<UdpSocket>,
    cmd_addr: SocketAddr,
    estop_addr: SocketAddr,
    token: String,
    rtt_alpha: f64,
    rate_window: Duration,
    local_ip: String,
    local_port: u16,

    seq: u64,
    last_ack_seq: i64,
    ack_total: u64,
    tel_total: u64,
    last_rtt_ms: Option<f64>,
    last_tel: Option<Tel2>,
    last_tel_at: Option<Instant>,
    last_ack_at: Option<Instant>,

    sent_at: HashMap<u64, Instant>,
    ack_times: VecDeque<Instant>,
    tel_times: VecDeque<Instant>,
    rtt_samples: Vec<f64>,
}

/// RTT 샘플 누적 상한 — 60s×20Hz=1200 정도라 넉넉. 초과 시 가장 오래된 절반 폐기.
const RTT_SAMPLES_CAP: usize = 20_000;

impl UdpControlTransport {
    /// 소켓 바인드 + 업링크 소스 IP 산출. `token` 은 핸드셰이크에 쓴 것과 같아야 한다.
    pub fn new(host: &str, cmd_port: u16, estop_port: u16, token: String) -> io::Result<Self> {
        let cmd_addr = resolve(host, cmd_port)?;
        let estop_addr = resolve(host, estop_port)?;
        let sock = UdpSocket::bind(("0.0.0.0", 0))?;
        sock.set_nonblocking(true)?;
        let local_port = sock.local_addr()?.port();
        let local_ip = local_ip_toward(host);
        Ok(UdpControlTransport {
            sock: Arc::new(sock),
            cmd_addr,
            estop_addr,
            token,
            rtt_alpha: DEFAULT_RTT_ALPHA,
            rate_window: Duration::from_secs_f64(DEFAULT_RATE_WINDOW_S),
            local_ip,
            local_port,
            seq: 0,
            last_ack_seq: 0,
            ack_total: 0,
            tel_total: 0,
            last_rtt_ms: None,
            last_tel: None,
            last_tel_at: None,
            last_ack_at: None,
            sent_at: HashMap::new(),
            ack_times: VecDeque::new(),
            tel_times: VecDeque::new(),
            rtt_samples: Vec::new(),
        })
    }

    /// 로봇이 TEL2 를 보낼 곳 — `/tmp/df-walklab-uplink` 에 기록할 "ip:port".
    pub fn uplink_value(&self) -> String {
        format!("{}:{}", self.local_ip, self.local_port)
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    /// DFCMD 하나를 단조 seq 로 송신하고 그 seq 를 반환. 송신 시각을 찍어 ACK 가
    /// 돌아오면 RTT 를 계산한다(로봇은 reordered/old seq 를 버린다 — §G.3).
    pub fn send_command(&mut self, line: &str) -> u64 {
        self.seq += 1;
        let seq = self.seq;
        self.sent_at.insert(seq, Instant::now());
        if self.sent_at.len() > SENT_AT_CAP {
            // 가장 오래된 seq 부터 정리(작은 seq = 오래됨, 단조 송신이므로).
            let mut keys: Vec<u64> = self.sent_at.keys().copied().collect();
            keys.sort_unstable();
            for k in keys.into_iter().take(self.sent_at.len() - SENT_AT_TRIM_TO) {
                self.sent_at.remove(&k);
            }
        }
        let dgram = cmd_datagram(&self.token, seq, line);
        let _ = self.sock.send_to(&dgram, self.cmd_addr);
        seq
    }

    /// §G.2 ×3연발(0/50/100ms). offset 0 은 **동기 송신**(INV-1 — 비동기 홉 없음),
    /// 50/100ms 반복은 보조 스레드. 반환: 즉시 datagram 의 io 결과.
    pub fn send_estop(&self) -> io::Result<()> {
        // offset 0 — 호출 스레드에서 즉시.
        let immediate = self
            .sock
            .send_to(&estop_datagram(&self.token, unix_millis()), self.estop_addr);

        // 50/100ms 반복 — 보조 스레드(먼저 도착한 쪽이 이김).
        let sock = Arc::clone(&self.sock);
        let token = self.token.clone();
        let estop_addr = self.estop_addr;
        std::thread::Builder::new()
            .name("ally-estop-burst".into())
            .spawn(move || {
                let start = Instant::now();
                for &offset_ms in ESTOP_BURST_OFFSETS_MS.iter().skip(1) {
                    let target = Duration::from_millis(offset_ms);
                    let elapsed = start.elapsed();
                    if target > elapsed {
                        std::thread::sleep(target - elapsed);
                    }
                    let _ = sock.send_to(&estop_datagram(&token, unix_millis()), estop_addr);
                }
            })
            .ok();

        immediate.map(|_| ())
    }

    /// 대기 중인 ACK/TEL2 를 비운다(non-blocking). 이번 사이클의 최신 TEL2 를 반환.
    pub fn pump(&mut self) -> Option<Tel2> {
        let mut latest: Option<Tel2> = None;
        let mut buf = [0u8; 2048];
        for _ in 0..PUMP_MAX_DATAGRAMS {
            match self.sock.recv_from(&mut buf) {
                Ok((n, _addr)) => {
                    let data = &buf[..n];
                    if data.starts_with(b"ACK") {
                        self.on_ack(data);
                    } else if data.starts_with(b"TEL2") {
                        if let Some(tel) = parse_tel2(data) {
                            let now = Instant::now();
                            self.tel_times.push_back(now);
                            self.tel_total += 1;
                            self.last_tel_at = Some(now);
                            latest = Some(tel.clone());
                            self.last_tel = Some(tel);
                        }
                    }
                }
                Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(_) => break,
            }
        }
        latest
    }

    fn on_ack(&mut self, data: &[u8]) {
        let Some((seq, _t_rx)) = parse_ack(data) else {
            return;
        };
        let now = Instant::now();
        self.last_ack_at = Some(now);
        self.ack_total += 1;
        if seq > self.last_ack_seq {
            self.last_ack_seq = seq;
        }
        if let Some(sent) = self.sent_at.remove(&(seq as u64)) {
            let rtt = now.duration_since(sent).as_secs_f64() * 1000.0;
            self.last_rtt_ms = Some(match self.last_rtt_ms {
                None => rtt,
                Some(prev) => self.rtt_alpha * rtt + (1.0 - self.rtt_alpha) * prev,
            });
            // 분포(p50/p95)용 raw 샘플 누적 — EMA 와 별개.
            if self.rtt_samples.len() >= RTT_SAMPLES_CAP {
                self.rtt_samples.drain(0..RTT_SAMPLES_CAP / 2);
            }
            self.rtt_samples.push(rtt);
        }
        self.ack_times.push_back(now);
        self.trim(now);
    }

    fn trim(&mut self, now: Instant) {
        let window = self.rate_window;
        while let Some(&front) = self.ack_times.front() {
            if now.duration_since(front) > window {
                self.ack_times.pop_front();
            } else {
                break;
            }
        }
        while let Some(&front) = self.tel_times.front() {
            if now.duration_since(front) > window {
                self.tel_times.pop_front();
            } else {
                break;
            }
        }
    }

    /// 적용 명령 처리율 — 윈도 내 수신한 ACK 수 / 윈도(s). `effective_hz` 등가.
    pub fn effective_hz(&mut self) -> f64 {
        self.trim(Instant::now());
        let ws = self.rate_window.as_secs_f64();
        if ws <= 0.0 {
            return 0.0;
        }
        self.ack_times.len() as f64 / ws
    }

    /// TEL2 수신율 — 윈도 내 수신한 TEL2 수 / 윈도(s).
    pub fn tel_hz(&mut self) -> f64 {
        self.trim(Instant::now());
        let ws = self.rate_window.as_secs_f64();
        if ws <= 0.0 {
            return 0.0;
        }
        self.tel_times.len() as f64 / ws
    }

    pub fn last_rtt_ms(&self) -> Option<f64> {
        self.last_rtt_ms
    }

    /// 누적 RTT raw 샘플(ms) — 보고의 p50/p95 산출용.
    pub fn rtt_samples(&self) -> &[f64] {
        &self.rtt_samples
    }

    pub fn last_ack_seq(&self) -> i64 {
        self.last_ack_seq
    }

    /// 세션 누적 ACK 수 — 평균 eff_hz(= ack_total / 송신 시간) 산출용.
    pub fn ack_total(&self) -> u64 {
        self.ack_total
    }

    /// 세션 누적 TEL2 수 — 평균 TEL2 수신율 산출용.
    pub fn tel_total(&self) -> u64 {
        self.tel_total
    }

    pub fn tx_seq(&self) -> u64 {
        self.seq
    }

    pub fn last_tel(&self) -> Option<&Tel2> {
        self.last_tel.as_ref()
    }

    /// 마지막 ACK 이후 경과 — None 이면 ACK 무수신. 1.5s 폴백 판정에 쓴다.
    pub fn ack_age(&self) -> Option<Duration> {
        self.last_ack_at.map(|t| t.elapsed())
    }

    /// 마지막 TEL2 이후 경과.
    pub fn tel_age(&self) -> Option<Duration> {
        self.last_tel_at.map(|t| t.elapsed())
    }
}

fn resolve(host: &str, port: u16) -> io::Result<SocketAddr> {
    (host, port).to_socket_addrs()?.next().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::AddrNotAvailable,
            format!("주소 해석 실패: {host}:{port}"),
        )
    })
}

/// `host` 로 향할 때 이 호스트가 쓸 소스 IP(패킷은 보내지 않음) — `local_ip_toward`.
/// connected UDP 는 egress 인터페이스만 결정하고 getsockname 이 로봇이 볼 소스
/// 주소를 알려준다 — 업링크 파일에 담아야 TEL2 가 돌아온다. 실패 시 loopback.
pub fn local_ip_toward(host: &str) -> String {
    (|| -> io::Result<String> {
        let probe = UdpSocket::bind(("0.0.0.0", 0))?;
        probe.connect((host, 9))?;
        Ok(probe.local_addr()?.ip().to_string())
    })()
    .unwrap_or_else(|_| "127.0.0.1".to_string())
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

    /// 로컬 루프백 소켓 페어로 송수신·RTT·도달율을 검증한다(로봇 없이).
    fn make_transport_to(server: &UdpSocket) -> UdpControlTransport {
        let port = server.local_addr().unwrap().port();
        UdpControlTransport::new("127.0.0.1", port, port, "testtoken1234567".into()).unwrap()
    }

    #[test]
    fn send_command_increments_seq_and_lands() {
        let server = UdpSocket::bind(("127.0.0.1", 0)).unwrap();
        server.set_nonblocking(true).unwrap();
        let mut tx = make_transport_to(&server);
        let s1 = tx.send_command("id1 0 0.00 0.00 0.00 600 40 13 1.0 0 2 0.00 0.00 0");
        let s2 = tx.send_command("id2 0 0.00 0.00 0.00 600 40 13 1.0 0 2 0.00 0.00 0");
        assert_eq!((s1, s2), (1, 2));
        // 서버가 DFCMD 두 개를 받는다.
        let mut buf = [0u8; 2048];
        std::thread::sleep(Duration::from_millis(20));
        let (n, from) = server.recv_from(&mut buf).unwrap();
        assert!(buf[..n].starts_with(b"DFCMD testtoken1234567 1 "));
        // 서버가 ACK 로 회신 → RTT 계산 + eff_hz 증가.
        server.send_to(b"ACK 1 12345", from).unwrap();
        std::thread::sleep(Duration::from_millis(10));
        tx.pump();
        assert_eq!(tx.last_ack_seq(), 1);
        assert!(tx.last_rtt_ms().is_some());
        assert!(tx.effective_hz() > 0.0);
    }

    #[test]
    fn pump_parses_tel2_and_counts_rate() {
        let server = UdpSocket::bind(("127.0.0.1", 0)).unwrap();
        let mut tx = make_transport_to(&server);
        // 우리 소켓의 주소로 TEL2 를 보내야 받는다 — uplink 로 광고할 IP:port.
        let our: SocketAddr = format!("127.0.0.1:{}", tx.local_port).parse().unwrap();
        let line = b"TEL2 1000 7 0 0.00 0.00 0.00 600.00 512 512 512 512 512 700 - - -1 - 0 file 5";
        server.send_to(line, our).unwrap();
        std::thread::sleep(Duration::from_millis(10));
        let tel = tx.pump();
        assert!(tel.is_some(), "TEL2 파싱 성공");
        assert_eq!(tel.unwrap().active_source, "file");
        assert!(tx.tel_hz() > 0.0);
        assert!(tx.tel_age().is_some());
    }

    #[test]
    fn estop_immediate_datagram_lands() {
        let server = UdpSocket::bind(("127.0.0.1", 0)).unwrap();
        server.set_nonblocking(true).unwrap();
        let tx = make_transport_to(&server);
        tx.send_estop().unwrap();
        std::thread::sleep(Duration::from_millis(20));
        let mut buf = [0u8; 2048];
        let (n, _) = server.recv_from(&mut buf).unwrap();
        assert!(buf[..n].starts_with(b"DF-ESTOP v1 testtoken1234567 "));
    }

    #[test]
    fn uplink_value_has_ip_and_port() {
        let server = UdpSocket::bind(("127.0.0.1", 0)).unwrap();
        let tx = make_transport_to(&server);
        let up = tx.uplink_value();
        assert!(up.contains(':'), "ip:port 형식 ({up})");
    }
}
