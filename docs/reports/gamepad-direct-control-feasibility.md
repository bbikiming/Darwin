# 조종기 무선화 & 조종기→로봇 직결 통신 기술 타당성 분석

> 작성: 2026-06-03 · 대상: DarwinForge (ROBOTIS DARwIn-OP / OP2)
> 질문 ① 다른 블루투스/와이파이 게임패드로 조종 가능한가?
> 질문 ② 조종기 → (Mac 앱 경유 없이) → 로봇 직결 통신이 가능한가?

---

## 0. 결론 (TL;DR)

| 질문 | 판정 | 한 줄 요약 |
|---|---|---|
| ① Mac 앱 경유 게임패드 | **가능·권장** | 패드가 Mac에 붙으면 로봇의 Linux 3.2 커널은 무관. DualSense·Xbox 등은 macOS `GameController.framework`가 USB/BT를 추상화하고, 코드베이스에 `GamepadPilotAdapter`/`CockpitGameControllerWatcher` 경로가 있음. |
| ① 와이파이 게임패드 | **사실상 비권장** | 진짜 TCP/IP 와이파이 게임패드 하드웨어는 시중에 거의 없음. 스마트폰 앱 방식은 가능하나 수신 서버를 직접 구현해야 함. |
| ③ 조종기 → 로봇 직결 | **조건부 가능** | 로봇 백업 기준 기본 커널은 `3.2.66-op2`. `joydev`/`usbhid`/`xpad`/`hid-sony`/`btusb`/`hidp` 자산은 있으나 세대가 오래됨. Logitech F710 D-mode·Xbox 360급 USB/2.4G는 현실적이고, DualSense·최신 Xbox·신형 8BitDo BT는 비권장. |

**핵심 한 줄**: ①은 "Mac이 최신 컨트롤러 호환성을 대신 흡수하는 경로"이고, ③은 "로봇의 구형 Linux 3.2 커널이 직접 패드를 받아야 하는 경로"다. 그래서 같은 DualSense/Xbox라도 ①에서는 유력하고, ③에서는 위험하다.

### 0-1. 이번 추가 검증 범위

사용자가 실행하려는 두 경로를 문서상 다음처럼 고정한다.

| 문서 기준 | 구현 목표 | 호환성 판단 기준 |
|---|---|---|
| **1번: Mac 앱을 거쳐 조종** | 패드 → Mac 앱 → SSH/TCP → 로봇 | macOS `GameController.framework` 또는 Mac IOKit raw HID |
| **3번: 로봇에 직접 연결해서 조종** | 패드 → 로봇 USB/BT → 온보드 데몬 → `Walking`/`Head` | 로봇의 Ubuntu 12.04 + Linux `3.2.66-op2` 드라이버 |

즉 Claude가 지적한 대로, 3번의 핵심 목은 컨트롤러 브랜드가 아니라 **로봇의 구형 커널 3.2**다. 반대로 1번은 로봇 커널을 거의 타지 않는다.

---

## 1. 지금 실제로 어떻게 작동하는가 (코드 기준 확정)

사용자가 "DJI 조종기를 Mac에 유선 연결"할 때 활성화되는 경로 (코드 추적 결과):

```
[DJI FPV RC3, USB]
  → IOKit IOHIDManager (DJIVirtualJoystickHIDClient, VID 0x2CA3 / PID 0x1021 하드코딩)
  → DJIVirtualJoystickReport.decode()  (13바이트 HID 리포트, axis ±660)
  → DJIVirtualJoystickMapper.map()      (Mode 2 부호 컨벤션)
  → CockpitState.apply(from: .djiRC)    (30Hz EMA 평활)
  → WalkLabSession.pilotApplyFreeform()
  → bus.setPositions()  over  TCP(192.168.123.1:5530)  또는  SSH 온보드
  → Dynamixel 서보
```

확정된 사실 3가지:

1. **현재 조종기는 "DJI FPV Remote Controller 3" 특정 모델**이다. `GameController.framework`가 아니라 IOKit raw HID로 읽으며, VID/PID가 하드코딩돼 있다. 이 모델이 작동하는 이유는 DJI 제품 중 예외적으로 **표준 USB HID 게임패드로 노출되기 때문**이다. (DJI RC-N1·RC2 등 다른 모델은 독자 DUML 프로토콜이라 macOS에서 HID로 안 잡힘.)
2. **코드베이스에는 이미 범용 게임패드 경로가 따로 있다** — `WalkLab/Pilot/Gamepad/GamepadPilotAdapter.swift`가 `GCExtendedGamepad`(Apple GameController framework)를 사용한다. 즉 Xbox·DualSense·MFi 컨트롤러를 위한 입력 레이어가 이미 존재한다.
3. **조종기 연결과 로봇 통신은 별개 회선**이다. 조종기는 Mac에 USB HID로 붙어 "입력"만 제공하고, 로봇과의 통신은 이더넷(192.168.123.1) 또는 USB-시리얼로 따로 나간다. iOS 앱은 독립 연결이 아니라 Mac을 경유(WebSocket relay)한다.

---

## 2. 질문 ① — 블루투스 / 와이파이 게임패드로 조종

### 2-1. 블루투스 게임패드: 이미 거의 된다

macOS `GameController.framework`(GCController)는 **입력원을 완전히 추상화**한다. Apple은 Game Controller 프레임워크를 MFi·콘솔 컨트롤러·플랫폼별 입력 장치를 공통 프로파일로 다루는 API로 설명한다.

즉 `GCExtendedGamepad`로 한 번 읽으면 USB든 Bluetooth든 동일 코드로 동작한다. DarwinForge에는 이미 그 코드(`GamepadPilotAdapter`)가 있으므로, **Bluetooth로 페어링된 컨트롤러는 추가 디바이스별 코드 없이 들어온다.**

공식 지원 무선 컨트롤러 / 최초 macOS 버전:

| 컨트롤러 | 연결 | 최초 macOS |
|---|---|---|
| Xbox Wireless Controller (BT) | BT/USB | 10.15 Catalina |
| Sony DualShock 4 | BT/USB | 10.15 Catalina |
| Sony DualSense (PS5) | BT/USB | **11.3 Big Sur** |
| Xbox Series X\|S | BT/USB | 11.3 Big Sur |
| Nintendo Switch Pro | BT | 13 Ventura |

출처: [Apple — Supporting Game Controllers](https://developer.apple.com/documentation/gamecontroller/supporting-game-controllers), [WWDC19 S616](https://developer.apple.com/videos/play/wwdc2019/616/), [MacRumors — DualSense](https://www.macrumors.com/2021/05/21/apple-begins-selling-ps5-dualsense-controller/)

**지연(latency)**: USB 유선 4–8ms vs Bluetooth 10–16ms. DARwIn-OP의 보행 모션은 내부적으로 사전 계획되므로 10–20ms의 추가 지연은 체감 영향이 낮다. 텔레오퍼레이션 연구상 인간 운영자는 50–200ms 루프 지연까지 적응한다. (우려: 2.4GHz 혼잡 환경에서 BT latency spike — 대회/전시장에서는 2.4GHz RF 동글이 더 안정적.)
출처: [gamepadtest.app — BT vs Wired](https://gamepadtest.app/guides/bluetooth-vs-wired-latency), [Teleop latency study (PMC)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11599268/)

**비지원(저가 비브랜드 HID) 컨트롤러**: `GCController.supportsHIDDevice(_:)`로 걸러지고, IOKit raw HID로 직접 매핑해야 한다(디바이스별 버튼 매핑 = 코드 복잡↑). 현재 DJI RC3가 바로 이 raw HID 방식이다.

### 2-2. 와이파이 게임패드: 실체가 거의 없다

진짜 TCP/IP 기반 와이파이 게임패드 **하드웨어**는 시중에 사실상 존재하지 않는다. "무선 컨트롤러"는 거의 전부 Bluetooth 또는 2.4GHz 독자 RF 동글이다.

가능한 유일한 와이파이 경로는 **스마트폰을 게임패드로 쓰는 앱**(Remote Gamepad, Ultimate Gamepad, VirtualGamePad Mobile 등)인데, 이들은 macOS 측에 별도 수신 데몬을 요구하고 `GCController`가 아닌 소켓/가상 HID로 입력을 주입한다 → DarwinForge에 통합하려면 **커스텀 소켓 수신 서버를 직접 작성**해야 한다. 투자 대비 효용 낮음.
출처: [Remote Gamepad (App Store)](https://apps.apple.com/us/app/remote-gamepad/id6448859108), [VirtualGamePad Mobile (F-Droid)](https://f-droid.org/packages/io.github.kitswas.virtualgamepadmobile/)

### 2-3. 질문 ① 판정

| 시나리오 | 가능성 | 코드 변경 |
|---|---|---|
| DualSense/Xbox BT → GCController | **즉시 가능** | 거의 없음 (`GamepadPilotAdapter` 재사용, 페어링만) |
| Switch Pro BT | 가능 | 없음 (macOS 13+ 필요) |
| 저가 HID 무선패드(RF 동글) | 가능, 주의 | 중간 (raw HID 매핑) |
| 스마트폰 와이파이 게임패드 | 조건부 | 큼 (수신 서버 자작) |
| DJI RC-N1/RC2 무선화 | **macOS 불가** | — (DUML, ViGEm은 Windows 전용) |

> 권장: **PS5 DualSense 또는 Xbox 무선 컨트롤러를 Bluetooth로 연결.** 이미 깔린 GCController 경로로 들어오고, 지연도 보행 제어 허용 범위. 현재 DJI RC3 raw-HID 경로는 "되는 예외 케이스"일 뿐, 무선화·범용화 측면에선 GCController 쪽이 정답.

---

## 3. 질문 ② — 조종기 → 로봇 직결 (Mac 우회)

### 3-1. 전제: 로봇은 자체 Linux 컴퓨터다

| | DARwIn-OP (원조) | ROBOTIS-OP2 |
|---|---|---|
| 온보드 CPU | Atom Z530 1.6GHz 싱글 | **Atom N2600 1.6GHz 듀얼** |
| RAM | 1GB | 4GB |
| Wi-Fi | 802.11g | **802.11n** (2.4GHz) |
| USB | USB-A | USB-A 복수 |
| OS | Ubuntu Linux | Ubuntu Linux |
| 서브컨트롤러 | CM-730 | CM-740 (USB-시리얼 ttyUSB) |

→ **"로봇"은 외부 PC 없이 독립 동작 가능한 완전한 Linux 시스템**이다. 따라서 USB 포트에 게임패드를 꽂아 `/dev/input/js0`로 읽는 것은 표준 Linux 기능이다.
출처: [ROBOTIS OP2 e-Manual](https://emanual.robotis.com/docs/en/platform/op2/getting_started/), [robot-advance OP vs OP2](https://www.robot-advance.com/EN/art-darwin-op2-robotis-2357.htm)

### 3-2. 실증 사례: 이미 존재한다

1. **스톡 공식 패키지** — `ROBOTIS-OP/robotis_op_teleop`에 **Xbox360 컨트롤러 전용 온보드 노드**가 있다. `joy_node`가 `/dev/input/js1`을 읽어 `geometry_msgs/Twist` 보행 명령으로 변환한다(소스 직접 확인). 즉 "게임패드 → 로봇 온보드 직결 조종"은 ROBOTIS가 공식 제공한 기능이다.
   출처: [ROBOTIS-OP/robotis_op_teleop](https://github.com/ROBOTIS-OP/robotis_op_teleop)
2. **RoboCup 2011–2013 우승** — DARwIn-OP가 외부 노트북 없이 온보드 PC만으로 인식·보행·킥·기립을 수행. 온보드 제어 루프는 완전히 검증된 패턴.
   출처: [RoMeLa DARwIn-OP](https://www.romela.org/darwin-op-open-platform-humanoid-robot-for-research-and-education/)
3. **Interbotix HROS5**(DARwIn-OP 파생) — PS3 컨트롤러를 Bluetooth(`sixad`)로 로봇에 직결해 온보드 조종하는 데모 포함.
   출처: [Interbotix HROS1 ps3_demo Wiki](https://github.com/Interbotix/HROS1-Framework/wiki/ps3_demo)

### 3-3. 그런데 "DJI 조종기" 직결은 별개 문제

- **현재 DJI FPV RC3는 표준 USB HID**이므로, 이론상 로봇 USB 포트에 직접 꽂으면 Linux도 `/dev/input/js0`로 인식할 가능성이 높다. 단 13바이트 리포트 해석·축 매핑(Mac의 `DJIVirtualJoystickMapper` 로직)을 **온보드 프로그램으로 포팅**해야 한다.
- **무선 DJI(DUML 모델) 직결**은 커뮤니티 드라이버(`stiad/dji-rc-linux`: WiFi 40007포트 DUML→uinput)로 이론상 가능하나 **갱신 9Hz**에 불과하고 미검증. 보행 제어 권장 20–50Hz에 못 미쳐 반응성 저하 우려. OP2의 802.11n이 DJI RC의 WiFi AP에 붙는 동안 다른 네트워크(텔레메트리/인터넷)와 동시 연결이 어려운 운용 제약도 있음.
  출처: [stiad/dji-rc-linux](https://github.com/stiad/dji-rc-linux)

### 3-4. 직결의 진짜 비용: Mac의 두뇌를 잃는다

직결 = 제어 로직이 로봇 온보드로 이동한다는 뜻. Mac이 빠지면:

| Mac DarwinForge 기능 | 직결 시 |
|---|---|
| 모션 라이브러리(`motion_4096.bin`) | 이미 로봇 온보드에 있음 → **영향 없음** |
| 워크 엔진/파라미터 | 온보드 C++로 실행 가능 → 이식 가능 |
| Cockpit 시각화(IMU 인공수평선·텔레메트리) | **포기**, 또는 텔레메트리만 별도 UDP로 Mac에 계속 전송 |
| 음성 명령 / LLM 대화 | **불가** (로봇엔 마이크 입력 장치 없음 — 음성은 Mac 마이크 경유가 전제) |
| SSH 회선 품질 모니터링 | 직결 시 불필요 |

### 3-5. 질문 ② 판정

| 시나리오 | 현실성 |
|---|---|
| Logitech F710 D-mode / generic USB HID → 온보드 직결 보행 | **높음** (커널 3.2의 `usbhid`+`joydev` 경로와 맞음) |
| Xbox 360 유선/무선 리시버 → 온보드 직결 보행 | **높음** (`xpad`가 커널 3.2에 존재) |
| PS3 Sixaxis Bluetooth → 온보드 직결 보행 | 중간 (구형 BlueZ4/sixad 사례는 있으나 페어링 UX가 나쁨) |
| 텔레메트리는 Mac으로 따로 보내며 직결 | 높음 (독립 경로) |
| DJI RC3(USB-HID)를 로봇 USB에 직결 | 중간 (매핑 로직 온보드 포팅 필요) |
| DualSense / 최신 Xbox / 신형 8BitDo Bluetooth 직결 | **낮음** (지원 드라이버가 Linux 3.2 이후 세대) |
| 무선 DJI(DUML)를 WiFi로 직결 | 낮음 (9Hz, 미검증, WiFi 충돌) |
| 직결하면서 LLM/음성까지 유지 | **낮음** (어디선가 Mac 개입 불가피) |

---

## 4. 종합 권고

1. **1번 (Mac 앱 경유)**: 바로 진행 가치 있음. **DualSense/Xbox를 Bluetooth로 페어링**해 기존 `GamepadPilotAdapter`(GCController) 경로로 흘리는 것이 가장 확실·저비용. 이 경로에서는 로봇 Linux 3.2 커널이 컨트롤러 호환성에 개입하지 않는다.
2. **3번 (로봇 직결)**: 기술적으로 가능하지만 컨트롤러 선택을 보수적으로 해야 한다. **Logitech F710 D-mode 또는 Xbox 360급 USB/2.4G 리시버**를 우선 검증하고, DualSense/최신 Xbox/신형 8BitDo Bluetooth는 목표 후보에서 제외한다.
3. **하이브리드가 가장 현실적**: 조종은 로봇 온보드 직결로 지연 최소화하고, 텔레메트리/시각화는 별도 경로로 Mac에 계속 올린다. "직결이냐 Mac이냐"의 양자택일이 아니다.

---

## 5. 불확실 항목 (추가 검증 필요)

- DJI FPV RC3가 로봇 Linux에서 `/dev/input/js0`로 곧바로 인식되는지 — 실기 테스트 미수행.
- Logitech F710 D-mode가 사용자 로봇 실기에서 `/dev/input/js0`로 안정 노출되는지 — 백업 기준 가능성 높음, 실기 미수행.
- 무선 DJI 9Hz가 실제 보행에 충분한지 — 미검증.
- OP2 802.11n과 DJI RC WiFi AP 동시 운용 시 네트워크 충돌 여부 — 미검증.
- BT 게임패드의 2.4GHz 혼잡 환경 latency spike 빈도 — 실측 데이터 없음.
- DualSense/최신 Xbox/8BitDo를 로봇 Bluetooth에 직접 붙이는 것은 현재 조사 기준 비권장. 성공 가능성을 보려면 별도 커널 업그레이드/사용자공간 드라이버 조사가 필요.

---

## 6. [후속] 직결 모드 컨셉 검증 — 단순 보행 / 헤드 무빙 / 볼 트래킹

> 사용자 컨셉: "DarwinForge 앱이 로봇에 **조종기 직결 모드 + 데모를 실행**시킨 뒤, 그 다음부터는 **게임패드로만** 조종". 이 컨셉에서 ⓐ 단순 보행 ⓑ 헤드 무빙 ⓒ 볼 트래킹이 문제없는지 검증.

### 6-1. 결론 먼저

- **ⓐ 단순 보행 — 문제 없음.** 온보드 보행 엔진(`Walking`, 125Hz CPG+IMU 밸런스)이 이미 자립 동작. 게임패드는 x/y/회전 진폭만 주면 됨.
- **ⓑ 헤드 무빙 — 문제 없음.** 온보드 `Head::MoveByAngle()`이 pan/tilt(ID 19/20) 직접 구동. 스틱→헤드 매핑이면 됨.
- **ⓒ 볼 트래킹 — 동작은 문제 없으나(온보드 검증됨), 자율 동작이라 수동 조종과 헤드를 동시에 못 씀 → 버튼 토글 필수.** 이게 유일한 실질 제약.
- **단, 진짜 "Mac이 빠지는" 직결을 하려면 새 코드가 필요하다**: 현재 게임패드는 Mac에 붙어 Mac이 SSH로 중계한다. 게임패드를 로봇에 직접 물려 온보드에서 읽는 입력 경로는 레포에 아직 없다.

### 6-2. 현재 코드가 이미 가진 것 (robotisOnboard 모드)

Mac 앱은 `RobotSetupCommand.walkLabRobotisStart`로 SSH를 통해 로봇에 `demo-pilot`(= `firmware-patches/walklab-brokerage/WalkLabBrokerage.cpp` 빌드물)을 기동한다. 그 뒤 온보드에서 자립적으로 도는 것:

| 온보드 기능 | 구현 | 자립도 |
|---|---|---|
| 보행 | `WalkLabBrokerage.cpp:413` `Walking` 8ms/125Hz 자체 루프 | **온보드 자립** (Mac은 x/y/a 파라미터만 50ms마다 SSH write) |
| 볼 트래킹 | `WalkLabBrokerage.cpp:298` `LinuxCamera`→`ColorFinder`→`BallTracker`→`Head::MoveTracking` | **온보드 자립** (Mac은 `ballTrackingEnabled` 토글만) |
| 헤드 pan/tilt | `WalkLabBrokerage.cpp:671` `Head::MoveByAngle()` | 명령은 Mac→SSH 경유. 볼트래킹 ON이면 온보드가 헤드 점유 |

즉 **"연산(보행·비전)은 이미 온보드 자립, 입력(게임패드)만 아직 Mac 경유"** 상태다. 데모 기동 시퀀스(1회)는 Mac SSH 필요.

### 6-3. 핵심 제약 — 볼 트래킹은 수동 조종과 공존 불가

스톡 프레임워크 소스 확인 결과:
- `BallTracker::Process()` → `Head::GetInstance()->MoveTracking()` : 매 프레임 **헤드를 자율 점유**.
- `BallFollower::Process()` → `Walking::Start()` + 진폭 자동 설정 : **보행까지 자율 점유**(공 가까우면 접근, 정렬되면 킥).
- `Head`는 싱글턴 → 수동 입력과 볼트래커가 같은 루프에서 호출하면 마지막 호출이 덮어써 제어가 뒤섞임 → **동시 구동 불가**.

따라서 컨셉은 반드시 **모드 토글**이어야 한다 (스톡 `StatusCheck` BTN_MODE 패턴과 동일):

```
[게임패드 버튼 A] MANUAL  : 볼트래커 OFF → 스틱이 보행 x/y/a + 헤드 pan/tilt 직접 구동
[게임패드 버튼 B] BALLTRACK: 스틱 무시 → 온보드 자율 볼 추적+접근 (헤드·보행 자동)
```

`WalkLabBrokerage`에 이미 `ballTrackingEnabled` 플래그가 있으므로, 토글 자체는 작은 변경이다.

### 6-4. 진짜 "직결"을 하려면 추가로 필요한 것

| 항목 | 현재 | 직결 시 필요 |
|---|---|---|
| 게임패드 입력 읽기 | Mac `GameController.framework` → SSH 중계 | **로봇 온보드에서 `/dev/input/js0` 직접 읽기** (신규 코드. `robotis_op_teleop` 로직 이식 또는 `WalkLabBrokerage`에 조이스틱 소스 추가) |
| Stale timeout | Mac이 5초 명령 끊기면 자동 정지(`WalkLabBrokerage.cpp:533`) | Mac 빠지면 정지됨 → 온보드 입력일 때는 timeout 완화/제거 필요 |
| 모드 토글 | 없음(Mac UI 토글) | 게임패드 버튼 → MANUAL/BALLTRACK 전환 온보드 처리 |

두 가지 구현 선택지:
- **(A) 완전 직결**: 게임패드를 로봇 USB/BT에 직접 연결, 온보드가 입력 읽음. Mac은 데모 기동 후 완전히 빠짐. → 위 3개 신규 작업 필요.
- **(B) Mac 얇은 중계 유지**: 게임패드→Mac→SSH 현 구조 그대로(이미 작동). "직결 모드"는 UX 명칭. Mac 노트북은 켜둬야 함. → 모드 토글 UX만 추가하면 거의 끝.

### 6-5. 직결 모드에서의 컨트롤러 선택 (중요 — Mac 경로와 다름)

로봇 직결은 **Linux `/dev/input/js0` 인식 여부**가 전부다. macOS GameController framework는 무관.
- **권장: Logitech F710 D-mode 또는 Xbox 360 세대 USB/2.4GHz 리시버.** 동글을 로봇 USB에 꽂고 `/dev/input/js0`로 잡히는지 확인한다. 페어링 UX가 단순하고 Linux 3.2의 `usbhid`/`joydev`/`xpad` 범위 안에 들어온다.
- **비권장: DualSense, 최신 Xbox, 신형 8BitDo를 로봇 Bluetooth에 직접 연결.** 로봇에는 BT 커널 자산은 있지만, Ubuntu 12.04/BlueZ4 + Linux 3.2 조합이라 최신 패드 지원을 기대하기 어렵다.
- 알리익스프레스 무명 패드는 "DirectInput/generic HID"와 Linux 인식 리뷰가 명확한 모델만 실험용으로 본다.

> 참고: **질문 ①(Mac 무선)** 에서는 반대다. Mac은 GCController가 정품 DualSense/Xbox를 더 잘 자동 인식하고, 싸구려 알리 패드는 raw HID 수동 매핑이 필요할 수 있어 **불확실**. 로봇 직결에서도 알리 패드는 generic HID/DirectInput 모드가 확실한 모델만 실험 대상으로 본다.

### 6-6. 직결 컨셉 최종 판정

| 기능 | 직결 모드 가능성 | 비고 |
|---|---|---|
| 단순 보행 | **문제 없음** | 온보드 엔진 검증됨. 입력 경로만 추가 |
| 헤드 무빙 | **문제 없음** | `Head::MoveByAngle` 존재. 스틱 매핑 |
| 볼 트래킹 | **기능 문제 없음** | 온보드 검증(RoboCup). 단 수동과 동시 불가 → 버튼 토글 |
| "Mac이 빠지는" 완전 직결 | **추가 구현 필요** | 온보드 조이스틱 리더 + stale timeout 완화 + 모드 토글 |

한 줄: **세 동작 모두 온보드에서 이미 돌거나 쉽게 돌릴 수 있고, 유일한 진짜 설계 포인트는 "볼 트래킹은 자율이라 수동 조종과 버튼으로 토글해야 한다"는 것. 완전 직결을 원하면 게임패드를 로봇에 직접 물리는 온보드 입력 코드만 새로 짜면 된다.**

---

## 7. [추가 검증] Linux 3.2 커널 기준 게임패드 직결 가능성

> 질문: "2.4GHz 동글 게임패드를 사서 로봇에 직결하면 되는가? DualSense/Xbox/8BitDo가 이 커널에서, 특히 Bluetooth로 잡히는가?"

### 7-1. 결론 먼저

**로봇 직결의 병목은 컨트롤러 브랜드가 아니라 `Linux 3.2.66-op2`다.** 사용자 로봇 백업에는 조이스틱의 기본 부품(`joydev`, `evdev`, `usbhid`, `xpad`, `hid-sony`, `btusb`, `hidp`)이 들어 있다. 그래서 **generic USB HID 또는 Xbox 360 세대의 USB/2.4GHz 리시버는 가능성이 높다.**

반대로 **DualSense, 최신 Xbox One/Series, 신형 8BitDo 2.4G/BT는 커널 3.2 시대 이후에 지원이 붙은 장치가 많아 로봇 직결 후보에서 빼는 것이 맞다.** Mac 앱 경유라면 이 문제를 macOS가 대신 해결하므로 DualSense/Xbox는 다시 좋은 후보가 된다.

### 7-2. 사용자 실제 로봇 환경 (백업 기준)

레포의 `firmware-backups/sda1-rootfs/`와 `docs/firmware-reference/01-system-os.md`에서 확인한 값:

| 항목 | 값 | 근거 |
|---|---|---|
| OS | **Ubuntu 12.04.5 LTS** (Precise, i386 32-bit) | `firmware-backups/sda1-rootfs/etc/lsb-release` |
| 기본 커널 | **3.2.66-op2** (ROBOTIS 커스텀, `SMP PREEMPT`) | `docs/firmware-reference/01-system-os.md:46-66` |
| 프레임워크 | ROBOTIS-OP2 v1.7.0 | `firmware-backups/sda1-rootfs/robotis/ReleaseNote.txt` |
| 컴파일러 | g++ 4.6.3, 사실상 C++03 기준 | `docs/firmware-reference/01-system-os.md:134` |
| USB | 4× USB 1.1 UHCI + 1× USB 2.0 EHCI | `firmware-backups/MANIFEST.md:38` |

조이스틱/블루투스 관련 커널 자산:

| 자산 | 백업 상태 | 의미 |
|---|---|---|
| `CONFIG_INPUT_JOYDEV=m`, `joydev.ko` | 있음 | `/dev/input/js0` 계열 조이스틱 노드 생성 |
| `CONFIG_INPUT_EVDEV=y` | 내장 | `/dev/input/event*` 이벤트 입력 |
| `CONFIG_USB_HID=m`, `usbhid.ko` | 있음 | 표준 USB HID 게임패드/동글 처리 |
| `CONFIG_JOYSTICK_XPAD=m`, `xpad.ko` | 있음 | Xbox 360 세대 XInput USB/리시버 처리 |
| `CONFIG_HID_SONY=m`, `hid-sony.ko` | 있음 | 커널 3.2 기준 PS3 Sixaxis 중심 |
| `CONFIG_BT_HCIBTUSB=m`, `CONFIG_BT_HIDP=m` | 있음 | USB BT 어댑터와 Bluetooth HIDP 스택은 있으나 최신 컨트롤러 보장 아님 |
| `CONFIG_INPUT_UINPUT=y`, `CONFIG_HIDRAW=y` | 있음 | 최후수단으로 사용자공간 드라이버/커스텀 HID 해석 가능 |

중요한 해석: **드라이버 자산이 있다는 것과 최신 컨트롤러가 자동으로 잡힌다는 것은 다르다.** 커널 3.2의 `xpad.c`에는 Xbox/Xbox 360 계열은 있으나 Xbox One 타입이 없다. Xbox One 기본 USB 지원은 Linux 3.17에서 등장한다. DualSense는 `hid-playstation` 드라이버가 필요한데, 이 드라이버는 Linux 5.12 계열부터 본격적으로 들어온다. 신형 8BitDo Ultimate 2C도 upstream `xpad.c`의 최신 ID 추가가 Linux 6.12 계열에 있다.

### 7-3. 컨트롤러별 판정

| 컨트롤러/연결 | Mac 경유(1번) | 로봇 직결(3번, Linux 3.2) | 판정 |
|---|---:|---:|---|
| **DualSense Bluetooth/USB** | 좋음 | 낮음 | Mac 경유 전용 후보. 로봇 커널에는 `hid-playstation` 없음 |
| **Xbox Wireless / Xbox Series Bluetooth** | 좋음 | 낮음 | Mac 경유 전용 후보. 로봇의 `xpad`는 USB 중심이고 3.2에는 Xbox One/Series 세대가 없음 |
| **Xbox 360 유선** | 보통 | 높음 | 로봇 직결 검증용으로 가장 단순 |
| **Xbox 360 Wireless Receiver** | 보통 | 높음 | 커널 3.2 `xpad`가 Xbox 360 무선 리시버 타입을 가짐 |
| **Logitech F710 2.4G, D-mode** | 보통 | **높음** | DirectInput/generic HID로 들어오면 `usbhid`+`joydev` 경로가 가장 안전 |
| **Logitech F710 2.4G, X-mode** | 보통 | 중간~높음 | `xpad` 경로. D-mode보다 커널/ID 의존이 큼 |
| **8BitDo 신형 2.4G/BT** | 모델별 | 낮음 | 신형 XInput ID는 커널 3.2에 없음. DInput/generic HID 모드가 명확한 모델만 예외 가능 |
| **PS3 Sixaxis Bluetooth** | 낮음 | 중간 | `hid-sony`/BlueZ4/sixad 사례는 있으나 페어링 UX가 번거롭고 구형 |
| 무명 알리 2.4G 패드 | 모델별 | 도박 | "Linux generic HID/DirectInput" 확인된 모델만 실험용 |

구매 우선순위는 **1순위 Logitech F710**, **2순위 Xbox 360 유선 또는 Xbox 360 Wireless Receiver**, **보류 DualSense/최신 Xbox/8BitDo**다. 1번(Mac 경유)용으로는 DualSense/Xbox가 더 깔끔하지만, 3번(로봇 직결)용으로는 오히려 구형·단순한 USB HID 장치가 더 안전하다.

### 7-4. 로봇 직결 실기 검증 절차

실기에서 확인할 최소 명령:

```bash
uname -a
sudo modprobe usbhid joydev xpad hid-sony btusb hidp
ls /dev/input/js* /dev/input/event*
dmesg | tail -80
cat /proc/bus/input/devices
jstest /dev/input/js0
```

성공 기준:

| 단계 | 성공 신호 | 실패 시 의미 |
|---|---|---|
| USB/동글 감지 | `dmesg`에 새 USB HID 또는 xpad 장치 표시 | 커널 드라이버/VID-PID 미지원 |
| 조이스틱 노출 | `/dev/input/js0` 생성 | `joydev` 미로드 또는 HID descriptor 비호환 |
| 축/버튼 값 | `jstest`에서 stick/button 변화 | 매핑 코드 작성 가능 |
| 30분 방치 | 입력 끊김 없음 | RF/전원/절전 문제 없음 |

Bluetooth 직결은 후순위다. USB BT 어댑터와 `hidp`는 있지만, Ubuntu 12.04/BlueZ4 시대의 페어링 UX와 최신 컨트롤러 호환성이 병목이다. 먼저 2.4GHz USB 리시버나 유선 USB로 `/dev/input/js0`를 만드는 것이 맞다.

### 7-5. 현재 SW 구조에서 지원되나?

| 층위 | 지원 여부 |
|---|---|
| 로봇 USB 포트 | 있음 |
| Linux 입력 드라이버 | 있음 (`usbhid`/`joydev`/`evdev`/`xpad`) |
| 구형/표준 패드가 `/dev/input/js0`로 노출 | 가능성 높음, 실기 검증 필요 |
| **그 입력을 읽어 보행/헤드로 보내는 온보드 코드** | **현재 없음, 신규 작성 필요** |
| DualSense/최신 Xbox/신형 8BitDo BT 직결 | 비권장 |

정확한 답은 이렇다: **로봇 OS는 표준/구형 게임패드를 받을 준비가 되어 있다. 그러나 현재 `demo-pilot`은 Mac이 쓰는 `/tmp/df-walklab-cmd`만 입력으로 받으므로, 완전 직결을 하려면 `/dev/input/js0`를 읽는 온보드 리더를 새로 붙여야 한다.**

## 8. 구현 방법론과 한계

### 8-1. 1번: Mac 앱 경유 조종

권장 구조:

```text
DualSense/Xbox/F710 등
  -> Mac GameController.framework 또는 IOKit HID
  -> GamepadPilotAdapter / CockpitGameControllerWatcher
  -> WalkLabOnboardBridge
  -> SSH로 /tmp/df-walklab-cmd write
  -> 로봇 WalkLabBrokerage
  -> Walking / Head / BallTracker
```

장점:

| 항목 | 평가 |
|---|---|
| 컨트롤러 호환성 | 가장 좋음. DualSense/Xbox는 macOS가 처리 |
| 구현량 | 가장 작음. 이미 `GamepadPilotAdapter`와 `CockpitGameControllerWatcher` 존재 |
| UX | Cockpit, 텔레메트리, 음성/LLM, 안전 배지 유지 |
| 로봇 커널 3.2 영향 | 거의 없음 |

한계:

| 한계 | 대응 |
|---|---|
| Mac이 꺼지면 조종 불가 | 직결 모드와 병행 구현 |
| SSH/네트워크 지연과 stale timeout | 현재 keepalive/ACK 구조 유지, UI에 회선 품질 노출 |
| 비MFi/저가 패드가 macOS `GCController`에 안 잡힐 수 있음 | IOKit raw HID 매핑을 추가하거나 검증된 DualSense/Xbox 사용 |

### 8-2. 3번: 로봇 직접 연결 조종

권장 구조:

```text
Logitech F710 D-mode 또는 Xbox 360급 USB/2.4G 리시버
  -> 로봇 USB
  -> Linux 3.2 usbhid/xpad + joydev
  -> /dev/input/js0
  -> 신규 OnboardJoystickReader
  -> WalkLabBrokerage 내부의 같은 Walking / Head / BallTracker API
```

신규 구현 항목:

| 항목 | 내용 |
|---|---|
| `OnboardJoystickReader` | C++03로 `/dev/input/js0` nonblocking read. `linux/joystick.h`의 `js_event` 사용 |
| 축 매핑 | 좌스틱: 전후/좌우, 우스틱 X: 회전, 우스틱 Y 또는 D-pad: head pan/tilt |
| 버튼 매핑 | A/Start: walk ready, B: stop, Y: recovery, X: ball tracking toggle, 별도 조합: e-stop |
| 입력 소스 선택 | 기존 파일 입력(`/tmp/df-walklab-cmd`)과 조이스틱 입력을 둘 다 지원 |
| stale 정책 | Mac 파일 입력에는 5초 stale stop 유지. 조이스틱 입력에는 "장치 disconnect/입력 read 실패 N회" 기준으로 별도 stop |
| 안전 UX | Mac이 없을 때도 토크 off/정지 버튼이 패드에 있어야 함 |

한계:

| 한계 | 설명 |
|---|---|
| 최신 컨트롤러 호환성 낮음 | 커널 3.2라 DualSense/최신 Xbox/신형 8BitDo BT는 목표에서 제외하는 게 현실적 |
| UI 피드백 감소 | Mac이 빠지면 Cockpit/텔레메트리/음성/LLM이 사라짐 |
| 볼 트래킹과 수동 헤드 조종 충돌 | 이미 정리한 것처럼 버튼 토글 모드로 분리해야 함 |
| 실기 검증 필수 | `/dev/input/js0` 생성과 축/버튼 번호는 구매한 패드마다 확인 필요 |

### 8-3. 최종 권장 로드맵

1. **먼저 1번으로 DualSense 또는 Xbox를 Mac에 붙여 조종 UX를 완성한다.** 이 경로는 로봇 커널 리스크가 없고 현재 코드 자산을 그대로 쓴다.
2. **3번은 Logitech F710 D-mode로 최소 실기 검증한다.** 목표는 `/dev/input/js0` 생성, `jstest` 축/버튼 변화, 30분 연결 안정성이다.
3. **그 다음 온보드 조이스틱 리더를 `WalkLabBrokerage`에 추가한다.** 보행/헤드/볼트래킹 API는 이미 있으므로 입력 소스만 추가한다.
4. **DualSense/Xbox/8BitDo를 로봇 Bluetooth에 직접 붙이는 방향은 후순위로 둔다.** 성공해도 페어링과 유지보수가 어렵고, 실패 가능성이 높다.

---

## 출처 (주요)

- 로컬 백업 근거: `firmware-backups/sda1-rootfs/etc/lsb-release`, `firmware-backups/sda1-rootfs/boot/config-3.2.66-op2`, `firmware-backups/sda1-rootfs/lib/modules/3.2.66-op2/`, `firmware-backups/MANIFEST.md`, `docs/firmware-reference/01-system-os.md`
- 로컬 코드 근거: `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Pilot/Gamepad/GamepadPilotAdapter.swift`, `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/Cockpit/CockpitGameControllerWatcher.swift`, `app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/Cockpit/DJI/DJIVirtualJoystickHIDClient.swift`, `firmware-patches/walklab-brokerage/WalkLabBrokerage.cpp`
- Linux kernel source: [v3.2 `xpad.c`](https://raw.githubusercontent.com/torvalds/linux/v3.2/drivers/input/joystick/xpad.c), [v3.17 `xpad.c`](https://raw.githubusercontent.com/torvalds/linux/v3.17/drivers/input/joystick/xpad.c), [v3.2 `hid-sony.c`](https://raw.githubusercontent.com/torvalds/linux/v3.2/drivers/hid/hid-sony.c), [v5.12 `hid-playstation.c`](https://raw.githubusercontent.com/torvalds/linux/v5.12/drivers/hid/hid-playstation.c), [v6.12 `xpad.c`](https://raw.githubusercontent.com/torvalds/linux/v6.12/drivers/input/joystick/xpad.c)
- [Apple — Game Controller](https://developer.apple.com/documentation/gamecontroller/) · [Apple Support — Connect a wireless game controller](https://support.apple.com/111099) · [GCExtendedGamepad](https://developer.apple.com/documentation/gamecontroller/gcextendedgamepad)
- [ROBOTIS OP2 e-Manual](https://emanual.robotis.com/docs/en/platform/op2/getting_started/) · [robotis_op_teleop (GitHub)](https://github.com/ROBOTIS-OP/robotis_op_teleop)
- [RoMeLa DARwIn-OP](https://www.romela.org/darwin-op-open-platform-humanoid-robot-for-research-and-education/) · [Interbotix HROS1 ps3_demo](https://github.com/Interbotix/HROS1-Framework/wiki/ps3_demo)
- [stiad/dji-rc-linux](https://github.com/stiad/dji-rc-linux) · [mDjiController](https://github.com/Matsemann/mDjiController) (DUML, Windows)
- [gamepadtest.app — BT vs Wired latency](https://gamepadtest.app/guides/bluetooth-vs-wired-latency)
