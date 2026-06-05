# Darwin Switch Controller PRD

작성일: 2026-06-04  
상태: Draft for planning  
대상: Nintendo Switch 1세대 + Switchroot L4T Ubuntu 기반 Darwin 로봇 조종 단말

## 1. 결론

Darwin 전용 Switch 조종 단말은 **기존 오픈소스 기반을 커스터마이징해서 구현 가능**하다.

첫 제품 방향은 Nintendo OS 자체를 고치는 펌웨어가 아니라, **Switchroot L4T Ubuntu 위에서 자동 실행되는 Darwin 전용 조종 런타임**으로 잡는다. Hekate/Nyx는 부팅과 Linux 파티션 관리, Switchroot는 실제 Linux 런타임, Atmosphere/libnx는 향후 native homebrew 이식 후보로 사용한다.

우선 구현은 다음 순서다.

1. Switchroot Linux 부팅 및 SSH 개발 환경 구축
2. Switch에서 Darwin 전용 조종 앱 자동 실행
3. Switch -> Mac DarwinForge -> 로봇 경로 구현
4. Switch -> Wi-Fi -> 로봇 직접 경로 추가
5. 안정화 후 필요 시 Atmosphere/libnx native `.nro` 앱으로 이식

## 2. 사용자 설문 반영

| 항목 | 선택 | PRD 반영 |
|---|---|---|
| 최우선 목표 | 1-A | Switchroot Linux 기반 조종 단말 |
| 1차 연결 방식 | 2-C | Mac 경유와 로봇 직결 모두 계획. 구현은 Mac 경유 먼저 |
| Switch 화면 역할 | 3-C | 완전한 cockpit: 상태, 로그, 모드 전환 포함 |
| 조종 입력 | 4-C | 스틱 + 터치 혼합 |
| Deadman | 5-A | `ZL hold` |
| E-stop | 6-C | 화면의 큰 빨간 버튼 중심 |
| 스틱 매핑 | 7-B | 왼쪽 스틱 전후/회전, 오른쪽 스틱 머리 |
| 머리 제어 | 8-B | 오른쪽 스틱 Y tilt, X pan |
| 시작/복구 | 9-B | Arm 확인 후 조종 가능 |
| 네트워크 UX | 10-C | 자동 탐색 + 실패 시 직접 입력 |
| 부팅 UX | 11-B | Linux 부팅 시 Darwin 앱 자동 실행 |
| 개발/관리 | 12-A | SSH 항상 허용 |
| UI 스타일 | 13-C | 산업용 teach pendant 느낌 |
| 실패 시 동작 | 14-B | 500ms heartbeat timeout 후 stop |

안전 보완 조건:

- 화면 E-stop은 제품 UX의 중심으로 둔다.
- 다만 실제 로봇 실기에서는 Mac/로봇 측 소프트 E-stop, stale timeout, 물리 전원 차단 수단을 계속 유지한다.
- 이동 명령은 `ZL hold` deadman이 눌린 상태에서만 송신한다.

## 3. 오픈소스 기반 구성

| 기반 | 역할 | 커스터마이징 범위 |
|---|---|---|
| Hekate / Nyx | Switch bootloader, SD partition, Linux flashing | boot entry, autoboot, SD 구조 |
| Switchroot L4T Ubuntu | Switch에서 실행되는 실제 Linux | SSH, 입력, 네트워크, 자동 실행, 조종 앱 |
| Atmosphere | Nintendo Horizon OS 커스텀 펌웨어 | 후속 native homebrew 실행 환경 |
| libnx / devkitPro | Switch homebrew SDK | 후속 `.nro` 앱에서 HID/소켓 사용 |
| DarwinForge MobileRelay | Mac relay protocol | Switch 클라이언트가 동일 schema로 접속 |
| WalkLabBrokerage | 로봇 온보드 보행 bridge | 직결 UDP command receiver 추가 |

참고 자료:

- Hekate: https://github.com/CTCaer/hekate
- Switchroot Linux features: https://wiki.switchroot.org/wiki/linux/linux-features
- Switchroot L4T Ubuntu Noble: https://wiki.switchroot.org/wiki/linux/l4t-ubuntu-noble-installation-guide
- Atmosphere: https://github.com/Atmosphere-NX/Atmosphere
- libnx HID: https://switchbrew.github.io/libnx/hid_8h.html
- libnx BSD sockets: https://switchbrew.github.io/libnx/bsd_8h.html

## 4. 제품 목표

### 4-1. 사용자 가치

Switch를 Darwin 로봇 전용 조종 패널로 만든다.

사용자는 Switch를 켜고 Linux가 부팅되면 별도 터미널 조작 없이 Darwin 조종 앱을 보게 된다. 화면에서는 연결 상태, 로봇 상태, Arm 여부, E-stop 상태, 배터리, 지연, 로그를 확인하고, Joy-Con과 터치 UI를 함께 사용해 로봇을 조종한다.

### 4-2. 핵심 경험

```text
Switch 전원/부팅
  -> Switchroot Linux
  -> Darwin Controller 자동 실행
  -> Mac 또는 로봇 자동 탐색
  -> Arm 확인
  -> ZL hold 중에만 조종
  -> 연결 끊김 또는 heartbeat timeout 시 자동 stop
```

### 4-3. 비목표

- Nintendo 공식 OS 자체를 Darwin 전용 OS로 대체하지 않는다.
- SysNAND를 실험 대상으로 삼지 않는다.
- 첫 단계에서 Atmosphere native `.nro` 앱을 만들지 않는다.
- 로봇에 UDP 직결을 먼저 붙이지 않는다.
- 화면 E-stop만을 유일한 안전 수단으로 간주하지 않는다.

## 5. 사용자 흐름

### 5-1. 첫 설치 흐름

1. Hekate로 Switchroot L4T Ubuntu 설치
2. Ubuntu 첫 부팅
3. SSH 활성화
4. Darwin controller package 설치
5. Mac/로봇 네트워크 설정
6. 앱 자동 실행 등록

### 5-2. 일반 사용 흐름

1. Switch 부팅
2. Darwin Controller 자동 실행
3. 네트워크 자동 탐색
4. Mac DarwinForge 또는 로봇 후보 표시
5. 사용자가 대상 선택
6. Arm 버튼 확인
7. `ZL hold` 상태에서 스틱 조종
8. `ZL release` 또는 heartbeat timeout 시 stop
9. 화면 E-stop 탭 시 즉시 E-stop

### 5-3. 실패 흐름

| 상황 | 동작 |
|---|---|
| Mac/로봇 탐색 실패 | 직접 IP 입력 화면 표시 |
| Wi-Fi 끊김 | 500ms timeout 후 stop |
| 앱 crash | systemd가 재시작, 로봇은 heartbeat timeout으로 stop |
| Switch sleep | 조종 비활성화, stop 송신 시도 |
| deadman release | 즉시 stop |
| E-stop tap | 즉시 E-stop latch |

## 6. 조종 매핑

### 6-1. 보행

사용자 선택은 `7-B`이므로 보행은 다음과 같이 잡는다.

| 입력 | 기능 |
|---|---|
| `ZL hold` | deadman. 눌린 동안만 이동 허용 |
| Left stick Y | 전진/후진 |
| Left stick X | 좌/우 회전 |
| Right stick X | 머리 pan |
| Right stick Y | 머리 tilt |
| 화면 E-stop | E-stop |
| 화면 Arm | Arm 확인 |
| 화면 Stop | 일반 stop |
| D-pad | preset 또는 속도 단계 |
| `L/R` | 속도 scale 감소/증가 후보 |

### 6-2. 값 범위

| 값 | 초기 범위 |
|---|---:|
| stride x | `-25mm` ~ `25mm` |
| turn a | `-12deg` ~ `12deg` |
| head pan | `-70deg` ~ `70deg` |
| head tilt | `-35deg` ~ `35deg` |
| speed scale | `0.5` ~ `1.0` MVP, 이후 `1.5`까지 확장 |
| deadzone | `0.12` |
| send rate | `20Hz` MVP, 필요 시 `30Hz` |

## 7. 화면 설계 원칙

UI 스타일은 산업용 teach pendant를 따른다.

### 7-1. 첫 화면 정보

첫 화면은 마케팅/설명 화면이 아니라 실제 조종 cockpit이다.

필수 표시:

- 연결 대상: Mac relay 또는 Robot direct
- 연결 상태: connected, searching, stale, disconnected
- Arm 상태
- E-stop 상태
- Deadman 상태
- 로봇 배터리
- 통신 지연
- 마지막 heartbeat
- 현재 입력 모드
- 최근 로그 3~5줄

### 7-2. 주요 조작

- 화면 하단 또는 측면에 큰 E-stop 버튼
- Arm은 의도적 확인 버튼으로 분리
- Stop은 E-stop보다 작지만 항상 접근 가능
- 조종 중에는 deadman 상태가 가장 명확해야 한다
- 개발 중에는 SSH/IP/port 정보가 보이는 diagnostics 패널을 둔다

## 8. 통신 설계

### 8-1. Mac 경유 모드

기존 DarwinForge MobileRelay를 우선 재사용한다.

```text
Switch Controller
  -> WebSocket /mobile-relay
  -> session.hello
  -> pilot.heartbeat every 100ms
  -> pilot.walk / pilot.stop / pilot.estop
  -> Mac MobileRelayServer
  -> WalkLabSession / WalkLabRCBridge
  -> robot WalkLabBrokerage
```

기존 기준:

- WebSocket path: `/mobile-relay`
- heartbeat: `100ms`
- watchdog: `500ms`
- priority command: `pilot.estop`, `pilot.stop`
- freeform walk: supported by Mac capabilities

관련 코드:

- `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayCommand.swift`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayServer.swift`
- `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayBootstrap.swift`

### 8-2. 로봇 직결 모드

로봇 직결은 2단계 기능이다.

현재 `WalkLabBrokerage`는 `/tmp/df-walklab-cmd` 파일 명령을 읽고, UDP는 telemetry uplink에만 사용한다. 따라서 Switch 직결을 위해서는 UDP command receiver를 새로 추가해야 한다.

초기 line protocol:

```text
SWP1 seq ts_ms token flags lx ly rx ry buttons speed
```

예:

```text
SWP1 1042 1780580000123 abcd1234 DEADMAN 0.00 -0.55 0.20 -0.10 0x0001 0.8
```

필수 검증:

- token 일치
- seq 증가
- timestamp stale 방지
- deadman flag 확인
- 값 clamp
- 500ms timeout 시 stop

관련 코드:

- `firmware-patches/walklab-brokerage/WalkLabBrokerage.cpp`
- `firmware-patches/walklab-brokerage/WalkLabBrokerage.h`

## 9. Switchroot Linux 런타임 구성

### 9-0. 선구현 설치 번들

Darwin 전용 Switch 런타임은 다음 경로에 미리 구현해 둔다.

```text
tools/switch-pilot/
```

패키징 산출물은 다음 명령으로 생성한다.

```bash
tools/switch-pilot/package.sh
```

생성되는 파일:

```text
dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz
```

Switchroot Ubuntu가 준비되면 다음처럼 복사하고 설치한다.

```bash
scp dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz <switch-user>@<switch-ip>:~
ssh <switch-user>@<switch-ip>
tar -xzf darwin-switch-agent-0.1.0.tar.gz
cd darwin-switch-agent-0.1.0
sudo ./install.sh
sudo nano /etc/darwin-switch-agent/config.json
sudo systemctl enable --now darwin-switch-agent
journalctl -u darwin-switch-agent -f
```

현재 번들의 범위:

- Linux `/dev/input/event*` 입력 리더
- `ZL` deadman 기본 매핑
- 왼쪽 스틱 보행/회전 매핑
- 오른쪽 스틱 머리 pan/tilt 값 계산
- Mac MobileRelay WebSocket client
- 로봇 직결 UDP line protocol client
- 로컬 웹 cockpit UI: `http://127.0.0.1:8765/`
- 화면 Arm / Stop / Recover / E-stop 버튼
- 데스크톱 로그인 시 cockpit 전체화면 자동 실행
- systemd 자동 실행 서비스
- 설치/제거/패키징 스크립트

아직 포함되지 않은 것:

- Mac head relay hook 보강
- 로봇 UDP command receiver
- 완전한 자동탐색 UI. 현재는 설정 파일의 IP/port 기반
- 로봇 telemetry를 Switch 화면에 직접 표시하는 수신 경로

### 9-1. 패키지 구조

제안 경로:

```text
tools/switch-pilot/
  README.md
  install.sh
  config.example.json
  systemd/darwin-switch-agent.service
  src/
    main.py
    input_evdev.py
    ui.py
    safety.py
    mac_relay_client.py
    robot_udp_client.py
    discovery.py
    mapping.py
    telemetry.py
```

### 9-2. 자동 실행

systemd service:

```text
darwin-switch-agent.service
```

역할:

- 부팅 후 네트워크 대기
- controller app 실행
- crash 시 자동 재시작
- 로그를 `journalctl`로 확인 가능하게 유지

### 9-3. SSH

개발/관리 모드는 SSH 항상 허용이다.

초기 설치 명령:

```bash
sudo apt update
sudo apt install -y openssh-server git python3 python3-pip evtest joystick
sudo systemctl enable --now ssh
```

운영 원칙:

- 개발 중에는 SSH 항상 켜기
- IP와 hostname을 controller UI diagnostics에 표시
- robot-control package는 git pull 또는 scp로 업데이트

## 10. 기술 리스크

| 리스크 | 영향 | 대응 |
|---|---|---|
| Switch가 RCM 불가 모델 | Linux 설치 불가 | serial 확인, unpatched 여부 먼저 검증 |
| Joy-Con 입력 노드 불확실 | 매핑 지연 | `evtest`, `jstest`로 실기 프로파일 수집 |
| Wi-Fi 지연 | 조종 품질 저하 | 20Hz 송신, 500ms watchdog, 지연 표시 |
| 화면 E-stop 오조작 | 정지 지연 | 화면 E-stop + Mac/로봇 stop fallback 유지 |
| Switch sleep | 명령 중단 | sleep 방지, sleep 진입 전 stop |
| 로봇 직결 UDP 구현 | 안전 리스크 | Mac 경유 검증 후 포팅 |
| native homebrew 이식 | 개발 난도 | Linux 앱으로 프로토콜 확정 후 진행 |

## 11. MVP 범위

### 포함

- Switchroot Linux 부팅 후 SSH 접속
- Darwin Switch Controller 자동 실행
- Mac 자동 탐색 + 직접 IP 입력
- Arm 확인
- `ZL` deadman
- 왼쪽 스틱 보행/회전
- 오른쪽 스틱 머리 pan/tilt
- 화면 E-stop
- 100ms heartbeat
- 500ms timeout stop
- 연결/배터리/지연/로그 표시

### 제외

- native `.nro` 앱
- Nintendo OS sysmodule 수정
- 로봇 UDP 직결 실사용
- camera streaming
- motion page 편집
- multi-robot 동시 제어

## 12. 후속 단계

### Phase 0. 스위치 Linux 준비

- RCM jig 준비
- Hekate 부팅
- NAND 백업
- Switchroot L4T Ubuntu Noble 설치
- SSH 확인

### Phase 1. 입력/네트워크 프로토타입

- `evtest`/`jstest` 입력 프로파일 수집
- Python 입력 리더 작성
- Mac IP 직접 입력으로 heartbeat 송신
- stop/E-stop 송신 검증

### Phase 2. Mac 경유 MVP

- MobileRelay WebSocket client 구현
- Arm/heartbeat/walk/stop/estop 송신
- Switch cockpit UI 구현
- DarwinForge에서 실제 로봇 경유 테스트

### Phase 3. 로봇 직결 실험

- 로봇 UDP command receiver 구현
- line protocol 검증
- deadman/stale/seq/token 검증
- 토크 OFF 상태에서 안전 테스트
- 제한 속도 실기 테스트

### Phase 4. Native homebrew 검토

- libnx HID 입력 매핑
- libnx BSD socket 송신
- Linux 앱 UX를 `.nro`로 이식할지 판단

## 13. 성공 기준

MVP 성공 기준:

- Switch 부팅 후 Darwin Controller가 자동 실행된다.
- SSH로 Switch에 접속해 로그를 볼 수 있다.
- Mac relay를 자동 탐색하거나 직접 IP로 연결할 수 있다.
- `ZL`을 누르지 않으면 로봇이 움직이지 않는다.
- `ZL`을 놓으면 500ms 이내 stop 상태가 된다.
- 화면 E-stop을 누르면 Mac/로봇 측 E-stop 상태가 활성화된다.
- 왼쪽 스틱으로 전후/회전, 오른쪽 스틱으로 머리 pan/tilt가 동작한다.
- 네트워크를 끊으면 로봇이 자동 stop 된다.

## 14. 열린 질문

1. 화면 E-stop만으로 충분한지, `Y` 또는 `L+R+Y` 같은 물리 버튼 백업을 추가할지 결정이 필요하다.
2. 오른쪽 스틱 머리 제어와 보행 회전이 동시에 필요한 상황에서 조작 난도가 괜찮은지 실기 검증이 필요하다.
3. Mac 경유와 로봇 직결을 UI에서 같은 모드처럼 보이게 할지, 명확히 다른 모드로 분리할지 결정해야 한다.
4. Switch 화면에서 로봇 카메라/공 추적 상태까지 표시할지 후속 범위를 정해야 한다.
5. native `.nro` 이식이 필요한 제품 목표인지, Switchroot Linux 앱으로 충분한지 MVP 후 판단한다.
