//! SSH 세션 — `ssh_control_client.py::ssh_args/_atomic_write` 의 Rust 포팅.
//!
//! **subprocess-ssh** 방식(ssh2 네이티브 라이브러리 미사용): 시스템 `ssh`(Win10+
//! ssh.exe / Unix /usr/bin/ssh)에 레거시 +ssh-rsa 플래그를 그대로 넘긴다. 이로써
//! OpenSSH 5.9 협상 리스크를 회피하고(검증된 Switch 경로와 동일), df-wire 외 외부
//! 크레이트 의존이 없다. (네이티브 ssh2/russh 는 W1 실기에서 성능 필요 시 분기.)

use std::io;
use std::process::{Command, Stdio};

// ── 로봇측 파일 경로 (WalkLabBrokerage 와 계약) ─────────────────────────────
/// §G.1 핸드셰이크 채널 파일.
pub const CHANNEL_PATH: &str = "/tmp/df-walklab-channel";
/// §7-5 업링크 등록 파일 ("ip:port").
pub const UPLINK_PATH: &str = "/tmp/df-walklab-uplink";
/// §C 명령 파일 폴백 (5Hz).
pub const CMD_PATH: &str = "/tmp/df-walklab-cmd";
/// §G.2 E-STOP 플래그 파일 (SSH 병행 경로).
pub const ESTOP_PATH: &str = "/tmp/df-walklab-estop";
/// 브로커리지 모드 파일 (walklab 진입 확인).
pub const PILOT_MODE_PATH: &str = "/tmp/df-pilot-mode";

/// §7-5 업링크 본문 — `"<ip> <port>\n"` **공백 구분**(로봇 `fscanf("%63s %d")` 계약).
///
/// 검증된 Mac(`RobotSetupCommand.walkLabWriteUplink`)·실기 벤치(`onboard-bench.py`)와 동일.
/// 콜론(`ip:port`)은 df_udp.py 참조의 미발견 버그이므로 따르지 않는다(H4).
pub fn uplink_value(ip: &str, port: u16) -> String {
    format!("{ip} {port}\n")
}

/// §7-7 철회 명령 — 채널·업링크·명령 파일 일괄 제거(멱등 `rm -f`). 스테일 잔재 금지(H2).
///
/// **`ESTOP_PATH` 는 의도적으로 제외**한다: E-STOP 플래그는 안전 래치이므로 세션 종료가
/// 이를 지우면 비상정지된 로봇을 조용히 재무장하는 셈(위험). 해제는 명시적 복구(Y)/재무장
/// 경로의 몫이다(계약 §B). 여기에 추가하지 말 것.
pub fn retract_command() -> String {
    format!("rm -f {CHANNEL_PATH} {UPLINK_PATH} {CMD_PATH}")
}

/// `ssh_control_client.py::ssh_args` 1:1 포팅 — 옵션 순서까지 동일(계약).
///
/// `identity`/`control_path` 가 모두 있을 때만 ControlMaster 블록을 낸다(핸드셰이크
/// 재사용 → 5Hz 폴백 지연 감소). Windows OpenSSH 는 ControlMaster 미지원이므로
/// 클라이언트가 `control_path=None` 으로 끌 수 있다(레거시 +ssh-rsa·identity 는 유지).
pub fn ssh_args(
    host: &str,
    user: &str,
    command: &str,
    identity: Option<&str>,
    control_path: Option<&str>,
    timeout_s: u32,
    port: u16,
) -> Vec<String> {
    let connect_timeout = timeout_s.min(10);
    let mut args: Vec<String> = vec![
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
    if let (Some(_), Some(cp)) = (identity, control_path) {
        args.extend([
            "-o".into(),
            "ControlMaster=auto".into(),
            "-o".into(),
            format!("ControlPath={cp}"),
            "-o".into(),
            "ControlPersist=30".into(),
        ]);
    }
    // 레거시 OpenSSH 5.9 호환 — 로봇 필수, 현대 ssh 에 무해.
    args.extend([
        "-o".into(),
        "PubkeyAcceptedAlgorithms=+ssh-rsa".into(),
        "-o".into(),
        "HostKeyAlgorithms=+ssh-rsa".into(),
    ]);
    if let Some(id) = identity {
        args.extend([
            "-i".into(),
            id.to_string(),
            "-o".into(),
            "IdentitiesOnly=yes".into(),
        ]);
    }
    args.extend(["-p".into(), port.to_string()]);
    args.push(format!("{user}@{host}"));
    args.push(command.to_string());
    args
}

/// 로봇 SSH 세션(subprocess). 명령 실행·원자 파일 기록을 캡슐화한다.
#[derive(Debug, Clone)]
pub struct SshClient {
    pub host: String,
    pub user: String,
    pub port: u16,
    pub identity: Option<String>,
    pub control_path: Option<String>,
    pub timeout_s: u32,
}

impl SshClient {
    /// 기본 세션. control_path 는 Unix 기본 `/tmp/df-cm-ally-{pid}-%C`, Windows 는
    /// None(ControlMaster off — Windows OpenSSH 미지원, 의도적 분기).
    ///
    /// pid 포함은 동시 실행/타 프로세스와의 ControlMaster 소켓 충돌 방지(df_udp.py
    /// 가 uid 를 넣은 것과 동일 취지 — 외부 크레이트 없이 pid 로 분리). 단일 프로세스
    /// 내 핸드셰이크·업링크·5Hz 폴백 ssh 호출은 같은 소켓을 재사용(ControlPersist=30).
    pub fn new(host: impl Into<String>, identity: Option<String>) -> Self {
        let control_path = if cfg!(windows) {
            None
        } else {
            Some(format!("/tmp/df-cm-ally-{}-%C", std::process::id()))
        };
        SshClient {
            host: host.into(),
            user: crate::ROBOT_USER.to_string(),
            port: 22,
            identity,
            control_path,
            timeout_s: 6,
        }
    }

    fn args(&self, command: &str) -> Vec<String> {
        ssh_args(
            &self.host,
            &self.user,
            command,
            self.identity.as_deref(),
            self.control_path.as_deref(),
            self.timeout_s,
            self.port,
        )
    }

    /// 원격 명령 실행(표준입력 없음). 종료코드 0 → Ok(stdout).
    pub fn run(&self, command: &str) -> io::Result<String> {
        self.run_with_stdin(command, None)
    }

    /// 원격 명령 실행 + 선택적 stdin(원자 파일 기록용).
    pub fn run_with_stdin(&self, command: &str, stdin: Option<&str>) -> io::Result<String> {
        let mut child = Command::new("ssh")
            .args(self.args(command))
            .stdin(if stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        if let Some(body) = stdin {
            use std::io::Write;
            if let Some(mut sin) = child.stdin.take() {
                sin.write_all(body.as_bytes())?;
                // drop(sin) → EOF.
            }
        }
        let out = child.wait_with_output()?;
        if out.status.success() {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        } else {
            Err(io::Error::other(format!(
                "ssh exit {}: {}",
                out.status.code().unwrap_or(-1),
                String::from_utf8_lossy(&out.stderr).trim()
            )))
        }
    }

    /// 원자 기록: `cat > tmp && mv -f tmp dst` (stdin 으로 body). 부분 기록 노출 방지.
    ///
    /// **안전 계약**: `dst` 는 공백·셸 메타문자 없는 고정 경로여야 한다(현재 호출부는
    /// 전부 `/tmp/df-walklab-*` 상수 — 주입 위험 0). 동적/외부 입력 경로를 받게 되면
    /// 셸 인용(shlex 등)을 추가할 것 — 지금은 의도적으로 의존성 없이 둔다.
    pub fn atomic_write(&self, dst: &str, body: &str) -> io::Result<()> {
        let tmp = format!("{dst}.tmp");
        let cmd = format!("cat > {tmp} && mv -f {tmp} {dst}");
        self.run_with_stdin(&cmd, Some(body)).map(|_| ())
    }

    /// §7-3 브로커리지 모드 확인 — `cat /tmp/df-pilot-mode` (트림).
    pub fn pilot_mode(&self) -> io::Result<String> {
        Ok(self
            .run(&format!("cat {PILOT_MODE_PATH} 2>/dev/null || true"))?
            .trim()
            .to_string())
    }

    /// §7-4 핸드셰이크: 토큰+포트를 채널 파일에 원자 기록. 로봇 RefreshHandshake 가 ≤1s 채택.
    pub fn write_handshake(&self, token: &str, estop_port: u16, cmd_port: u16) -> io::Result<()> {
        self.atomic_write(
            CHANNEL_PATH,
            &df_wire::handshake_line(token, estop_port, cmd_port),
        )
    }

    /// §7-5 업링크 등록 — `"<ip> <port>\n"` 공백 구분([`uplink_value`]).
    ///
    /// **포맷 정정(H4)**: 로봇 `RefreshUplinkTarget` 은 `fscanf("%63s %d")` 로 공백 2토큰을
    /// 기대한다. 콜론(`ip:port`)이면 `%63s` 가 콜론까지 먹어 포트 파싱이 실패 → TEL2 UDP
    /// push 미작동(파일 폴백에 가려짐). 검증된 Mac/onboard-bench 와 동일하게 공백으로 쓴다.
    pub fn write_uplink(&self, ip: &str, port: u16) -> io::Result<()> {
        self.atomic_write(UPLINK_PATH, &uplink_value(ip, port))
    }

    /// §7-6 폴백: 14-token 명령 라인을 명령 파일에 원자 기록(5Hz).
    pub fn write_cmd_file(&self, line: &str) -> io::Result<()> {
        self.atomic_write(CMD_PATH, line)
    }

    /// §G.2 E-STOP 병행 경로: 플래그 파일 touch.
    pub fn touch_estop(&self) -> io::Result<()> {
        self.run(&format!("touch {ESTOP_PATH}")).map(|_| ())
    }

    /// §7-7 종료: 채널·업링크·명령 파일 일괄 제거 — 스테일 토큰/타깃 금지(계약 §G.1 MUST).
    ///
    /// **누수 정정(H2)**: 채널만 지우면 `df-walklab-uplink`(이전 운영자 IP)·`df-walklab-cmd`
    /// (폴백 잔재)가 남아 다음 세션을 오염시킨다. 검증된 참조(ssh_control_client.py)는 채널+
    /// 업링크를 함께 지운다 — 여기에 폴백 명령 파일까지 정리한다([`retract_command`]).
    pub fn retract_handshake(&self) -> io::Result<()> {
        self.run(&retract_command()).map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_args_order_matches_switch_reference() {
        // ssh_control_client.py::ssh_args 와 옵션·순서 1:1.
        let a = ssh_args(
            "192.168.123.1",
            "robotis",
            "echo hi",
            Some("/home/rog/.ssh/id_rsa_darwin"),
            Some("/tmp/df-cm-ally-%C"),
            6,
            22,
        );
        let joined = a.join(" ");
        assert_eq!(
            joined,
            "-o BatchMode=yes \
             -o StrictHostKeyChecking=accept-new \
             -o LogLevel=ERROR \
             -o ConnectTimeout=6 \
             -o ServerAliveInterval=2 \
             -o ServerAliveCountMax=2 \
             -o ControlMaster=auto \
             -o ControlPath=/tmp/df-cm-ally-%C \
             -o ControlPersist=30 \
             -o PubkeyAcceptedAlgorithms=+ssh-rsa \
             -o HostKeyAlgorithms=+ssh-rsa \
             -i /home/rog/.ssh/id_rsa_darwin -o IdentitiesOnly=yes \
             -p 22 robotis@192.168.123.1 echo hi"
        );
    }

    #[test]
    fn ssh_args_clamps_timeout_to_10() {
        let a = ssh_args("h", "u", "c", None, None, 99, 22);
        assert!(a
            .windows(2)
            .any(|w| w[0] == "-o" && w[1] == "ConnectTimeout=10"));
    }

    #[test]
    fn ssh_args_no_controlmaster_without_control_path() {
        // identity 있어도 control_path None 이면 ControlMaster 블록 생략(Windows).
        let a = ssh_args("h", "u", "c", Some("/k"), None, 6, 22);
        assert!(!a.iter().any(|s| s.starts_with("ControlMaster")));
        // 레거시 호환·identity 는 유지.
        assert!(a.iter().any(|s| s == "PubkeyAcceptedAlgorithms=+ssh-rsa"));
        assert!(a.windows(2).any(|w| w[0] == "-i" && w[1] == "/k"));
    }

    #[test]
    fn ssh_args_no_identity_skips_identity_block() {
        let a = ssh_args("h", "u", "c", None, Some("/cp"), 6, 2222);
        assert!(!a.iter().any(|s| s == "-i"));
        assert!(!a.iter().any(|s| s.starts_with("ControlMaster"))); // identity 없으면 CM 도 없음
        assert!(a.windows(2).any(|w| w[0] == "-p" && w[1] == "2222"));
    }

    #[test]
    fn uplink_value_is_space_separated_with_newline() {
        // 로봇 fscanf("%63s %d") 계약 — 공백 구분, 콜론 금지(H4).
        assert_eq!(uplink_value("192.168.0.33", 54321), "192.168.0.33 54321\n");
        assert!(!uplink_value("10.0.0.1", 1).contains(':'));
    }

    #[test]
    fn retract_command_clears_all_session_files() {
        // 채널만이 아니라 업링크·명령 파일까지 일괄 정리(H2).
        let cmd = retract_command();
        assert!(cmd.starts_with("rm -f "));
        assert!(cmd.contains(CHANNEL_PATH));
        assert!(cmd.contains(UPLINK_PATH));
        assert!(cmd.contains(CMD_PATH));
    }

    #[test]
    fn client_default_control_path_per_platform() {
        let c = SshClient::new("192.168.0.33", Some("/k".into()));
        if cfg!(windows) {
            assert_eq!(c.control_path, None);
        } else {
            let cp = c.control_path.as_deref().unwrap();
            assert!(cp.starts_with("/tmp/df-cm-ally-")); // pid 분리
            assert!(cp.ends_with("-%C"));
        }
        assert_eq!(c.user, "robotis");
    }
}
