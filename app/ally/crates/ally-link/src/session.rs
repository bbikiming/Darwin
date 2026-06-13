//! 제어 세션 — 핸드셰이크 → 프로브 → UDP/파일-폴백 상태머신.
//!
//! `ssh_control_client.py` 의 auto/fallback 상태기계를 Rust 로 옮긴 것:
//! UDP 가 1차(20Hz), SSH 파일이 영구 폴백(5Hz, INV-3). 핸드셰이크를 쓰고 첫 ACK 가
//! 프로브 창(1.5s) 안에 오면 `Udp`, 없으면 핸드셰이크를 철회하고 `Ssh` 파일 경로로
//! 강등한다. 세션 종료 시 핸드셰이크를 제거해 로봇을 파일 폴백으로 되돌린다
//! (스테일 토큰 금지 §G.1 — 타 세션 UDP 즉사 방지).

use std::io;
use std::time::{Duration, Instant};

use df_wire::{build_line, gen_token, GaitConfig, MotionCommand, Tel2};

use crate::ssh::RobotShell;
use crate::udp::UdpControlTransport;
use crate::{ACK_PROBE_MS, DEFAULT_CMD_PORT, DEFAULT_ESTOP_PORT};

/// 활성 명령 전송 경로.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportState {
    /// SSH 파일 폴백만(5Hz) — UDP 없음/강등.
    Ssh,
    /// 핸드셰이크 기록, UDP 송신 중, 첫 ACK 대기.
    Probing,
    /// ACK 확인 — UDP 단독(20Hz).
    Udp,
}

/// 한 명령 송신이 실제로 탄 경로(보고·표시용).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dispatch {
    Udp,
    SshFile,
}

/// 제어 세션 — 셸(SSH) + UDP 전송 + 폴백 상태머신을 묶는다.
pub struct ControlSession<S: RobotShell> {
    shell: S,
    udp: Option<UdpControlTransport>,
    state: TransportState,
    probe_started: Option<Instant>,
    ack_probe: Duration,
    gait: GaitConfig,
}

impl<S: RobotShell> ControlSession<S> {
    /// 세션 개시 — 도달성 확인 → 핸드셰이크/업링크 → UDP 프로브.
    ///
    /// SSH 협상 실패는 Err 로 멈춘다(04 게이트: ssh2↔OpenSSH 5.9 실패 시 분기 결정).
    /// 핸드셰이크 쓰기 실패는 치명이 아니라 파일 폴백(Ssh)으로 시작한다.
    pub fn start(shell: S, host: &str, gait: GaitConfig) -> io::Result<Self> {
        Self::start_with_ports(shell, host, gait, DEFAULT_CMD_PORT, DEFAULT_ESTOP_PORT)
    }

    pub fn start_with_ports(
        shell: S,
        host: &str,
        gait: GaitConfig,
        cmd_port: u16,
        estop_port: u16,
    ) -> io::Result<Self> {
        if !shell.verify_reachable() {
            return Err(io::Error::new(
                io::ErrorKind::ConnectionRefused,
                "SSH 도달성 확인 실패 — OpenSSH 5.9 협상/키/네트워크 점검 (게이트에서 russh/plink 분기 결정)",
            ));
        }

        let token = gen_token();
        let transport = UdpControlTransport::new(host, cmd_port, estop_port, token.clone())?;

        let mut session = ControlSession {
            shell,
            udp: None,
            state: TransportState::Ssh,
            probe_started: None,
            ack_probe: Duration::from_millis(ACK_PROBE_MS),
            gait,
        };

        // 핸드셰이크 + 업링크 기록 → 프로브 진입. 실패 시 파일 폴백으로 시작.
        if session.shell.write_handshake(&token, estop_port, cmd_port) {
            session.shell.write_uplink(&transport.uplink_value());
            session.udp = Some(transport);
            session.state = TransportState::Probing;
            session.probe_started = Some(Instant::now());
        }
        Ok(session)
    }

    pub fn state(&self) -> TransportState {
        self.state
    }

    /// 명령이 UDP 스트림으로 나가는가(udp 또는 probing — 워치독 티어 무장).
    pub fn streaming(&self) -> bool {
        matches!(self.state, TransportState::Udp | TransportState::Probing)
    }

    /// 현재 경로의 송신 케이던스 — UDP(프로브 포함) 20Hz, SSH 파일 5Hz.
    pub fn current_send_hz(&self) -> f64 {
        if self.streaming() {
            crate::UDP_SEND_HZ
        } else {
            crate::SSH_SEND_HZ
        }
    }

    /// 명령 1개 송신 — 경로에 맞게 라우팅. df-wire 가 라인을 직렬화(골든 벡터 검증).
    pub fn send_command(&mut self, cmd: &MotionCommand) -> Dispatch {
        let cmd_id = df_wire::gen_cmd_id();
        let line = build_line(&cmd_id, &self.gait, cmd);
        if self.streaming() {
            if let Some(u) = self.udp.as_mut() {
                u.send_command(&line);
                return Dispatch::Udp;
            }
        }
        // SSH 파일 폴백 — 전체 ssh 왕복(느림). 케이던스는 호출부가 5Hz 로 제한.
        self.shell.write_command_file(&line);
        Dispatch::SshFile
    }

    /// UDP 소켓 서비스 + 상태머신 전진. 이번 사이클 최신 TEL2 를 반환.
    /// Probing → Udp(첫 ACK) / → Ssh(프로브 창 만료, 핸드셰이크 철회).
    pub fn pump(&mut self) -> Option<Tel2> {
        let tel = self.udp.as_mut().and_then(|u| u.pump());
        if self.state == TransportState::Probing {
            let acked = self.udp.as_ref().and_then(|u| u.ack_age()).is_some();
            let expired = self
                .probe_started
                .is_some_and(|t| t.elapsed() >= self.ack_probe);
            if acked {
                self.state = TransportState::Udp;
            } else if expired {
                self.fallback_to_ssh();
            }
        }
        tel
    }

    /// 핸드셰이크 철회 → 로봇 파일-폴백 복귀. UDP 소켓 닫음.
    fn fallback_to_ssh(&mut self) {
        self.udp = None;
        self.state = TransportState::Ssh;
        self.probe_started = None;
        self.shell.clear_handshake();
    }

    /// 복구 — estop flag 제거(재무장 허용). Y 복구 경로.
    pub fn recover(&self) -> bool {
        self.shell.clear_estop()
    }

    /// 전송 메트릭 접근(eff_hz·RTT·TEL2 수신율) — 보고용.
    pub fn transport_mut(&mut self) -> Option<&mut UdpControlTransport> {
        self.udp.as_mut()
    }

    pub fn transport(&self) -> Option<&UdpControlTransport> {
        self.udp.as_ref()
    }

    pub fn shell(&self) -> &S {
        &self.shell
    }

    /// 세션 정리 — 핸드셰이크 제거(스테일 토큰 금지 §G.1). UDP 소켓 닫음.
    pub fn close(&mut self) {
        self.shell.clear_handshake();
        self.udp = None;
        self.state = TransportState::Ssh;
    }
}

impl<S: RobotShell + Clone + Send + 'static> ControlSession<S> {
    /// E-STOP — UDP ×3연발(즉시 동기 발화, INV-1) **+** SSH touch 병행(보조 스레드).
    /// UDP 가 없으면(파일 폴백) SSH touch 만. 호출자를 블록하지 않는다.
    pub fn estop(&self) {
        if let Some(u) = self.udp.as_ref() {
            let _ = u.send_estop(); // offset 0 동기, 50/100ms 보조 스레드
        }
        // SSH flag touch — 느린 왕복이라 별도 스레드(estop 즉시 경로를 블록하지 않음).
        let shell = self.shell.clone();
        std::thread::Builder::new()
            .name("ally-estop-ssh".into())
            .spawn(move || {
                shell.touch_estop();
            })
            .ok();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ssh::ShellResult;
    use std::sync::{Arc, Mutex};

    /// 명령을 기록하는 목 셸 — 도달성/핸드셰이크 결과를 주입한다.
    #[derive(Clone, Default)]
    struct MockShell {
        calls: Arc<Mutex<Vec<String>>>,
        reachable: bool,
        handshake_ok: bool,
    }

    impl RobotShell for MockShell {
        fn run(&self, command: &str, _input: Option<&[u8]>) -> ShellResult {
            self.calls.lock().unwrap().push(command.to_string());
            ShellResult {
                code: Some(0),
                stdout: String::new(),
                stderr: String::new(),
                timed_out: false,
            }
        }
        fn verify_reachable(&self) -> bool {
            self.reachable
        }
        fn write_handshake(&self, _t: &str, _e: u16, _c: u16) -> bool {
            self.calls.lock().unwrap().push("write_handshake".into());
            self.handshake_ok
        }
        fn write_uplink(&self, _v: &str) -> bool {
            self.calls.lock().unwrap().push("write_uplink".into());
            true
        }
        fn clear_handshake(&self) -> bool {
            self.calls.lock().unwrap().push("clear_handshake".into());
            true
        }
    }

    #[test]
    fn unreachable_shell_errors_out() {
        let shell = MockShell {
            reachable: false,
            ..Default::default()
        };
        let r = ControlSession::start(shell, "127.0.0.1", GaitConfig::default());
        assert!(r.is_err(), "도달성 실패 → Err(게이트에서 분기 결정)");
    }

    #[test]
    fn handshake_success_enters_probing() {
        let shell = MockShell {
            reachable: true,
            handshake_ok: true,
            ..Default::default()
        };
        let calls = shell.calls.clone();
        let session = ControlSession::start(shell, "127.0.0.1", GaitConfig::default()).unwrap();
        assert_eq!(session.state(), TransportState::Probing);
        assert!(session.streaming());
        assert!((session.current_send_hz() - crate::UDP_SEND_HZ).abs() < 1e-9);
        let recorded = calls.lock().unwrap();
        assert!(recorded.iter().any(|c| c == "write_handshake"));
        assert!(recorded.iter().any(|c| c == "write_uplink"));
    }

    #[test]
    fn handshake_failure_starts_on_ssh_fallback() {
        let shell = MockShell {
            reachable: true,
            handshake_ok: false,
            ..Default::default()
        };
        let mut session = ControlSession::start(shell, "127.0.0.1", GaitConfig::default()).unwrap();
        assert_eq!(session.state(), TransportState::Ssh);
        assert!(!session.streaming());
        assert!((session.current_send_hz() - crate::SSH_SEND_HZ).abs() < 1e-9);
        // 폴백 상태에서 명령은 SSH 파일로 간다.
        assert_eq!(
            session.send_command(&MotionCommand::zero()),
            Dispatch::SshFile
        );
    }

    #[test]
    fn probe_timeout_demotes_to_ssh_and_clears_handshake() {
        let shell = MockShell {
            reachable: true,
            handshake_ok: true,
            ..Default::default()
        };
        let calls = shell.calls.clone();
        let mut session = ControlSession::start(shell, "127.0.0.1", GaitConfig::default()).unwrap();
        // 프로브 창을 0 으로 강제 — 다음 pump 에서 ACK 없으면 즉시 강등.
        session.ack_probe = Duration::from_millis(0);
        let _ = session.pump();
        assert_eq!(session.state(), TransportState::Ssh);
        assert!(calls.lock().unwrap().iter().any(|c| c == "clear_handshake"));
        // 강등 후 send 는 SSH 파일.
        assert_eq!(
            session.send_command(&MotionCommand::zero()),
            Dispatch::SshFile
        );
    }

    #[test]
    fn close_clears_handshake() {
        let shell = MockShell {
            reachable: true,
            handshake_ok: true,
            ..Default::default()
        };
        let calls = shell.calls.clone();
        let mut session = ControlSession::start(shell, "127.0.0.1", GaitConfig::default()).unwrap();
        session.close();
        assert_eq!(session.state(), TransportState::Ssh);
        assert!(calls.lock().unwrap().iter().any(|c| c == "clear_handshake"));
    }
}
