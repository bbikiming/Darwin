# Claude Prompt: DarwinForge에 Switch 연결 브리지 기능 최종 구현

작성 시각: 2026-06-07 KST  
작성자: Codex  
전달 대상: Claude  
목적: Nintendo Switch Linux 조종석이 실제 DARwIn 로봇을 움직이는 데 성공한 실기기 이력을 바탕으로, DarwinForge Mac 앱에 **Switch 연결 다리 역할**을 하는 기능을 최종 구현하도록 지시한다.

---

## 1. 최종 목표

DarwinForge Mac 앱에 **Switch Bridge / 스위치 연결 세팅** 기능을 완성해 주세요.

이 기능은 Mac 앱이 이미 가진 로봇 SSH 연결 능력을 이용해서, Nintendo Switch Linux 조종석이 로봇에 직접 SSH로 붙어 조종할 수 있도록 설정, 검증, 복구, 튜닝을 한 화면에서 안내하는 기능입니다.

최종 사용자는 개발자가 아니라 UI/UX 기획자입니다. 따라서 터미널 명령어를 외우게 하지 말고, DarwinForge 안에서 다음을 순서대로 버튼/상태/로그로 안내해야 합니다.

1. Mac → Robot 연결 확인
2. Mac → Switch 연결 확인
3. Switch 공개키 생성 및 읽기
4. Mac의 기존 Robot SSH 채널로 Switch 공개키를 로봇 `authorized_keys`에 등록
5. Switch → Robot SSH 인증 확인
6. Switch에서 접근 가능한 Robot IP 확정
7. 로봇 WalkLab/demo 상태 확인 및 시작
8. Switch agent를 `mode=ssh`로 전환
9. 조이콘 입력과 `/tmp/df-walklab-cmd` 갱신 확인
10. 안전한 조종 파라미터 적용 및 연결 끊김 완화 설정 적용

---

## 2. 현재 실기기 성공 이력

아래는 실제 Nintendo Switch + DARwIn 로봇으로 확인된 내용입니다. 이 이력은 추정이 아니라 실측입니다.

### 2.1 Switch Linux 기본 상태

- Switchroot L4T Ubuntu 24.04.3 LTS
- Switch IP: `192.168.0.25`
- Switch user: `yuseok`
- Switch SSH 접속 가능
- `darwin-switch-agent.service` active/enabled
- 조종석 API: `http://127.0.0.1:8765/api/state`
- Joy-Con combined input: `/dev/input/event8`

Joy-Con 확인:

```text
Nintendo Switch Combined Joy-Cons
selected: /dev/input/event8
deadman / ZL or ZR: seen
arm / A: seen
stop / B: seen
estop / Home: seen
left stick X/Y: seen
right stick X/Y: seen
Darwin Switch input check: GOOD
```

### 2.2 Robot IP와 SSH 인증 성공

최종적으로 Switch에서 로봇에 닿는 IP는 다음으로 확인되었습니다.

```text
robotis@192.168.0.33
```

Switch에서 다음 명령이 성공했습니다.

```bash
darwin-switch-robot-ready probe --robot-host 192.168.0.33
```

결과:

```text
Robot SSH auth: OK
```

즉 Switch → Robot SSH 키 인증은 성공했습니다.

### 2.3 mode=ssh 전환 성공

Switch의 `/etc/darwin-switch-agent/config.json`이 `mode=ssh`로 전환되었습니다.

확인 명령:

```bash
grep -n '"mode"\|"host"' /etc/darwin-switch-agent/config.json
systemctl is-active darwin-switch-agent
curl -s http://127.0.0.1:8765/api/state | grep -E '"mode"|"target"|"ssh_connected"'
```

확인된 핵심 상태:

```json
{
  "mode": "ssh",
  "target": "robotis@192.168.0.33",
  "input_status": "/dev/input/event8"
}
```

초기에는 `ssh_connected:false`였으나 원인이 확인되었습니다.

### 2.4 중요 버그: identity_file의 `~` 확장 문제

처음 config에는 다음처럼 저장되었습니다.

```json
"identity_file": "~/.ssh/id_rsa_darwin"
```

하지만 `darwin-switch-agent`는 systemd 서비스로 실행되며, 이때 `~`가 `/root`로 확장되었습니다.

실측:

```text
expanded_identity: /root/.ssh/id_rsa_darwin
exists: False
```

실제 키는 다음 경로에 있습니다.

```text
/home/yuseok/.ssh/id_rsa_darwin
```

따라서 최종 config는 반드시 절대경로를 써야 합니다.

```json
"identity_file": "/home/yuseok/.ssh/id_rsa_darwin"
```

DarwinForge의 Switch Bridge 기능은 이 문제를 UI에서 자동 검출하고 고쳐야 합니다.

요구:

- `~/.ssh/id_rsa_darwin`를 config에 저장하지 마세요.
- Switch user가 `yuseok`이면 `/home/yuseok/.ssh/id_rsa_darwin`처럼 절대경로로 저장하세요.
- 설정 후 `sudo systemctl restart darwin-switch-agent`를 실행하고 `/api/state`로 확인하세요.

### 2.5 실제 조종 성공

조이콘 입력이 `/tmp/df-walklab-cmd`에 반영되는 것을 확인했습니다.

실측 출력:

```text
61868d0c87f04cf2830017f5 1 0.00 0 0.00 600 40 13 1.0 0 2 0.00 0.00 0
c641d853ca4b4f0ca091ebb6 1 10.99 0 0.00 600 40 13 1.0 0 2 0.00 0.00 0
83912c7475934e74886d0c51 1 24.95 0 0.00 600 40 13 1.0 0 2 0.00 0.00 0
a395a42cdcbb45cc96e64779 1 0.00 0 -3.96 600 40 13 1.0 0 2 0.00 0.00 0
2d90a593b0444619808fa99c 1 0.41 0 -10.94 600 40 13 1.0 0 2 0.00 0.00 0
```

해석:

- token 1: `enabled`
- token 2: `stride`
- token 4: `turn`
- `stride=24.95`, `turn=-10.94`까지 실제 반영됨

그리고 사용자가 보고했습니다.

```text
로봇이 움직이긴 해
```

즉 전체 경로는 성공했습니다.

```text
Joy-Con → Switch Ubuntu agent → SSH → robot /tmp/df-walklab-cmd → WalkLab/demo → DARwIn 보행
```

---

## 3. 현재 남은 문제

### 3.1 속도 가변이 체감되지 않음

사용자 보고:

```text
속도가 가변적으로 변하지 않고 동일해
```

원인:

기존 SSH WalkLab 명령에서 `speed_scale`은 UI/API state에는 있지만, 실제 14-token WalkLab 파일 명령에는 반영되지 않습니다.

기존 명령 예:

```text
cmd_id enabled stride side turn period foot hip bgain benable blevel headPan headTilt ballTrack
...    1       24.95  0    0.00 600    40   13  1.0   0       2      0.00    0.00     0
```

WalkLab 쪽 속도 체감은 `stride`만으로 충분히 가변되지 않을 수 있습니다. 따라서 최근 Codex가 로컬 코드에서 다음을 수정했습니다.

파일:

```text
tools/switch-pilot/src/darwin_switch_agent/ssh_control_client.py
```

수정 방향:

- 스틱 입력 강도에 따라 WalkLab 명령의 `period`와 `foot`를 동적으로 변경
- 작은 입력: 긴 period, 낮은 foot
- 큰 입력: 짧은 period, 높은 foot

새 config 키:

```json
"min_period_ms": 520,
"max_period_ms": 780,
"min_foot_mm": 18,
"stride_ref_mm": 25,
"turn_ref_deg": 12
```

Claude는 이 수정이 실제 배포/패키지/다윈포지 세팅 UI에 반영되었는지 확인하고, 부족하면 완성해 주세요.

### 3.2 Switch 내부에서 연결이 자주 끊김

사용자 보고:

```text
스위치 내에서 자주 연결이 끊겨
```

원인 추정:

- 현재 SSH 제어는 명령/텔레메트리마다 `/usr/bin/ssh`를 반복 실행합니다.
- ControlMaster를 쓰지만 Switch Wi-Fi와 로봇 Wi-Fi 환경에서는 여전히 부담이 큽니다.
- telemetry polling까지 겹치면 `ssh_connected`가 흔들릴 수 있습니다.

Codex가 로컬 기본값을 보수적으로 수정했습니다.

파일:

```text
tools/switch-pilot/config.example.json
```

변경 방향:

```json
"timeout_seconds": 8,
"connect_timeout_seconds": 3,
"send_hz": 3,
"telemetry_hz": 0.5,
"heartbeat_ms": 1500
```

Claude는 DarwinForge Switch Bridge에서 이 안정화 설정을 버튼 하나로 Switch config에 적용할 수 있게 만들어 주세요.

UI 문구 예:

```text
안정 우선 설정 적용
초기 실기 테스트용입니다. SSH 전송 빈도를 낮춰 연결 끊김을 줄이고, 보행 속도 변화를 더 완만하게 만듭니다.
```

---

## 4. DarwinForge에 구현해야 할 최종 기능

### 4.1 새 화면 또는 기존 전문가 탭 완성

현재 Claude가 이미 다음 파일들을 추가/수정한 이력이 있습니다.

```text
app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/SwitchRobotLinkCommands.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/SwitchRobotLinkSession.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/SwitchLink/SwitchRobotLinkView.swift
app/ui/DarwinForge/Tests/DarwinForgeUITests/Connection/SwitchRobotLinkCommandsTests.swift
app/ui/DarwinForge/Tests/DarwinForgeUITests/Connection/SwitchRobotLinkSessionTests.swift
```

Codex가 확인한 테스트:

```bash
cd app/ui/DarwinForge
swift test --filter 'SwitchRobotLink|SSHShellArguments'
```

결과:

```text
Executed 30 tests, with 0 failures
```

이 구조를 유지하되, 위 실기기 성공 이력과 남은 문제를 반영해서 최종 완성해 주세요.

### 4.2 필수 단계

DarwinForge UI는 다음 단계를 제공해야 합니다.

#### 1. Mac → Robot 연결 상태 확인

DarwinForge가 이미 로봇에 SSH 연결되어 있어야 합니다.

보여줄 것:

- Mac이 보는 로봇 주소
- 연결 채널 상태
- 연결 안 된 경우 “먼저 로봇 연결” 안내

#### 2. Mac → Switch 연결 확인

기본값:

```text
yuseok@192.168.0.25
```

단, 사용자가 수정 가능해야 합니다.

확인 명령:

```bash
echo ok
hostname
whoami
```

#### 3. Switch 도구 확인

Switch에서 아래를 확인해야 합니다.

```bash
command -v darwin-switch-robot-ready
systemctl is-active darwin-switch-agent
darwin-switch-robot-ready --help
curl -s http://127.0.0.1:8765/api/state
```

문제가 있으면 재배포 안내를 표시하세요.

#### 4. Switch 키 생성 및 공개키 읽기

Switch에서:

```bash
darwin-switch-robot-ready keygen
cat /home/yuseok/.ssh/id_rsa_darwin.pub
```

public key 형식 검증:

- `ssh-rsa`
- `ssh-ed25519`
- `ecdsa-sha2-*`

이번 로봇은 OpenSSH 5.9 계열이므로 RSA 경로가 가장 안전합니다.

#### 5. Mac의 로봇 SSH 채널로 authorized_keys 등록

Switch에서 `ssh-copy-id`를 실행하지 마세요.

Mac DarwinForge의 기존 로봇 SSH 성공 채널로 다음을 실행하세요.

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
grep -qxF '<SWITCH_PUBLIC_KEY>' ~/.ssh/authorized_keys || printf '%s\n' '<SWITCH_PUBLIC_KEY>' >> ~/.ssh/authorized_keys
echo DF_SWITCH_KEY_INSTALLED
```

반드시 shell escaping 처리하세요.

#### 6. Robot IP 후보 탐색

Mac의 로봇 SSH 채널로 로봇 IP 후보를 가져옵니다.

```bash
{ hostname -I 2>/dev/null; ip -4 -o addr show 2>/dev/null | awk '{print $4}'; } | tr ' ' '\n'
```

실제 성공 IP:

```text
192.168.0.33
```

주의:

- 기존 기본값 `192.168.123.1`은 Mac/로봇 직접 연결 또는 USB Ethernet 계열일 수 있습니다.
- Switch Wi-Fi에서는 `192.168.123.1`이 닿지 않을 수 있습니다.
- Switch에서 실제로 TCP 22가 닿는 IP를 찾아야 합니다.

Switch에서 후보를 테스트:

```bash
darwin-switch-robot-ready reachability --candidates '192.168.0.33,192.168.123.1'
```

또는 직접:

```bash
nc -vz <candidate-ip> 22
```

#### 7. Switch → Robot SSH probe

Switch에서:

```bash
darwin-switch-robot-ready probe --robot-host 192.168.0.33
```

성공 마커:

```text
Robot SSH auth: OK
```

#### 8. WalkLab/demo 상태 확인 및 시작

Switch에서:

```bash
darwin-switch-robot-ready status --robot-host 192.168.0.33
darwin-switch-robot-ready start-walklab --robot-host 192.168.0.33
```

주의:

- `start-walklab`는 로봇의 demo/WalkLab를 켜며 모터 토크가 켜질 수 있습니다.
- UI에서 반드시 안전 확인 체크박스를 요구하세요.

안전 문구:

```text
로봇을 손으로 잡고 있고, 주변에 사람이 없으며, 넘어질 경우 즉시 전원을 끌 수 있습니다.
```

#### 9. Switch agent SSH 모드 전환

Switch에서:

```bash
darwin-switch-robot-ready enable-agent-ssh --robot-host 192.168.0.33
```

단, 위 명령이 `identity_file`을 `~/.ssh/id_rsa_darwin`로 저장하면 안 됩니다.

최종 config 보정이 필요합니다.

```json
"mode": "ssh",
"ssh": {
  "host": "192.168.0.33",
  "user": "robotis",
  "port": 22,
  "identity_file": "/home/yuseok/.ssh/id_rsa_darwin"
}
```

Claude에게 요청:

- `robot_ready.py`의 `_agent_config_payload()` 또는 관련 로직을 수정해, `identity_file` 저장 시 절대경로를 쓰도록 하세요.
- `cfg.identity_file`이 `~`로 시작하면 Switch user home 기준으로 expand한 절대경로를 저장하세요.
- systemd/root 기준으로 expand되지 않도록 주의하세요.

#### 10. 최종 상태 확인

Switch에서:

```bash
sudo systemctl restart darwin-switch-agent
sleep 3
curl -s http://127.0.0.1:8765/api/state
```

정상 기대:

```json
{
  "mode": "ssh",
  "target": "robotis@192.168.0.33",
  "input_status": "/dev/input/event8",
  "ssh_connected": true
}
```

`connected`는 UI/telemetry 상태에 따라 흔들릴 수 있으므로, 최소한 `ssh_connected`와 실제 `/tmp/df-walklab-cmd` 갱신을 함께 봐야 합니다.

---

## 5. 조종 성공 검증 기능

DarwinForge Switch Bridge는 최종적으로 “연결됨”만 표시하면 안 됩니다.

반드시 다음 실사용 검증을 제공하세요.

### 5.1 `/tmp/df-walklab-cmd` 갱신 확인

Switch가 로봇에 SSH로 붙어 다음을 읽을 수 있어야 합니다.

```bash
ssh -i /home/yuseok/.ssh/id_rsa_darwin \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o HostKeyAlgorithms=+ssh-rsa \
  robotis@192.168.0.33 \
  'stat -c "%y %s" /tmp/df-walklab-cmd 2>/dev/null; cat /tmp/df-walklab-cmd 2>/dev/null'
```

UI는 다음을 표시하세요.

- 최근 command id
- enabled
- stride
- turn
- period
- foot
- timestamp

### 5.2 입력 게이트 안내

사용자가 조종하려면 다음 순서가 필요합니다.

```text
A: 조종 권한 켜기
ZL 또는 ZR 유지: deadman
왼쪽 스틱 위/아래: 전후 보행
왼쪽 스틱 좌/우: 회전
B: 정지
Home: 비상정지
```

실기기에서 `A + ZL/ZR + 왼쪽 스틱`으로 `stride`와 `turn`이 실제 바뀌는 것을 확인했습니다.

UI에서는 `armed`, `deadman`, `moving`, `stride`, `turn`이 모두 보이게 하세요.

### 5.3 강제 보행 테스트는 숨겨진 고급 기능으로만 제공

실제 실기기에서 강제 명령으로 로봇이 걸었습니다.

명령:

```bash
echo "manualtest 1 15.00 0 0.00 600 40 13 1.0 0 2 0.00 0.00 0" > /tmp/df-walklab-cmd
```

이 명령은 위험하므로 일반 사용자 버튼으로 노출하지 말고, 고급/진단 모드에서만 안전 확인 후 제공하세요.

---

## 6. 안정화 설정 UI

DarwinForge에 “초기 실기 테스트 안정화 설정 적용” 버튼을 추가해 주세요.

Switch config에 다음 값을 쓰고 agent를 재시작합니다.

```json
{
  "ssh": {
    "send_hz": 3,
    "telemetry_hz": 0.5,
    "heartbeat_ms": 1500,
    "timeout_seconds": 8,
    "connect_timeout_seconds": 3,
    "min_period_ms": 520,
    "max_period_ms": 780,
    "min_foot_mm": 18,
    "stride_ref_mm": 25,
    "turn_ref_deg": 12,
    "identity_file": "/home/yuseok/.ssh/id_rsa_darwin"
  }
}
```

설명:

- `send_hz=3`: SSH 명령 빈도를 낮춰 Wi-Fi/SSH 부담 감소
- `telemetry_hz=0.5`: telemetry polling 부담 감소
- `heartbeat_ms=1500`: 로봇 stale watchdog 5초보다 충분히 짧으면서 과도하지 않은 heartbeat
- `min/max period`, `min foot`: 작은 스틱 입력에서 더 느리게 체감되도록 보행 파라미터 가변화

---

## 7. UX 요구사항

사용자는 UI/UX 기획자이고 터미널 전문가는 아닙니다.

따라서 UI는 다음처럼 설계해 주세요.

### 7.1 화면 구조

권장 화면명:

```text
스위치 연결 브리지
```

주요 섹션:

1. 현재 연결 지도
   - Mac ↔ Robot
   - Mac ↔ Switch
   - Switch ↔ Robot
2. 단계별 세팅
3. 안전 확인
4. 조종 입력 실시간 확인
5. 명령 파일 확인
6. 안정화 설정
7. 원클릭 로그 수집

### 7.2 상태 문구

기술적 상태를 사용자 문장으로 번역하세요.

예:

```text
Switch가 로봇에 SSH로 연결되었습니다.
조이콘 입력이 로봇 명령 파일에 반영되고 있습니다.
아직 로봇이 움직일 준비가 되지 않았습니다. WalkLab 시작이 필요합니다.
키 경로가 root 기준으로 잘못 저장되어 있습니다. /home/yuseok 경로로 보정합니다.
```

### 7.3 실패 원인 분류

실패 시 단순히 “실패”라고 하지 말고 원인을 나눠 보여주세요.

- Switch 접속 실패
- 로봇 접속 실패
- Switch → Robot IP 경로 없음
- SSH key 등록 안 됨
- identity_file 경로 오류
- agent 비활성
- mode가 dry_run
- Joy-Con 미선택
- WalkLab patch 없음
- WalkLab/demo 미실행
- command file 미갱신
- estop 파일 존재

---

## 8. 코드 수정 요구

### 8.1 `robot_ready.py`

파일:

```text
tools/switch-pilot/src/darwin_switch_agent/robot_ready.py
```

수정:

- `enable-agent-ssh`가 config 저장 시 identity를 절대경로로 써야 합니다.
- 현재 실기기 버그:

```json
"identity_file": "~/.ssh/id_rsa_darwin"
```

는 systemd/root에서 `/root/.ssh/id_rsa_darwin`로 풀려 실패합니다.

기대:

```json
"identity_file": "/home/yuseok/.ssh/id_rsa_darwin"
```

테스트 추가:

- user home 기반 key path 저장 테스트
- `~` 저장 금지 테스트

### 8.2 `ssh_control_client.py`

파일:

```text
tools/switch-pilot/src/darwin_switch_agent/ssh_control_client.py
```

현재 Codex가 로컬 수정한 내용이 있는지 확인하고 마무리하세요.

요구:

- `period`와 `foot`를 입력 강도에 따라 동적으로 계산
- 14-token contract 유지
- `speed_scale`은 UI state에만 있지 말고, 실제 WalkLab 체감에 반영되도록 설계
- 테스트에서 토큰 수와 period/foot 변화 검증

### 8.3 DarwinForge Swift 앱

관련 파일:

```text
app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/SwitchRobotLinkCommands.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/SwitchRobotLinkSession.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/SwitchLink/SwitchRobotLinkView.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift
```

요구:

- 실기기에서 확인된 `192.168.0.33` 성공 사례를 기본값으로 하드코딩하지 말고, 탐색 결과로 반영하세요.
- `192.168.0.25` Switch IP는 기본 입력값으로 둘 수 있지만 사용자가 수정 가능해야 합니다.
- `identity_file` 보정 기능 추가
- 안정화 설정 적용 버튼 추가
- `/api/state` polling으로 `mode`, `target`, `ssh_connected`, `input_status`, `armed`, `deadman`, `moving`, `stride`, `turn` 표시
- `/tmp/df-walklab-cmd` 읽기 진단 추가
- 실패 단계별 fallback command 제공

---

## 9. 검증 명령

작업 후 반드시 실행하세요.

### 9.1 Switch 패키지

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin
tools/switch-pilot/verify-release.sh
```

현재 Codex 기준 통과 이력:

```text
Ran 151 tests
OK
Darwin Switch preflight: GOOD
Install kit: OK
```

### 9.2 DarwinForge Swift tests

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge
swift test --filter 'SwitchRobotLink|SSHShellArguments'
```

현재 통과 이력:

```text
Executed 30 tests, with 0 failures
```

새 기능 추가 후 관련 테스트를 확장하세요.

---

## 10. 완료 기준

완료로 판단하려면 다음이 모두 만족되어야 합니다.

1. DarwinForge UI에서 Mac→Robot, Mac→Switch, Switch→Robot 상태를 각각 볼 수 있음
2. Switch 공개키를 Mac의 Robot SSH 채널로 등록할 수 있음
3. Switch가 실제로 닿는 Robot IP를 탐색/선택/저장할 수 있음
4. `identity_file`이 `/home/yuseok/.ssh/id_rsa_darwin` 절대경로로 저장됨
5. `mode=ssh` 전환 후 agent 재시작 가능
6. UI에서 `ssh_connected`, `armed`, `deadman`, `moving`, `stride`, `turn`을 확인 가능
7. `/tmp/df-walklab-cmd`가 조이콘 입력에 따라 갱신되는지 확인 가능
8. 안정화 설정 적용 가능
9. 연결 실패 시 사용자가 해야 할 다음 행동이 UI에 명확히 표시됨
10. Swift tests와 Switch release verification 통과

---

## 11. Claude에게 전달할 핵심 요약

실기기에서 Switch 조종은 성공했습니다. 최종 성공 경로는 다음입니다.

```text
Joy-Con → Switch Ubuntu agent → SSH → robotis@192.168.0.33 → /tmp/df-walklab-cmd → WalkLab/demo → DARwIn 보행
```

성공 확인:

- `Robot SSH auth: OK`
- `mode=ssh`
- `target=robotis@192.168.0.33`
- `input_status=/dev/input/event8`
- `/tmp/df-walklab-cmd`에 `stride=24.95`, `turn=-10.94`까지 반영
- 로봇 실제 보행 확인

남은 핵심 문제:

- `identity_file=~/.ssh/id_rsa_darwin` 저장 버그를 절대경로로 수정해야 함
- 속도 가변 체감을 위해 SSH WalkLab 명령의 `period/foot` 동적 변경 필요
- Switch Wi-Fi에서 SSH 연결이 흔들리므로 안정화 설정 UI 필요
- 이 모든 과정을 DarwinForge Mac 앱에서 터미널 없이 진행할 수 있어야 함

이제 DarwinForge는 단순 로봇 앱이 아니라, **Mac이 Switch와 Robot 사이의 초기 연결 다리를 놓아주는 세팅 도구**가 되어야 합니다.

