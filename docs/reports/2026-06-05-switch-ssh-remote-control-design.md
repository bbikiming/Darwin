# Switch ↔ Robot SSH 원격 제어 설계 (grounding + evidence)

- 작성일: 2026-06-05 (Fri, KST)
- 범위: Nintendo Switch(Switchroot L4T Ubuntu)에서 DARwIn-OP(OP2/CM-740)를
  무선 보행 조종(walk RC)하는 **원격 제어 경로(remote control path)** 설계와 그 근거.
- Ground-truth 출처(본 문서의 모든 주장은 아래 실제 파일에서 추출):
  - 로봇측 데몬: `firmware-patches/walklab-brokerage/WalkLabBrokerage.cpp` / `.h`
  - Mac측 SSH 전송: `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/SSHShell.swift`
  - Mac측 RC 브리지: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Pilot/WalkLabRCBridge.swift`
  - 연결 상수: `app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/DFConnectionConstants.swift`

---

## 1. 결론 (conclusion first)

**SSH 위의 파일 프로토콜(file-based protocol over SSH)이 Switch→로봇 원격 제어의 핵심
경로다.** Switch는 `/usr/bin/ssh`로 로봇의 `/tmp/df-walklab-*` 파일을 atomic하게
쓰고/읽어, 로봇 온보드 데몬 `WalkLabBrokerage`가 그 파일을 100ms 주기로 폴링해
ROBOTIS Walking 엔진을 구동한다. 새 프로토콜·새 펌웨어 데몬을 만들 필요가 없다.

근거는 두 가지다.

1. **이미 검증된 경로다 (proven by DarwinForge).** Mac DarwinForge가 정확히 이
   파일 프로토콜로 OP2를 조종하고 있고, 데몬(`WalkLabBrokerage.cpp`)·전송 계층
   (`SSHShell.swift`)·제어 cadence(`WalkLabRCBridge` + 데몬 stale-stop)가 코드에
   존재한다. Switch는 Mac이 하던 SSH 호출을 그대로 흉내 내면 된다 — 로봇 펌웨어를
   건드릴 이유가 전혀 없다.
2. **로봇의 구형 커널이 SSH는 안정적으로 처리한다.** DARwIn-OP의 OpenSSH 5.9는
   "낡았지만 신뢰성 있는" 채널이다. 비유하자면 — 최신 화상통화는 못 깔아도 유선
   전화는 100년째 잘 되는 시골 전화국과 같다. SSH는 그 유선 전화다. 알고리즘만 옛
   방식(RSA + ssh-rsa)으로 맞춰주면 핸드셰이크가 그대로 성립한다(§3).

비유: 로봇의 `/tmp/df-walklab-*` 파일은 **냉장고 문에 붙이는 메모지**다. Switch가
"앞으로 25mm로 걸어"라고 메모를 갈아 붙이면(`mv -f`로 atomic 교체), 로봇은 100ms마다
냉장고를 들여다보고(폴링) 메모가 바뀌었으면 실행한다. 메모 1장이 e-stop이고
(붙어 있으면 정지), 다른 메모 1장이 로봇이 거꾸로 써 두는 상태 보고(telemetry)다.

> 한계 솔직히: **아직 Switch+로봇을 실제로 함께 돌려본 적이 없다(hardware-unverified).**
> 본 문서는 검증된 Mac 경로와 실제 데몬/전송 코드로부터 도출한 설계 근거이지,
> Switch에서의 end-to-end 실측 보고가 아니다(§6).

---

## 2. 파일 프로토콜 — 정확한 계약 (byte-for-byte contract)

데몬 경로 상수(`WalkLabBrokerage.cpp` L63–67):

| 파일 | 상수 | 방향 | 의미 |
|---|---|---|---|
| `/tmp/df-walklab-cmd` | `CMD_PATH` | Switch→로봇 | 보행 명령 1줄 (atomic write) |
| `/tmp/df-walklab-estop` | `ESTOP_PATH` | Switch→로봇 | **존재 == 정지** (touch/rm) |
| `/tmp/df-walklab-telemetry` | `TELEMETRY_PATH` | 로봇→Switch | 상태 1줄 (~200ms) |
| `/tmp/df-walklab-ack` | `ACK_PATH` | 로봇→Switch | 마지막 명령 ACK(선택) |
| `/tmp/df-pilot-mode` | (main.cpp) | (기동시 1회) | `"walklab"` 면 데몬 진입(§5) |
| `/tmp/df-walklab-uplink` | `UPLINK_PATH` | Switch→로봇 | `"IP PORT"` 적으면 UDP push(선택, §4) |

### 2.1 COMMAND 파일 — 14 토큰 (cmd_id 포함 형식)

`/tmp/df-walklab-cmd`에 **한 줄**, 토큰 공백 구분. 데몬은 nanosecond mtime + size
변화로 변경을 감지하므로(`WalkLabBrokerage.cpp` L522–525), 쓰는 쪽은 반드시 **임시
파일에 쓰고 `mv -f`로 atomic 교체**해야 한다(부분 읽기·동일 길이 명령 미감지 방지).

형식(데몬이 항상 권장하는 cmd_id 포함 14-token 형식):

```
{cmd_id} {enabled} {x} {y} {a} {period} {foot} {hip} {bgain} {benable} {blevel} {headPan} {headTilt} {ballTrack}
```

데몬 파서(`ParseAndApply`, L603–605)는 `sscanf("%31s %d %f %f %f %f %f %f %f %d %d %f %f %f", …)`
로 읽는다. cmd_id 없는 13-token 형식도 받지만(L608–610), **항상 cmd_id 형식으로 보낼 것**.

| 토큰 | 의미 | 데몬 적용 | clamp / 권장값 |
|---|---|---|---|
| `cmd_id` | nonce 문자열(≤31자, 공백X) | ACK에 echo (stale ACK 검출) | `no_id` 기본 |
| `enabled` | 0/1 | `1`→`Walking::Start()`, `0`→`Walking::Stop()` (L679–689) | x/a=0이면 enabled=1로 제자리 걸음 |
| `x` | `X_MOVE_AMPLITUDE` 전후 stride(mm) | L635 즉시 반영 | ~[-40,40], 우리는 max 25 |
| `y` | `Y_MOVE_AMPLITUDE` 측면(mm) | L636 | 현재 0 |
| `a` | `A_MOVE_AMPLITUDE` 회전(deg) | L637 | 우리는 max 12 |
| `period` | `PERIOD_TIME`(ms) | L639, 8ms tick마다 즉시 반영 | ROBOTIS default 600 |
| `foot` | `Z_MOVE_AMPLITUDE` 발 들림 | L638 | default 40 |
| `hip` | `HIP_PITCH_OFFSET`(deg) | L623–624 **데몬이 [0,20] clamp** | default 13 |
| `bgain` | balance gain | **consume만, 미적용** (L597) | 1.0 송신 |
| `benable` | balance enable | **미사용** | 0 송신 |
| `blevel` | balance level | **미사용** | 2 송신 |
| `headPan` | 머리 좌우(deg) | L627–628 **데몬이 [-90,90] clamp** | 우리는 max ~70 |
| `headTilt` | 머리 상하(deg) | L629–630 **데몬이 [-45,45] clamp** | 우리는 max ~35 |
| `ballTrack` | 0/1 온보드 자동 볼 추적 | 1이면 데몬이 머리를 자체 제어(L644–676) | **수동 제어는 0** |

주의: `ballTrack=1`이면 `ProcessBallTracking()`이 카메라로 머리를 잡으므로
`headPan`/`headTilt` Mac 명령은 무시된다(L673, last-write-wins 충돌 방지). 수동
머리 조종을 원하면 반드시 `ballTrack=0`.

### 2.2 E-STOP 파일 — presence == STOP

`/tmp/df-walklab-estop`는 **존재 자체가 정지 신호**다(`EstopRequested()` =
`access(F_OK)`, L137–139).

- e-stop: 파일을 `touch`로 생성 → 데몬이 매 poll 명령 파싱보다 **먼저** 검사
  (L475)하여 즉시 `Walking::Stop()` + body torque off, 파일이 사라질 때까지
  **hold-stopped** 유지(L475–485). getup(자동 일어서기)도 e-stop 동안 발동하지
  않는다(L159–162).
- 복구/재-arm: 파일을 `rm -f` → 데몬이 re-arm, 다음 `Start()`가 torque 복구
  (L486–491). 또한 SIGTERM/SIGINT 핸들러가 별도로 `Stop()`+torque off 후 `_exit`
  (L108–115) — `killall -TERM` 류 belt-and-suspenders 경로.

### 2.3 TELEMETRY 파일 — 10 필드

로봇이 ~200ms(5Hz)마다 atomic write(`WriteTelemetry`, tmp+rename, L758–765).
`cat /tmp/df-walklab-telemetry`로 읽는다. 형식(L749–750):

```
TEL {ts_ms} {gx} {gy} {gz} {ax} {ay} {az} {voltage_dV} {walking01} {fallen}
```

| 필드 | 의미 |
|---|---|
| `ts_ms` | unix epoch ms (간이 monotonic id) |
| `gx gy gz` | raw 10-bit gyro ADC(0..1023, center-subtract 안 됨) |
| `ax ay az` | raw 10-bit accel ADC |
| `voltage_dV` | **deci-volts** (122 ⇒ 12.2V; 0 ⇒ unknown). 3S LiPo [10.5V..12.6V]→[0..100]% 추정 |
| `walking01` | 보행 중 1 / 아니면 0 |
| `fallen` | -1 뒤로 / 0 직립(STANDUP) / 1 앞으로 (`MotionStatus::FALLEN`) |

`voltage_dV=0`은 "unknown"이므로 클라이언트는 저전압 게이트를 발동하면 안 된다
(cm730 NULL fallback 경로, L727–737).

### 2.4 ACK 파일 (선택)

`ParseAndApply` 성공 시 atomic write(L695–705):

```
OK {ts_ms} {cmd_id} {cmd_line}
```

`cmd_id`가 echo되므로 클라이언트가 자기 명령 도달을 확인할 수 있다(stale ACK 구분).
필수는 아니다 — 전달 확인이 필요할 때만 `cat`.

---

## 3. SSH 전송 요구사항 (`SSHShell.swift` 그대로 미러)

로봇은 **OpenSSH 5.9**(매우 구형)다. 아래 옵션은 선택이 아니라 **필수**다 —
`SSHShell.sshArguments()`(L84–122)와 **순서까지 동일하게** 맞춘다.

```
/usr/bin/ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  -o LogLevel=ERROR \
  -o ConnectTimeout=<=10 \
  -o ServerAliveInterval=2 \
  -o ServerAliveCountMax=2 \
  # (멀티플렉스 — identity/~.ssh 존재 시)
  -o ControlMaster=auto \
  -o ControlPath=~/.ssh/df-cm-%C \
  -o ControlPersist=30 \
  # (구형 OpenSSH 5.9 호환 — 필수, 최신 서버엔 무해)
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o HostKeyAlgorithms=+ssh-rsa \
  # (전용 키 존재 시)
  -i <identity_file> -o IdentitiesOnly=yes \
  <user>@<host> <command>
```

핵심 근거:

- **`+ssh-rsa` 두 축 모두 필요**(L108–115): `PubkeyAcceptedAlgorithms`(클라이언트
  *인증 서명*용 SHA-1 RSA)와 `HostKeyAlgorithms`(5.9의 *호스트키*도 SHA-1 RSA)는
  별개 축이다. **하나만으론 5.9와 핸드셰이크 자체가 안 된다** — 둘 다 있어야 함.
  최신 macOS/Ubuntu ssh 클라이언트는 기본적으로 SHA-1 ssh-rsa를 꺼서, 이 옵션 없이는
  구형 서버 RSA 키 인증이 실패한다.
- **RSA 키만 가능, ed25519 불가**: ed25519는 OpenSSH 6.5+. 5.9는 지원 안 함
  (`keyAuthSetupCommand` 주석 L217–219). 그래서 전용 키는 `~/.ssh/id_rsa_darwin`(RSA).
- **ControlMaster 멀티플렉싱**(L99–107): 첫 SSH가 마스터 소켓을 만들고 이후
  명령/telemetry가 핸드셰이크 없이 재사용 → 무선 RTT·throughput 대폭 개선. 소켓
  경로(`~/.ssh/df-cm-%C`)가 필요하므로 `~/.ssh`가 보장될 때(=RSA 키 존재)만 켠다.
- **`ServerAlive 2/2`**(L94–98): WiFi 끊김/stall 시 ~4초(2×2) 안에 ssh가 abort →
  30초 행(hang) + 직렬 큐 막힘 방지. 정지/제어 빠른 복구에 핵심.
- **`accept-new`**(SSHShell L148–152): TOFU. `StrictHostKeyChecking=no` +
  `/dev/null known_hosts`(MITM 취약, 2026-05-17 audit 지적)를 피하면서 첫 연결
  자동 등록.
- **`BatchMode=yes`**: 키 인증 가정. password가 필요하면 즉시 exit 255 +
  "Permission denied"/"publickey" → 키 셋업 미완료로 판단(L193–198, §5).

기본값(`DFConnectionConstants.swift` L9, `SSHShell.swift`):
- host `192.168.123.1` (**유선 직결** — 무선 대비 ~166배 빠름. 항상 유선 우선),
- user `robotis`,
- identity `~/.ssh/id_rsa_darwin` (RSA).

---

## 4. 제어 cadence (amplitude-set + heartbeat + 5s stale-stop)

**보행 gait는 로봇 온보드에서 돈다.** SSH 명령은 amplitude(stride/turn/head)만
바꾼다 — 20Hz로 매 tick을 밀어넣는 것이 아니다. 따라서 cadence는:

1. **변경 시 송신(on change)** — stick 값이 바뀔 때 ~5Hz로 debounce해서
   `cmd` 파일을 교체. (Mac 측 `WalkLabRCBridge`도 amplitude를 slider 채널로 주입
   후 debounce SSH 송출하는 동일 구조 — RCBridge L523–526 주석.)
2. **heartbeat ~1s** — 변화가 없어도 최신 명령을 1초마다 재송신. 데몬의 **stale
   stop(5초)**(`STALE_TIMEOUT_MS=5000`, `.h` L62; 검사 L534–540)이 능동 조종 중에
   트립되지 않게 한다. 5초간 명령 갱신이 끊기면 데몬이 자동 `Stop()`.
3. **deadman-release/stop edge** — 즉시 `enabled=0` 송신.
4. **e-stop edge** — 즉시 `touch` estop 파일.
5. **recover/arm edge** — `rm -f` estop 파일.

선택적 가속 경로(telemetry만): 클라이언트가 `/tmp/df-walklab-uplink`에 `"IP PORT"`를
쓰면 로봇이 매 poll(10–30Hz) 그 주소로 `TEL …` 줄을 **UDP push**한다
(`RefreshUplinkTarget`/`SendTelemetryUDP`, L774–814). 비차단·lossy 허용 —
**신뢰 경로(명령/ACK/e-stop)는 파일+SSH 그대로**라 안전 영향 없음. SSH `cat`
폴링(≈2Hz) 대비 신선도만 향상.

데몬 폴링 주기는 100ms(`POLL_INTERVAL_MS`, `.h` L52)로 e-stop latency를 줄였다.
볼 트래킹 ON일 때만 카메라 프레임 페이스(~30fps)로 더 자주 돈다(L570–572).

---

## 5. switch-pilot 현황 / 전제 / out-of-scope

검증 위치: `tools/switch-pilot/src/darwin_switch_agent/`.

### 현재 구현된 것

- **컨트롤러 입력**: `/dev/input/event*`에서 Switch 스틱/버튼 읽기(`input_linux.py`),
  deadman = `ZL`, Home = e-stop, edge 검출(`safety.py`).
- **매핑/안전 게이트**: 좌스틱→보행 stride/turn, 우스틱→head pan/tilt(`mapping.py`),
  arm/estop 상태 머신과 `gate_motion`(`main.py` L279).
- **코크핏 HUD**: 로컬 웹 UI(`http://127.0.0.1:8765/`, `cockpit.py` + `web/`),
  안전 상태·command authority·스틱 축·로그·직접 안전 액션(arm/stop/estop/recover) +
  로봇 MJPEG 카메라 스트림 메카 HUD(camera tunnel).
- **셋업/배포**: `install.sh`, systemd 서비스, desktop autostart 풀스크린 런처.
- **전송(현재 형태)**: Mac `/mobile-relay` WebSocket 명령(`mac_relay_client.py`,
  `websocket_client.py`) + 로봇-직결 **UDP line-protocol** placeholder
  (`robot_udp_client.py` — 데몬 SAFETY CONTRACT를 주석으로 참조하며 STOP/ESTOP
  edge 송신). `config.py`에 `ssh` 섹션(host/user/port/identity_file) 검증은 존재.

### 본 SSH 파일 프로토콜 경로의 위치

위 UDP/WebSocket은 **현재 형태**이고, 본 문서가 규정한 **SSH `/tmp/df-walklab-*`
파일 경로가 검증된 핵심 원격 경로**다. switch-pilot이 §2의 명령/estop write +
§3의 SSH 전송 + §4 cadence를 구현하면 Mac 없이도 로봇을 직접 조종할 수 있다.
`config.py`의 `ssh` 섹션이 그 자리(host=`192.168.123.1`, user=`robotis`,
identity=RSA 키)를 이미 마련해 둔 상태다.

### 전제(prerequisite) / out-of-scope

1. **walklab 모드 진입은 out-of-scope.** `/tmp/df-pilot-mode == "walklab"`은 로봇
   프로그램이 **기동 시 1회만** 읽는다(`WalkLabBrokerage.cpp` 헤더 주석 L12–17).
   따라서 데몬 진입 = 로봇 프로그램 재시작은 본 설계 범위 밖이다. **로봇이 이미
   walklab brokerage 모드에 있다고 가정**한다. 클라이언트가 mode 파일을 써 두는
   것은 무방하나, 로봇 프로그램을 재시작하려 시도해서는 안 된다.

2. **SSH 키 셋업은 전제다.** Switch의 darwin/사용자 계정이 로봇에 RSA 공개키를 1회
   등록해야 BatchMode 무인증이 성립한다. `SSHShell.keyAuthSetupCommand`(L220–239)를
   그대로 미러한 정확한 셋업 명령(Switch 셸에서 1회):

   ```bash
   # ── DarwinForge SSH 무인증 셋업 (Switch 셸에서 한 번만) ──
   # 로봇 OpenSSH 5.9 구형 → RSA 키 + ssh-rsa 알고리즘 필요.

   # 0. 로봇 SSH 가 꺼져 있으면 먼저 로봇 VNC 에서: sudo service ssh start

   # 1. 전용 RSA 키 생성 (없을 때만, passphrase 없이).
   [ ! -f ~/.ssh/id_rsa_darwin ] && \
     ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa_darwin -C darwin-robot

   # 2. 로봇에 public key 등록 (robotis 비번 한 번 — 기본 111111, 변경했다면 그 비번).
   ssh-copy-id -o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa \
     -i ~/.ssh/id_rsa_darwin.pub robotis@192.168.123.1

   # 3. 검증 — password 없이 'OK' 가 나오면 성공.
   ssh -i ~/.ssh/id_rsa_darwin -o IdentitiesOnly=yes \
     -o PubkeyAcceptedAlgorithms=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa \
     robotis@192.168.123.1 'echo OK from $(hostname)'
   ```

   (`host`/`user`는 wifi 경로면 wlan0 IP로 치환. 키 파일명 `id_rsa_darwin`는
   `SSHShell.defaultOptions()`와 호환 유지.)

---

## 6. 정직성 — 검증 상태 (honesty)

- **hardware-unverified**: Switch와 로봇을 **함께 실측한 적이 없다.** 본 문서는
  (a) 검증된 Mac↔로봇 SSH 파일 프로토콜 코드와 (b) switch-pilot의 현재 골격으로부터
  도출한 설계·근거 문서이지, Switch end-to-end 동작 보고가 아니다.
- 따라서 다음은 **미검증 가정**으로 남는다:
  - Switch의 ssh 클라이언트가 OpenSSH 5.9와 `+ssh-rsa`로 실제 핸드셰이크 성립
    (Mac에서는 검증됨; Switch L4T Ubuntu의 ssh 버전/기본 정책 확인 필요).
  - 무선 경로에서의 cadence(5Hz on-change + 1s heartbeat)가 5s stale-stop을
    실측에서 안정적으로 회피하는지.
  - `mv -f` atomic write가 로봇 `/tmp`(tmpfs) 동일 filesystem에서 보장되는지
    (데몬은 같은 fs 가정, `rename` 사용).
- 다음 단계(실측 게이트): ① §5 키 셋업 → `echo OK` 통과, ② `cat
  /tmp/df-walklab-telemetry`로 `TEL …` 수신 확인, ③ `enabled=1 x=0 a=0`(제자리
  걸음) 단일 명령 + 1s heartbeat로 stale-stop 미트립 확인, ④ e-stop touch/rm 왕복
  레이턴시 측정. 모두 **반드시 정비 스탠드(cradle) + 다리 토크 off + 배터리 분리
  가시권**에서 수행(CLAUDE.md hardware safety).
