//! ally-link — 소켓·세션 계층 (W1 구현 예정).
//!
//! W1 범위 (docs/03_ARCHITECTURE.md §2·§7):
//! - `UdpControlTransport` 포팅 (df_udp.py): 단일 UDP 소켓, DFCMD 송신(seq 단조)
//!   + ACK 수신(RTT EMA α=0.3, effective_hz 1s 윈도) + TEL2 수신
//! - E-STOP 버스트 전용 스레드: `df_wire::ESTOP_BURST_OFFSETS_MS` 0/50/100ms
//!   3연발 + SSH 파일 병행 (먼저 도착한 쪽이 이긴다)
//! - ssh2 세션: 브로커리지 기동(/tmp/df-pilot-mode walklab) → 핸드셰이크
//!   (/tmp/df-walklab-channel) → 업링크 등록(/tmp/df-walklab-uplink) → 파일 폴백
//! - connected-UDP getsockname 트릭으로 업링크 소스 IP 결정 (df_udp.local_ip_toward)
//! - 듀얼 경로: 유선(WIRED_HOST) 우선 프로브, 전환은 세션 재시작(토큰 폐기)

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
/// 주의(RG G01 실기 2026-06-13): 브로커리지는 **한 세션 내 첫 핸드셰이크만 ACK** 하고,
/// teardown 후 재채택 시 UDP 포트는 다시 bind 하나 ACK 를 멈춘다(로봇측 한계 — 프로브
/// 창과 무관, 넓혀도 오지 않는 ACK 를 못 받음). 게이트는 브로커리지 재기동 후 1회 측정.
pub const ACK_PROBE_MS: u64 = 1500;

pub mod session;
pub mod ssh;
pub mod udp;

pub use session::{ControlSession, Dispatch, TransportState};
pub use ssh::{RobotShell, ShellResult, SshConfig, SshShell};
pub use udp::{local_ip_toward, UdpControlTransport};

// 재노출: 송신 계층 사용자는 df-wire 를 직접 의존하지 않아도 된다.
pub use df_wire::{DEFAULT_CMD_PORT, DEFAULT_ESTOP_PORT, DEFAULT_TELEMETRY_PORT};
