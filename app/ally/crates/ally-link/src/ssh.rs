//! SSH 세션 — 시스템 `ssh.exe` 서브프로세스 백엔드 (사용자 결정 2026-06-13).
//!
//! 검증된 단일 출처 `ssh_control_client.py::ssh_args` 를 옵션·순서까지 그대로
//! 미러한다: OpenSSH 5.9 레거시 `+ssh-rsa`(PubkeyAccepted/HostKey) · RSA identity ·
//! ControlMaster 재사용. 라이브러리(libssh2/russh) 대신 서브프로세스를 쓰는 이유 =
//! 빌드 신뢰성(C 의존 0) + 그 레거시 협상을 ssh.exe 가 이미 처리(03 §9 최우선 리스크).
//!
//! [`RobotShell`] 트레잇이 와이어 프로토콜(핸드셰이크·업링크·estop·파일 폴백)을
//! `run`/`atomic_write` 위의 기본 메서드로 올려, 목 셸로 세션 상태머신을 로봇
//! 없이 단위 검증할 수 있게 한다. [`SshShell`] 이 실제 서브프로세스 구현이다.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use df_wire::handshake_line;

// 로봇측 파일 경로 — 브로커리지 계약 고정(ssh_control_client.py 와 동일).
pub const CMD_PATH: &str = "/tmp/df-walklab-cmd";
pub const CMD_TMP_PATH: &str = "/tmp/df-walklab-cmd.tmp";
pub const ESTOP_PATH: &str = "/tmp/df-walklab-estop";
pub const CHANNEL_PATH: &str = "/tmp/df-walklab-channel";
pub const CHANNEL_TMP_PATH: &str = "/tmp/df-walklab-channel.tmp";
pub const UPLINK_PATH: &str = "/tmp/df-walklab-uplink";
pub const UPLINK_TMP_PATH: &str = "/tmp/df-walklab-uplink.tmp";
pub const PILOT_MODE_PATH: &str = "/tmp/df-pilot-mode";

/// 기본 RSA 키 경로(로봇은 OpenSSH 5.9 — ed25519 불가). `~` 는 %USERPROFILE% 로 확장.
pub const DEFAULT_IDENTITY: &str = "~/.ssh/id_rsa_darwin";

/// 한 ssh 호출의 결과 — 제어 루프에 패닉을 던지지 않는다(falsy 로 표면화).
#[derive(Debug, Clone)]
pub struct ShellResult {
    /// 종료 코드(None = 스폰 실패/타임아웃/시그널). ssh 의 255 = 전송 계층 실패.
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

impl ShellResult {
    fn spawn_failure(msg: String) -> Self {
        ShellResult {
            code: None,
            stdout: String::new(),
            stderr: msg,
            timed_out: false,
        }
    }

    /// 원격 명령이 exit 0 으로 끝났는가(원격 비0 ≠ 전송 실패).
    pub fn success(&self) -> bool {
        self.code == Some(0)
    }

    /// ssh 전송 계층 실패(255) 또는 스폰 실패/타임아웃 — 재접속 필요 신호.
    pub fn transport_failed(&self) -> bool {
        self.timed_out || self.code.is_none() || self.code == Some(255)
    }

    pub fn stdout_trimmed(&self) -> &str {
        self.stdout.trim()
    }
}

/// 로봇 셸 추상 — `run`/`atomic_write` 만 구현하면 와이어 프로토콜이 따라온다.
pub trait RobotShell {
    /// 명령 1개 실행(하드 타임아웃, 패닉 없음). `input` 은 stdin 으로 흘려보낸다.
    fn run(&self, command: &str, input: Option<&[u8]>) -> ShellResult;

    /// 원자적 temp+mv 쓰기 — stdin → tmp, 성공 시 dst 로 rename(브로커리지 패턴).
    fn atomic_write(&self, tmp: &str, dst: &str, body: &str) -> bool {
        let cmd = format!("cat > {tmp} && mv -f {tmp} {dst}");
        self.run(&cmd, Some(body.as_bytes())).success()
    }

    /// 도달성 확인 — `echo ok`(identity 있으면 ControlMaster 워밍업 겸함).
    fn verify_reachable(&self) -> bool {
        self.run("echo ok", None).stdout_trimmed() == "ok"
    }

    /// §G.1 핸드셰이크 기록 — `/tmp/df-walklab-channel` "TOKEN estop cmd\n".
    fn write_handshake(&self, token: &str, estop_port: u16, cmd_port: u16) -> bool {
        let body = handshake_line(token, estop_port, cmd_port);
        self.atomic_write(CHANNEL_TMP_PATH, CHANNEL_PATH, &body)
    }

    /// 업링크 등록 — `/tmp/df-walklab-uplink` "ip:port\n"(TEL2 회신 주소).
    fn write_uplink(&self, ip_port: &str) -> bool {
        self.atomic_write(UPLINK_TMP_PATH, UPLINK_PATH, &format!("{ip_port}\n"))
    }

    /// E-STOP 병행 경로 — flag 파일 touch(§B, 존재 = STOP). UDP ×3연발과 동시.
    fn touch_estop(&self) -> bool {
        self.run(&format!("touch {ESTOP_PATH}"), None).success()
    }

    /// 복구 — estop flag 제거(재무장 허용). Y 복구 경로(§B REMOVER).
    fn clear_estop(&self) -> bool {
        self.run(&format!("rm -f {ESTOP_PATH}"), None).success()
    }

    /// SSH 파일 폴백 — `/tmp/df-walklab-cmd` 에 14-token 라인 원자 기록(영구 보존 INV-3).
    fn write_command_file(&self, line: &str) -> bool {
        self.atomic_write(CMD_TMP_PATH, CMD_PATH, line)
    }

    /// 세션 종료 — 핸드셰이크·업링크 제거(스테일 토큰 금지 §G.1, 타 세션 UDP 즉사 방지).
    fn clear_handshake(&self) -> bool {
        self.run(&format!("rm -f {CHANNEL_PATH} {UPLINK_PATH}"), None)
            .success()
    }
}

/// SSH 접속 설정 — `ssh_control_client.py` cfg 미러.
#[derive(Debug, Clone)]
pub struct SshConfig {
    pub host: String,
    pub user: String,
    pub port: u16,
    /// RSA identity 경로(없으면 ControlMaster·`-i` 생략 — 에이전트/기본키 의존).
    pub identity: Option<PathBuf>,
    pub timeout: Duration,
    /// ControlMaster 멀티플렉싱 사용 — 5Hz 폴백의 핸드셰이크 비용을 줄인다.
    /// Win32-OpenSSH 버전에 따라 미지원일 수 있어 게이트에서 토글 가능(03 §9).
    pub multiplex: bool,
    /// ssh 바이너리(기본 "ssh" — PATH 의 Win32-OpenSSH).
    pub ssh_bin: String,
}

impl SshConfig {
    /// 유선 기본(192.168.123.1 · robotis · 기본 RSA 키가 있으면 채택).
    pub fn wired() -> Self {
        SshConfig {
            host: crate::WIRED_HOST.to_string(),
            user: crate::ROBOT_USER.to_string(),
            port: 22,
            identity: resolve_identity(DEFAULT_IDENTITY),
            timeout: Duration::from_secs(6),
            multiplex: true,
            ssh_bin: "ssh".to_string(),
        }
    }

    /// 무선(192.168.0.33) — W2 경로. 나머지는 동일.
    pub fn wireless() -> Self {
        SshConfig {
            host: crate::WIRELESS_HOST.to_string(),
            ..Self::wired()
        }
    }
}

/// ssh 인자 벡터 조립 — `ssh_control_client.py::ssh_args` 옵션·순서 미러(순수·테스트용).
///
/// BatchMode/accept-new/LogLevel/ConnectTimeout/ServerAlive → (identity 있을 때)
/// ControlMaster → 레거시 `+ssh-rsa` → identity/IdentitiesOnly → `-p` → user@host → command.
pub fn ssh_args(cfg: &SshConfig, command: &str) -> Vec<String> {
    let connect_timeout = cfg.timeout.as_secs().clamp(1, 10);
    let mut a: Vec<String> = vec![
        "-o".into(),
        "BatchMode=yes".into(),
        "-o".into(),
        "StrictHostKeyChecking=accept-new".into(),
        "-o".into(),
        "LogLevel=ERROR".into(),
        "-o".into(),
        format!("ConnectTimeout={connect_timeout}"),
        "-o".into(),
        "ServerAliveInterval=2".into(),
        "-o".into(),
        "ServerAliveCountMax=2".into(),
    ];
    if cfg.identity.is_some() && cfg.multiplex {
        // ControlMaster 는 핸드셰이크를 호스트당 1회로 재사용 — identity(=~/.ssh 보장)일 때만.
        a.extend([
            "-o".into(),
            "ControlMaster=auto".into(),
            "-o".into(),
            format!("ControlPath={}", control_path()),
            "-o".into(),
            "ControlPersist=30".into(),
        ]);
    }
    // OpenSSH 5.9 레거시 호환 — 로봇 필수, 현대 서버엔 무해.
    a.extend([
        "-o".into(),
        "PubkeyAcceptedAlgorithms=+ssh-rsa".into(),
        "-o".into(),
        "HostKeyAlgorithms=+ssh-rsa".into(),
    ]);
    if let Some(id) = &cfg.identity {
        a.extend([
            "-i".into(),
            id.to_string_lossy().into_owned(),
            "-o".into(),
            "IdentitiesOnly=yes".into(),
        ]);
    }
    a.extend(["-p".into(), cfg.port.to_string()]);
    a.push(format!("{}@{}", cfg.user, cfg.host));
    a.push(command.to_string());
    a
}

/// 시스템 ssh.exe 서브프로세스 셸.
#[derive(Clone)]
pub struct SshShell {
    cfg: SshConfig,
}

impl SshShell {
    pub fn new(cfg: SshConfig) -> Self {
        SshShell { cfg }
    }

    pub fn config(&self) -> &SshConfig {
        &self.cfg
    }

    /// ControlMaster 소켓 정리(`ssh -O exit`) — 세션 종료 시 best-effort.
    pub fn close_master(&self) {
        if self.cfg.identity.is_none() || !self.cfg.multiplex {
            return;
        }
        let args = vec![
            "-o".to_string(),
            format!("ControlPath={}", control_path()),
            "-p".to_string(),
            self.cfg.port.to_string(),
            "-O".to_string(),
            "exit".to_string(),
            format!("{}@{}", self.cfg.user, self.cfg.host),
        ];
        let _ = Command::new(&self.cfg.ssh_bin).args(&args).output();
    }
}

impl RobotShell for SshShell {
    fn run(&self, command: &str, input: Option<&[u8]>) -> ShellResult {
        let args = ssh_args(&self.cfg, command);
        run_subprocess(&self.cfg.ssh_bin, &args, input, self.cfg.timeout)
    }
}

/// 서브프로세스 실행 + 하드 타임아웃(패닉·블록 없음). 타임아웃 시 child kill.
fn run_subprocess(
    bin: &str,
    args: &[String],
    input: Option<&[u8]>,
    timeout: Duration,
) -> ShellResult {
    use std::io::Write;

    let mut cmd = Command::new(bin);
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return ShellResult::spawn_failure(format!("ssh 스폰 실패: {e}")),
    };
    if let Some(data) = input {
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(data);
            // drop(stdin) → EOF.
        }
    } else {
        drop(child.stdin.take());
    }

    match wait_timeout::ChildExt::wait_timeout(&mut child, timeout) {
        Ok(Some(status)) => {
            let out = child.wait_with_output();
            let (stdout, stderr) = out
                .map(|o| {
                    (
                        String::from_utf8_lossy(&o.stdout).into_owned(),
                        String::from_utf8_lossy(&o.stderr).into_owned(),
                    )
                })
                .unwrap_or_default();
            ShellResult {
                code: status.code(),
                stdout,
                stderr,
                timed_out: false,
            }
        }
        Ok(None) => {
            // 타임아웃 — child kill 후 실패로 보고.
            let _ = child.kill();
            let _ = child.wait();
            ShellResult {
                code: None,
                stdout: String::new(),
                stderr: format!("ssh 타임아웃 ({:?})", timeout),
                timed_out: true,
            }
        }
        Err(e) => {
            let _ = child.kill();
            ShellResult::spawn_failure(format!("ssh wait 실패: {e}"))
        }
    }
}

/// ControlMaster 소켓 경로 — %TEMP%\df-cm-%C (%C 는 ssh 가 host/port/user 로 확장).
fn control_path() -> String {
    let base = std::env::var("TEMP")
        .or_else(|_| std::env::var("TMP"))
        .unwrap_or_else(|_| "/tmp".to_string());
    format!("{base}\\df-cm-%C")
}

/// identity 경로 해석 — `~` 확장 후 존재할 때만 Some(없으면 에이전트/기본키 폴백).
fn resolve_identity(raw: &str) -> Option<PathBuf> {
    let expanded = if let Some(rest) = raw.strip_prefix("~/").or_else(|| raw.strip_prefix("~\\")) {
        let home = std::env::var("USERPROFILE")
            .or_else(|_| std::env::var("HOME"))
            .ok()?;
        PathBuf::from(home).join(rest)
    } else {
        PathBuf::from(raw)
    };
    expanded.exists().then_some(expanded)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn ssh_args_mirror_legacy_options() {
        let cfg = SshConfig {
            host: "192.168.123.1".into(),
            user: "robotis".into(),
            port: 22,
            identity: None,
            timeout: Duration::from_secs(6),
            multiplex: true,
            ssh_bin: "ssh".into(),
        };
        let a = ssh_args(&cfg, "echo ok");
        // 레거시 +ssh-rsa 가 양쪽(Pubkey·HostKey) 다 있어야 OpenSSH 5.9 협상.
        assert!(a
            .windows(2)
            .any(|w| w == ["-o", "PubkeyAcceptedAlgorithms=+ssh-rsa"]));
        assert!(a
            .windows(2)
            .any(|w| w == ["-o", "HostKeyAlgorithms=+ssh-rsa"]));
        // identity 없으면 ControlMaster·-i 생략.
        assert!(!a.iter().any(|s| s == "ControlMaster=auto"));
        assert!(!a.iter().any(|s| s == "-i"));
        // user@host 다음에 command 가 마지막.
        assert_eq!(a[a.len() - 2], "robotis@192.168.123.1");
        assert_eq!(a[a.len() - 1], "echo ok");
        // ConnectTimeout 은 10 으로 클램프.
        assert!(a.iter().any(|s| s == "ConnectTimeout=6"));
    }

    #[test]
    fn ssh_args_with_identity_adds_controlmaster_and_key() {
        let cfg = SshConfig {
            host: "h".into(),
            user: "robotis".into(),
            port: 2222,
            identity: Some(PathBuf::from("C:\\keys\\id_rsa")),
            timeout: Duration::from_secs(30),
            multiplex: true,
            ssh_bin: "ssh".into(),
        };
        let a = ssh_args(&cfg, "touch /tmp/x");
        assert!(a.iter().any(|s| s == "ControlMaster=auto"));
        assert!(a.windows(2).any(|w| w == ["-i", "C:\\keys\\id_rsa"]));
        assert!(a.iter().any(|s| s == "IdentitiesOnly=yes"));
        assert!(a.windows(2).any(|w| w == ["-p", "2222"]));
        // timeout 30 → ConnectTimeout 10 클램프.
        assert!(a.iter().any(|s| s == "ConnectTimeout=10"));
    }

    #[test]
    fn multiplex_off_drops_controlmaster() {
        let cfg = SshConfig {
            multiplex: false,
            identity: Some(PathBuf::from("C:\\k")),
            ..SshConfig::wired()
        };
        let a = ssh_args(&cfg, "x");
        assert!(!a.iter().any(|s| s == "ControlMaster=auto"));
        // identity 는 여전히 -i 로 들어간다.
        assert!(a.iter().any(|s| s == "-i"));
    }

    // ── 와이어 프로토콜 기본 메서드 — 목 셸로 명령 조립 검증(로봇 불요) ──

    #[derive(Default)]
    struct MockShell {
        calls: RefCell<Vec<(String, Option<String>)>>,
    }

    impl RobotShell for MockShell {
        fn run(&self, command: &str, input: Option<&[u8]>) -> ShellResult {
            self.calls.borrow_mut().push((
                command.to_string(),
                input.map(|b| String::from_utf8_lossy(b).into_owned()),
            ));
            ShellResult {
                code: Some(0),
                stdout: "ok".into(),
                stderr: String::new(),
                timed_out: false,
            }
        }
    }

    #[test]
    fn handshake_writes_pinned_body_atomically() {
        let m = MockShell::default();
        assert!(m.write_handshake("tok1234567890abcd", 17372, 17374));
        let calls = m.calls.borrow();
        let (cmd, input) = &calls[0];
        assert_eq!(cmd, "cat > /tmp/df-walklab-channel.tmp && mv -f /tmp/df-walklab-channel.tmp /tmp/df-walklab-channel");
        assert_eq!(input.as_deref(), Some("tok1234567890abcd 17372 17374\n"));
    }

    #[test]
    fn uplink_and_estop_and_fallback_paths() {
        let m = MockShell::default();
        assert!(m.write_uplink("192.168.123.50:41000"));
        assert!(m.touch_estop());
        assert!(m.clear_estop());
        assert!(m.write_command_file("id 0 0.00 0.00 0.00 600 40 13 1.0 0 2 0.00 0.00 0"));
        assert!(m.clear_handshake());
        let calls = m.calls.borrow();
        assert_eq!(calls[1].0, "touch /tmp/df-walklab-estop");
        assert_eq!(calls[2].0, "rm -f /tmp/df-walklab-estop");
        assert_eq!(
            calls[3].0,
            "cat > /tmp/df-walklab-cmd.tmp && mv -f /tmp/df-walklab-cmd.tmp /tmp/df-walklab-cmd"
        );
        assert_eq!(
            calls[4].0,
            "rm -f /tmp/df-walklab-channel /tmp/df-walklab-uplink"
        );
        // 업링크 본문에 개행.
        assert_eq!(calls[0].1.as_deref(), Some("192.168.123.50:41000\n"));
    }

    #[test]
    fn shell_result_classification() {
        let ok = ShellResult {
            code: Some(0),
            stdout: "ok".into(),
            stderr: String::new(),
            timed_out: false,
        };
        assert!(ok.success() && !ok.transport_failed());
        let remote_nonzero = ShellResult {
            code: Some(1),
            ..ok.clone()
        };
        assert!(!remote_nonzero.success() && !remote_nonzero.transport_failed());
        let transport = ShellResult {
            code: Some(255),
            ..ok.clone()
        };
        assert!(transport.transport_failed());
        let timeout = ShellResult {
            code: None,
            timed_out: true,
            ..ok.clone()
        };
        assert!(timeout.transport_failed());
    }
}
