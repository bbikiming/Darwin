# Claude Prompt: DarwinForge Mac 앱에 Switch→Darwin SSH 연결 세팅 기능 구현

작성 시각: 2026-06-07 15:48 KST  
작성자: Codex  
목적: Claude가 DarwinForge Mac 앱 코드에서 바로 이어서 구현할 수 있도록, 현재 Switch Linux 조종석 구현 상태와 막힌 지점, 그리고 Mac 앱에 추가해야 할 세팅 기능 요구사항을 상세히 전달한다.

---

## 1. 최종 목표

DarwinForge Mac 앱은 현재 로봇 SSH 연결이 성공한다. 이 성공 경로를 이용해, Nintendo Switch Linux 조종석이 로봇에 직접 SSH로 접속하고 조종할 수 있도록 **Mac 앱 안에 “Switch→Darwin 연결 세팅 마법사”**를 구현해 달라.

핵심은 다음이다.

1. Mac DarwinForge 앱은 이미 로봇 `robotis@<robot-ip>`에 SSH로 접속 가능하다.
2. Switch Linux에는 `darwin-switch-robot-ready` CLI와 웹 조종석이 설치되어 있다.
3. Switch에서 `ssh-copy-id robotis@192.168.123.1`을 직접 실행했지만, 비밀번호 프롬프트가 보이지 않고 멈춘 것처럼 보인다.
4. 따라서 DarwinForge Mac 앱이 중계자 역할을 해서:
   - Switch의 로봇용 공개키를 가져오고,
   - Mac 앱의 성공한 로봇 SSH 채널로 로봇의 `~/.ssh/authorized_keys`에 그 공개키를 등록하고,
   - Switch의 robot-ready/probe/status/agent mode 전환까지 순차적으로 도와주는 기능이 필요하다.

---

## 2. 현재 확인된 상태

### 2.1 Switch Linux 상태

Switchroot L4T Ubuntu가 부팅되어 있고 Mac에서 SSH 접속 가능하다.

확인된 명령:

```bash
ssh yuseok@192.168.0.25 'command -v darwin-switch-robot-ready; systemctl is-active darwin-switch-agent; ls -t ~/darwin-switch-install-*.log 2>/dev/null | head -1; darwin-switch-robot-ready plan'
```

출력:

```text
/usr/local/bin/darwin-switch-robot-ready
active
/home/yuseok/darwin-switch-install-20260607-144843.log
Robot SSH target: robotis@192.168.123.1:22
Identity: /home/yuseok/.ssh/id_rsa_darwin
Protocol: DarwinForge parity: BatchMode, accept-new known_hosts, ServerAlive 2x2, +ssh-rsa, ControlMaster when identity exists
Control contract: /tmp/df-pilot-mode=walklab, /tmp/df-walklab-cmd=14-token atomic writes, /tmp/df-walklab-estop=presence stop
Copy key command: ssh-copy-id -o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa -i /home/yuseok/.ssh/id_rsa_darwin.pub -p 22 robotis@192.168.123.1
Final switch command: darwin-switch-robot-ready all
```

Switch에 최신 `darwin-switch-robot-ready`가 있는지 확인:

```bash
ssh yuseok@192.168.0.25 'darwin-switch-robot-ready --help | grep enable-agent-ssh || echo old-version'
```

출력:

```text
{plan,keygen,copy-key,probe,status,start-walklab,enable-agent-ssh,all}
--no-restart          for enable-agent-ssh: update config without restarting
```

현재 agent 설정은 아직 dry-run이다.

```bash
ssh yuseok@192.168.0.25 'grep -n "\"mode\"" /etc/darwin-switch-agent/config.json; systemctl is-active darwin-switch-agent'
```

출력:

```text
2:  "mode": "dry_run",
active
```

즉 Switch 조종석은 설치되어 있고 agent도 active지만, 실제 로봇 조종 모드(`mode=ssh`)로 전환되지는 않았다.

### 2.2 Switch에서 직접 시도한 것

Switch SSH 세션에서 다음을 실행했다.

```bash
darwin-switch-robot-ready copy-key
darwin-switch-robot-ready all
```

출력:

```text
Generating public/private rsa key pair.
Your identification has been saved in /home/yuseok/.ssh/id_rsa_darwin
Your public key has been saved in /home/yuseok/.ssh/id_rsa_darwin.pub
The key fingerprint is:
SHA256:13PmeeD1OuwvFU1pvNdU0+0g2RgXx3wXDUMicF0eKhs darwin-switch-robot
...
+ ssh-copy-id -o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa -i /home/yuseok/.ssh/id_rsa_darwin.pub -p 22 robotis@192.168.123.1
/usr/bin/ssh-copy-id: INFO: Source of key(s) to be installed: "/home/yuseok/.ssh/id_rsa_darwin.pub"
```

문제:

- 여기서 로봇 비밀번호 프롬프트가 보이지 않았다.
- 멈춘 것처럼 보였다.
- 원인은 아직 확정하지 말 것.
  - `192.168.123.1`이 Switch에서 접근 가능한 로봇 IP가 아닐 수 있다.
  - Switch와 로봇이 같은 네트워크가 아닐 수 있다.
  - SSH TCP 연결 단계에서 대기 중일 수 있다.
  - 터미널/프롬프트 표시 문제일 수도 있다.
  - 단순히 비밀번호 입력이 안 보이는 정상 password prompt 상태라고 단정하지 말 것.

### 2.3 DarwinForge Mac 앱 상태

사용자 발언 기준:

- DarwinForge Mac 앱에서는 로봇 연결이 된다.
- 즉 Mac 앱의 `SSHShell` / `RemoteShell` 경로는 로봇에 성공적으로 접근하는 실사용 경로다.

관련 코드:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/SSHShell.swift`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/RemoteShell.swift`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/RobotSetupCommand.swift`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/ConnectionWizard.swift`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/InitialSetupWizard.swift`

DarwinForge의 SSH 성공 옵션:

```text
BatchMode=yes
StrictHostKeyChecking=accept-new
LogLevel=ERROR
ConnectTimeout=<timeout>
ServerAliveInterval=2
ServerAliveCountMax=2
ControlMaster=auto
ControlPath=~/.ssh/df-cm-%C
ControlPersist=30
PubkeyAcceptedAlgorithms=+ssh-rsa
HostKeyAlgorithms=+ssh-rsa
-i ~/.ssh/id_rsa_darwin
IdentitiesOnly=yes
```

이 옵션은 Switch 쪽 Python 구현에도 반영되어 있다.

---

## 3. 현재 Switch 쪽에 구현된 내용

### 3.1 CLI

파일:

- `tools/switch-pilot/src/darwin_switch_agent/robot_ready.py`
- `tools/switch-pilot/bin/darwin-switch-robot-ready`

명령:

```bash
darwin-switch-robot-ready plan
darwin-switch-robot-ready keygen
darwin-switch-robot-ready copy-key
darwin-switch-robot-ready probe
darwin-switch-robot-ready status
darwin-switch-robot-ready start-walklab
darwin-switch-robot-ready enable-agent-ssh
darwin-switch-robot-ready all
```

의도:

- `keygen`: Switch 내부 `/home/yuseok/.ssh/id_rsa_darwin` 생성
- `copy-key`: Switch 공개키를 로봇에 `ssh-copy-id`로 등록
- `probe`: `ssh robotis@<robot>`로 `echo ok` 확인
- `status`: 로봇의 `demo`/`demo-pilot` 바이너리에 `df-walklab-cmd` 문자열이 있는지 확인
- `start-walklab`: 로봇에서 `/tmp/df-pilot-mode=walklab`, `/tmp/df-walklab-cmd` 준비 후 `demo`/`demo-pilot` 실행
- `enable-agent-ssh`: Switch `/etc/darwin-switch-agent/config.json`을 `mode=ssh`로 업데이트하고 `darwin-switch-agent.service` 재시작
- `all`: key/probe/status/start/enable 순서 자동 실행. 단, `copy-key`가 필요하면 사용자에게 명령을 안내하고 중단.

### 3.2 Switch 조종석 웹 UI

파일:

- `tools/switch-pilot/src/darwin_switch_agent/cockpit.py`
- `tools/switch-pilot/web/setup.html`
- `tools/switch-pilot/web/setup.js`
- `tools/switch-pilot/tests/test_cockpit.py`

추가된 UI:

- `/setup.html` 오른쪽 패널에 “로봇 SSH 준비” 섹션 추가
- 버튼:
  - 계획
  - 키 생성
  - SSH 확인
  - 패치 확인
  - WalkLab 시작
  - SSH 모드
  - 전체 준비 실행

API:

```http
POST /api/robot-ready
{ "action": "plan" | "keygen" | "probe" | "status" | "start-walklab" | "enable-agent-ssh" | "all" }
```

주의:

- `copy-key`는 UI API에서 의도적으로 제외했다.
- 이유: `ssh-copy-id`는 로봇 password prompt가 필요할 수 있고, 웹 버튼에서 실행하면 브라우저 요청이 hang될 수 있다.

### 3.3 검증

로컬 검증 통과:

```bash
tools/switch-pilot/verify-release.sh
```

최근 결과:

```text
Python tests: 141 tests OK
Web runtime tests OK
Runtime bundle: 34 required files OK
Package build + checksum OK
Install kit OK
```

시각 검증:

- 1280x720 기준 `/setup.html`에서 “로봇 SSH 준비” 패널이 첫 화면 안에 들어오는 것을 확인.
- 스크린샷:
  - `tmp/setup-robot-ready-1280.png`

---

## 4. 현재 막힌 지점

Switch에서 직접:

```bash
darwin-switch-robot-ready copy-key
```

를 실행하면 `ssh-copy-id`가 source key 메시지까지만 출력하고, 비밀번호 프롬프트가 보이지 않는다.

중요:

- 이 상태를 “비밀번호 입력만 하면 된다”고 단정하지 말 것.
- Switch→Robot 네트워크 경로 자체가 안 열려 있을 가능성이 있다.
- Mac DarwinForge가 로봇에 연결된다는 사실은 Mac→Robot은 성공한다는 뜻이지 Switch→Robot도 같은 IP/경로로 성공한다는 뜻은 아니다.

따라서 DarwinForge Mac 앱에 필요한 기능은 단순히 명령어를 보여주는 수준이 아니라, Mac이 성공한 로봇 연결을 활용해 Switch와 로봇 사이의 SSH 키/주소/설정 문제를 해결하는 세팅 마법사다.

---

## 5. Claude에게 요청할 구현 방향

### 5.1 기능명 제안

DarwinForge Mac 앱에 다음 기능을 추가:

```text
Switch Robot Link Setup
또는
스위치 조종석 연결 세팅
```

위치는 다음 중 적절한 곳:

- `ConnectionWizard`
- `RemoteShellView`
- `MobileRelayPanel`
- 별도 `SwitchSetupWizard` SwiftUI view

기존 UI 패턴을 따르고, 과한 새 디자인 시스템은 만들지 말 것.

### 5.2 핵심 사용자 흐름

Mac 앱에서:

1. 현재 DarwinForge가 연결 중인 로봇 SSH host/user를 읽는다.
   - 예: `robotis@192.168.123.1` 또는 Mac 앱이 실제 사용 중인 Wi-Fi/LAN IP
   - 절대 `192.168.123.1`로 고정하지 말 것.
2. 사용자가 Switch IP/user를 입력한다.
   - 현재 확인된 Switch: `yuseok@192.168.0.25`
3. Mac에서 Switch에 SSH 접속 가능 여부를 확인한다.
   - `ssh yuseok@192.168.0.25 'echo ok'`
   - Switch password prompt 처리는 Swift `Process`로 어렵다면 “터미널에서 실행” fallback 제공.
4. Switch에서 로봇용 RSA 키가 없으면 생성한다.
   - `darwin-switch-robot-ready keygen`
   - 또는 `ssh yuseok@<switch> 'darwin-switch-robot-ready keygen'`
5. Switch 공개키를 가져온다.
   - `ssh yuseok@<switch> 'cat ~/.ssh/id_rsa_darwin.pub'`
6. DarwinForge Mac 앱의 이미 성공한 로봇 SSH 채널로, 로봇 `~/.ssh/authorized_keys`에 Switch 공개키를 등록한다.
   - 이 단계가 핵심이다.
   - Switch에서 `ssh-copy-id`가 멈추는 문제를 우회한다.
7. Switch에서 robot-ready probe를 실행한다.
   - `ssh yuseok@<switch> 'darwin-switch-robot-ready probe'`
8. Switch에서 robot-ready status를 실행한다.
   - `ssh yuseok@<switch> 'darwin-switch-robot-ready status'`
9. 사용자가 명시적으로 승인하면 WalkLab을 시작한다.
   - `ssh yuseok@<switch> 'darwin-switch-robot-ready start-walklab'`
   - 이 단계는 로봇 모터/보행 엔진 초기화 가능성이 있으므로 “로봇을 잡고 있는지” 확인하는 경고 UI 필요.
10. 성공하면 Switch agent를 SSH 모드로 전환한다.
    - `ssh yuseok@<switch> 'darwin-switch-robot-ready enable-agent-ssh'`
11. 최종 확인:
    - `ssh yuseok@<switch> 'grep -n "\"mode\"" /etc/darwin-switch-agent/config.json; systemctl is-active darwin-switch-agent; curl -fsS http://127.0.0.1:8765/api/state | head -c 1200'`

### 5.3 로봇 authorized_keys 등록 명령

Mac 앱이 로봇 SSH에 이미 성공한다면, 로봇 측에는 `SSHShell.run`으로 다음 계열 명령을 보낼 수 있다.

주의: 공개키 문자열은 반드시 shell-safe하게 quote 처리할 것. Swift에서 single quote escaping 함수 사용.

예시 로봇 명령:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
grep -qxF '<SWITCH_PUBLIC_KEY>' ~/.ssh/authorized_keys || printf '%s\n' '<SWITCH_PUBLIC_KEY>' >> ~/.ssh/authorized_keys
```

가능하면 한 줄로:

```bash
KEY='<escaped switch pubkey>'; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF "$KEY" ~/.ssh/authorized_keys || printf "%s\n" "$KEY" >> ~/.ssh/authorized_keys
```

필수:

- 중복 등록 방지
- `authorized_keys` 권한 `600`
- `.ssh` 권한 `700`
- 실패 시 stderr 표시

### 5.4 Switch 쪽 config 업데이트

Switch의 `darwin-switch-robot-ready enable-agent-ssh`는 내부적으로:

- `/etc/darwin-switch-agent/config.json` 업데이트
- `mode=ssh`
- `ssh.host/user/port/identity_file` 유지/설정
- `darwin-switch-agent.service` restart

단, 현재 구현은 Switch에서 실행되는 명령이다. Mac 앱은 Switch에 SSH로 이 명령을 실행하면 된다.

### 5.5 Robot IP 관련 주의

현재 Switch config 기본값은:

```json
"ssh": {
  "host": "192.168.123.1",
  "user": "robotis",
  "port": 22,
  "identity_file": "~/.ssh/id_rsa_darwin"
}
```

하지만 Mac DarwinForge 앱이 실제로 연결한 robot host가 `192.168.123.1`이 아닐 수 있다.

요구:

- DarwinForge Mac 앱이 현재 사용 중인 robot SSH host를 Switch config에도 전달할 수 있게 해야 한다.
- Switch에서 로봇으로 접근 가능한 IP인지 별도 probe해야 한다.
- Mac에서 연결되는 IP와 Switch에서 연결되는 IP가 다를 수 있으므로, UI에 “Mac이 보는 로봇 IP”와 “Switch가 접근할 로봇 IP”를 분리해서 표시하는 것이 좋다.

---

## 6. 구현 시 참고 파일

### DarwinForge Mac 앱

읽어야 할 파일:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/SSHShell.swift`
  - 다윈포지 성공 SSH 옵션의 원본.
  - `SSHShell.run`, `SSHShell.defaultOptions`, `keyAuthSetupCommand` 참고.
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/RemoteShell.swift`
  - 기존 remote shell abstraction.
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/RobotSetupCommand.swift`
  - `walkLabRobotisStart`, `walkLabVerifyMode`, `walkLabRobotisSendCommand`, `demoPatchedStatus` 등.
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/ConnectionWizard.swift`
  - 기존 자동 연결/SSH onboard 흐름.
- `app/ui/DarwinForge/Sources/DarwinForgeUI/Remote/RemoteShellView.swift`
  - 수동 명령 실행 UI와 기존 setup 안내 UI.
- `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/*`
  - Switch/Mobile relay 관련 UI 패턴이 있을 수 있음.

### Switch pilot

읽어야 할 파일:

- `tools/switch-pilot/src/darwin_switch_agent/robot_ready.py`
- `tools/switch-pilot/bin/darwin-switch-robot-ready`
- `tools/switch-pilot/src/darwin_switch_agent/ssh_control_client.py`
- `tools/switch-pilot/src/darwin_switch_agent/cockpit.py`
- `tools/switch-pilot/web/setup.html`
- `tools/switch-pilot/web/setup.js`
- `tools/switch-pilot/config.example.json`
- `tools/switch-pilot/tests/test_robot_ready.py`
- `tools/switch-pilot/tests/test_cockpit.py`

---

## 7. 필요한 새 코드 제안

### 7.1 Switch SSH 실행기

DarwinForge Mac 앱에 robot용 `SSHShell`과 별개로 Switch용 SSH 실행기를 추가하는 것을 권장한다.

예:

```swift
enum SwitchSSHShell {
    struct Result { stdout, stderr, exitCode, elapsedMs }
    static func run(command: String, host: String, user: String, timeoutSeconds: TimeInterval) async throws -> Result
}
```

차이:

- Switch는 최신 Ubuntu라 `+ssh-rsa` legacy 옵션은 필수 아님.
- 하지만 일관성을 위해 `BatchMode=no` 또는 사용자 안내 fallback을 고려해야 한다.
- Swift `Process`에서 password prompt를 제대로 처리하기 어렵다면 BatchMode로 빠르게 실패시키고, 복사 가능한 터미널 명령을 보여주는 UX로 시작해도 된다.

### 7.2 공개키 등록 유틸

```swift
struct SwitchRobotLinkSetup {
    let switchHost: String
    let switchUser: String
    let robotHostForSwitch: String
    let robotUser: String

    func ensureSwitchKey() async throws
    func readSwitchPublicKey() async throws -> String
    func installSwitchPublicKeyOnRobot(pubkey: String) async throws
    func probeSwitchToRobot() async throws
    func verifyWalkLabPatchFromSwitch() async throws
    func startWalkLabFromSwitch() async throws
    func enableSwitchAgentSSH() async throws
}
```

### 7.3 UI

SwiftUI panel/wizard:

- 단계별 상태:
  - Switch 연결
  - Switch 키 확인/생성
  - Robot authorized_keys 등록
  - Switch→Robot SSH probe
  - WalkLab patch 확인
  - WalkLab 시작
  - Switch agent SSH 모드 전환
- 각 단계에:
  - 성공/실패 아이콘
  - stdout/stderr detail 접기/펼치기
  - 복사 가능한 fallback 명령
  - “로봇을 잡고 있음” 체크 후 start-walklab 활성화

---

## 8. 안전/품질 요구사항

1. **거짓 성공 금지**
   - `authorized_keys`에 키를 넣었다고 바로 성공 처리하지 말 것.
   - 반드시 Switch에서 `darwin-switch-robot-ready probe`를 실행해 `Robot SSH auth: OK`를 확인해야 한다.

2. **WalkLab patch 검증**
   - 반드시 Switch에서 `darwin-switch-robot-ready status`를 실행하고, `walklab_patch=present` 또는 `Robot WalkLab patch: OK`를 확인해야 한다.

3. **start-walklab는 명시적 승인 후**
   - 이 단계는 로봇 `demo`/`demo-pilot` 실행과 보행 엔진 초기화가 포함될 수 있다.
   - “로봇을 잡고 있음 / 주변 안전 확인” 체크가 필요하다.

4. **IP 고정 금지**
   - `192.168.123.1`은 기본값일 뿐이다.
   - Mac 앱의 현재 robot host와 Switch에서 접근 가능한 robot host를 분리해 다룰 것.

5. **비밀번호 처리**
   - Swift Process에서 SSH password prompt를 직접 다루는 것은 복잡하다.
   - 1차 구현은 BatchMode 빠른 실패 + 사용자에게 정확한 터미널 명령 제공으로 충분하다.
   - 더 나아가 macOS `open Terminal` 또는 AppleScript로 명령을 열어주는 버튼을 제공할 수 있다.

6. **기존 DarwinForge SSH 성공 경로 재사용**
   - 로봇에 쓰는 명령은 반드시 기존 `SSHShell.run` 또는 `RemoteShell` 경로를 사용해라.
   - 새로 임의 SSH 옵션을 만들지 말고 `SSHShell` 옵션과 호환되게 유지해라.

---

## 9. 완료 기준

Claude 구현이 완료되었다고 판단하려면 아래를 모두 만족해야 한다.

1. DarwinForge Mac 앱 UI에서 Switch IP/user와 robot host를 입력/확인할 수 있다.
2. Mac 앱이 Switch에 `darwin-switch-robot-ready keygen`을 실행하거나, 실행할 수 없는 경우 정확한 fallback 명령을 제공한다.
3. Mac 앱이 Switch 공개키를 읽어올 수 있다.
4. Mac 앱이 기존 성공한 robot SSH 경로로 robot `authorized_keys`에 Switch 공개키를 등록한다.
5. Mac 앱이 Switch에서 `darwin-switch-robot-ready probe`를 실행해 성공 여부를 보여준다.
6. Mac 앱이 Switch에서 `darwin-switch-robot-ready status`를 실행해 WalkLab patch 상태를 보여준다.
7. 사용자가 안전 확인 후 `start-walklab`을 실행할 수 있다.
8. Mac 앱이 Switch에서 `enable-agent-ssh`를 실행해 Switch 조종석을 `mode=ssh`로 전환할 수 있다.
9. 최종 확인으로 Switch config와 agent 상태를 표시한다.
   - `/etc/darwin-switch-agent/config.json`의 `"mode": "ssh"`
   - `systemctl is-active darwin-switch-agent` = `active`
10. 실패 시 어느 단계에서 실패했는지 stdout/stderr와 다음 행동이 UI에 명확히 나타난다.

---

## 10. Claude에게 바로 전달할 요약 지시

아래 문장을 Claude에게 그대로 전달해도 된다.

> DarwinForge Mac 앱에는 이미 로봇 SSH 연결이 성공하는 경로가 있습니다. 현재 Switch Linux 조종석에는 `darwin-switch-robot-ready`가 설치되어 있고 agent도 active지만, `mode`는 아직 `dry_run`입니다. Switch에서 `darwin-switch-robot-ready copy-key`를 실행하면 RSA 키는 생성되지만 `ssh-copy-id robotis@192.168.123.1` 단계에서 password prompt가 보이지 않고 멈춘 것처럼 보여 Switch→Robot 키 등록이 막혀 있습니다. Mac 앱은 로봇에 이미 연결되므로, Mac 앱이 Switch 공개키를 읽고 기존 로봇 SSH 채널로 robot `~/.ssh/authorized_keys`에 등록하는 “Switch Robot Link Setup” 마법사를 구현해 주세요. 그 후 Switch에서 `probe`, `status`, `start-walklab`, `enable-agent-ssh`를 순서대로 실행하고, 최종적으로 Switch config가 `mode=ssh`, agent가 active인지 확인하는 UI를 만들어 주세요. IP는 `192.168.123.1`로 고정하지 말고, Mac 앱의 현재 robot host와 Switch에서 접근할 robot host를 분리해 다뤄 주세요. `start-walklab`은 로봇 모터/보행 엔진을 초기화할 수 있으므로 사용자 안전 확인 체크 후에만 실행되게 해 주세요.

