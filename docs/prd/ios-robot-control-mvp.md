# iOS Robot Control MVP PRD

작성일: 2026-05-25  
대상 프로젝트: DarwinForge  
상태: Draft for implementation planning

## 1. 결론

현재 DarwinForge를 분석하면 **iOS 앱으로 로봇을 조종하고 테스트하는 MVP는 가능하다.** 다만 첫 MVP의 권장 구조는 iPhone이 로봇의 USB/시리얼 버스를 직접 제어하는 방식이 아니라, **iPhone → Mac DarwinForge 릴레이 → 로봇** 구조다.

이유는 명확하다.

- 현재 앱은 `Package.swift`에서 `.macOS(.v14)`만 선언된 macOS 전용 SwiftUI 앱이다. `README.md`와 `ADR-001`도 Mac + SwiftUI + Rust FFI + USB serial을 1차 전제로 둔다.
- 로봇 제어 핵심은 CM-730/740 또는 로봇 onboard PC의 `/dev/ttyUSB0`을 거치는 Dynamixel/CM 버스다. ROBOTIS 공식 문서도 Linux 코드 예시에서 `LinuxCM730("/dev/ttyUSB0")`로 CM-730을 제어한다.
- iOS는 일반 USB serial 장치를 자유롭게 여는 플랫폼이 아니다. Apple의 External Accessory는 MFi 액세서리 중심이고, iPadOS DriverKit도 M-series iPad와 별도 드라이버/권한 전제가 있다.
- 반대로 iOS의 `Network.framework`, Bonjour, local network 권한 체계는 **로컬 TCP/WebSocket 기반 원격 컨트롤러**를 만들기에 적합하다.
- 이 프로젝트에는 이미 `Endpoint.network(host:port)`, TCP bus `fc_bus_open_tcp`, `TcpBus`, `RemoteShell`, `WalkLabOnboardBridge`, Remote Pilot, E-stop, ARM, telemetry UI가 있어 Mac을 안전 릴레이로 쓰기 좋다.

따라서 MVP는 “iPhone을 실제 모터 버스의 주 제어기”로 만들지 말고, **iPhone을 안전한 조종 패널**, Mac을 **권한 있는 하드웨어 컨트롤러**, 로봇을 **명령 실행기**로 나눈다.

## 2. 조사 근거

### 2.1 프로젝트 내부 근거

| 근거 | 확인 내용 | MVP 판단 |
|---|---|---|
| `README.md` | macOS 전용 통합 앱, Rust core + SwiftUI UI, USB serial 실기기 연결 | iOS 직접 포팅보다 companion 앱이 현실적 |
| `ADR-001` | macOS-only native Swift/SwiftUI 결정 | 기존 앱 전체를 iOS로 옮기는 것은 아키텍처 변경 |
| `ADR-006` | 기본 통신은 Mac USB → CM-730/740 → Dynamixel bus | iPhone 직접 USB 제어는 기존 전제와 충돌 |
| `ADR-008` | 1차 안전은 하드웨어 E-stop, 2차 소프트 E-stop | 폰 조종도 Mac/robot 측 failsafe가 필수 |
| `Endpoint.swift`, `Bus.swift`, `serial/tcp.rs` | TCP endpoint `host:port`, `fc_bus_open_tcp`, raw byte stream TCP bus 구현 존재 | Mac 또는 robot 네트워크 경로는 이미 설계됨 |
| `RemoteShell.swift` | SSH 우선, SMB fallback 원격 명령 채널 존재 | Mac이 robot onboard PC에 명령을 보낼 수 있음 |
| `WalkLabOnboardBridge.swift` | SSH로 `/tmp/df-walklab-cmd` write, ACK 검증, queue, fallback 구현 | iOS 명령을 Mac이 기존 Onboard 명령으로 변환 가능 |
| `RemotePilotView`, `TeleopChannel`, `PilotSafetyGate` | ARM, Action Bar, E-stop, demo bus 점유 감지 등 이미 있음 | iOS MVP가 새 제어 로직을 만들 필요 없음 |

### 2.2 외부 공식 근거

| 주제 | 근거 | PRD 반영 |
|---|---|---|
| iOS TCP/UDP | Apple `Network.framework`는 TCP/UDP/TLS 등 커스텀 프로토콜 접근을 제공한다. | iOS ↔ Mac relay는 TCP/WebSocket으로 구현 가능 |
| 로컬 네트워크 권한 | `NSLocalNetworkUsageDescription`은 Bonjour와 local host 직접 연결에 필요하다. Bonjour 사용 시 `NSBonjourServices`도 필요하다. | iOS 앱 Info.plist에 local network 사용 사유와 `_darwinforge._tcp` 등록 |
| Bonjour | Bonjour는 로컬 네트워크 서비스 자동 발견용이다. | Mac relay 자동 검색에 사용 |
| MultipeerConnectivity | iOS/macOS 간 nearby discovery와 메시지/stream 통신을 지원하나, 서비스 등록/초대 UX가 들어간다. | 빠른 프로토타입 후보. MVP 주경로는 WebSocket + Bonjour |
| Wi-Fi 가입 | `NEHotspotConfigurationManager`는 iOS에서 SSID 설정/가입을 도울 수 있지만 사용자 승인이 필요하고 capability가 필요하다. | 로봇 AP 가입은 보조 온보딩 기능으로만 둔다 |
| USB/accessory | External Accessory는 MFi 액세서리 통신용이다. DriverKit on iPadOS는 M-series iPad와 드라이버 target 전제다. | iPhone direct USB serial 제어는 MVP 제외 |
| Bluetooth | Core Bluetooth는 BLE/BR-EDR 통신 프레임워크지만 로봇이 BLE GATT 프로토콜을 제공해야 한다. | BLE 브리지는 추가 하드웨어/펌웨어가 필요해 MVP 제외 |
| ROBOTIS OP/OP2 | OP2는 onboard PC, LAN, CM-740 USB/serial, `/dev/ttyUSB0` 기반 Linux 제어를 전제로 한다. Wi-Fi IP는 고정이 아닐 수 있다. | IP 직접 입력보다 mDNS/QR/pairing이 필요 |

참고 링크:

- Apple Network framework: https://developer.apple.com/documentation/network
- Apple local network privacy: https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSLocalNetworkUsageDescription
- Apple TN3179 local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Apple Bonjour: https://developer.apple.com/bonjour/
- Apple MultipeerConnectivity: https://developer.apple.com/documentation/multipeerconnectivity
- Apple NEHotspotConfigurationManager: https://developer.apple.com/documentation/NetworkExtension/NEHotspotConfigurationManager
- Apple External Accessory: https://developer.apple.com/documentation/externalaccessory
- Apple DriverKit for iPadOS: https://developer.apple.com/documentation/driverkit/creating-drivers-for-ipados
- Apple Core Bluetooth: https://developer.apple.com/documentation/corebluetooth
- ROBOTIS OP development: https://emanual.robotis.com/docs/en/platform/op/development/
- ROBOTIS OP2 getting started/spec: https://emanual.robotis.com/docs/en/platform/op2/getting_started/
- Webots ROBOTIS OP2 networking note: https://www.cyberbotics.com/doc/guide/robotis-op2

## 3. 연결 방법론 비교

### 방법 A. iPhone → Mac Relay → Robot

개요:

```
iPhone iOS app
  └── Wi-Fi / local network / Bonjour / WebSocket
      └── Mac DarwinForge relay
          ├── USB serial direct
          ├── TCP 5530 bridge over robot Wi-Fi
          └── SSH WalkLab onboard brokerage
              └── ROBOTIS OP/OP2
```

가능성: **높음**  
MVP 권장도: **1순위**

장점:

- 현재 DarwinForge의 Mac-only Rust FFI, ConnectionStore, TeleopChannel, WalkLab, E-stop, ARM, telemetry를 그대로 활용한다.
- iOS 앱은 하드웨어 제어 앱이 아니라 remote panel이므로 구현 범위가 작다.
- 로봇에 새 바이너리를 반드시 깔지 않아도 된다.
- 유선 LAN이 불가능해도 Mac과 robot이 같은 Wi-Fi 또는 robot AP에 붙으면 동작 가능하다.
- 안전 정책을 Mac에서 단일화할 수 있다. iPhone 연결 끊김, 앱 백그라운드, 네트워크 지연 시 Mac이 즉시 stop/failsafe를 수행한다.

단점:

- Mac이 항상 켜져 있고 DarwinForge가 실행 중이어야 한다.
- iPhone은 Mac relay가 허용한 기능만 쓸 수 있다.
- Mac과 iPhone이 같은 로컬 네트워크에 있어야 한다.

MVP 판단:

- 가장 빠르고 안전하다.
- 사용자가 “유선 LAN으로 로봇 연결이 불가능”하다고 했을 때도, Mac이 robot Wi-Fi/SSH/TCP로 붙는 경로와 잘 맞는다.
- 첫 실기기 테스트는 이 방법으로 시작해야 한다.

### 방법 B. iPhone → Robot Onboard Agent 직접 연결

개요:

```
iPhone iOS app
  └── Wi-Fi / WebSocket
      └── robot onboard PC: darwin-mobile-agent
          ├── /dev/ttyUSB0 / CM-730/740
          ├── ROBOTIS demo / walking module
          └── camera / telemetry
```

가능성: **중간**  
MVP 권장도: **2순위, Mac Relay 이후**

장점:

- Mac 없이 iPhone만으로 로봇을 조종할 수 있다.
- 데모 환경이 간결하다.
- robot-side 125Hz walking engine을 직접 쓰는 구조와 잘 맞는다.

단점:

- robot onboard PC에 새 daemon 설치/업데이트/부팅 등록이 필요하다.
- OP/OP2의 오래된 Ubuntu, 패키지, 권한, `/dev/ttyUSB0` 점유 문제를 다뤄야 한다.
- 보안, pairing, auth, 로그, crash recovery까지 robot-side에서 책임져야 한다.
- iOS 앱이 직접 raw Dynamixel 패킷을 보내면 안전 책임이 분산된다.

MVP 판단:

- 최종 제품 방향으로는 매력적이지만 첫 MVP로는 작업량과 위험이 크다.
- Mac Relay MVP에서 command schema와 UX를 검증한 뒤, 같은 schema를 robot agent로 이식하는 것이 좋다.

### 방법 C. iPhone → Robot TCP 5530 Raw Bridge 직접 연결

개요:

```
iPhone app
  └── TCP 5530 raw Dynamixel/CM byte stream
      └── robot forge-bridge / socat
          └── /dev/ttyUSB0
```

가능성: **기술적으로 가능, 제품적으로 위험**  
MVP 권장도: **비권장**

장점:

- 기존 `forge-bridge`/`socat` TCP 5530 개념과 맞다.
- Mac 없이 직접 연결할 수 있다.

단점:

- iOS 앱에 Dynamixel/CM 프로토콜, safety gate, retry, stale byte drain, timeout, telemetry polling을 새로 구현해야 한다.
- 폰 앱 종료/백그라운드/네트워크 전환이 곧 제어 루프 중단으로 이어진다.
- raw motor command는 UX 실수와 안전 리스크가 크다.
- 기존 Rust core를 iOS로 cross-compile하더라도 현재 SwiftPM/FFI는 macOS 전제라 별도 빌드 시스템이 필요하다.

MVP 판단:

- 실험용 진단 앱으로는 가능하지만, 사용자가 로봇을 움직이는 MVP에서는 제외한다.

### 방법 D. iPhone → BLE/Wi-Fi microcontroller bridge → Robot

개요:

```
iPhone
  └── BLE / Wi-Fi
      └── ESP32 / Pico W / Raspberry Pi bridge
          └── TTL bus 또는 robot PC
```

가능성: **중간**  
MVP 권장도: **비권장**

장점:

- 로봇 자체에 무선 인터페이스를 추가할 수 있다.
- BLE는 iOS에서 표준적으로 접근 가능하다.

단점:

- 추가 하드웨어, 전원, 케이스, 배선, 펌웨어가 필요하다.
- BLE는 raw servo stream에 부적합하다. high-level command만 가능하다.
- Dynamixel TTL bus에 직접 붙는 경우 bus arbitration과 안전성이 복잡하다.

MVP 판단:

- 하드웨어 제품화 단계에서 검토한다. 소프트웨어 MVP에는 맞지 않는다.

### 방법 E. iPhone Hotspot / Robot AP 네트워크 구성

가능성: **보조 수단**  
MVP 권장도: **네트워크 온보딩 기능으로만 반영**

사용 가능한 구성:

- 공용 Wi-Fi/휴대용 라우터: iPhone, Mac, robot onboard PC가 같은 SSID에 접속
- robot AP: robot PC가 Wi-Fi AP를 만들고 iPhone/Mac이 접속
- iPhone Personal Hotspot: Mac/robot이 iPhone hotspot에 접속

주의:

- robot Wi-Fi IP는 고정이 아닐 수 있다. Webots OP2 문서도 Wi-Fi IP는 `ifconfig`로 확인해야 하며 바뀔 수 있다고 설명한다.
- iOS 앱이 주변 Wi-Fi를 마음대로 스캔하거나 무단으로 전환하는 것은 불가능하다.
- `NEHotspotConfiguration`은 사용자의 명시 승인을 요구한다.

MVP 판단:

- 네트워크는 “한 가지 정답”보다 **mDNS/QR/manual IP 3경로**를 제공해야 한다.

## 4. 최종 권장 MVP

제품 이름 가칭: **DarwinForge Mobile Pilot**

핵심 가치:

> iPhone에서 로봇의 상태를 보고, 안전하게 ARM한 뒤, 검증된 동작/보행 명령을 Mac DarwinForge를 통해 실행하고, 테스트 결과를 즉시 기록한다.

### 4.1 MVP 범위

포함:

- iOS SwiftUI 앱 신규 생성
- Mac DarwinForge 내 relay server 추가
- Bonjour 기반 Mac relay 자동 발견
- QR pairing fallback
- iPhone → Mac WebSocket command channel
- Mac → iPhone telemetry stream
- E-stop, ARM, DISARM, stop, walk-ready, 검증된 motion/action 실행
- WalkLab onboard brokerage 명령을 iPhone 조이스틱에서 실행
- 네트워크 끊김/앱 백그라운드/명령 stale 시 자동 stop
- 테스트 세션 로그 저장

제외:

- iPhone direct USB serial
- iPhone direct raw Dynamixel packet 제어
- motion_4096 raw page chain의 iOS 직접 재생
- iOS 단독 카메라/비전 폐루프
- App Store 배포
- BLE bridge 하드웨어 제작
- Mac 없이 완전 단독 동작

### 4.2 성공 기준

첫 MVP는 다음을 모두 만족해야 한다.

- iPhone에서 Mac DarwinForge relay를 10초 이내 발견 또는 QR로 연결할 수 있다.
- iPhone에서 “ARM”을 수행하면 Mac의 기존 `TeleopChannel.arm()` 또는 WalkLab preflight를 통과한 뒤 준비 상태가 표시된다.
- iPhone에서 “정지”를 누르면 300ms 이내 Mac relay가 `stop` 또는 `emergencyStop` 경로를 호출한다.
- iPhone 앱을 강제 종료하거나 Wi-Fi를 끊으면 Mac이 500ms 이내 active walking command를 0으로 만들고 UI에 stale 상태를 표시한다.
- 로봇이 cradle 위에서 `walkReady`, `stop`, `turn left/right`, `slow walk`, `motion action 1개`를 실행할 수 있다.
- 모든 실제 모터 명령은 Mac의 기존 safety gate를 통과한다.
- iOS 화면에는 “시뮬”, “Mac 연결”, “로봇 연결”, “ARM”, “로봇 데모가 bus 점유 중” 상태가 구분되어 보인다.

### 4.3 한 번에 성공하기 위한 MVP 범위 고정

첫 구현에서 이슈를 줄이려면 기능을 많이 넣는 것보다 **성공 가능한 조종 경로를 하나로 고정**해야 한다.

MVP에서 고정할 것:

- 제어 경로는 **iPhone → Mac Relay → 기존 DarwinForge 제어 API** 하나만 사용한다.
- iPhone은 raw Dynamixel packet, USB serial, TCP 5530 raw byte stream을 직접 다루지 않는다.
- 보행 조작은 **deadman 방식**만 허용한다. 화면에서 손을 떼면 항상 `pilot.stop`.
- 조이스틱은 연속 analog streaming이 아니라, MVP에서는 `slowForward`, `turnLeft`, `turnRight`, `stop`의 제한된 command set으로 시작한다.
- 실제 모터 명령은 Mac의 `TeleopChannel`, `ConnectionStore`, `WalkLabSession`, `RemoteShell` 중 이미 검증된 경로만 호출한다.
- iPhone에서 재시도 버튼은 제공하되, Mac relay가 motor command를 자동 반복하지 않는다.
- 모든 화면은 `Mac 연결`, `Robot 연결`, `ARM`, `명령 활성`, `응답 지연`, `E-stop`을 같은 용어로 표시한다.

MVP에서 의도적으로 제외할 것:

- free-form 속도 slider로 실시간 보행 parameter를 무제한 변경
- HighRisk motion의 빠른 실행 버튼
- iOS 단독 camera/vision tracking
- 복수 iPhone 동시 조종
- Mac 없이 robot에 직접 연결

이 제한은 기능 축소가 아니라 첫 실기기 성공률을 높이기 위한 안전한 범위다. 조종기 MVP가 안정되면, 같은 command schema로 robot onboard agent를 후속 구현한다.

## 5. 사용자 경험 PRD

### 5.1 주요 사용자

주 사용자:

- UI/UX 기획자 또는 바이브코더
- 로봇 제어 프로토콜 전문가는 아니지만, 동작 실험을 빠르게 수행하고 싶은 사람
- Mac에서 DarwinForge를 실행할 수 있고, iPhone을 조종 패널로 쓰고 싶은 사람

보조 사용자:

- 실기기 검증자
- 로봇 하드웨어를 옆에서 감시하는 안전 담당자

### 5.2 핵심 시나리오

#### 시나리오 1. iPhone을 Mac 조종 패널로 연결

1. Mac에서 DarwinForge 실행
2. `Mobile Pilot Relay` 토글 ON
3. Mac 화면에 QR 코드와 pairing code 표시
4. iPhone 앱 실행
5. 자동 발견된 Mac 선택 또는 QR 스캔
6. iPhone에 “Mac 연결됨 / 로봇 미연결 또는 로봇 연결됨” 표시

UX 원칙:

- 네트워크 용어보다 상태를 먼저 보여준다.
- 실패 시 “왜 안 되는지”를 한 문장으로 보여준다.
- 예: “Mac은 찾았지만 로봇이 아직 연결되지 않았어요. Mac에서 연결 마법사를 완료하세요.”

#### 시나리오 2. 안전하게 ARM 후 동작 실행

1. iPhone에 하드웨어 체크리스트 표시
2. 사용자가 cradle/tether 확인
3. iPhone에서 길게 밀어 ARM
4. Mac이 기존 ARM sequence 수행
5. iPhone에 준비 완료 표시
6. 사용자가 “보행 자세”, “인사”, “앉기”, “정지” 실행

UX 원칙:

- ARM은 일반 버튼이 아니라 의도적 제스처다.
- 위험 동작은 별도 확인 sheet를 띄운다.
- 실 로봇이 연결되지 않았으면 같은 버튼이 “시뮬 미리보기”로만 동작한다.

#### 시나리오 3. 무선 보행 테스트

1. robot과 Mac이 같은 Wi-Fi에 있음
2. Mac DarwinForge가 robot과 SSH/Onboard 또는 TCP 5530으로 연결
3. iPhone에서 “WalkLab Remote” 진입
4. 조이스틱 또는 segmented command로 `slowWalk`, `turnLeft`, `turnRight`, `stop`
5. iPhone을 놓거나 앱이 백그라운드로 가면 자동 stop

UX 원칙:

- 조이스틱은 “누르고 있는 동안만 이동”한다.
- 손을 떼면 항상 stop.
- 네트워크 지연이 커지면 화면 색으로 “명령 제한”을 보여준다.

#### 시나리오 4. 테스트 기록

1. iPhone에서 테스트 시작
2. motion/walk command 실행
3. Mac이 telemetry와 event log를 기록
4. iPhone에서 결과 summary 확인
5. “통과 / 실패 / 관찰 메모” 입력

UX 원칙:

- 사용자는 파일 경로를 몰라도 된다.
- “이번 테스트에서 실제로 보낸 명령”과 “로봇이 ACK한 명령”을 구분해서 보여준다.

## 6. 정보 구조

iOS 앱 탭 구조:

1. **Connect**
   - Mac relay 발견
   - QR pairing
   - robot 연결 상태
   - network diagnostics

2. **Pilot**
   - ARM slider
   - E-stop
   - Action buttons
   - walk joystick
   - latency/status strip

3. **Test**
   - predefined checklist
   - session timer
   - pass/fail notes

4. **Logs**
   - recent events
   - command/ACK history
   - export hint

첫 화면은 Connect가 아니라, 연결이 되어 있으면 바로 Pilot으로 진입한다. 연결이 없을 때만 Connect flow를 보여준다.

## 7. iOS 조종기 화면 설계

### 7.1 화면 설계 원칙

iOS 앱은 “로봇 설명서”가 아니라 **손에 쥐는 조종기**다. 첫 화면부터 로봇을 조작할 수 있어야 하며, 사용자가 현재 위험 상태를 즉시 이해해야 한다.

화면 원칙:

- 첫 화면은 Pilot이다. 연결이 없을 때만 Connect 화면을 먼저 보여준다.
- E-stop은 모든 화면에서 즉시 접근 가능해야 한다.
- 실 로봇 명령 버튼은 `Robot 연결됨 + ARM 완료 + safety gate 통과` 전까지 비활성 또는 시뮬 미리보기로 표시한다.
- 보행 조작은 눌러서 유지하는 동안만 활성이다. 손을 떼면 정지한다.
- 화면에는 긴 설명 문단을 넣지 않는다. 상태 chip, 버튼 label, toast, bottom sheet로만 안내한다.
- iPhone 한 손 조작을 기준으로 세로 화면을 우선 설계한다. 가로 화면은 검증용 보조 layout으로 둔다.
- 조종 중에는 화면 이동을 최소화한다. Connect, Test, Logs는 조종 전후에 쓰고, Pilot 화면 안에서는 주요 기능을 한 화면에 둔다.
- 색상은 의미 중심으로 쓴다. 초록=준비/정상, 노랑=주의/대기, 빨강=정지/위험, 파랑=연결/정보.

### 7.2 전체 내비게이션

MVP는 4개 탭을 사용한다.

| 탭 | 목적 | 조종 중 접근 |
|---|---|---|
| Pilot | 실제 조종 화면 | 기본 화면 |
| Connect | Mac relay 연결, pairing, robot 상태 | 조종 전 |
| Test | 테스트 세션 시작/종료, 체크리스트, 메모 | 조종 전후 |
| Logs | command/ACK/telemetry 확인 | 조종 후 |

전역 요소:

- 상단 status rail: Mac, Robot, ARM, Latency
- 우상단 E-stop button: 모든 탭에서 고정
- 하단 tab bar: command active 중에도 보이지만, active walk 중 탭 이동 시 `pilot.stop`을 먼저 보낸다.

기본 진입 규칙:

| 조건 | 시작 화면 |
|---|---|
| pairing 없음 | Connect |
| Mac relay 연결됨, robot 미연결 | Pilot, 시뮬/대기 상태 |
| Mac relay + robot 연결됨 | Pilot |
| 직전 세션이 E-stop 상태 | Pilot, E-stop recovery banner |

### 7.3 Pilot 화면

Pilot은 iOS 앱의 핵심 조종 화면이다.

세로 화면 구조:

```text
┌────────────────────────────────────┐
│ Mac ✓   Robot ✓   ARM 잠김   42ms  │  status rail
│                              [STOP]│  global E-stop
├────────────────────────────────────┤
│ 로봇 상태 카드                       │
│ 배터리 11.7V · 온도 42C · endpoint   │
├────────────────────────────────────┤
│ ARM 슬라이더                         │
│ [잠금 해제하려면 길게 밀기 ━━━━━▶]    │
├────────────────────────────────────┤
│ [동작] [보행] [상태]                  │  segmented mode
├────────────────────────────────────┤
│ mode content                         │
│ - 동작: action grid                  │
│ - 보행: deadman joystick             │
│ - 상태: telemetry + last ACK         │
├────────────────────────────────────┤
│ 최근 명령 / toast                    │
└────────────────────────────────────┘
```

#### 7.3.1 Status Rail

목적: 사용자가 “지금 눌러도 되는가”를 1초 안에 판단하게 한다.

항목:

| Chip | 상태 | 표시 |
|---|---|---|
| Mac | connected / searching / lost | `Mac ✓`, `Mac 찾는 중`, `Mac 끊김` |
| Robot | sim / connected / stale / busBusy / disconnected | `Robot ✓`, `시뮬`, `응답 지연`, `데모 점유`, `미연결` |
| ARM | locked / arming / ready / degraded / estopped | `잠김`, `준비 중`, `ARM`, `부분 준비`, `정지됨` |
| Latency | good / caution / blocked | `42ms`, `150ms+`, `제한` |

상태별 버튼 정책:

- `Mac 끊김`: 모든 실 명령 비활성, Connect CTA 표시
- `Robot 미연결`: action button은 시뮬 미리보기만 가능
- `데모 점유`: action/motion 비활성, “수동 모드 복구” CTA 표시
- `응답 지연`: walk joystick 비활성, stop/e-stop만 활성
- `정지됨`: recovery flow 전까지 ARM 불가

#### 7.3.2 E-stop Button

위치: 모든 화면 우상단 고정  
형태: 빨간 원형 icon button, label은 접근성용으로 `긴급 정지`  
동작:

- tap 즉시 `pilot.estop`
- Mac relay는 기존 `ConnectionStore.emergencyStop()` 호출
- iOS는 즉시 화면을 E-stop 상태로 전환한다. Mac ACK를 기다리지 않는다.
- ACK 수신 후 `토크 OFF 확인` 또는 `Mac 응답 없음, 하드웨어 E-stop 사용`으로 표시한다.

허용 상태:

- 항상 활성
- pairing 이전에는 비활성처럼 보이되, 최근 Mac 연결 정보가 있으면 마지막 relay로 전송 시도 가능

완료 기준:

- Pilot, Connect, Test, Logs 어디서 눌러도 같은 동작
- active walk 중 tap 시 joystick touch state와 무관하게 stop보다 높은 우선순위

#### 7.3.3 ARM Slider

목적: 실 로봇 명령 허가를 명시적인 행동으로 만든다.

화면:

- 잠김 상태: `잠금 해제하려면 길게 밀기`
- 진행 상태: `전원 확인`, `토크 준비`, `보행 자세`, `준비 완료`
- 완료 상태: `ARM 완료`
- degraded 상태: `부분 준비`, 세부 사유 chip

동작:

- 80% 이상 drag + 0.2초 hold 시 `pilot.arm`
- checklist 미통과 시 bottom sheet 표시
- 실 로봇 미연결 상태에서는 `시뮬 모드`로 전환하며 gate를 열지 않는다
- ARM 완료 후 action/walk controls가 활성화된다

ARM 전 checklist:

| 항목 | 소스 | 차단 여부 |
|---|---|---|
| Cradle/tether 확인 | 사용자 checkbox | 미확인 시 ARM 차단 |
| Robot 연결 | telemetry | 미연결 시 sim만 허용 |
| Battery | telemetry | 낮음은 경고, 위험은 차단 |
| Temperature | telemetry | 60C 이상 차단 |
| E-stop 상태 | relay state | active면 차단 |
| demo bus 점유 | telemetry | 점유 중이면 차단 |

#### 7.3.4 Mode Segments

Pilot 안의 mode는 세 가지다.

| Segment | 목적 | MVP 활성 |
|---|---|---|
| 동작 | 검증된 motion/action 버튼 | 활성 |
| 보행 | deadman 방식 walk/turn 조종 | 활성 |
| 상태 | telemetry, ACK, 연결 진단 | 활성 |

Segment 변경 규칙:

- active walk 중 segment 변경 시 먼저 `pilot.stop`
- active motion 중 segment 변경은 허용하되 motion progress card 유지
- E-stop 상태에서는 상태 segment로 자동 전환

### 7.4 동작 화면

동작 화면은 “검증된 단발 명령”만 제공한다.

MVP action grid:

| 버튼 | 명령 | Safety | 조건 |
|---|---|---|---|
| 보행 자세 | `pilot.motion(slot: 9)` 또는 `sendPose(.walkReady)` | Safe | ARM 필요 |
| 기본 자세 | `pilot.motion(slot: 1)` 또는 pose mapping | Safe | ARM 필요 |
| 앉기 | `pilot.motion(slot: 15)` 또는 pose mapping | Caution | ARM 필요 |
| 인사 | `pilot.motion(slot: 4)` 또는 pose mapping | Safe/Caution | ARM 필요 |
| 정지 | `pilot.stop` | Safe | 항상 활성 |
| 오른발 차기 | disabled in MVP or high-risk confirm | HighRisk | cradle + confirm 필요 |

MVP 권장 활성 범위:

- 첫 HIL에서는 `보행 자세`, `기본 자세`, `앉기`, `인사`, `정지`만 활성화한다.
- `오른발 차기`, `왼발 차기`는 UI skeleton만 두고 “cradle 검증 후 활성” 상태로 둔다.

버튼 상태:

| 상태 | UI |
|---|---|
| 활성 | icon + label + duration + safety dot |
| ARM 전 | dimmed, tap 시 ARM sheet |
| robot 미연결 | `시뮬` badge, tap 시 preview |
| 실행 중 | progress ring + cancel button |
| 실패 | button 하단 1줄 error, Logs에 상세 |

실패 copy:

- `ARM이 필요해요`
- `로봇 응답이 늦어요. 정지 후 다시 시도하세요.`
- `Mac은 연결됐지만 로봇이 연결되지 않았어요.`
- `ROBOTIS 데모가 USB를 사용 중이에요. 수동 모드로 복구하세요.`

### 7.5 보행 화면

보행 화면은 “조이스틱”처럼 보이되, MVP 내부는 제한된 command set으로 동작한다.

화면:

```text
┌────────────────────────────────────┐
│ 속도 [느림] [보통 잠금] [빠름 잠금] │
│                                    │
│          ┌──────────────┐          │
│          │      ↑       │          │
│          │   ↶  ■  ↷    │          │
│          │      ↓       │          │
│          └──────────────┘          │
│                                    │
│ 현재: 천천히 전진 · ACK 82ms        │
│ [정지]                             │
└────────────────────────────────────┘
```

MVP 활성 command:

| 사용자 입력 | iOS intent | Mac 변환 |
|---|---|---|
| 위 영역 press | `pilot.walkPreset("slowForward")` | `enabled=1 x=20 y=0 a=0 period=700 foot=35 hip=13` |
| 왼쪽 회전 press | `pilot.walkPreset("turnLeft")` | `enabled=1 x=0 y=0 a=8 period=700 foot=35 hip=13` |
| 오른쪽 회전 press | `pilot.walkPreset("turnRight")` | `enabled=1 x=0 y=0 a=-8 period=700 foot=35 hip=13` |
| 중앙/정지 tap | `pilot.stop` | `enabled=0` |
| touch ended/cancelled | `pilot.stop` | `enabled=0` |

Deadman 규칙:

- iOS는 touch active 동안 heartbeat를 100ms마다 보낸다.
- Mac relay는 robot brokering을 최대 5Hz로 제한한다.
- 같은 command 반복은 Mac에서 dedup한다.
- touch ended, app background, WebSocket close, heartbeat 500ms 초과 시 stop.

속도 정책:

- MVP는 `느림`만 활성화한다.
- `보통`, `빠름`은 disabled로 표시하고, 후속 실측 후 활성화한다.
- 이유: 첫 실기기 성공 목표에서는 stride/period 자유 조정이 낙상 리스크를 만든다.

### 7.6 상태 화면

상태 화면은 조종 중 문제를 빠르게 진단하기 위한 화면이다.

표시 항목:

| 섹션 | 표시 |
|---|---|
| 연결 | Mac host, relay port, robot endpoint, active channel |
| 안전 | ARM, E-stop, dxlPower, demo bus 점유 |
| 전원/열 | batteryV, maxTempC, warning threshold |
| 응답 | latency, last command id, last ACK age |
| 최근 이벤트 | last 5 command/result |

액션:

- `Mac 재연결`
- `수동 모드 복구`
- `로봇 정지`
- `로그 열기`

상태 화면은 command 조작을 하지 않는다. 단, `로봇 정지`와 `E-stop`만 예외다.

### 7.7 Connect 화면

Connect 화면은 pairing과 문제 해결에 집중한다.

화면 상태:

| 상태 | 화면 |
|---|---|
| searching | `Mac 찾는 중` + spinner + QR scan button |
| found | Mac 목록 card, `연결` button |
| pairing | 6자리 code 입력 또는 QR scan |
| connected | Mac/Robot 상태 summary, `Pilot으로 이동` |
| blocked | local network 권한 안내 + Settings CTA |
| manual | host:port 직접 입력 |

Mac card 정보:

- Mac 이름
- IP/host
- relay 상태
- robot 연결 여부
- 마지막 응답 시간

QR payload 예:

```json
{
  "type": "darwinforge.mobileRelay",
  "host": "192.168.0.20",
  "port": 17370,
  "pairingCode": "482913",
  "service": "_darwinforge._tcp"
}
```

오류 처리:

- Bonjour 검색 실패: QR scan/manual host를 바로 노출
- local network 권한 거부: 설정 이동 안내
- pairing code 불일치: 3회 제한 후 Mac에서 code 재생성 요구
- Mac 연결 성공, robot 미연결: Pilot 진입 허용, sim/대기 상태 표시

### 7.8 Test 화면

Test 화면은 로봇 실험을 반복 가능하게 만드는 화면이다.

MVP test template:

1. 환경 확인
2. ARM
3. 보행 자세
4. 인사 또는 앉기
5. slow forward 2초
6. turn left 1초
7. stop
8. pass/fail/note

화면 구성:

- session timer
- checklist rows
- 현재 step
- `다음 step` button
- `실패 기록` button
- note field
- 마지막 command/ACK 요약

자동 기록:

- 시작/종료 시각
- Mac host
- robot endpoint
- commands sent
- ACK latency
- E-stop 여부
- 사용자 note

### 7.9 Logs 화면

Logs는 사용자 디버깅용이다. 개발자 콘솔이 아니라, “무슨 일이 일어났는지”를 짧게 보여준다.

표시:

- `12:01:03 ARM 요청`
- `12:01:04 ARM 완료`
- `12:01:06 slowForward 시작`
- `12:01:08 stop ACK 92ms`
- `12:01:10 Robot 응답 지연`

필터:

- 전체
- 명령
- 안전
- 연결
- 오류

액션:

- session summary 보기
- Mac에서 상세 로그 열기 요청

### 7.10 UI/UX 방법론 적용

이 앱은 일반 생산성 앱이 아니라 **물리 로봇을 움직이는 안전 임계 조종기**다. 따라서 사용성 방법론은 “예쁘고 단순한 화면”보다 **상태 인지, 실수 방지, 회복 가능성, 반복 조작 피로 감소**에 맞춘다.

적용 방법론:

| 방법론 | 핵심 | 이 앱에서의 적용 |
|---|---|---|
| Apple Human Interface Guidelines | iOS 사용자에게 익숙한 네이티브 구조와 시스템 컴포넌트 사용 | `TabView`, `NavigationStack`, `Button`, `Toggle`, `Picker(.segmented)`, `confirmationDialog`, `sheet`, SF Symbols, Dynamic Type 사용 |
| Nielsen 10 Usability Heuristics | 상태 가시성, 현실 세계 언어, 사용자 제어, 일관성, 오류 예방 | Status Rail, ARM slider, E-stop, deadman walk, disabled reason, ACK timeline로 반영 |
| Progressive Disclosure | 초보자에게 필요한 것만 먼저 보여주고 고급 정보는 접기 | Pilot에는 조종 필수 요소만, 상세 네트워크/ACK는 상태/Logs로 이동 |
| Safety-Critical Interaction | 위험 동작은 의도적 행동과 명확한 피드백을 요구 | ARM은 drag+hold, HighRisk는 confirm, E-stop은 항상 노출 |
| Recognition over Recall | 사용자가 명령어/상태 의미를 외우지 않게 함 | `Mac ✓`, `Robot ✓`, `ARM`, `응답 지연`처럼 상태 chip으로 표시 |
| Usability Testing | 실제 사용자 과업 기반 검증 | “연결 → ARM → 보행 자세 → 2초 전진 → 정지 → 기록”을 기본 테스트 과업으로 사용 |

Nielsen 휴리스틱 매핑:

| 휴리스틱 | 조종기 적용 규칙 |
|---|---|
| Visibility of system status | 모든 화면 상단에 Mac/Robot/ARM/Latency 표시 |
| Match with real world | “토크”, “ACK” 같은 내부어는 상태 화면에만 사용하고, Pilot에서는 “준비 완료”, “응답 지연”으로 표시 |
| User control and freedom | E-stop, Stop, Disarm을 항상 명확하게 제공 |
| Consistency and standards | iOS 표준 탭, sheet, segmented control, system color, SF Symbol 사용 |
| Error prevention | ARM checklist, latency gate, HighRisk confirm, deadman release stop |
| Recognition rather than recall | 버튼에 icon+label+상태 badge 제공 |
| Flexibility and efficiency | 반복 사용자는 Pilot에서 즉시 조작, 초보자는 Test 화면 step-by-step |
| Aesthetic and minimalist design | Pilot 화면에는 조종에 필요한 상태와 제어만 표시 |
| Error recovery | 오류 메시지는 원인+다음 행동을 한 줄로 제공 |
| Help and documentation | 긴 설명서 대신 상황별 bottom sheet와 Test checklist 제공 |

### 7.11 iOS 네이티브 디자인 방향

디자인 목표:

- iPhone 기본 앱처럼 익숙해야 한다.
- 로봇 조종기처럼 즉각적이어야 한다.
- 위험 상태는 장식보다 정보 위계로 전달해야 한다.
- 한 손 조작이 가능해야 한다.
- Dynamic Type, Dark Mode, Reduce Motion, VoiceOver에서 무너지면 안 된다.

네이티브 구현 기준:

| 영역 | iOS 네이티브 선택 | 사용 이유 |
|---|---|---|
| 앱 구조 | `TabView` + `NavigationStack` | iOS 표준 정보 구조 |
| Pilot segment | `Picker` with `.segmented` | 세 모드 전환을 즉시 이해 |
| 상태 목록 | `List` 또는 grouped `ScrollView` | iOS 설정/상태 화면과 유사 |
| 확인 | `confirmationDialog` / `sheet` | 위험 동작 확인에 적합 |
| 토글 | `Toggle` | 자동 stop, mock mode 등 binary state |
| 진행 | `ProgressView` | ARM/motion 진행도 |
| 아이콘 | SF Symbols `Label` | 시스템 폰트와 자동 정렬 |
| 알림 | inline banner + haptic | 조종 맥락을 끊지 않음 |
| 심각 경고 | full-width red banner / sheet | E-stop, robot stale 등 높은 위험 |

피해야 할 것:

- 커스텀 게임패드처럼 과도하게 스큐어모픽한 조이스틱
- 한 화면에 많은 카드와 긴 설명을 넣는 대시보드식 구성
- 색상만으로 상태를 구분
- 작은 icon-only 버튼
- custom font 중심 디자인
- gesture만 있고 대체 버튼이 없는 조작
- “성공처럼 보이는 pending 상태”

### 7.12 디자인 토큰

iOS 시스템 색상과 Dynamic Type을 우선 사용한다. 브랜드 색은 보조 강조에만 쓴다.

Color tokens:

| Token | iOS source | 용도 |
|---|---|---|
| `AppBackground` | `Color(.systemGroupedBackground)` | 전체 배경 |
| `PanelBackground` | `Color(.secondarySystemGroupedBackground)` | 상태 패널, grouped block |
| `ElevatedBackground` | `Color(.tertiarySystemGroupedBackground)` | 눌림/선택 상태 |
| `PrimaryText` | `.primary` | 주요 label |
| `SecondaryText` | `.secondary` | 보조 label |
| `Accent` | `.accentColor` 또는 system blue | 연결/정보 |
| `Success` | `Color(.systemGreen)` | 준비/정상 |
| `Warning` | `Color(.systemYellow)` 또는 orange | 주의/지연 |
| `Danger` | `Color(.systemRed)` | E-stop/위험 |
| `Disabled` | `.secondary.opacity(0.45)` | 비활성 |

상태 색상 규칙:

| 상태 | 색상 | 보조 표시 |
|---|---|---|
| 정상 | green | checkmark icon |
| 연결/정보 | blue | antenna/network icon |
| 대기/주의 | yellow/orange | exclamationmark icon |
| 위험/정지 | red | octagon/xmark icon |
| 시뮬/미연결 | gray | slash 또는 dotted icon |

Typography tokens:

| Token | SwiftUI style | 용도 |
|---|---|---|
| `ScreenTitle` | `.title2.bold()` | 화면 제목, 과도한 large title 금지 |
| `SectionTitle` | `.headline` | 패널 제목 |
| `Body` | `.body` | 기본 설명 |
| `Metric` | `.title3.monospacedDigit()` | latency, voltage, temp |
| `Caption` | `.caption` | secondary metadata |
| `ButtonLabel` | `.body.weight(.semibold)` | 주요 버튼 |

Typography 규칙:

- SF Pro system font 사용.
- Dynamic Type 전체 지원.
- 조종 중 핵심 숫자(latency, voltage, temp)는 `monospacedDigit()` 사용.
- action button label은 1줄로 강제하지 않는다. 작은 화면에서는 2줄까지 허용한다.
- 가장 큰 접근성 글자 크기에서 Status Rail은 세로 stack으로 전환한다.

Spacing tokens:

| Token | 값 | 용도 |
|---|---:|---|
| `spaceXS` | 4pt | chip 내부 |
| `spaceS` | 8pt | control 간격 |
| `spaceM` | 12pt | 패널 내부 |
| `spaceL` | 16pt | 섹션 간격 |
| `spaceXL` | 24pt | 화면 상하 여백 |

Shape tokens:

| Token | 값 | 용도 |
|---|---:|---|
| `radiusS` | 8pt | chip, small badge |
| `radiusM` | 12pt | button, small panel |
| `radiusL` | 16pt | sheet 내부 panel |
| `radiusXL` | 22pt | ARM slider, walk pad |

Touch target:

- 모든 tappable control은 최소 44x44pt를 기본으로 한다.
- E-stop은 최소 56x56pt로 둔다.
- Walk pad zone은 각 방향 최소 72x72pt 이상으로 설계한다.
- 인접 위험 버튼 사이에는 최소 12pt 이상 간격을 둔다.

### 7.13 컴포넌트 시스템

#### 7.13.1 StatusChip

목적: 연결/안전/응답 상태를 압축해서 표시한다.

구조:

```text
[icon] Label [optional value]
```

상태:

| Variant | 예 | 색 |
|---|---|---|
| connected | `Mac ✓` | green |
| searching | `Mac 찾는 중` | blue |
| warning | `응답 지연` | orange |
| danger | `정지됨` | red |
| neutral | `시뮬` | gray |

규칙:

- chip만으로는 상태 의미가 부족하면 icon을 함께 쓴다.
- 색상만으로 의미를 전달하지 않는다.
- VoiceOver label은 `Mac 연결됨`, `로봇 응답 지연`처럼 완전한 문장으로 둔다.

#### 7.13.2 EmergencyStopButton

목적: 모든 상태에서 즉시 위험을 멈춘다.

UI:

- 빨간 원형 버튼
- SF Symbol: `stop.fill` 또는 `exclamationmark.octagon.fill`
- label text는 시각적으로 `STOP` 또는 `정지`
- accessibility label: `긴급 정지`

상호작용:

- tap 즉시 haptic warning
- UI는 즉시 EStopped로 전환
- ACK pending이면 버튼에 spinner를 넣지 않는다. spinner는 버튼 옆 상태 텍스트로 표시한다.

#### 7.13.3 ArmSlider

목적: 실 로봇 동작 허가를 실수로 누르지 않게 한다.

UI:

```text
[lock icon] 잠금 해제하려면 밀기 ━━━━━▶
```

규칙:

- tap으로 ARM 불가. drag+hold만 허용.
- 완료 전 손을 떼면 원위치.
- 완료 후 slider는 `ARM 완료` 상태 chip으로 바뀐다.
- 실패 시 같은 영역에 inline reason 표시.

#### 7.13.4 ActionButton

목적: 검증된 단발 동작 실행.

구조:

```text
[SF Symbol]
보행 자세
Safe · 1.2s
```

상태:

| 상태 | UI |
|---|---|
| enabled | filled background, clear label |
| disabled | 낮은 opacity + disabled reason on tap |
| running | progress ring + command label |
| success | brief green flash + haptic success |
| failed | red/orange inline text |

규칙:

- label은 동사/결과 중심: `보행 자세`, `앉기`, `인사`, `정지`
- raw slot 번호는 기본 화면에서 숨기고 상태/Logs에서만 표시
- 위험 동작은 destructive confirm sheet 사용

#### 7.13.5 WalkPad

목적: deadman 방식 보행 조종.

구조:

```text
      ↑
   ↶  ■  ↷
      ↓
```

규칙:

- MVP는 위/좌회전/우회전/정지만 활성.
- 아래 방향은 UI skeleton만 두거나 `후속 활성` 상태.
- press 시작 시 haptic light.
- release 시 haptic soft + `정지` toast.
- active 영역은 finger down 상태에서 색상과 scale로 표시하되, 과한 애니메이션 금지.

#### 7.13.6 InlineBanner

목적: 조종 흐름을 방해하지 않고 상태를 알린다.

종류:

| Variant | 예 |
|---|---|
| info | `Mac은 연결됨 · 로봇은 아직 미연결` |
| warning | `응답이 늦어 보행 조작을 제한했어요` |
| danger | `긴급 정지됨 · 하드웨어 E-stop도 확인하세요` |
| success | `ARM 완료` |

규칙:

- 성공 toast는 1.5초 이내 자동 소멸.
- 위험/오류 banner는 사용자가 확인하거나 상태가 회복될 때까지 유지.
- 자동 소멸 banner에는 중요한 안전 정보를 넣지 않는다.

#### 7.13.7 BottomSheet

목적: 흐름을 유지하면서 추가 확인/복구를 제공한다.

사용:

- ARM checklist
- HighRisk confirm
- pairing code 입력
- local network permission recovery
- E-stop recovery

규칙:

- destructive action은 system red role 사용.
- sheet 안의 primary action은 하단에 고정.
- cancel은 항상 제공.
- 한 sheet에 선택지를 3개 이상 넣지 않는다.

### 7.14 화면별 iOS 네이티브 UI 상세

#### Pilot

Navigation:

- `NavigationStack`
- title은 inline `Pilot`
- 우측 toolbar에 E-stop
- large title은 사용하지 않는다. 조종 화면에서는 vertical space가 중요하다.

Layout:

- top: Status Rail
- middle: RobotStatePanel + ArmSlider
- segment: Actions / Walk / State
- bottom: 최근 command banner

Native feel:

- panel은 grouped background 위에 secondary grouped background 사용.
- scroll은 필요할 때만. 기본 iPhone 크기에서는 Pilot 주요 조작이 첫 viewport에 들어와야 한다.
- Tab bar는 유지하되 active walk 중 tab tap은 stop 후 이동.

#### Connect

Navigation:

- title `연결`
- grouped list 스타일

Sections:

1. 자동 발견
2. QR 연결
3. 직접 입력
4. 문제 해결

Native feel:

- Mac relay card는 `List` row처럼 동작.
- pairing code 입력은 system number pad.
- local network 권한 안내는 system Settings CTA와 함께 표시.

#### Test

Navigation:

- title `테스트`
- checklist는 numbered list

Native feel:

- 각 step은 `Label` + status circle.
- 현재 step만 강조.
- `다음` 버튼은 bottom safe area에 고정.
- 실패 기록은 destructive가 아니라 warning action으로 둔다. 실제 파괴 동작이 아니기 때문이다.

#### Logs

Navigation:

- title `기록`
- `List` 사용

Native feel:

- event row는 시간, icon, title, detail 구조.
- filter는 segmented picker.
- 상세는 sheet로 표시.
- raw JSON은 기본 숨김. copy/export action에서만 노출.

### 7.15 Interaction and Feedback

Haptics:

| 이벤트 | Haptic |
|---|---|
| ARM slider threshold 도달 | medium impact |
| ARM 성공 | success notification |
| ARM 실패 | warning notification |
| Walk press 시작 | light impact |
| Walk release stop | soft impact |
| E-stop | error notification |
| command ACK | very light 또는 없음 |

Motion:

- Reduce Motion이 켜져 있으면 scale/spring 대신 opacity transition 사용.
- E-stop flash는 강한 반복 점멸 금지. 1회 색상 전환 + banner로 충분하다.
- progress ring은 linear로 움직인다.

Feedback hierarchy:

| 중요도 | UI |
|---|---|
| 낮음 | passive chip/text |
| 보통 | inline banner |
| 높음 | sheet |
| 안전 임계 | persistent red banner + haptic + E-stop state |

Loading:

- 연결/페어링은 spinner 허용.
- E-stop은 spinner로 버튼을 대체하지 않는다.
- command pending은 `ACK 대기` 상태로 표시한다.

### 7.16 접근성 설계

Apple 접근성 지침을 조종기 앱에 적용한다.

필수:

- Dynamic Type 전체 지원
- VoiceOver label/value/hint 제공
- 색상 외 icon/text로 상태 구분
- 최소 touch target 44x44pt
- Reduce Motion 대응
- Dark Mode 대응
- Increase Contrast 대응
- Voice Control에서 주요 버튼 이름으로 실행 가능

VoiceOver 예:

| UI | label | value | hint |
|---|---|---|---|
| Mac chip | `Mac 연결 상태` | `연결됨` | 없음 |
| Robot chip | `로봇 연결 상태` | `응답 지연` | `상태 탭에서 자세히 확인할 수 있습니다` |
| ARM slider | `로봇 동작 허가` | `잠김` | `오른쪽으로 끝까지 밀어 ARM합니다` |
| E-stop | `긴급 정지` | 없음 | `즉시 모든 동작을 정지합니다` |
| Walk forward | `천천히 전진` | `누르는 동안 활성` | `손을 떼면 정지합니다` |

Large text 대응:

- Status Rail: horizontal chips → 2열 grid 또는 vertical stack
- Action grid: 2 columns → 1 column
- WalkPad: 고정 최소 영역 유지, label은 pad 아래로 이동
- Bottom sheet: content scroll 가능, primary action은 bottom 고정

### 7.17 사용성 테스트 계획

대상 사용자:

- 개발 전문성이 낮은 UI/UX 기획자 1명
- 로봇 조작 경험자 1명
- 안전 감시자 역할 사용자 1명

정성 테스트 과업:

| 과업 | 성공 기준 |
|---|---|
| Mac relay 연결 | 도움 없이 2분 내 연결 |
| ARM 전 상태 이해 | 왜 버튼이 비활성인지 설명 가능 |
| ARM 수행 | checklist 의미를 이해하고 완료 |
| 보행 자세 실행 | action 완료 상태를 인지 |
| 2초 전진 후 정지 | 손을 떼면 정지된다는 모델 이해 |
| E-stop 사용 | 1초 내 버튼 발견 |
| 오류 복구 | `응답 지연` 상태에서 다음 행동 이해 |
| 테스트 기록 | pass/fail/note 저장 |

관찰 지표:

- 첫 E-stop 발견 시간
- ARM 실패 사유 이해 여부
- disabled reason 확인 여부
- release stop mental model 형성 여부
- status rail을 읽는 순서
- 조종 중 시선이 과도하게 분산되는지

정량 기준:

- E-stop 발견: 1초 이내
- ARM 성공: 2분 이내
- slowForward → release stop 과업: 1회 설명 후 성공
- local network 오류 복구: 3분 이내
- `왜 안 움직이는지` 질문에 사용자가 UI만 보고 답변 가능

### 7.18 디자인 QA 체크리스트

첫 빌드 전 디자인 QA:

- Pilot 첫 화면에서 E-stop이 보이는가?
- Pilot 첫 화면에서 Mac/Robot/ARM/Latency가 보이는가?
- Robot 미연결 상태가 실 조작 가능처럼 보이지 않는가?
- ARM 전 action button tap 시 이유와 다음 행동이 보이는가?
- WalkPad release가 확실히 stop으로 보이는가?
- 위험 상태가 색상만으로 전달되지 않는가?
- Dynamic Type largest에서 텍스트가 겹치지 않는가?
- Dark Mode에서 Danger/Warning/Success 대비가 충분한가?
- VoiceOver로 E-stop, ARM, Stop, Walk forward를 실행할 수 있는가?
- Reduce Motion에서 조작 피드백이 유지되는가?
- 한 손으로 E-stop과 Stop에 닿는가?
- 화면 회전/잠금/앱 전환 후 상태가 stale로 표시되는가?

### 7.19 UI/UX 참고 근거

본 디자인 시스템은 아래 자료를 기준으로 한다.

| 자료 | 반영 내용 |
|---|---|
| Apple Human Interface Guidelines | iOS 네이티브 구조, 플랫폼 일관성 |
| Apple Buttons | 버튼은 즉각적 action을 수행하고 style/content/role로 의미를 전달 |
| Apple Color | 색상은 상태와 피드백을 돕되 접근성을 고려 |
| Apple Typography | SF Pro, Dynamic Type, 가독성, 정보 위계 |
| Apple SF Symbols | system font와 맞는 일관된 icon, 상태 variant |
| Apple Accessibility | Dynamic Type, 색상 외 정보 전달, 44x44pt control, VoiceOver |
| Apple Feedback | 상태/성공/실패/경고의 중요도에 맞는 피드백 방식 |
| Nielsen Norman Group 10 Heuristics | 상태 가시성, 사용자 제어, 오류 예방, 회복성 |
| Nielsen Norman Group Usability Testing 101 | 실제 과업 기반 정성 테스트 |

링크:

- Apple HIG: https://developer.apple.com/design/human-interface-guidelines/
- Apple Buttons: https://developer.apple.com/design/human-interface-guidelines/buttons
- Apple Color: https://developer.apple.com/design/human-interface-guidelines/color
- Apple Typography: https://developer.apple.com/design/human-interface-guidelines/typography
- Apple SF Symbols: https://developer.apple.com/design/human-interface-guidelines/sf-symbols
- Apple Accessibility: https://developer.apple.com/design/human-interface-guidelines/accessibility
- Apple Feedback: https://developer.apple.com/design/human-interface-guidelines/feedback
- Apple Layout: https://developer.apple.com/design/human-interface-guidelines/layout
- NN/g 10 Usability Heuristics: https://www.nngroup.com/articles/ten-usability-heuristics/
- NN/g Usability Testing 101: https://www.nngroup.com/articles/usability-testing-101/

## 8. 기능 정의

### 8.1 기능 목록

| ID | 기능 | Priority | iOS 책임 | Mac relay 책임 | 완료 기준 |
|---|---|---|---|---|---|
| F-01 | Mac relay 자동 발견 | P0 | Bonjour browse, 목록 표시 | `_darwinforge._tcp` advertise | 같은 Wi-Fi에서 10초 이내 발견 |
| F-02 | QR/manual pairing | P0 | QR scan, code 입력, token 저장 | code 생성, token 발급 | Bonjour 실패 시에도 연결 가능 |
| F-03 | 연결 상태 동기화 | P0 | status rail 갱신 | telemetry 1Hz 송신 | Mac/Robot/ARM/Latency가 1초 내 반영 |
| F-04 | Heartbeat | P0 | 100ms heartbeat during active control | timeout watchdog | iPhone 종료/끊김 시 stop |
| F-05 | E-stop | P0 | 모든 화면에서 즉시 전송 | `ConnectionStore.emergencyStop()` | active command 중 300ms 이내 정지 경로 호출 |
| F-06 | ARM | P0 | checklist + slider | `TeleopChannel.arm()` | ARM 완료/실패가 iOS에 표시 |
| F-07 | DISARM | P0 | 잠금 버튼/탭 이동 시 호출 | `TeleopChannel.disarm()` | motion task cancel, gate close |
| F-08 | Safe action 실행 | P0 | action button, progress | `sendMotion` 또는 `sendPose` | walkReady/기본/앉기/인사 중 1개 이상 성공 |
| F-09 | 보행 deadman | P0 | press/release gesture | WalkLab onboard command send | 손을 떼면 stop |
| F-10 | Stop | P0 | stop button, touch cancel | `pilot.stop` 처리 | 항상 활성, ACK 표시 |
| F-11 | Latency gate | P0 | latency warning, control disable | RTT/ACK age 계산 | 150ms+ 지속 시 walk 제한 |
| F-12 | Robot state display | P0 | sim/connected/stale/busBusy 표시 | endpoint/demo/ACK 상태 제공 | 사용자가 왜 비활성인지 알 수 있음 |
| F-13 | Test session | P1 | checklist/note/pass fail | session log 저장 | 테스트 1회 기록 |
| F-14 | Logs timeline | P1 | event list/filter | recent events stream | command/ACK 이력 확인 |
| F-15 | Local network permission recovery | P1 | Settings 안내 | 해당 없음 | 권한 거부 후 복구 경로 제공 |
| F-16 | Sim mode | P1 | robot 미연결 preview | mock telemetry | 실 로봇 없이 UI 검증 가능 |
| F-17 | HighRisk confirm | P1 | confirm sheet | safety gate 재검증 | confirm 없이는 실행 불가 |
| F-18 | Robot agent future compatibility | P2 | command schema 유지 | relay/agent 공통 protocol | 후속 direct-agent 이식 가능 |

### 8.2 주요 기능 상세

#### F-05 E-stop

입력:

- E-stop button tap
- iOS app active command 중 crash/disconnect는 watchdog stop, 수동 E-stop은 별도

처리:

1. iOS UI를 즉시 `EStopped`로 전환
2. `pilot.estop` 전송
3. Mac relay가 `ConnectionStore.emergencyStop()` 호출
4. Mac relay가 `safety.estop.ack` 또는 `safety.estop.failed` 전송

수용 기준:

- E-stop button은 어떤 상태에서도 disabled되지 않는다.
- E-stop 후 ARM은 자동 해제된다.
- E-stop 후 조종 화면에는 recovery banner가 표시된다.

#### F-06 ARM

입력:

- ARM slider complete
- checklist confirmed

처리:

1. iOS가 `pilot.arm` 전송
2. Mac relay가 robot 연결, bus 점유, battery/temp, E-stop 상태 확인
3. Mac relay가 `TeleopChannel.arm()` 호출
4. `arming.progress` event를 iOS로 전송
5. 완료 시 `armed=true`

수용 기준:

- 실패 사유가 한 줄로 표시된다.
- sim mode에서는 ARM이 gate를 열지 않고 `시뮬 모드`로 표시된다.
- degraded ready는 성공처럼 숨기지 않고 별도 상태로 표시한다.

#### F-09 보행 Deadman

입력:

- joystick up/left/right press
- touch end/cancel
- app background

처리:

1. press 시작 시 `pilot.walkPreset`
2. touch 유지 중 heartbeat
3. Mac relay는 dedup + 5Hz send limit
4. touch end 시 `pilot.stop`
5. heartbeat timeout 시 Mac relay가 stop

수용 기준:

- release 후 300ms 이내 Mac relay가 stop 처리
- reconnect 후 이전 walk command가 자동 재개되지 않음
- latency gate가 warning 이상이면 새 walk command block

#### F-13 Test Session

입력:

- `테스트 시작`
- command 실행
- pass/fail/note
- `테스트 종료`

처리:

1. iOS가 session start 전송
2. Mac relay가 session id 생성
3. command/ACK/telemetry event 연결
4. 종료 시 summary 생성

수용 기준:

- 사용자가 파일 경로를 몰라도 결과를 볼 수 있다.
- E-stop이 발생하면 session result는 자동으로 `fail/safety`로 표시된다.

## 9. 조종 상태 모델

MVP는 상태가 흔들리면 이슈가 생긴다. iOS와 Mac이 같은 상태 이름을 써야 한다.

```text
NotPaired
  → Pairing
  → PairedNoMac
  → MacConnectedNoRobot
  → RobotConnectedLocked
  → Arming
  → ArmedReady
  → CommandActive
  → RobotConnectedLocked

AnyState → EStopped
AnyActiveState → StaleStop → RobotConnectedLocked
```

상태 정의:

| 상태 | 의미 | 허용 command |
|---|---|---|
| NotPaired | Mac relay 정보 없음 | pairing only |
| Pairing | code/QR 검증 중 | cancel |
| PairedNoMac | 저장된 Mac은 있으나 연결 안 됨 | reconnect |
| MacConnectedNoRobot | Mac relay만 연결 | sim preview, connect hint |
| RobotConnectedLocked | robot 연결, ARM 전 | arm, stop, estop |
| Arming | ARM sequence 진행 | estop only |
| ArmedReady | 실 명령 가능 | safe action, walk, stop, disarm, estop |
| CommandActive | motion/walk 실행 중 | stop, estop |
| StaleStop | heartbeat/ACK 지연으로 stop 중 | estop only |
| EStopped | 비상 정지 후 복구 대기 | recovery, reconnect |

전이 규칙:

- `CommandActive`에서 WebSocket disconnect → Mac relay가 `StaleStop`
- `StaleStop` ACK 성공 → `RobotConnectedLocked` 또는 `ArmedReady`, 설정에 따름. MVP는 `RobotConnectedLocked`로 되돌린다.
- `EStopped` 후에는 사용자가 Mac/robot 상태를 확인하고 ARM을 다시 수행해야 한다.
- `MacConnectedNoRobot`에서 action button tap → 실 명령이 아니라 sim preview.

## 10. 시스템 설계

### 10.1 구성 요소

#### iOS App

기술:

- SwiftUI
- `Network.framework` 또는 `URLSessionWebSocketTask`
- Bonjour browse: `_darwinforge._tcp`
- `NSLocalNetworkUsageDescription`
- `NSBonjourServices`
- 선택: `NEHotspotConfiguration` for robot AP onboarding

책임:

- Mac relay discovery
- pairing
- command intent 생성
- live telemetry 표시
- UI-level deadman 전송
- test note 작성

책임지지 않는 것:

- raw motor packet 생성
- Dynamixel retry/timeout 판단
- 하드웨어 E-stop 대체

#### Mac DarwinForge Relay

기술:

- 기존 macOS app 안에 `MobileRelayServer` 추가
- `NWListener` 또는 WebSocket server
- Bonjour advertise `_darwinforge._tcp`
- existing `ConnectionStore`, `TeleopChannel`, `WalkLabSession`, `RemoteShell` 호출

책임:

- pairing/auth
- command validation
- safety gate 적용
- robot connection ownership
- telemetry aggregation
- stale command watchdog
- audit log 기록

#### Robot

지원 경로:

- Mac USB direct
- robot Wi-Fi + TCP 5530 bridge
- robot Wi-Fi + SSH WalkLab brokerage
- future: `darwin-mobile-agent`

MVP에서는 robot을 직접 iOS에 노출하지 않는다. robot은 Mac이 이미 다루는 endpoint로 남긴다.

### 10.2 통신 프로토콜

전송:

- MVP: WebSocket over local network
- Discovery: Bonjour `_darwinforge._tcp`
- Pairing: Mac QR code + 6자리 code
- Message format: JSON line or WebSocket JSON object

공통 envelope:

```json
{
  "v": 1,
  "id": "cmd_000123",
  "type": "pilot.walk",
  "sentAt": "2026-05-25T12:00:00.000Z",
  "payload": {}
}
```

핵심 command:

```json
{ "type": "session.hello", "payload": { "app": "ios", "version": "0.1.0" } }
{ "type": "pilot.arm", "payload": { "cradleConfirmed": true } }
{ "type": "pilot.disarm", "payload": {} }
{ "type": "pilot.estop", "payload": { "reason": "user" } }
{ "type": "pilot.motion", "payload": { "slot": 9, "confirmRisk": false } }
{ "type": "pilot.walk", "payload": { "enabled": true, "xMm": 20, "yMm": 0, "aDeg": 0, "periodMs": 700, "footMm": 35, "hipPitchDeg": 13 } }
{ "type": "pilot.stop", "payload": {} }
```

telemetry event:

```json
{
  "type": "telemetry.state",
  "payload": {
    "mac": "connected",
    "robot": "connected",
    "endpoint": "tcp://192.168.123.1:5530",
    "armed": true,
    "dxlPower": true,
    "batteryV": 11.7,
    "maxTempC": 42,
    "latencyMs": 34,
    "lastAckAgeMs": 90,
    "safety": "ready"
  }
}
```

### 10.3 Watchdog 정책

| 상황 | Mac relay 동작 |
|---|---|
| iPhone WebSocket disconnect | active walk command 즉시 stop |
| iPhone 앱 background | iOS가 `pilot.stop` 전송 시도, Mac은 heartbeat timeout으로 stop |
| heartbeat 500ms 초과 | walk command stop, ARM 유지 여부는 설정에 따름 |
| heartbeat 2s 초과 | disarm 권장, UI stale |
| E-stop 수신 | 기존 `ConnectionStore.emergencyStop()` 경로 호출 |
| robot ACK stale | command block, iPhone에 “로봇 응답 지연” 표시 |
| demo가 USB bus 점유 | motion/action 버튼 disable |

## 11. 안전 요구사항

P0:

- 하드웨어 E-stop은 필수다. iPhone E-stop은 보조 수단이다.
- iPhone은 raw servo streaming을 하지 않는다.
- Mac relay는 모든 실기기 명령의 최종 gatekeeper다.
- walk command는 deadman 방식이어야 한다.
- app background/disconnect는 stop으로 귀결되어야 한다.
- HighRisk motion은 iPhone에서도 confirm sheet를 거쳐야 한다.
- robot 미연결 상태에서는 “실행”이 아니라 “시뮬 미리보기”로 라벨링한다.

P1:

- latency > 150ms 지속 시 joystick command를 제한한다.
- battery/temperature 경고는 iPhone에도 표시한다.
- command/ACK 불일치 시 같은 명령을 자동 반복하지 않는다.

P2:

- Mac relay와 iPhone pairing token은 매 실행마다 갱신한다.
- 허용된 iPhone만 연결 가능하게 한다.

## 12. 검증 방법론

### 12.1 조사 기반 검증 원칙

첫 빌드에서 바로 사용할 수 있으려면 “구현 후 사람이 만져본다” 수준으로는 부족하다. iOS 조종기 앱은 네트워크, 화면 상태, 로봇 안전이 동시에 얽히므로 **자동 테스트 + fault injection + 실기기 HIL**을 한 세트로 설계해야 한다.

조사한 공식 검증 근거:

| 근거 | 핵심 내용 | PRD 적용 |
|---|---|---|
| Apple XCUIAutomation | 앱 UI를 실제 사용자처럼 조작하고 상태를 검증할 수 있다. | Pilot/Connect/Test/Logs의 핵심 플로우는 XCUITest로 고정 |
| SwiftUI `accessibilityIdentifier` | 사용자에게 보이지 않는 안정적인 테스트 식별자를 view에 지정할 수 있다. | 모든 P0 버튼/chip/sheet에 identifier 필수 |
| `URLSessionWebSocketTask` | WebSocket message send/receive, ping, close code를 제공한다. | heartbeat, reconnect, close handling 테스트 |
| Bonjour | service publication, browsing, resolution이 zero-config discovery의 기본 operation이다. | Mac relay 발견/QR fallback 검증 |
| iOS app lifecycle | background app은 foreground보다 제한되므로 state 전이에 맞게 동작을 조정해야 한다. | scene background 진입 시 `pilot.stop` + Mac watchdog 검증 |
| Instruments Network | iOS/macOS 앱의 network traffic을 기록/분석할 수 있다. | latency, reconnect, message burst 확인 |
| TestFlight | 내부/외부 테스터 배포와 screenshot/crash feedback 수집 가능 | 실기기 베타 검증 루프에 사용 |

검증 원칙:

- 안전 기능은 “수동 확인”이 아니라 자동 테스트와 HIL에서 둘 다 검증한다.
- mock relay에서 통과하지 못한 기능은 실 로봇에 연결하지 않는다.
- ACK 없는 성공 상태는 테스트 실패로 본다.
- UI 테스트는 표시 텍스트가 아니라 `accessibilityIdentifier`를 우선 사용한다.
- iPhone app lifecycle 전이는 조종 기능의 일부다. background/lock/disconnect는 반드시 stop으로 이어져야 한다.

참고 링크:

- Apple XCUIAutomation: https://developer.apple.com/documentation/XCUIAutomation
- SwiftUI `accessibilityIdentifier`: https://developer.apple.com/documentation/swiftui/view/accessibilityidentifier%28_%3A%29
- Apple URLSessionWebSocketTask: https://developer.apple.com/documentation/foundation/urlsessionwebsockettask
- Apple Bonjour: https://developer.apple.com/bonjour/
- Apple app lifecycle: https://developer.apple.com/documentation/uikit/managing-your-app-s-life-cycle
- Apple Instruments network traffic: https://developer.apple.com/documentation/Foundation/analyzing-http-traffic-with-instruments
- Apple TestFlight: https://developer.apple.com/testflight

### 12.2 검증 레이어

MVP 검증은 6개 레이어로 나눈다.

| Layer | 목적 | 실행 환경 | 차단 기준 |
|---|---|---|---|
| L1 Unit | DTO, state reducer, command mapping 검증 | macOS/iOS simulator | 실패 시 빌드 차단 |
| L2 Contract | iOS command ↔ Mac relay message schema 검증 | mock relay | schema 불일치 차단 |
| L3 UI Automation | 화면 플로우와 disabled reason 검증 | iOS simulator + XCUITest | P0 flow 실패 차단 |
| L4 Network Fault | 지연/끊김/background/watchdog 검증 | iPhone + mock relay | stop 누락 차단 |
| L5 Mac Integration | 실제 DarwinForge relay와 연결 | Mac + iPhone | telemetry/ACK 불일치 차단 |
| L6 Robot HIL | cradle/tether 실 로봇 검증 | Mac + iPhone + robot | stale motion 잔존 시 차단 |

첫 빌드 목표는 L1~L5 통과다. “실 로봇에서 쓸 수 있음”을 선언하려면 L6까지 통과해야 한다.

### 12.3 테스트 가능한 아키텍처 요구사항

iOS 앱은 처음부터 테스트 가능한 구조로 만든다.

필수 protocol:

```swift
protocol MobileRelayClient {
    var stateStream: AsyncStream<RelayState> { get }
    func connect(to endpoint: RelayEndpoint) async throws
    func send(_ command: PilotCommand) async throws -> CommandReceipt
    func close() async
}

protocol PilotClock {
    func now() -> Date
    func sleep(milliseconds: Int) async
}

protocol AppLifecycleObserver {
    var phaseStream: AsyncStream<AppPhase> { get }
}
```

필수 구현체:

| 구현체 | 용도 |
|---|---|
| `WebSocketRelayClient` | 실제 iPhone → Mac 통신 |
| `MockRelayClient` | Unit/UI 테스트 |
| `ScriptedRelayClient` | fault injection |
| `DeterministicClock` | heartbeat/timeout 테스트 |
| `LiveAppLifecycleObserver` | scene phase 연결 |

이 구조가 없으면 background stop, heartbeat timeout, reconnect 테스트가 불안정해진다.

### 12.4 Mock Relay 설계

첫 빌드는 실 로봇 없이도 조종기 UX를 완성해야 한다. 이를 위해 iOS 테스트용 mock relay를 둔다.

Mock relay 기능:

- Bonjour 발견 결과 mock
- WebSocket 연결 성공/실패
- pairing 성공/실패
- telemetry script 재생
- command ACK 지연/누락/오류
- disconnect 주입
- robot state 전환: `sim`, `connected`, `stale`, `busBusy`, `estopped`

script 예:

```json
[
  { "atMs": 0, "event": "telemetry.state", "robot": "connected", "armed": false, "latencyMs": 35 },
  { "onCommand": "pilot.arm", "afterMs": 100, "event": "arming.progress", "stage": "enablingPower" },
  { "onCommand": "pilot.arm", "afterMs": 900, "event": "telemetry.state", "armed": true },
  { "onCommand": "pilot.walkPreset", "afterMs": 80, "event": "command.ack", "id": "$commandId" },
  { "atMs": 2500, "event": "transport.disconnect" }
]
```

수용 기준:

- mock relay만으로 Connect, Pilot, Test, Logs 전체 flow를 시연할 수 있다.
- mock script로 14개 P0 QA 항목 중 robot HIL을 제외한 항목을 재현할 수 있다.

### 12.5 UI 테스트 식별자 계약

모든 P0 UI에는 안정적인 identifier를 붙인다. 표시 문구는 한국어 UX 개선으로 바뀔 수 있으므로 테스트 selector로 쓰지 않는다.

| UI | Identifier |
|---|---|
| Pilot root | `pilot.root` |
| Status rail | `pilot.status.rail` |
| Mac chip | `pilot.status.mac` |
| Robot chip | `pilot.status.robot` |
| ARM chip | `pilot.status.arm` |
| Latency chip | `pilot.status.latency` |
| E-stop | `global.estop.button` |
| ARM slider | `pilot.arm.slider` |
| ARM checklist sheet | `pilot.arm.checklist.sheet` |
| Segment 동작 | `pilot.segment.actions` |
| Segment 보행 | `pilot.segment.walk` |
| Segment 상태 | `pilot.segment.state` |
| Action 보행 자세 | `pilot.action.walkready` |
| Action 정지 | `pilot.action.stop` |
| Walk pad | `pilot.walk.pad` |
| Walk forward zone | `pilot.walk.forward` |
| Walk turn left zone | `pilot.walk.turnLeft` |
| Walk turn right zone | `pilot.walk.turnRight` |
| Connect root | `connect.root` |
| QR scan | `connect.qr.scan` |
| Manual host | `connect.manual.host` |
| Test start | `test.session.start` |
| Logs list | `logs.timeline` |

수용 기준:

- XCUITest는 위 identifier만으로 P0 flow를 탐색할 수 있어야 한다.
- identifier는 제품 문구 변경으로 깨지면 안 된다.

### 12.6 Unit Test 목록

`MobilePilotKitTests`에 최소 다음 테스트를 둔다.

| Test | 검증 |
|---|---|
| `PilotCommandEncodingTests` | command JSON round-trip |
| `RelayStateDecodingTests` | telemetry event decode |
| `PilotStateReducerTests` | 상태 전이 table 검증 |
| `DisabledReasonTests` | 각 상태별 button disable reason |
| `HeartbeatControllerTests` | active command 중 100ms heartbeat |
| `WatchdogPolicyTests` | heartbeat timeout → stop |
| `WalkPresetMappingTests` | slowForward/turnLeft/turnRight 값 고정 |
| `ArmChecklistTests` | checklist 미확인 시 ARM 차단 |
| `LatencyGateTests` | 150ms+ 지속 시 walk block |
| `EstopPriorityTests` | E-stop이 모든 command보다 우선 |

차단 기준:

- Unit test 실패 0
- command schema snapshot 변경 시 PRD와 protocol version 갱신 필요

### 12.7 XCUITest 목록

`DarwinForgeMobileUITests`에 최소 다음 flow를 둔다.

| Test | Flow |
|---|---|
| `testPairingViaBonjour` | mock Bonjour → Mac card → pairing success → Pilot |
| `testPairingViaQRCodeFallback` | Bonjour 없음 → QR payload 입력 → connected |
| `testLocalNetworkDeniedShowsRecovery` | permission denied simulation → Settings 안내 |
| `testPilotStatusRailReflectsTelemetry` | telemetry script → chips 갱신 |
| `testArmChecklistBlocksUntilConfirmed` | ARM slider → checklist sheet → 확인 전 차단 |
| `testArmSuccessEnablesActions` | ARM success → action buttons enabled |
| `testActionRequiresArm` | ARM 전 action tap → ARM 안내 |
| `testEstopAvailableFromEveryTab` | 4개 탭에서 E-stop 존재/동작 |
| `testWalkReleaseSendsStop` | forward press/release → stop receipt |
| `testBackgroundSendsStopIntent` | simulated scene background → stop intent |
| `testLatencyGateDisablesWalk` | latency 200ms script → walk disabled |
| `testLogsShowsCommandAckTimeline` | commands 실행 → Logs timeline |

수용 기준:

- P0 XCUITest는 simulator에서 매번 통과해야 한다.
- physical iPhone smoke test에서는 Pairing, E-stop, Walk release 3개 flow를 수동+자동으로 확인한다.

### 12.8 Network Fault Injection

조종기 앱의 핵심 실패는 네트워크에서 나온다. 다음 fault는 mock relay와 실제 Mac relay 양쪽에서 검증한다.

| Fault | 주입 방법 | 기대 결과 |
|---|---|---|
| ACK delay 200ms | mock script delay | latency warning, walk block |
| ACK missing | command ACK 생략 | command pending → timeout → error |
| WebSocket close | close frame 또는 socket cancel | active walk stop |
| Half-open | receive 중단, send 성공처럼 보임 | heartbeat timeout stop |
| Bonjour not found | browser empty | QR/manual fallback |
| Pairing mismatch | invalid code | 재입력, 3회 후 code 재생성 |
| App background | scene phase background | `pilot.stop` 전송 + watchdog 보조 |
| App terminated | 강제 종료 | Mac heartbeat timeout stop |

측정 값:

- command send timestamp
- Mac receipt timestamp
- robot ACK timestamp
- iOS state update timestamp
- stop latency
- disconnect-to-stop latency

차단 기준:

- active walk 상태에서 disconnect-to-stop latency가 500ms를 넘으면 첫 빌드 사용 불가
- E-stop command dispatch가 UI tap 이후 300ms를 넘으면 사용 불가

### 12.9 Mac Integration 검증

실제 DarwinForge Mac 앱과 붙는 단계다.

사전 조건:

- Mac relay server ON
- Bonjour service visible
- iPhone과 Mac 같은 네트워크
- robot 미연결 상태에서도 sim telemetry 제공

검증 항목:

| 항목 | 기대 |
|---|---|
| Bonjour 발견 | `_darwinforge._tcp` service 표시 |
| QR pairing | host/port/code로 연결 |
| telemetry | 1Hz 이상 수신 |
| ARM command | Mac relay가 command reject/accept 응답 |
| E-stop | Mac `ConnectionStore.emergencyStop()` 호출 로그 |
| stop watchdog | iPhone disconnect 시 Mac relay stop event |
| Logs | Mac Harness event와 iOS Logs command id 일치 |

Mac relay는 iOS에서 받은 모든 command에 대해 다음 중 하나를 반드시 응답한다.

```json
{ "type": "command.accepted", "id": "cmd_001" }
{ "type": "command.rejected", "id": "cmd_001", "reason": "robotDisconnected" }
{ "type": "command.ack", "id": "cmd_001", "latencyMs": 82 }
{ "type": "command.failed", "id": "cmd_001", "reason": "noAck" }
```

### 12.10 Robot HIL 검증

실 로봇 검증은 안전 순서를 고정한다.

환경:

- cradle 또는 tether 필수
- 하드웨어 E-stop 접근 가능
- Mac 옆에 보조 감시자 1명 권장
- 첫 검증은 `느림` preset만 사용

HIL Gate:

| Gate | 조건 | 통과 기준 |
|---|---|---|
| HIL-0 | robot 미연결 | iPhone sim/대기 상태 정확 |
| HIL-1 | robot 연결 | status rail Robot ✓ |
| HIL-2 | ARM | walkReady 완료, torque 상태 정상 |
| HIL-3 | Safe action | 보행 자세/앉기/인사 중 1개 성공 |
| HIL-4 | Walk deadman | press 중만 walking, release stop |
| HIL-5 | E-stop | active walk 중 E-stop 즉시 정지 |
| HIL-6 | Disconnect | iPhone 앱 종료 후 walking 잔존 없음 |
| HIL-7 | 반복 | 10분 반복 조작 중 stale command 없음 |

실패 시 기록:

- iOS Logs screenshot
- Mac Harness event export
- robot endpoint
- command id
- ACK latency
- 실패 시점 영상 또는 관찰 메모

### 12.11 First Build Release Gate

첫 빌드를 “사용 가능”으로 판단하는 gate다.

Build Gate:

- iOS app debug build가 실 iPhone에 설치된다.
- Mac app relay가 켜지고 iPhone이 연결된다.
- mock relay mode와 real Mac relay mode를 앱에서 구분할 수 있다.
- P0 unit tests pass.
- P0 XCUITests pass.
- Network fault injection pass.
- Mac integration pass.
- HIL-0~HIL-5 pass.

No-Go 조건:

- E-stop이 특정 화면이나 modal 위에서 동작하지 않음
- active walk 중 앱 종료 후 robot이 계속 움직임
- ACK 없이 완료 표시
- Robot 미연결인데 실 명령처럼 보임
- disabled reason 없이 버튼이 눌리지 않음
- pairing 없이 임의 iPhone이 relay에 연결 가능
- latency gate가 동작하지 않음

TestFlight Gate:

- Apple Developer Program 계정, App Store Connect app record, bundle id, signing team이 준비되어 있다.
- App Store Connect Test Information에 beta app description, feedback email, What to Test, reviewer/tester note가 작성되어 있다.
- Xcode archive upload 또는 App Store Connect 업로드 후 build processing이 완료되어 TestFlight build list에 표시된다.
- export compliance 상태가 `Missing Compliance`로 남아 있지 않다.
- 내부 테스터 배포 전 HIL-0~HIL-5를 통과한다.
- beta test note에 하드웨어 E-stop, cradle/tether requirement, Mac relay requirement, mock/review mode 사용법을 명시한다.
- crash feedback과 screenshot feedback 수집 경로가 준비되어 있다.
- 외부 테스터 전 HIL-6~HIL-7을 통과하고, 첫 외부 배포 build의 Beta App Review 승인을 확인한다.
- public link를 쓰는 경우 device/OS 조건과 최대 테스터 수를 제한하고, robot hardware 보유 여부를 선별한다.
- 테스트 종료 또는 위험 build 회수 절차가 문서화되어 있다.

### 12.12 구현 산출물 체크리스트

첫 빌드 PR에는 다음 산출물이 포함되어야 한다.

- `DarwinForgeMobile` iOS app target
- `MobilePilotKit` command/state module
- `MockRelayClient`
- `ScriptedRelayClient`
- `WebSocketRelayClient`
- Mac `MobileRelayServer`
- Mac relay pairing UI
- iOS Pilot/Connect/Test/Logs screens
- P0 unit tests
- P0 XCUITests
- network fault scripts
- HIL result markdown

문서 산출물:

- `docs/handoff/ios-mobile-pilot-first-build.md`
- `docs/handoff/ios-mobile-pilot-hil.md`
- `docs/protocols/mobile-relay-v1.md`
- `docs/release/ios-mobile-pilot-testflight.md`

TestFlight 문서 산출물은 단순 배포 방법이 아니라, 테스트 가능한 앱을 만들기 위한 제품 요구사항이다. 구현자는 해당 문서에 Apple 계정/서명 준비, App Store Connect 입력 항목, build upload, internal/external tester 운영, feedback triage, stop testing 절차를 빠짐없이 작성해야 한다.

## 13. 구현 계획

### Sprint 1. Mac Relay Skeleton + iOS Connect

목표:

- Mac에서 relay server를 켜고 iPhone이 발견/연결할 수 있다.

Mac 작업:

- `MobileRelayServer` 추가
- `NWListener` 또는 WebSocket server 생성
- Bonjour `_darwinforge._tcp` advertise
- QR pairing code 표시
- `telemetry.state` mock 송신

iOS 작업:

- 새 iOS app target 생성
- Connect 화면
- Bonjour browse
- QR/manual host 연결
- WebSocket 연결 상태 표시

완료 기준:

- iPhone이 Mac을 자동 발견한다.
- pairing 후 telemetry mock이 1Hz로 표시된다.
- local network permission 문구가 정상 표시된다.

### Sprint 2. Safety Commands

목표:

- iPhone에서 ARM, DISARM, E-stop, walkReady를 Mac 경유로 실행한다.

Mac 작업:

- relay command router 추가
- `pilot.arm` → `TeleopChannel.arm()`
- `pilot.disarm` → `TeleopChannel.disarm()`
- `pilot.estop` → `ConnectionStore.emergencyStop()`
- telemetry에 `armed`, `dxlPower`, `endpoint`, `lastError` 포함

iOS 작업:

- Pilot 화면
- ARM slider
- E-stop button
- status strip
- command result toast

완료 기준:

- 실 로봇 미연결 시 sim 상태가 정확히 표시된다.
- 실 로봇 연결 시 ARM과 E-stop이 Mac UI와 동기화된다.
- E-stop은 어떤 화면에서도 접근 가능하다.

### Sprint 3. WalkLab Remote MVP

목표:

- iPhone 조이스틱/버튼으로 Mac의 WalkLab onboard command를 보낸다.

Mac 작업:

- `pilot.walk` command를 `WalkingEngineCommand.serializedLine`으로 변환
- 기존 `WalkLabOnboardBridge` 또는 세션 API로 send
- relay watchdog 구현
- command/ACK history stream

iOS 작업:

- press-and-hold walk controls
- slow walk / turn left / turn right / stop presets
- ACK 상태 표시
- stale 경고 표시

완료 기준:

- cradle에서 slow walk, turn, stop이 동작한다.
- iPhone 손을 떼면 stop된다.
- Wi-Fi disconnect 시 Mac이 stop을 보낸다.

### Sprint 4. Test Session Logging

목표:

- 사용자가 폰에서 테스트를 진행하고 결과를 기록할 수 있다.

Mac 작업:

- relay session id 생성
- command/telemetry event log 저장
- existing Harness/WalkLab session과 연결

iOS 작업:

- Test checklist
- pass/fail/note 입력
- 최근 command/ACK timeline

완료 기준:

- 한 번의 테스트 결과를 Mac에 session log로 남긴다.
- iPhone에서 마지막 테스트 summary를 볼 수 있다.

### Sprint 5. HIL Lockdown

목표:

- 실제 로봇에서 실패 가능성이 높은 흐름을 닫고, 조종기 MVP를 “시연 가능한 상태”로 고정한다.

Mac 작업:

- relay watchdog event를 Harness log에 기록
- `pilot.stop` ACK 실패 시 escalation banner 추가
- Mobile Relay UI에 active iPhone, last heartbeat, last command 표시

iOS 작업:

- E-stop recovery banner
- latency gate 시각화
- command disabled reason 통일
- Test 화면의 기본 HIL 시나리오 고정

완료 기준:

- 아래 QA 매트릭스의 P0 항목 전체 통과
- 실기기 cradle에서 10분 반복 조작 중 stale command 잔존 없음
- iPhone 앱 강제 종료 후 robot walking 잔존 없음

### 13.1 화면별 구현 우선순위

한 번에 성공하기 위한 구현 순서는 다음과 같이 고정한다.

| 순서 | 화면/기능 | 이유 |
|---|---|---|
| 1 | Mac relay mock + iOS Connect | 하드웨어 없이 통신 UX 검증 |
| 2 | Status Rail + telemetry mock | 모든 화면의 상태 의존성 고정 |
| 3 | E-stop | 가장 높은 우선순위 안전 기능 |
| 4 | ARM Slider | 실 명령 gate |
| 5 | Action 화면 | 단발 명령으로 end-to-end 검증 쉬움 |
| 6 | 보행 Deadman | stale/latency/watchdog 검증 필요 |
| 7 | Test/Logs | 동작 검증 후 기록 기능 연결 |

구현 금지 순서:

- 보행 joystick을 E-stop/heartbeat/watchdog보다 먼저 구현하지 않는다.
- robot direct 연결을 Mac relay보다 먼저 구현하지 않는다.
- HighRisk action을 safe action보다 먼저 활성화하지 않는다.

### 13.2 P0 QA 매트릭스

| ID | 케이스 | 절차 | 기대 결과 |
|---|---|---|---|
| QA-01 | Mac 발견 | Mac relay ON → iPhone Connect | 10초 내 Mac 표시 |
| QA-02 | QR fallback | Bonjour 차단 → QR scan | pairing 성공 |
| QA-03 | 권한 거부 | local network 거부 | Settings 안내 + manual fallback |
| QA-04 | Robot 미연결 | Mac만 연결 | Pilot 진입, 실 명령은 sim/대기 |
| QA-05 | ARM 성공 | robot 연결 + checklist 확인 + slider | `ArmedReady` |
| QA-06 | ARM 차단 | demo bus 점유 상태 | ARM 차단 사유 표시 |
| QA-07 | Safe action | ARM 후 보행 자세 | progress + ACK + 완료 |
| QA-08 | Action 중 E-stop | action progress 중 E-stop | 즉시 EStopped, ARM 해제 |
| QA-09 | Walk press/release | 위 방향 press 2초 후 release | release 후 stop |
| QA-10 | 앱 background | walk 중 홈 버튼/잠금 | Mac watchdog stop |
| QA-11 | Wi-Fi 끊김 | walk 중 네트워크 off | Mac watchdog stop |
| QA-12 | Latency gate | artificial delay 200ms | 새 walk command 차단 |
| QA-13 | Logs | command 3개 실행 | command/ACK timeline 표시 |
| QA-14 | Test session | 기본 시나리오 1회 | summary 저장 |

### 13.3 HIL 시나리오

실기기 테스트는 반드시 cradle 또는 tether 상태에서 수행한다.

1. **연결**
   - Mac relay ON
   - iPhone pairing
   - robot endpoint 연결
   - iPhone status rail이 `Mac ✓ / Robot ✓ / 잠김` 표시

2. **ARM**
   - checklist 확인
   - ARM slider
   - walkReady 완료
   - status rail이 `ARM` 표시

3. **Action**
   - `보행 자세` 실행
   - `인사` 또는 `앉기` 실행
   - progress와 ACK 확인

4. **Walk**
   - 보행 화면에서 `slowForward` 2초 press
   - release
   - stop ACK 확인
   - turnLeft 1초, turnRight 1초 반복

5. **Safety**
   - walk 중 E-stop
   - walk 중 iPhone 앱 종료
   - walk 중 Wi-Fi off
   - 세 경우 모두 robot walking 잔존 없음

### 13.4 구현자가 지켜야 할 UX 계약

아래 계약은 구현 중 변경하지 않는다.

- 모든 실기기 명령 버튼은 disabled reason을 가져야 한다.
- E-stop은 modal, loading, pairing 중에도 접근 가능해야 한다.
- active walk 중에는 navigation 전환보다 `pilot.stop`이 먼저다.
- iOS가 `CommandActive`를 표시하는 동안 Mac relay도 동일 command id를 알고 있어야 한다.
- ACK 없는 성공 표시는 금지한다. 단, E-stop은 UI를 먼저 EStopped로 바꾸고 ACK는 나중에 표시한다.
- sim mode와 real robot mode는 같은 버튼을 쓰더라도 badge와 copy가 달라야 한다.
- 사용자가 “왜 안 움직이지?”라고 느낄 수 있는 상태는 모두 status rail 또는 toast에 표시한다.

### 13.5 TestFlight 배포 문서화 지시

첫 빌드가 “휴대폰에서 실제로 설치해 테스트할 수 있는 앱”이 되려면 TestFlight 절차를 구현 범위에 포함해야 한다. 이 항목은 배포 후반 작업이 아니라 Sprint 1부터 준비하는 release workstream이다.

필수 작성 문서:

- `docs/release/ios-mobile-pilot-testflight.md`

문서에 반드시 들어갈 항목:

| 항목 | 누락 시 위험 | 문서화 요구 |
|---|---|---|
| Apple 계정/권한 | TestFlight upload 자체가 막힘 | Apple Developer Program, App Store Connect role, signing team, bundle id 확인 절차 |
| App Store Connect app record | build가 연결될 앱이 없음 | app name, bundle id, SKU, primary language, platform 생성 절차 |
| Xcode archive/upload | 로컬 빌드와 배포 빌드가 달라짐 | scheme, configuration, version/build number, archive, upload, processing 확인 절차 |
| Test Information | 외부 리뷰/테스터가 앱 목적을 이해하지 못함 | beta app description, feedback email, What to Test, reviewer note, hardware requirement 문구 |
| Export compliance | build가 Missing Compliance로 막힘 | 네트워크 암호화 사용 여부와 compliance 답변/Info.plist 처리 절차 |
| Review/mock mode | Apple reviewer가 로봇 없이 앱을 열어볼 수 없음 | `Mock Relay` 또는 `Review Mode`로 연결/ARM/Test flow를 실제 로봇 없이 확인하는 절차 |
| Internal tester | 첫 배포 대상이 불명확 | 내부 그룹, 역할, 초대, 설치, 테스트 시나리오 |
| External tester | 안전 검증 전 외부 노출 | HIL-6~HIL-7 이후 외부 그룹, Beta App Review, public link 조건 |
| Feedback triage | screenshot/crash가 쌓이기만 함 | feedback 수집 위치, 담당자, 심각도, 수정 여부, 재검증 방식 |
| Stop testing | 위험 build 회수 지연 | build expire, tester group 제거, 공지 문구, Mac relay 호환성 회수 절차 |

TestFlight release note 템플릿:

```text
DarwinForge Mobile Pilot 0.1.0 (Build N)

목적:
- iPhone에서 Mac DarwinForge Relay에 연결해 로봇 safe action과 느린 deadman 보행을 검증합니다.

테스트 전 필수 조건:
- 로봇은 cradle 또는 tether 상태여야 합니다.
- 물리 E-stop을 손 닿는 곳에 둡니다.
- Mac DarwinForge Relay 버전은 <version>이어야 합니다.
- iPhone과 Mac은 같은 Wi-Fi 또는 허용된 로컬 네트워크에 있어야 합니다.

테스트할 항목:
- Connect: Bonjour/QR/manual fallback
- Pilot: ARM, E-stop, safe action
- Walk: press 중 이동, release/background/disconnect 시 stop
- Logs: 실패 시 command id와 ACK latency 확인

테스트 금지:
- 고속 보행
- raw motor command
- cradle/tether 없는 보행
- 두 대 이상의 iPhone 동시 조종
```

## 14. iOS 앱 기술 범위

새 target 제안:

```
app/mobile/DarwinForgeMobile/
  Package.swift or Xcode project
  Sources/DarwinForgeMobileApp/
  Sources/MobilePilotKit/
  Tests/MobilePilotKitTests/
```

공유 가능한 코드:

- command/telemetry DTO
- enum/string mapping
- safety display labels
- protocol tests

공유하지 않을 코드:

- `DarwinForgeUI` 전체
- AppKit/NSPasteboard/NSWorkspace 의존 view
- Rust FFI direct Bus
- macOS-only connection wizard

Info.plist 필수:

- `NSLocalNetworkUsageDescription`
- `NSBonjourServices`: `_darwinforge._tcp`
- 선택: Hotspot Configuration capability, robot AP onboarding을 구현할 경우만

## 15. Mac Relay 구현 범위

새 파일 후보:

- `Sources/DarwinForgeUI/MobileRelay/MobileRelayServer.swift`
- `Sources/DarwinForgeUI/MobileRelay/MobileRelayCommand.swift`
- `Sources/DarwinForgeUI/MobileRelay/MobileRelayPairing.swift`
- `Sources/DarwinForgeUI/MobileRelay/MobileRelayTelemetry.swift`
- `Tests/DarwinForgeUITests/MobileRelayTests.swift`

UI 위치:

- Connection Dashboard 또는 Remote Pilot 상단에 “Mobile Pilot” section
- 상태: Off / Discoverable / Paired / Active / Error
- QR code + manual host display
- active iPhone disconnect button

Mac entitlement:

- 현재 macOS entitlement에 `com.apple.security.network.client`와 `com.apple.security.network.server`가 이미 있다.

## 16. 위험과 대응

| 위험 | 영향 | 대응 |
|---|---|---|
| iPhone local network permission 거부 | Mac discovery 실패 | QR/manual IP fallback, Settings 안내 |
| robot Wi-Fi IP 변경 | 연결 실패 | Mac에서 robot 연결을 책임지고 iPhone은 Mac만 찾음 |
| Mac과 iPhone 다른 네트워크 | 연결 실패 | QR 화면에 현재 Mac IP/SSID 힌트 표시 |
| iPhone 앱 background | 명령 중단 | heartbeat timeout stop |
| WebSocket 지연 | 로봇 반응 늦음 | joystick rate limit, latency gate |
| Mac relay crash | stop 미전송 가능 | robot-side stale stop, 하드웨어 E-stop, cradle |
| 사용자가 ARM 의미를 오해 | 안전 사고 | ARM copy와 UI 상태를 “실 로봇 동작 허가”로 명확히 표시 |
| 기존 RemotePilot 기능이 raw motion이 아님 | 기대 불일치 | UI에 “검증된 pose/action만” 표시, raw page chain은 제외 |

## 17. 직접 Robot Agent 후속 PRD 방향

Mac Relay MVP가 통과하면 다음 단계로 `darwin-mobile-agent`를 설계한다.

목표:

- Mac 없이 iPhone이 robot onboard PC의 high-level daemon에 연결
- command schema는 MVP와 동일하게 유지
- agent가 `/dev/ttyUSB0`, ROBOTIS walking module, camera, telemetry를 책임

전제:

- robot OS별 설치 스크립트
- init.d/systemd 등록
- mDNS advertise
- token pairing
- stale command watchdog
- boot recovery
- demo/forge-bridge USB bus 점유 관리

이 단계에서도 iPhone이 raw motor packet을 직접 만들지는 않는다.

## 18. 완성도 점검 결과

### 18.1 이전 PRD에서 부족했던 지점

1차 PRD는 가능성과 구조 판단은 충분했지만, 첫 빌드 구현 관점에서는 아래가 부족했다.

| 부족했던 지점 | 위험 | 이번 보완 |
|---|---|---|
| 화면별 상태와 버튼 동작이 추상적 | 구현자가 임의 UI를 만들 가능성 | Pilot/Connect/Test/Logs 화면 구조와 상태별 정책 정의 |
| 조종기 UX의 핵심인 deadman 규칙 미흡 | 손을 뗐는데 로봇이 계속 움직일 수 있음 | press/release/background/disconnect 모두 stop으로 정의 |
| 검증 방법론 부족 | “빌드는 됐지만 실사용 불가” 위험 | Unit, Contract, XCUITest, Fault, Mac Integration, HIL 6-layer 검증 추가 |
| 테스트 selector 미정 | UI 문구 변경 때 자동 테스트 깨짐 | `accessibilityIdentifier` 계약 추가 |
| 첫 빌드 사용 가능 조건 미정 | 완료 판단이 모호 | First Build Release Gate와 No-Go 조건 추가 |
| mock 없이 실기기부터 붙을 위험 | 하드웨어 디버깅으로 일정 지연 | Mock Relay, Scripted Relay, fault injection 설계 추가 |
| lifecycle 검증 누락 | iOS background/종료 시 제어 잔존 위험 | app lifecycle 기반 stop/heartbeat/watchdog 테스트 추가 |
| TestFlight 절차가 추상적 | 빌드는 됐지만 실기기 배포/피드백 수집이 막힘 | TestFlight runbook, App Store Connect 입력 항목, reviewer/tester note, feedback triage 추가 |

### 18.2 첫 빌드 완성도 판정

이 PRD대로 구현하면 첫 빌드는 다음 수준을 목표로 한다.

| 항목 | 판정 | 근거 |
|---|---|---|
| iOS 조종기 사용성 | 가능 | Pilot 화면에 ARM, E-stop, action, walk, status를 한 화면에 배치 |
| 실기기 안전성 | 조건부 가능 | Mac relay gate + deadman + watchdog + hardware E-stop 전제 |
| 로봇 직접 제어 | 제외 | iPhone raw serial/packet 미사용으로 범위 축소 |
| 네트워크 실패 대응 | 가능 | fault injection과 watchdog stop gate 포함 |
| 첫 빌드 QA | 가능 | P0 unit/XCUITest/HIL matrix 정의 |
| TestFlight 전 단계 | 가능 | TestFlight runbook, 내부/외부 배포 gate, feedback/stop testing 절차 정의 |

첫 빌드에서 “사용 가능”의 의미:

- iPhone으로 Mac relay에 연결한다.
- iPhone에서 ARM한다.
- iPhone에서 safe action을 실행한다.
- iPhone에서 느린 보행/회전/정지를 deadman 방식으로 조작한다.
- iPhone 앱 종료/네트워크 끊김/E-stop이 모두 정지로 이어진다.
- Test 화면에서 한 번의 검증 세션을 기록한다.

첫 빌드에서 “아직 제품 아님”의 의미:

- Mac 없이 단독 조종은 안 된다.
- 고속 보행/자유 조이스틱은 안 된다.
- 공 추적, 카메라 폐루프, raw motion chain은 안 된다.
- App Store 배포 품질은 아니다. 내부 TestFlight 또는 로컬 설치 검증 단계다.

### 18.3 구현 전 최종 체크리스트

구현을 시작하기 전에 아래를 잠근다.

- service name: `_darwinforge._tcp`
- transport: WebSocket JSON
- pairing: QR + 6자리 code
- active walk heartbeat: iOS 100ms, Mac send limit 5Hz
- heartbeat timeout: 500ms stop
- latency gate: 150ms+ sustained warning/block
- first active walk presets: slowForward, turnLeft, turnRight, stop
- first action buttons: walkReady, 기본 자세, 앉기, 인사, 정지
- E-stop priority: 모든 상태에서 최상위
- test selector: `accessibilityIdentifier` 표준 사용
- first HIL: cradle/tether, 느림 preset만
- TestFlight runbook: `docs/release/ios-mobile-pilot-testflight.md`
- TestFlight internal gate: HIL-0~HIL-5 통과
- TestFlight external gate: HIL-6~HIL-7 + Beta App Review 승인
- App Review fallback: robot 없이도 열람 가능한 Mock Relay 또는 Review Mode

### 18.4 최종 No-Go 목록

아래 항목이 하나라도 남아 있으면 “첫 빌드 사용 가능”으로 보지 않는다.

- E-stop이 특정 modal/sheet/tab에서 눌리지 않는다.
- active walk 중 앱 background/종료/disconnect 후 robot walking이 남는다.
- ACK 없이 `완료`로 표시한다.
- Robot 미연결 상태에서 실 로봇 명령처럼 보인다.
- ARM 실패 사유가 사용자에게 보이지 않는다.
- 버튼 disabled reason이 없다.
- mock relay 없이 실기기에서만 검증 가능하다.
- P0 XCUITest가 text label 변경에 취약하다.
- Mac relay가 command id 없이 ACK를 보낸다.
- iPhone 두 대가 동시에 command authority를 가진다.
- TestFlight build가 `Missing Compliance` 상태로 남아 있다.
- Apple reviewer가 robot/Mac 없이 기본 flow를 확인할 Review Mode가 없다.
- TestFlight release note에 hardware E-stop/cradle/tether 조건이 없다.

## 19. 최종 판정

가능하다. 하지만 “iOS 앱으로 DarwinForge 전체를 이식”하거나 “iPhone이 로봇 serial bus를 직접 제어”하는 방식은 MVP로 적절하지 않다.

**MVP는 iPhone을 조종 UI로, Mac DarwinForge를 안전 릴레이로, 로봇을 기존 방식대로 실행기로 두는 구조가 가장 논리적이다.** 이 구조는 현재 프로젝트의 macOS-only 결정, TCP endpoint 구현, RemoteShell, WalkLab onboard brokerage, Remote Pilot safety gate를 가장 많이 재사용하며, 유선 LAN이 불가능한 상황에서도 Wi-Fi 기반 실험을 시작할 수 있다.
