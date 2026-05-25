# Claude Handoff: iOS Robot Control Truth-Gap Fix Report

작성일: 2026-05-25  
Workspace:

```text
/Users/bbikiming/Documents/vibe_coding/Darwin
```

대상:

- Claude 구현 에이전트
- iOS Mobile Pilot 구현자
- Mac DarwinForge MobileRelay 구현자
- UI/UX 검수자
- 실제 로봇 HIL 테스트 담당자

## 0. 결론

현재 iOS 앱은 빌드와 Mock/Review 흐름은 가능하지만, **첫 빌드로 실제 로봇을 조종할 수 있다고 말하면 안 된다.**

이유는 네 가지다.

1. Mac `MobileRelayBootstrap`이 실제 `WalkLabSession`을 주입받지 않아 iPhone 보행 명령이 실제 WalkLab으로 이어지지 않는다.
2. iOS 메인 "조종기" 화면은 `freeform` 조이스틱을 보내지만 Mac Relay는 `freeform`을 명시적으로 reject한다.
3. `WebSocketRelayClient.connect()`가 같은 socket에 대해 두 수신 루프를 동시에 시작해 `session.welcome` 수신 race가 생긴다.
4. iOS의 `bow` 액션은 slot 41로 전송되는데, 프로젝트의 `motion_4096` 카탈로그상 41은 "절"이 아니라 `talk2` long-chain 시작 페이지다.

Claude의 목표는 새 기능 확장이 아니라 **거짓된 UI와 끊긴 제어 경로를 제거하고, iPhone -> Mac Relay -> WalkLabSession -> robot의 최소 real path를 증명하는 것**이다.

## 1. 조사 근거

### 1.1 외부 공식 근거

이 문서는 Apple 공식 문서 중심으로 구현 기준을 잡는다.

| 주제 | 공식 근거 | 적용 기준 |
|---|---|---|
| Local Network 권한 | [NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSLocalNetworkUsageDescription), [TN3179 Local Network Privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) | iOS가 Mac Relay에 직접 연결하거나 Bonjour를 쓰면 Info.plist에 로컬 네트워크 사용 사유가 있어야 한다. |
| Bonjour 서비스 선언 | [NSBonjourServices](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSBonjourServices), [Bonjour](https://developer.apple.com/bonjour/) | `_darwinforge._tcp` 탐색은 Info.plist와 Mac listener service type이 일치해야 한다. |
| WebSocket client | [URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask) | WebSocket 메시지는 비동기 send/receive 기반이다. 하나의 socket에서 handshake와 event loop가 동시에 `receive()`를 경쟁하면 안 된다. |
| 비동기 테스트 | [XCTest asynchronous tests](https://developer.apple.com/documentation/xctest/asynchronous-tests-and-expectations) | 연결, handshake, watchdog, ACK timeout은 `async` 테스트나 expectation으로 검증한다. |
| TestFlight | [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/), [Add internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers) | 내부 테스터 배포 전에 build upload, test information, export compliance, known limitation을 문서화한다. |
| iOS UI 접근성 | [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [HIG Color](https://developer.apple.com/design/human-interface-guidelines/color), [HIG Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [HIG Toggles](https://developer.apple.com/design/human-interface-guidelines/toggles) | 상태를 색만으로 전달하지 말고, 위험/잠금/연결 상태는 텍스트와 아이콘으로 함께 전달한다. Toggle은 실제 binary state에만 사용한다. |

### 1.2 프로젝트 내부 근거

반드시 먼저 읽을 파일:

```text
docs/prd/ios-robot-control-mvp.md
docs/protocols/mobile-relay-v1.md
docs/release/ios-mobile-pilot-testflight.md
docs/handoff/2026-05-25-claude-ios-mobile-pilot-implementation.md
docs/motion-format/page-catalog-motion4096.md
docs/motion-format/page-metadata-motion4096.toml
```

핵심 구현 파일:

```text
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/RootView.swift
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/AppState.swift
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/RemotePilotScreen.swift
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/PilotScreen.swift
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/ConnectScreen.swift
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/TestScreen.swift
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/LogsScreen.swift
app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/CommandBuilder.swift
app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/WebSocketRelayClient.swift
app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/HeartbeatController.swift
app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/MobileRelayModels.swift
app/mobile/DarwinForgeMobile/Tests/MobilePilotKitTests/
app/mobile/DarwinForgeMobile/Tests/DarwinForgeMobileAppTests/
```

Mac Relay 구현 파일:

```text
app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayBootstrap.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayController.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayServer.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayCommand.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayStatusChip.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/ConnectionStoreSafetyPort.swift
app/ui/DarwinForge/Tests/DarwinForgeUITests/MobileRelay/
```

## 2. 구현 방법론

Claude는 아래 순서로 작업한다.

### 2.1 "실제 제어 경로 1개"를 먼저 세운다

첫 빌드의 성공 기준은 많은 버튼이 아니라 아래 한 경로가 끊기지 않는 것이다.

```text
iPhone
  -> WebSocketRelayClient
  -> Mac MobileRelayWebSocketServer
  -> MobileRelayServer
  -> ConnectionStoreSafetyPort
  -> MobileRelayBootstrap live hooks
  -> WalkLabSession.start / stop
  -> existing robot control path
```

이 경로가 증명되기 전에는 analog joystick, head tracking, bow, QR camera 같은 보조 기능을 확장하지 않는다.

### 2.2 거짓 UI 제거 원칙

실제로 실행되지 않는 기능은 "조종 가능"처럼 보이면 안 된다.

- Mac이 `freeform`을 reject한다면 iOS real relay 모드에서 analog joystick을 비활성화하거나 숨긴다.
- slot 41이 bow가 아니라면 `절` 버튼을 제거한다.
- QR camera scanner가 없으면 버튼명은 "QR로 연결"이 아니라 "QR JSON 붙여넣기로 연결"이어야 한다.
- Bonjour로 Mac을 발견했어도 pairing code 없이 연결할 수 없다면 자동 연결 버튼을 만들지 않는다.

### 2.3 Fail-closed safety

지원하지 않는 제어는 UI와 서버 양쪽에서 모두 막는다.

- UI: 버튼 disable + reason 표시
- iOS state machine: ARM/latency/telemetry 조건 확인
- Mac server: safelist 검사
- Mac port: dxlPower/preflight/session availability 검사
- Robot path: 기존 WalkLab preflight와 E-stop 체인 유지

### 2.4 비동기 네트워크 검증

WebSocket handshake는 단일 receive owner 원칙을 적용한다.

허용되는 구조:

```text
connect()
  socket.resume()
  send session.hello
  await session.welcome or session.rejected
  mark connected
  start receiveLoop()
```

또는:

```text
connect()
  start one receiveLoop()
  receiveLoop resolves welcomeContinuation
```

금지되는 구조:

```text
receiveLoop() starts
awaitWelcome() also calls socket.receive()
```

### 2.5 HIL 단계 검증

검증은 simulator build에서 끝내지 않는다.

| 단계 | 목적 | 통과 기준 |
|---|---|---|
| L0 Unit | 모델/state/encoding/heartbeat | iOS `swift test` 통과 |
| L1 Mac Relay Unit | pairing/single authority/watchdog/walk port | Mac `swift test --filter MobileRelay --jobs 1` 통과 |
| L2 iOS Build | TestFlight 후보 기본 빌드 | simulator build 성공 |
| L3 Local E2E | iPhone client와 Mac relay handshake | real WebSocket 연결, welcome, telemetry 수신 |
| L4 Cradle HIL | 로봇 cradle/tether 상태 | ARM, walkReady, greeting, stop 성공 |
| L5 Safety HIL | 실패와 중단 | E-stop, app background, Wi-Fi disconnect, heartbeat timeout 모두 stop |
| L6 TestFlight | 내부 테스터 설치 | TestFlight 설치 후 Review Mode와 real relay smoke 통과 |

## 3. P0 수정 항목

### P0-1. WalkLabSession 주입 누락 수정

문제:

- `RootView`는 `walkLabSession`을 보유한다.
- 하지만 `MobileRelayBootstrap` 호출 시 `walkSession` 인자를 넘기지 않는다.
- `MobileRelayBootstrap.sendWalk`는 `walkSession == nil`이면 `walkSessionUnavailable`로 reject한다.

현재 위치:

```text
app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayBootstrap.swift
```

수정:

```swift
MobileRelayBootstrap(store: store,
                     controller: mobileRelayController,
                     walkSession: walkLabSession)
```

추가 확인:

- `walkLabSession`이 `@State` reference로 앱 생명주기 동안 유지되는지 확인한다.
- `MobileRelayBootstrap`의 `weak var walkSession`이 nil이 되지 않는지 실제 화면에서 확인한다.
- 필요하면 `MobileRelayBootstrap`에 debug-only assertion 또는 log를 추가한다.

통과 기준:

- iPhone에서 `slowForward`, `turnLeft`, `turnRight`, `stop` preset이 Mac Relay를 거쳐 `WalkLabSession.start(...)` 또는 `session.stop()`으로 들어간다.
- `walkSessionUnavailable`가 정상 설정에서 발생하지 않는다.

권장 테스트:

- `MobileRelayWalkIntegrationTests`에 live hook에서 walk session이 주입된 케이스를 추가한다.
- UI-level 테스트가 어렵다면 최소한 `RootView` 호출부 regression을 코드 리뷰 체크리스트에 고정한다.
- HIL에서 slow forward 2초, turn left 1초, release stop을 확인한다.

### P0-2. iOS analog freeform 조종의 거짓 표현 제거

문제:

- `RemotePilotScreen`은 analog joystick으로 조종되는 것처럼 보인다.
- `AppState.streamWalk()`는 `CommandBuilder.walkFreeform(...)`을 사용한다.
- `CommandBuilder.walkFreeform(...)`은 `WalkPreset.freeform`을 보낸다.
- Mac `MobileRelayBootstrap`은 `.freeform`을 `highRiskNotAllowed`로 reject한다.

현재 위치:

```text
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/RemotePilotScreen.swift
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/AppState.swift
app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/CommandBuilder.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayBootstrap.swift
docs/protocols/mobile-relay-v1.md
```

첫 빌드 권장 수정:

1. Real relay 모드에서는 `RemotePilotScreen`의 joystick/rotation freeform을 비활성화한다.
2. 기본 첫 탭을 analog 조종기가 아니라 검증된 `PilotScreen`의 preset/action 중심 화면으로 바꾼다.
3. `RemotePilotScreen` 상단에 "프리폼 조이스틱은 아직 실 로봇에서 비활성" 상태를 명확히 표시한다.
4. real relay에서 `streamWalk()`가 호출되면 `lastError`와 log에 `freeformUnsupportedInMVP`를 남기고 네트워크 명령을 보내지 않는다.
5. Mock/Review mode에서는 analog UI를 유지할 수 있지만, "시뮬레이션" 상태가 명확해야 한다.

대안:

- `freeform`을 실제 WalkLab parameter 제어로 구현할 수도 있지만 첫 TestFlight 빌드에는 권장하지 않는다. WalkLab이 x/y/turn continuous input을 안전하게 clamp하고 5Hz 이하로 적용한다는 HIL 근거가 먼저 필요하다.

통과 기준:

- 사용자가 real relay 모드에서 조이스틱을 움직여도 "실제 조종 가능"처럼 오해하지 않는다.
- 실제 로봇으로 나가는 보행은 `.slowForward`, `.turnLeft`, `.turnRight`, `.stop` preset뿐이다.
- docs/protocols/mobile-relay-v1.md의 "freeform은 인터페이스만 정의하고 서버가 reject" 설명과 UI가 일치한다.

### P0-3. WebSocket handshake receive race 수정

문제:

`WebSocketRelayClient.connect()`에서 `receiveLoop()`를 먼저 시작한 뒤 `awaitWelcome()`도 같은 socket에서 `receive()`를 호출한다. `session.welcome`을 어느 쪽이 먼저 받는지 비결정적이다.

현재 위치:

```text
app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/WebSocketRelayClient.swift
```

권장 수정:

```swift
socket.resume()
transportContinuation.yield(.handshaking)
try await sendRaw(helloEnvelope)

let welcome = try await awaitWelcome()
lock.lock()
sessionId = welcome.payload.sessionId
connected = true
lock.unlock()
transportContinuation.yield(.connected(sessionId: sessionId))

receiveTask = Task { [weak self] in await self?.receiveLoop() }
```

실패 처리도 같이 정리한다.

- welcome timeout이면 socket cancel
- pending continuation 정리
- `transportContinuation.yield(.disconnected(reason: ...))`
- `connected = false`, `task = nil`

통과 기준:

- Mac Relay가 `session.welcome` 직후 telemetry를 보내도 iOS 연결이 안정적으로 성공한다.
- 20회 반복 연결/해제에서 timeout이 재현되지 않는다.

권장 테스트:

- WebSocket client handshake test를 추가한다.
- 별도 패키지 의존성 때문에 Mac server와 iOS client를 한 테스트 target에 넣기 어렵다면, 최소한 실제 Mac app + iPhone/simulator local E2E 스크립트를 문서화한다.
- XCTest async test 방식을 사용한다.

### P0-4. `bow` slot 41 오표기 제거

문제:

iOS는 `bow`를 slot 41로 정의하지만, 프로젝트 내부 motion catalog는 41을 `talk2` long-chain 시작으로 설명한다. 즉 "절" 버튼이 실제 로봇에서 전혀 다른 긴 동작을 실행할 수 있다.

근거:

```text
app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/MobileRelayModels.swift
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/PilotScreen.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayServer.swift
docs/protocols/mobile-relay-v1.md
docs/motion-format/page-catalog-motion4096.md
```

`docs/motion-format/page-catalog-motion4096.md` 기준:

- slot 4 = `hi` / greeting
- slot 9 = `walkready`
- slot 15 = `sit down`
- slot 41 = `talk2` long-chain start, not bow

첫 빌드 권장 수정:

1. iOS `SafeMotionCatalog.mvpEnabledLabels`에서 `bow` 제거
2. `PilotScreen.ActionGrid`에서 `bow` 버튼 제거
3. Mac `MobileRelayServer.allowedLabels`에서 `bow` 제거
4. `docs/protocols/mobile-relay-v1.md`의 MVP table에서 `bow` 제거 또는 `deferred/custom only`로 수정
5. release note known limitation에 "bow/custom gesture는 다음 빌드" 명시

통과 기준:

- 첫 빌드에서 `bow` label이 real robot command로 나가지 않는다.
- UI에 표시된 액션 이름과 실제 slot 의미가 일치한다.

## 4. P1 수정 항목

### P1-1. Bonjour 발견 후 pairing code 흐름 수정

문제:

`ConnectScreen`은 Bonjour discovery result를 누르면 pairing code `"000000"`으로 연결한다. 실제 Mac Relay code가 다르면 실패한다.

현재 위치:

```text
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/ConnectScreen.swift
```

권장 수정:

- discovery result tap -> pairing code 입력 sheet 표시
- sheet에는 Mac 이름, host, port, 6자리 code field, 연결 버튼 표시
- 또는 discovery result tap -> manual host/port 자동 채움 + code field focus
- `"000000"` 자동 연결 코드는 제거

통과 기준:

- 사용자는 Mac 화면의 실제 pairing code를 iPhone에 입력한다.
- 잘못된 code는 `pairingMismatch`로 표시되고 재시도 가능하다.
- local network permission denied와 pairing mismatch가 서로 다른 메시지로 표시된다.

### P1-2. Mac Relay 상태칩의 connected 상태 표시

문제:

`MobileRelayStatusChip`은 `activeIPhoneName`이 있으면 connected로 표시하지만, `MobileRelayController`는 session accept 시 이 값을 설정하지 않는다.

현재 위치:

```text
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayController.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayServer.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayStatusChip.swift
```

권장 수정:

1. `MobileRelayServer`에 `currentDeviceName()` 또는 session lifecycle callback을 추가한다.
2. `MobileRelayController.start()`의 `onConnect` 후 accepted session이면 `activeIPhoneName`을 업데이트한다.
3. `onDisconnect`, `stop`, `closeSession` 후에는 nil로 되돌린다.

주의:

- `onConnect` closure는 `@Sendable` async이므로 `@MainActor` property 업데이트는 `await MainActor.run { ... }`로 처리한다.
- rejected hello에서는 connected로 표시하면 안 된다.

통과 기준:

- Mac toolbar chip이 `대기 -> 연결됨 -> 대기/꺼짐`으로 실제 session 상태를 반영한다.
- 잘못된 pairing code 시 connected로 표시되지 않는다.

### P1-3. watchdog active command 추적 강화

문제:

Mac watchdog은 heartbeat payload의 `activeCommandId`가 있어야 stop을 보낸다. iOS가 첫 heartbeat를 보내기 전에 walk 명령이 들어가거나 heartbeat가 누락되면 server가 active walk를 모를 수 있다.

현재 위치:

```text
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayServer.swift
app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/HeartbeatController.swift
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/AppState.swift
```

권장 수정:

- `handleWalk`에서 `env.payload.enabled == true`이고 preset이 `.stop`이 아니면 server-side `session.activeCommandId = env.id`로 설정한다.
- `handleStop`, `handleEstop`, `handleDisarm`, `handleClientDisconnected`에서 activeCommandId를 clear한다.
- heartbeat는 activeCommandId를 refresh하는 보조 신호로 유지한다.

통과 기준:

- walk command가 accepted된 뒤 heartbeat가 끊기면 Mac이 stop을 보낸다.
- heartbeat가 아직 도착하지 않은 edge case에서도 fail-closed로 동작한다.

### P1-4. ARM checklist를 실제 확인 항목으로 바꾸기

문제:

현재 physical E-stop과 observer 항목이 `.constant(true).disabled(true)`다. 사용자는 실제로 확인하지 않았는데 확인된 것처럼 보인다.

현재 위치:

```text
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/PilotScreen.swift
app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/RemotePilotScreen.swift
```

권장 수정:

- `cradleConfirmed`
- `physicalEStopConfirmed`
- `lineOfSightConfirmed`

세 항목을 모두 사용자 toggle로 받는다. Real relay ARM은 세 항목이 true일 때만 가능하다.

Mock/Review mode에서는 설명을 달고, real relay에서는 진짜 gate로 동작한다.

통과 기준:

- 사용자가 체크하지 않은 안전 항목은 ARM을 막는다.
- ARM 요청 payload 또는 iOS log에 checklist state를 남긴다.

## 5. P2 수정 항목

### P2-1. QR camera scanner와 paste fallback 구분

현재 QR 섹션은 카메라 scanner가 아니라 JSON paste다. 첫 빌드에서 카메라 scanner를 넣지 않을 수는 있지만, UI 문구는 사실과 일치해야 한다.

선택지:

1. 첫 빌드: "QR JSON 붙여넣기"로 명확히 rename
2. 다음 빌드: AVFoundation metadata capture로 QR camera scanner 추가, Info.plist에 `NSCameraUsageDescription` 추가

### P2-2. 테스트 화면을 검증 artifact로 개선

현재 `TestScreen`은 checklist와 `print("[TEST]")`만 있다. TestFlight/HIL 증거로는 부족하다.

권장 수정:

- `TestRunRecord: Codable` 추가
- fields: startedAt, endedAt, appVersion, mode, endpoint, pairing method, steps, result, notes, commandIds, maxLatency, stopReasons, estopVerified, backgroundStopVerified, disconnectStopVerified
- `LogsScreen` 또는 `TestScreen`에 JSON export/share 추가
- TestFlight feedback에 첨부할 수 있는 텍스트 요약 생성

첫 빌드 통과 기준:

- HIL 테스트 후 최소한 JSON/text summary를 저장하거나 공유할 수 있다.
- 실패 사유와 command id가 남는다.

### P2-3. TestFlight 문서 갱신

수정 후 아래 문서를 업데이트한다.

```text
docs/release/ios-mobile-pilot-testflight.md
docs/handoff/ios-mobile-pilot-first-build.md
docs/handoff/ios-mobile-pilot-hil.md
docs/protocols/mobile-relay-v1.md
```

반드시 반영할 내용:

- 첫 빌드 real relay 지원 범위
- freeform joystick 비활성 사실
- bow/custom gesture 제외
- 실제 Bundle ID, scheme, version/build
- HIL 통과/미통과 항목
- TestFlight known limitations

## 6. 권장 구현 순서

1. P0-4 `bow` 제거부터 한다. 잘못된 동작 실행 가능성을 먼저 없앤다.
2. P0-1 `walkLabSession` 주입을 고친다.
3. P0-3 WebSocket handshake race를 고친다.
4. P0-2 real relay에서 freeform UI/command를 막고 preset-only 조작으로 정렬한다.
5. P1-1 discovery pairing code sheet를 만든다.
6. P1-2 Mac status chip connected 상태를 고친다.
7. P1-3 watchdog active command 추적을 강화한다.
8. P1-4 ARM checklist를 실제 확인 항목으로 만든다.
9. P2-2 테스트 artifact export를 만든다.
10. 문서와 TestFlight runbook을 실제 구현에 맞게 갱신한다.

## 7. 검증 명령

Claude는 구현 후 아래를 실행한다.

### iOS unit test

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/mobile/DarwinForgeMobile
swift test
```

### iOS simulator build

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/mobile/DarwinForgeMobile
xcodebuild \
  -project Xcode/DarwinForgeMobile.xcodeproj \
  -scheme OPPilot \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

### Mac MobileRelay tests

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge
swift test --filter MobileRelay --jobs 1
```

### 추가 권장 테스트

```bash
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge
swift test --filter WalkLab --jobs 1
```

실패가 나면 실패 로그와 관련 파일을 보고 원인을 수정한다. 단, 기존 dirty worktree의 무관한 변경을 되돌리지 않는다.

## 8. HIL 수동 검증 체크리스트

실제 robot 테스트는 cradle 또는 tether 상태에서만 한다.

### HIL-0. 준비

- Mac DarwinForge 실행
- Mobile Pilot Relay ON
- iPhone과 Mac이 같은 Wi-Fi
- robot connected
- dxlPower ON 가능
- 물리 E-stop 손 닿는 곳
- observer 또는 operator line of sight 확보

### HIL-1. 연결

- iPhone real relay mode
- Bonjour discovery 또는 manual host로 Mac 선택
- 실제 pairing code 입력
- `session.welcome` 수신
- telemetry 표시
- Mac status chip connected 표시

### HIL-2. ARM

- 세 안전 checklist 모두 직접 확인
- ARM slider 실행
- Mac/robot telemetry에서 armed/dxlPower 상태 확인
- 실패 시 UI가 이유를 표시

### HIL-3. Safe motion

허용:

- `walkReady` slot 9
- `basicPosture` slot 1
- `sit` slot 15
- `greeting` slot 4
- `stop`

금지:

- `bow` slot 41
- kick slot 12/13
- freeform joystick
- raw motion chain

### HIL-4. Preset walk

- slow forward 2초 press-hold
- release stop
- turn left 1초
- release stop
- turn right 1초
- release stop

통과 기준:

- press 중에만 움직인다.
- release 후 stop이 들어간다.
- heartbeat timeout 전후 로그가 일관된다.

### HIL-5. Safety stop

- active walk 중 E-stop
- active walk 중 iOS app background
- active walk 중 tab switch
- active walk 중 Wi-Fi disconnect 또는 Mac relay stop

통과 기준:

- 모두 stop 또는 E-stop으로 이어진다.
- UI가 ACK 없는 성공을 표시하지 않는다.
- log에 command id와 stop reason이 남는다.

## 9. Claude에게 붙여넣을 구현 프롬프트

아래 전체를 Claude에게 붙여넣는다.

```text
You are implementing the iOS Robot Control truth-gap fixes for the DarwinForge repo.

Workspace root:
/Users/bbikiming/Documents/vibe_coding/Darwin

User context:
- The product owner is a UI/UX planner and needs a first build that is honest, testable, and safe.
- Do not ship fake control affordances.
- The first build must work as an iPhone controller through the Mac relay, not through direct iPhone USB/serial control.

Read these files first:
- docs/handoff/2026-05-25-claude-ios-robot-control-fix-report.md
- docs/prd/ios-robot-control-mvp.md
- docs/protocols/mobile-relay-v1.md
- docs/release/ios-mobile-pilot-testflight.md
- docs/motion-format/page-catalog-motion4096.md
- docs/motion-format/page-metadata-motion4096.toml
- app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift
- app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayBootstrap.swift
- app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayController.swift
- app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayServer.swift
- app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayStatusChip.swift
- app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/RootView.swift
- app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/AppState.swift
- app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/RemotePilotScreen.swift
- app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/PilotScreen.swift
- app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/ConnectScreen.swift
- app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/Screens/TestScreen.swift
- app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/WebSocketRelayClient.swift
- app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/CommandBuilder.swift
- app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/MobileRelayModels.swift

Implement these fixes in order:

1. Remove the unsafe/false `bow` MVP action.
   - Remove `bow` from iOS SafeMotionCatalog MVP enabled labels.
   - Remove the `bow` button from PilotScreen ActionGrid.
   - Remove `bow` from Mac MobileRelayServer allowedLabels.
   - Update docs/protocols/mobile-relay-v1.md so slot 41 is not presented as bow.
   - Reason: project motion catalog says slot 41 is `talk2` long-chain, not bow.

2. Wire the real WalkLabSession into MobileRelayBootstrap.
   - In app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift, pass `walkSession: walkLabSession` into `MobileRelayBootstrap`.
   - Confirm MobileRelayBootstrap no longer rejects normal preset walk with `walkSessionUnavailable`.
   - Do not bypass WalkLabSession quickPreflight.

3. Fix WebSocketRelayClient handshake receive race.
   - Ensure only one code path calls `URLSessionWebSocketTask.receive()` during handshake.
   - Recommended: send hello, await welcome/rejected, mark connected, then start receiveLoop.
   - On handshake failure, cancel socket, clear task, clear connected, and yield disconnected state.

4. Align real relay UI with supported controls.
   - Real relay mode must be preset-only for walking: slowForward, turnLeft, turnRight, stop.
   - Disable or hide freeform joystick/rotation controls in real relay mode.
   - If joystick remains in Mock/Review mode, clearly label it as simulated.
   - Make `AppState.streamWalk()` refuse to send `freeform` in real relay mode and log the reason.

5. Fix Bonjour discovery pairing.
   - Remove hardcoded pairing code "000000".
   - Selecting a discovered Mac should ask for the actual 6-digit pairing code or populate manual host/port and focus the code field.

6. Fix Mac Relay connected status.
   - Update MobileRelayController.activeIPhoneName when MobileRelayServer accepts a session.
   - Clear it on disconnect/stop/rejection.
   - Preserve MainActor correctness.

7. Harden server-side watchdog active command tracking.
   - When handleWalk accepts an enabled non-stop walk command, set session.activeCommandId = env.id.
   - Clear activeCommandId on stop, E-stop, disarm, disconnect.
   - Heartbeat should refresh activeCommandId, not be the only source.

8. Make ARM checklist real.
   - Replace disabled constant true toggles with real state:
     physicalEStopConfirmed and lineOfSightConfirmed.
   - ARM requires cradle/tether, physical E-stop, and line of sight in real relay mode.

9. Improve test evidence.
   - Add a minimal TestRunRecord JSON/text export from TestScreen or LogsScreen.
   - Include appVersion, mode, endpoint, startedAt, endedAt, result, notes, commandIds, maxLatency, stop reasons, and safety checks.

10. Update docs after implementation.
   - docs/protocols/mobile-relay-v1.md
   - docs/release/ios-mobile-pilot-testflight.md
   - docs/handoff/ios-mobile-pilot-first-build.md
   - docs/handoff/ios-mobile-pilot-hil.md

Constraints:
- Do not implement iPhone direct USB/serial/raw Dynamixel control.
- Do not enable kick/high-risk motion in the first build.
- Do not make the UI claim analog control works on the real robot until Mac/WalkLab supports it and HIL verifies it.
- Preserve unrelated dirty worktree changes. Do not run destructive git commands.
- Keep edits scoped to the iOS mobile app, MobileRelay, docs, and focused tests.

Required verification:

Run:
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/mobile/DarwinForgeMobile
swift test

Run:
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/mobile/DarwinForgeMobile
xcodebuild -project Xcode/DarwinForgeMobile.xcodeproj -scheme OPPilot -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

Run:
cd /Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge
swift test --filter MobileRelay --jobs 1

Final response must include:
- Changed files
- What was fixed
- Tests run and results
- Remaining HIL steps that still need real robot/iPhone/TestFlight verification
- Any known limitations left intentionally disabled
```

## 10. 완료 정의

Claude 작업이 완료됐다고 보려면 아래가 모두 true여야 한다.

- `bow`가 첫 빌드 real action에서 제거됐다.
- iPhone preset walk가 Mac Relay를 통해 `WalkLabSession`으로 연결된다.
- WebSocket welcome race가 제거됐다.
- real relay mode에서 freeform joystick이 실제 조종 가능처럼 보이지 않는다.
- Bonjour discovery가 실제 pairing code 흐름을 갖는다.
- Mac toolbar가 연결된 iPhone 상태를 정확히 표시한다.
- heartbeat/watchdog stop이 server-side active command 기준으로도 동작한다.
- ARM checklist가 실제 사용자 확인 항목이다.
- iOS test, iOS build, Mac MobileRelay test가 통과한다.
- HIL runbook에 아직 실기기 검증이 필요한 항목이 명확히 남아 있다.

