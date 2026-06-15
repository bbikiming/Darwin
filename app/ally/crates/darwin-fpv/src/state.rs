//! StateHub — `RwLock<Snapshot>` (§2 채널 규율: RX 스레드 단일 쓰기, 메인·수퍼바이저
//! 읽기). 스냅샷 스키마는 §3 Rust→UI 계약의 Rust측 표현이다. 직렬화(serde)는 Tauri
//! 셸(Phase 3)이 입히고, 여기서는 순수 데이터로 둔다(런타임 라이브러리 dep 최소).

use std::sync::RwLock;

use df_wire::Tel2;

/// 연결 경로 — §3 `conn.path`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ConnPath {
    Wired,
    Wireless,
    #[default]
    None,
}

impl ConnPath {
    pub fn as_str(self) -> &'static str {
        match self {
            ConnPath::Wired => "wired",
            ConnPath::Wireless => "wireless",
            ConnPath::None => "none",
        }
    }
}

/// 활성 명령 경로 — §3 `conn.transport` (ACK 신선도로 UDP↔SSH폴백 결정).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ConnTransport {
    #[default]
    Udp,
    SshFile,
}

impl ConnTransport {
    pub fn as_str(self) -> &'static str {
        match self {
            ConnTransport::Udp => "udp",
            ConnTransport::SshFile => "ssh_file",
        }
    }
}

/// §3 `conn.*` — 경로·전송·RTT·eff_hz.
#[derive(Debug, Clone, Copy, Default)]
pub struct ConnState {
    pub path: ConnPath,
    pub transport: ConnTransport,
    pub rtt_ms: Option<f64>,
    pub eff_hz: f64,
}

/// §3 `safety.*` — ally-input 게이트 상태머신의 표시 투영.
#[derive(Debug, Clone, Copy, Default)]
pub struct SafetySnapshot {
    pub armed: bool,
    pub estop_latched: bool,
    pub recovering: bool,
}

/// §3 `cmd.*` — TX 가 보낸 **명령값**(mm/mm/deg). TEL2 의 `latch_*`(적용값)와 쌍이 되어
/// HUD "명령 vs 적용" 인디케이터를 이룬다. 머리 pan/tilt(deg)는 RS 헤드 레이트 적분값.
#[derive(Debug, Clone, Copy, Default)]
pub struct CmdSnapshot {
    pub x: f64,
    pub y: f64,
    pub a: f64,
    pub head_pan: f64,
    pub head_tilt: f64,
}

/// §3 `pad.*` — 패드 존재·터보.
#[derive(Debug, Clone, Copy, Default)]
pub struct PadSnapshot {
    pub connected: bool,
    pub turbo: bool,
}

/// HUD 한 프레임의 전체 상태 (§3 `state` 이벤트 페이로드의 Rust측 원본).
///
/// `tel` 은 마지막 TEL2 원본을 그대로 보관한다 — §3 의 `tel.*` 필드(x_lat·phase·imu·fsr·
/// cop·voltage…)로의 사상은 Tauri 직렬화(Phase 3)가 수행한다. `tel_ms`(0=미수신)로
/// 신선도(§3 `tel.age_ms`, >1500ms → UI 채도 저하)를 도출한다.
#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub conn: ConnState,
    pub safety: SafetySnapshot,
    pub cmd: CmdSnapshot,
    pub pad: PadSnapshot,
    pub cam_healthy: bool,
    pub tel: Option<Tel2>,
    pub tel_ms: i64,
}

impl Snapshot {
    /// 초기·단절 스냅샷 — 경로 없음, 명령 0, 안전 비무장.
    pub fn disconnected() -> Self {
        Snapshot::default()
    }

    /// 마지막 TEL2 경과(ms). 미수신이면 None — UI 는 "텔레메트리 없음"으로 정직 표기.
    pub fn tel_age_ms(&self, now_ms: i64) -> Option<i64> {
        if self.tel_ms == 0 {
            None
        } else {
            Some((now_ms - self.tel_ms).max(0))
        }
    }

    /// TEL2 1샘플 반영 — 원본 보관 + 수신 시각 갱신.
    pub fn apply_tel2(&mut self, tel: Tel2, now_ms: i64) {
        self.tel = Some(tel);
        self.tel_ms = now_ms;
    }
}

/// 단일 쓰기·다중 읽기 상태 허브 (§2). 쓰기는 짧은 클로저로 잠금을 최소화한다.
#[derive(Default)]
pub struct StateHub {
    inner: RwLock<Snapshot>,
}

impl StateHub {
    pub fn new() -> Self {
        StateHub {
            inner: RwLock::new(Snapshot::disconnected()),
        }
    }

    /// 현재 스냅샷 복제(읽기 잠금 짧게). 표시계층/수퍼바이저용.
    pub fn read(&self) -> Snapshot {
        self.inner.read().expect("StateHub read poisoned").clone()
    }

    /// 짧은 쓰기 클로저(RX 스레드 단일 쓰기). 잠금을 들고 부수효과를 하지 말 것.
    pub fn write(&self, f: impl FnOnce(&mut Snapshot)) {
        let mut g = self.inner.write().expect("StateHub write poisoned");
        f(&mut g);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tel_age_none_until_received() {
        let s = Snapshot::disconnected();
        assert_eq!(s.tel_age_ms(1000), None, "미수신이면 age 없음(정직)");
    }

    #[test]
    fn write_then_read_roundtrips() {
        let hub = StateHub::new();
        hub.write(|s| {
            s.conn.eff_hz = 20.0;
            s.safety.armed = true;
            s.cmd.x = 12.5;
        });
        let s = hub.read();
        assert_eq!(s.conn.eff_hz, 20.0);
        assert!(s.safety.armed);
        assert_eq!(s.cmd.x, 12.5);
    }

    #[test]
    fn tel_age_clamps_nonnegative_and_tracks() {
        let mut s = Snapshot::disconnected();
        // now_ms 가 수신시각보다 과거(시계 역행 방어)여도 음수 age 를 내지 않는다.
        s.tel_ms = 5000;
        assert_eq!(s.tel_age_ms(4000), Some(0));
        assert_eq!(s.tel_age_ms(5300), Some(300));
    }

    #[test]
    fn conn_str_mapping() {
        assert_eq!(ConnPath::Wired.as_str(), "wired");
        assert_eq!(ConnPath::None.as_str(), "none");
        assert_eq!(ConnTransport::SshFile.as_str(), "ssh_file");
    }
}
