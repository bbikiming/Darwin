# Nintendo Switch 기반 Darwin 조종 단말 세팅 계획

작성일: 2026-06-03  
목표: 보유 중인 1세대 Nintendo Switch를 Darwin 로봇 조종 단말로 활용하기 위한 개조, SSH 개발 환경, Mac 경유 조종, 로봇 Wi-Fi 직결 조종의 실행 계획을 정리한다.

## 1. 현재까지 완료된 상태

### 1-1. SD 카드 상태

사용자가 제공한 SD 카드 경로:

```text
/Volumes/SD_Card/DCIM
```

확인 결과 해당 볼륨은 128GB SD 카드였고, 다음과 같이 초기화했다.

| 항목 | 현재 상태 |
|---|---|
| 디스크 | `/dev/disk8` |
| 기존 볼륨 | `/Volumes/SD_Card` |
| 포맷 후 볼륨명 | `SWITCHSD` |
| 파티션 방식 | MBR |
| 파일 시스템 | FAT32 |
| 용량 | 약 128GB |
| 현재 상태 | Hekate 부팅용 1단계 준비 후 안전 추출 완료 |

수행한 명령:

```bash
diskutil eraseDisk FAT32 SWITCHSD MBRFormat /dev/disk8
```

### 1-2. Hekate 설치

공식 Hekate 최신 릴리즈 기준으로 다음 파일을 SD 카드에 설치했다.

| 항목 | 값 |
|---|---|
| Hekate | `v6.5.2` |
| Nyx | `v1.9.2` |
| SD 루트 payload | `/Volumes/SWITCHSD/hekate_ctcaer_6.5.2.bin` |
| SD bootloader 폴더 | `/Volumes/SWITCHSD/bootloader` |
| Mac 보관 payload | `/Users/bbikiming/Downloads/hekate_ctcaer_6.5.2.bin` |

참고: Switchroot L4T Ubuntu Noble은 Hekate `6.0.6` 이상을 요구하므로 `6.5.2`는 조건을 충족한다.

### 1-3. 아직 완료되지 않은 것

현재 SD 카드는 **SSH-ready 상태가 아니다.**

아직 완료되지 않은 작업:

| 작업 | 상태 |
|---|---|
| 스위치 RCM 진입 | 미수행 |
| Hekate 부팅 확인 | 미수행 |
| NAND 백업 | 미수행 |
| SD Linux 파티션 생성 | 미수행 |
| Switchroot L4T Ubuntu 설치 | 미수행 |
| Ubuntu 부팅 | 미수행 |
| SSH 서버 활성화 | 미수행 |
| Switch 조종 앱 구현 | 미수행 |
| Mac 수신기 또는 로봇 UDP 수신기 구현 | 미수행 |

## 2. 최종 목표 구조

진행하려는 경로는 두 가지다.

### 2-1. 경로 A: Switch 앱 → Mac → 로봇

우선 구현 경로로 추천한다.

```text
Nintendo Switch
  -> Joy-Con / 터치 / 버튼 입력
  -> Wi-Fi
  -> Mac DarwinForge
  -> 기존 WalkLabRCBridge / MobileRelay / SSH bridge
  -> 로봇 WalkLabBrokerage
  -> Walking / Head / E-stop
```

장점:

- 현재 Mac 앱에 이미 모바일 릴레이, watchdog, E-stop, preflight, dxlPower 확인 구조가 있다.
- 로봇 온보드 코드를 처음부터 크게 바꾸지 않아도 된다.
- 실패 시 Mac 앱에서 로그와 상태를 보기 쉽다.
- UI/UX 검증이 빠르다.

단점:

- Mac이 반드시 중간에 있어야 한다.
- Switch 앱이 Mac의 WebSocket 프로토콜 또는 새 UDP 어댑터와 통신해야 한다.

### 2-2. 경로 B: Switch 앱 → Wi-Fi → 로봇 직접

2단계 확장 경로로 본다.

```text
Nintendo Switch
  -> Joy-Con / 터치 / 버튼 입력
  -> Wi-Fi UDP
  -> 로봇 WalkLabBrokerage UDP command receiver
  -> Walking / Head / E-stop
```

장점:

- Mac 없이 조종 가능하다.
- 구조가 단순해질 수 있다.

단점:

- 현재 로봇 코드는 UDP 명령 수신을 하지 않는다.
- C++03 온보드 코드에 안전한 UDP 수신기, deadman, stale timeout, sequence 검증을 새로 넣어야 한다.
- Mac의 기존 safety UX와 telemetry UI를 우회하므로 위험도가 높다.

## 3. 스위치 개조 방안

### 3-1. 권장 접근

보유한 모델이 배터리 개선판 이전 1세대라면 우선 **납땜 없는 RCM 기반 softmod**로 접근한다.

추천 순서:

1. RCM 진입 가능 여부 확인
2. Hekate 부팅
3. NAND 백업
4. Switchroot L4T Ubuntu 설치
5. SSH 활성화
6. Switchroot Linux에서 조종 프로토타입 제작
7. 조종 UX와 안전 정책 검증
8. 필요 시 Atmosphère/libnx native homebrew 앱으로 이식

처음부터 native `.nro` 앱으로 가는 것은 가능하지만, 개발/디버깅 난도가 높다. 로봇 조종 UX와 통신 프로토콜을 먼저 안정화하려면 Switchroot Linux가 더 적합하다.

### 3-2. 준비물

| 준비물 | 목적 |
|---|---|
| 현재 세팅한 microSD | Hekate / Switchroot Linux 설치 |
| RCM jig | 스위치를 RCM 모드로 진입 |
| USB-C 데이터 케이블 | Mac/PC에서 payload 주입 |
| Mac 또는 PC | payload 주입 및 SD 파일 복사 |
| Wi-Fi AP | Switch, Mac, 로봇이 같은 네트워크에 있어야 함 |

주의:

- SysNAND를 깨끗하게 유지한다.
- 로봇 조종 실험은 EmuMMC 또는 Switchroot Linux에서만 진행한다.
- Nintendo 온라인 서비스 접속은 피한다.

## 4. 다음 수행 절차

### 4-1. 스위치에서 Hekate 부팅

현재 SD 카드는 이미 안전 추출된 상태다.

다음 절차:

1. SD 카드를 스위치에 삽입한다.
2. 스위치를 완전히 전원 종료한다.
3. RCM jig를 오른쪽 Joy-Con 레일에 삽입한다.
4. `Volume +`를 누른 상태로 전원 버튼을 눌러 RCM 진입을 시도한다.
5. Mac/PC에 USB-C로 연결한다.
6. payload injector로 다음 파일을 주입한다.

```text
/Users/bbikiming/Downloads/hekate_ctcaer_6.5.2.bin
```

성공 기준:

- 스위치 화면에 Hekate/Nyx UI가 표시된다.

실패 기준:

- Nintendo 로고로 정상 부팅된다: RCM 진입 실패 가능성이 높다.
- Mac/PC에서 RCM 장치가 보이지 않는다: 케이블, RCM jig, 모델 패치 여부를 확인해야 한다.

### 4-2. NAND 백업

Hekate가 뜨면 Linux 설치보다 먼저 백업한다.

권장:

- `Tools`에서 eMMC 백업 진행
- BOOT0/BOOT1 및 raw GPP 백업
- 백업 파일은 Mac의 별도 디스크에 복사 보관

이 단계는 시간이 걸리지만, 실패 복구 가능성을 위해 먼저 수행하는 것이 안전하다.

### 4-3. SD 파티션 생성

Switchroot L4T Ubuntu 공식 가이드는 Hekate에서 SD 파티션을 만들도록 안내한다.

절차:

1. Hekate에서 `Tools > Partition SD Card` 진입
2. Linux 파티션 생성
3. FAT32 영역은 설치 파일 복사용으로 최소 8GiB 이상 남김

128GB 카드 기준 제안:

| 파티션 | 권장 크기 |
|---|---:|
| FAT32 | 16~32GB |
| Linux | 나머지 대부분 |

### 4-4. Switchroot L4T Ubuntu 파일 복사

파티션 생성 후 SD를 다시 Mac에 연결한다.

권장 배포판:

| 배포판 | 판단 |
|---|---|
| Ubuntu Unity Noble | 조종 단말 용도로 상대적으로 가볍고 적합 |
| Kubuntu Noble | 데스크톱 기능은 좋지만 조금 무거움 |

공식 다운로드 위치:

```text
https://download.switchroot.org/ubuntu-noble/
```

다운로드할 파일 예:

```text
theofficialgman-ubuntu-unity-noble-5.1.2-2025-08-16.7z
```

압축 해제는 SD FAT32 루트에 한다. 폴더를 하나 더 만들지 않고, 압축 파일 내부 내용을 루트에 직접 풀어야 한다.

### 4-5. Hekate에서 Flash Linux

SD에 Switchroot 파일을 복사한 뒤 다시 스위치에 삽입한다.

절차:

1. Hekate 부팅
2. `Tools > Partition SD Card > Flash Linux`
3. 완료 후 `Nyx Options > Dump Joy-Con BT` 실행
4. `More Configs`에서 L4T Ubuntu Noble 부팅

`Dump Joy-Con BT`는 Joy-Con pairing/calibration 데이터를 Linux에서 안정적으로 쓰기 위해 필요하다.

### 4-6. Ubuntu 부팅 후 SSH 활성화

Switchroot L4T Ubuntu가 부팅되면 터미널에서 SSH를 활성화한다.

```bash
sudo apt update
sudo apt install -y openssh-server git python3 python3-pip evtest joystick
sudo systemctl enable --now ssh
hostname -I
```

Mac에서 접속 확인:

```bash
ssh <switch-user>@<switch-ip>
```

성공 기준:

- Mac 터미널에서 스위치 Ubuntu 셸에 접속된다.

### 4-7. Darwin Switch 런타임 설치

Switchroot Ubuntu와 SSH가 준비되면, repo에서 미리 만든 설치 번들을 스위치로 복사한다.

현재 준비된 패키지:

```text
dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz
```

Mac에서:

```bash
scp dist/switch-pilot/darwin-switch-agent-0.1.0.tar.gz <switch-user>@<switch-ip>:~
```

Switch SSH 안에서:

```bash
tar -xzf darwin-switch-agent-0.1.0.tar.gz
cd darwin-switch-agent-0.1.0
sudo ./install.sh
sudo nano /etc/darwin-switch-agent/config.json
sudo systemctl enable --now darwin-switch-agent
journalctl -u darwin-switch-agent -f
```

설치 결과:

- `darwin-switch-agent` systemd 서비스 등록
- Linux 입력 리더 + Mac relay client + robot UDP client 설치
- 로컬 cockpit UI 서버 실행: `http://127.0.0.1:8765/`
- 데스크톱 로그인 시 cockpit 전체화면 자동 실행

자동 실행은 XDG autostart `.desktop` 파일을 `/etc/xdg/autostart`에 설치하는 방식이다. 데스크톱 환경이 XDG autostart를 처리하면 로그인 후 browser kiosk가 자동으로 열린다.

## 5. 조종 앱 구현 계획

### 5-1. 1차 MVP: Switchroot Linux → Mac

초기 앱은 Switchroot Linux에서 Python으로 만든다.

목표:

- Joy-Con/내장 컨트롤러 입력 확인
- 버튼/스틱을 조종 명령으로 변환
- Mac DarwinForge로 전송
- Mac이 기존 로봇 bridge를 통해 로봇에 전달

입력 검증:

```bash
evtest
jstest /dev/input/js0
```

통신 방식 후보:

| 방식 | 판단 |
|---|---|
| 기존 MobileRelay WebSocket 직접 사용 | 안전 구조 재사용 가능. JSON/WebSocket 구현 필요 |
| Mac에 Switch UDP adapter 추가 | Switch 구현 쉬움. Mac 앱에 새 수신 모듈 필요 |

초기 개발은 빠른 검증을 위해 `UDP -> Mac adapter -> WalkLabRCBridge`도 고려할 수 있다. 안정화 후 기존 MobileRelay WebSocket schema에 맞추는 방식이 좋다.

### 5-2. 버튼 매핑 초안

| Switch 입력 | 기능 |
|---|---|
| ZL hold | deadman. 누르고 있을 때만 이동 허용 |
| Left stick X/Y | 좌우/전후 보행 |
| Right stick X | 회전 |
| B | stop |
| Y | E-stop |
| A long press | arm/recover 확인 |
| D-pad | preset 선택 |
| L/R | 속도 scale 감소/증가 |
| + | 메뉴 / 상태 화면 |
| - | disarm 또는 pairing 화면 |

원칙:

- 이동은 deadman이 눌린 상태에서만 보낸다.
- deadman을 놓으면 즉시 stop을 보낸다.
- E-stop은 어떤 상태에서도 최우선이다.

### 5-3. 2차: Switchroot Linux → 로봇 직접

Mac 경유가 안정화된 뒤 로봇 직결을 구현한다.

로봇 쪽 추가 구현:

| 모듈 | 내용 |
|---|---|
| UDP command socket | 로봇에서 특정 포트 bind, nonblocking receive |
| packet parser | seq, timestamp, token, flags, stick, buttons 파싱 |
| stale timeout | 300~500ms 명령 미수신 시 자동 stop |
| deadman gate | deadman 없으면 이동 명령 무시 |
| clamp | x/y/a/period/foot/hip 값 안전 범위 제한 |
| E-stop latch | E-stop 수신 시 기존 `/tmp/df-walklab-estop`와 동일한 효과 |
| telemetry reply | Switch에 배터리, fall, walking 상태 회신 |

권장 UDP 패킷 초안:

```text
SWP1 seq ts_ms token flags lx ly rx buttons speed
```

예:

```text
SWP1 1042 1780500000123 abcd1234 MOVE 0.10 -0.65 0.00 0x0004 1.0
```

초기에는 사람이 읽을 수 있는 line protocol로 시작하고, 안정화 후 바이너리 패킷으로 바꾸는 것이 디버깅에 유리하다.

## 6. 안전 검증 체크리스트

### 6-1. Switch/Hekate/Linux

| 확인 | 성공 기준 |
|---|---|
| RCM 진입 | payload 주입 가능 |
| Hekate 부팅 | Nyx UI 표시 |
| NAND 백업 | 백업 파일 생성 및 Mac 보관 |
| Linux 부팅 | L4T Ubuntu 화면 표시 |
| SSH | Mac에서 `ssh` 접속 가능 |
| Joy-Con 입력 | `evtest` 또는 `jstest`에서 축/버튼 변화 확인 |

### 6-2. Mac 경유 조종

| 확인 | 성공 기준 |
|---|---|
| Switch → Mac 연결 | pairing 또는 UDP adapter 연결 |
| deadman | 놓으면 stop |
| E-stop | 즉시 로봇 정지 |
| watchdog | Switch 앱 종료/네트워크 끊김 시 500ms 내 stop |
| 속도 제한 | 최대 보행 amplitude 제한 |
| telemetry | Mac UI에서 상태 확인 |

### 6-3. 로봇 직결 조종

| 확인 | 성공 기준 |
|---|---|
| UDP 수신 | 로봇에서 Switch 패킷 수신 |
| sequence 검증 | 오래된 패킷 무시 |
| stale timeout | Wi-Fi 차단 시 자동 stop |
| deadman | deadman 없으면 이동 없음 |
| E-stop | 기존 E-stop latch와 동일 효과 |
| 낙상 복구 | 자동 getup 로직과 충돌 없음 |

## 7. 현재 코드 기준 연결 지점

### Mac 경유에 활용할 수 있는 코드

| 파일 | 역할 |
|---|---|
| `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayCommand.swift` | WebSocket protocol, heartbeat, watchdog 정의 |
| `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayServer.swift` | session, command routing, safety gate |
| `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayBootstrap.swift` | MobileRelay 명령을 WalkLabSession으로 연결 |
| `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Pilot/WalkLabRCBridge.swift` | 보행, stop, emergency 입력 처리 |

### 로봇 직결에 수정해야 할 코드

| 파일 | 현재 상태 | 필요한 변경 |
|---|---|---|
| `firmware-patches/walklab-brokerage/WalkLabBrokerage.cpp` | `/tmp/df-walklab-cmd` 파일 명령만 처리 | UDP command receiver 추가 |
| `firmware-patches/walklab-brokerage/WalkLabBrokerage.h` | UDP telemetry 멤버만 있음 | command socket 상태 추가 |

현재 로봇 브로커리지는 UDP를 텔레메트리 업링크에만 사용한다. Switch 직결 명령을 받으려면 별도 수신 경로를 추가해야 한다.

## 8. 판단

현재 상태에서 가장 안전한 다음 단계는 다음이다.

1. 지금 준비한 SD로 Hekate 부팅 확인
2. NAND 백업
3. Hekate에서 Linux 파티션 생성
4. Switchroot L4T Ubuntu Noble 설치
5. SSH 접속 확인
6. Switchroot Linux에서 입력/네트워크 프로토타입 작성
7. 먼저 Mac 경유 조종을 성공시킨다
8. 이후 로봇 Wi-Fi 직결 UDP 수신기를 추가한다

최종 판단:

> Switch를 Darwin 조종 단말로 쓰는 것은 기술적으로 가능하다.  
> 다만 현재 SD는 Hekate 부팅 준비까지만 완료되었고, 실제 SSH 개발 환경은 Switchroot Linux를 스위치에서 파티션/플래시한 뒤 활성화해야 한다.  
> Mac 경유 경로를 먼저 만들고, 안전 정책이 검증된 뒤 로봇 직결 경로로 확장하는 순서가 맞다.

## 9. 참고 자료

- Switchroot L4T Ubuntu Noble 설치 가이드: https://wiki.switchroot.org/wiki/linux/l4t-ubuntu-noble-installation-guide
- Switchroot Linux 기능: https://wiki.switchroot.org/wiki/linux/linux-features
- Switchroot Ubuntu Noble 다운로드: https://download.switchroot.org/ubuntu-noble/
- Hekate 공식 GitHub: https://github.com/CTCaer/hekate
- Atmosphère 공식 GitHub: https://github.com/Atmosphere-NX/Atmosphere
- libnx HID 문서: https://switchbrew.github.io/libnx/hid_8h.html
- libnx BSD sockets 문서: https://switchbrew.github.io/libnx/bsd_8h.html
