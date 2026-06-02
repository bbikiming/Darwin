# iOS-Mac Mobile Relay 상태 불일치 진단 보고서

작성일: 2026-05-25  
범위: 코드 수정 없음. 현재 업그레이드된 소스를 읽고, "iOS 앱은 연결됨으로 표시되지만 Mac 앱은 대기중으로 표시"되는 원인 후보와 검증 방법만 정리.

## 결론 요약

iOS와 Mac의 연결 자체는 충분히 가능하다. 현재 구조도 공식적으로 권장되는 로컬 네트워크 방식과 맞다.

- Mac: `NWListener`로 TCP listener를 열고 Bonjour service `_darwinforge._tcp`를 광고한다.
- iOS: Bonjour로 Mac을 찾고 `URLSessionWebSocketTask`로 `ws://host:port/mobile-relay`에 연결한다.
- 프로토콜: iOS/Mac 양쪽 모두 `session.hello` -> `session.welcome` handshake를 사용한다.

따라서 현재 증상은 "네트워크 연결 자체가 불가능"보다는 다음 중 하나일 가능성이 높다.

1. iOS가 실제 Mac UI 반영 전에 너무 일찍 `연결됨`으로 표시한다.
2. Mac 서버는 세션을 만들었지만 툴바 chip이 보는 `activeIPhoneName`이 갱신되지 않는다.
3. Mac에서 실행 중인 앱이 현재 소스의 최신 빌드가 아니다.
4. `session.welcome` 직후 transport disconnect가 발생해 Mac은 다시 `대기중`으로 돌아가지만, iOS UI는 연결 상태를 유지한다.
5. Bonjour/Local Network 권한은 discovery 문제의 후보지만, iOS가 이미 `연결됨`까지 갔다면 1차 원인은 아닐 가능성이 크다.

## 공식 가이드 근거

Apple 공식 문서 기준으로 이 방식은 타당하다.

- Bonjour는 로컬 네트워크의 기기와 서비스를 자동 발견하기 위한 Apple의 zero-configuration networking 기술이다.  
  출처: https://developer.apple.com/bonjour/
- Network framework는 `NWListener`, `NWBrowser`, `NWConnection`을 통해 로컬 네트워크 listener, discovery, TCP 연결을 구성할 수 있다. `NWListener.Service`는 listener가 Bonjour service를 광고하는 구조다.  
  출처: https://developer.apple.com/documentation/network
- `NWBrowser.Descriptor.bonjour(type:domain:)`는 Bonjour service discovery 용 descriptor다.  
  출처: https://developer.apple.com/documentation/network/nwbrowser/descriptor-swift.enum/bonjour(type:domain:)
- `URLSessionWebSocketTask`는 `ws:` 또는 `wss:` URL로 WebSocket handshake를 수행하고 메시지를 비동기로 send/receive하는 Apple Foundation API다.  
  출처: https://developer.apple.com/documentation/foundation/urlsessionwebsockettask
- Apple TN3179 기준, 앱이 Bonjour service를 browse/register하면 `Info.plist`의 `NSBonjourServices`에 service type을 선언해야 한다.  
  출처: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy

## 현재 코드에서 확인한 구조

### iOS 연결 흐름

파일: `app/mobile/DarwinForgeMobile/Sources/DarwinForgeMobileApp/AppState.swift`

- `connect(to:)`는 연결 시작 후 `relayClient.connect(request)`를 호출한다.
- 성공하면 `pairedEndpoint`를 세팅하고 `pairingSucceeded`로 상태를 바꾼다.
- 동시에 transport stream이 아직 `.connected`를 반영하지 않았으면 임시로 아래 상태를 직접 넣는다.

```swift
transport = .connected(sessionId: "ses_pending")
```

이 부분은 테스트와 UI 결정성을 높이기 위한 코드지만, 실제 세션 ID를 받기 전 또는 Mac UI가 갱신되기 전에 iOS가 먼저 연결됨처럼 보일 수 있다. 즉, 현재 증상의 1순위 후보 중 하나다.

파일: `app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/WebSocketRelayClient.swift`

- `connect(_:)`는 `URLSessionWebSocketTask`를 만들고 `session.hello`를 보낸다.
- `awaitWelcome()`에서 `session.welcome`을 기다린 뒤에야 내부 `connected = true`로 바꾸고 `.connected(sessionId:)`를 yield한다.
- 이 자체는 올바른 방향이다. 다만 `AppState`의 `ses_pending` 임시 상태가 실제 truth source를 흐릴 수 있다.

### Mac 연결 상태 표시 흐름

파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayStatusChip.swift`

Mac 툴바 chip은 상태를 아주 단순하게 판정한다.

```swift
guard controller.isRunning else { return .off }
if let name = controller.activeIPhoneName { return .connected(name: name) }
return .waiting(code: controller.pairingCode)
```

즉 Mac에서 "대기중"이 보인다는 뜻은 다음과 같다.

- relay server는 켜져 있다: `isRunning == true`
- 하지만 연결된 iPhone 이름은 없다: `activeIPhoneName == nil`

파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayController.swift`

현재 소스에는 이미 이 문제를 의식한 수정 흔적이 있다.

- `onPaired` callback으로 페어링 즉시 `activeIPhoneName = device`를 넣는다.
- `startTelemetryPump()`에서도 1초마다 `server.currentDeviceName()`을 읽어 `activeIPhoneName`을 동기화한다.

파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/MobileRelayServer.swift`

`acceptHello()`는 정상 페어링 시 다음 순서로 동작한다.

1. pairing code 검증
2. `sessionId` 생성
3. `session = Session(...)` 저장
4. `session.welcome` 전송
5. harness에 `mobilePilotPairingSuccess` 기록
6. `onPaired(deviceName, sessionId)` 호출
7. telemetry broadcast
8. watchdog 시작

따라서 iOS가 실제로 `session.welcome`을 받았다면 Mac 서버의 `session` 생성과 `onPaired` 호출까지 가는 것이 정상이다. 이 경우 Mac UI가 계속 대기중이면 서버보다 UI 반영 경로, 실행 중인 바이너리, 또는 직후 disconnect/reset을 의심해야 한다.

### RootView 인스턴스 공유 확인

파일: `app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift`

현재 소스 기준으로는 `MobileRelayBootstrap`과 `MobileRelayStatusChip`이 같은 `@StateObject mobileRelayController`를 공유한다.

- floating panel: `MobileRelayBootstrap(store: controller: mobileRelayController, ...)`
- toolbar chip: `MobileRelayStatusChip(controller: mobileRelayController)`

따라서 현재 소스만 보면 "서버는 A controller, chip은 B controller를 본다"는 문제는 이미 방지되어 있다. 그래도 실제 앱에서 대기중이면 최신 소스가 실행 중인지, 다른 status chip이 렌더링되고 있는지, 또는 build artifact가 오래된 것인지 확인해야 한다.

## 원인 후보와 우선순위

### P0-1. iOS의 `ses_pending` 임시 연결 상태가 실제 연결 상태를 과대표시

근거:

- `AppState.connect(to:)`는 `relayClient.connect` 성공 직후 transport stream 반영 전 `transport = .connected(sessionId: "ses_pending")`를 넣는다.
- 사용자는 이 시점에 "연결됨" UI를 볼 수 있다.
- 실제 세션 ID인 `ses_...`가 아닌 `ses_pending`이면 Mac과의 진짜 세션 동기화가 검증된 것이 아니다.

Claude 확인 지시:

- iOS 화면 또는 debug log에 현재 session id를 임시 표시한다.
- `ses_pending`이 보이는 동안 "연결됨"으로 표시되는지 확인한다.
- 연결 성공 판정은 반드시 `WebSocketRelayClient`가 받은 실제 `WelcomePayload.sessionId`를 기준으로 통일한다.

수정 방향:

- iOS UI의 "연결됨"은 `session.welcome`에서 받은 실제 `sessionId`가 있을 때만 표시한다.
- `ses_pending`은 없애거나 "연결 확인 중" 같은 별도 상태로 분리한다.
- command 가능 여부도 `ses_pending`이 아니라 실제 session id 기준으로 판정한다.

### P0-2. Mac UI가 `activeIPhoneName`만 보고 있어 서버 세션과 UI 상태가 분리됨

근거:

- `MobileRelayStatusChip`은 `server.hasActiveSession()`을 직접 보지 않는다.
- 오직 `MobileRelayController.activeIPhoneName`만 본다.
- `onPaired` 또는 polling update가 누락되면 서버는 연결됐어도 chip은 대기중이다.

Claude 확인 지시:

- `MobileRelayServer.acceptHello()`에서 `onPaired` 호출 직전/직후 로그를 확인한다.
- `MobileRelayController.pairedSink`가 실제 호출되는지 확인한다.
- `activeIPhoneName`이 한 번이라도 non-nil이 되는지 확인한다.
- `startTelemetryPump()`에서 `server.currentDeviceName()`이 non-nil을 반환하는지 확인한다.

수정 방향:

- Mac UI의 source of truth를 `activeIPhoneName` 단일 문자열이 아니라 `RelaySessionState`로 승격한다.
- 예: `.off`, `.advertising(code)`, `.handshaking(device)`, `.paired(device, sessionId, connectedAt)`, `.disconnecting(reason)`, `.error(message)`.
- chip은 이 state를 렌더링하고, 서버 session과 session id를 함께 보여줘야 한다.

### P0-3. 실제 실행 중인 Mac 앱이 최신 소스가 아닐 가능성

근거:

- 현재 소스에는 이미 `V293 fix`, `P1-2 fix` 주석과 함께 mismatch 보완 코드가 있다.
- 그런데 실제 앱에서 여전히 "대기중"이면 이전 빌드가 실행 중일 가능성이 있다.

Claude 확인 지시:

- Mac 앱에서 build number 또는 git commit hash를 표시하거나 로그에 출력한다.
- Xcode/SwiftPM/수동 실행 중 어느 바이너리가 실행되는지 확인한다.
- clean build 후 같은 증상이 재현되는지 확인한다.

수정 방향:

- Mac 앱 About/Debug 영역에 `CFBundleShortVersionString`, `CFBundleVersion`, git short SHA를 표시한다.
- Mobile Relay panel에 "빌드 시각" 또는 "protocol build"를 표시해 테스트 혼선을 줄인다.

### P1-1. `session.welcome` 직후 disconnect/reset으로 Mac이 다시 대기중으로 돌아감

근거:

- `MobileRelayServer.handleClientDisconnected()`는 active session disconnect를 감지하면 grace 이후 stop/disarm/close를 수행한다.
- `closeSession()` 또는 `onUnpaired`가 호출되면 `activeIPhoneName = nil`이 된다.
- iOS는 임시 연결 상태 또는 delayed UI 때문에 끊김을 늦게 반영할 수 있다.

Claude 확인 지시:

- Mac harness에서 `mobilePilotPairingSuccess` 직후 `mobilePilotDisconnected`가 찍히는지 확인한다.
- iOS 로그에서 `session.welcome` 직후 `receive error`, `disconnected`, `handshakeFailed`가 이어지는지 확인한다.
- WebSocket server의 `WSChannel.stateUpdateHandler`에서 `.cancelled`, `.failed`가 언제 발생하는지 타임스탬프로 확인한다.

수정 방향:

- iOS와 Mac 모두 connection timeline을 남긴다.
- 최소 이벤트: `socketOpen`, `helloSent`, `welcomeReceived`, `onPaired`, `firstTelemetry`, `heartbeatStarted`, `disconnect`.
- 사용자 UI는 "연결됨"과 "연결 끊김" 사이의 순간 상태를 숨기지 말고 "연결 확인 중" 또는 "다시 연결 중"으로 표시한다.

### P1-2. Bonjour/Local Network 권한 및 service 선언 누락 가능성

근거:

- iOS Xcode plist에는 `NSLocalNetworkUsageDescription`, `NSBonjourServices`가 있다.
- Mac plist에는 `NSLocalNetworkUsageDescription`은 있지만 `NSBonjourServices`가 현재 검색되지 않았다.
- Mac app은 sandbox entitlements에서 `network.server`, `network.client`를 켜고 있다.
- 현재 Mac plist 문구는 Tello 드론 중심이라 Mobile Pilot Relay 목적이 명확하지 않다.

이 이슈는 "iOS가 연결됨까지 갔다"면 1차 원인은 아닐 수 있다. 다만 discovery, 권한 prompt, packaged app 동작 안정성에는 반드시 정리해야 한다.

Claude 확인 지시:

- Mac packaged app의 실제 `Contents/Info.plist`에 `NSLocalNetworkUsageDescription`이 들어가는지 확인한다.
- 필요 시 `_darwinforge._tcp`를 `NSBonjourServices`에 선언한다.
- macOS 시스템 설정에서 Local Network 권한과 Firewall inbound 허용 상태를 확인한다.
- iPhone과 Mac이 같은 Wi-Fi, 같은 subnet에 있고 AP isolation/client isolation이 꺼져 있는지 확인한다.

수정 방향:

- Mac plist 문구를 Tello만이 아니라 "iPhone Mobile Pilot 앱과 로컬 네트워크로 연결"까지 포함하도록 정리한다.
- Bonjour service type `_darwinforge._tcp`를 앱의 source-of-truth로 문서화하고 iOS/Mac 양쪽 상수와 plist를 동기화한다.

### P2-1. 현재 테스트가 실제 UI 상태 불일치를 충분히 잡지 못함

근거:

- `MobileRelayServerTests`는 `session.welcome` 수신은 검증한다.
- `MobileRelayStatusChipTests`는 실제 connected 분기를 통합 테스트하지 않고, `activeIPhoneName == nil` 조건 확인에 가깝다.
- iOS `RelayClientFlowTests`도 mock/scripted 중심이며 실제 Mac server와 cross-process handshake를 검증하지 않는다.

Claude 확인 지시:

- "서버가 `session.welcome` 전송 후 controller `activeIPhoneName`이 non-nil이 되는지"를 검증하는 통합 테스트를 추가한다.
- 가능하면 in-memory channel이 아니라 `MobileRelayWebSocketServer`를 localhost 포트로 띄우고 iOS `WebSocketRelayClient`와 실제 WebSocket handshake를 수행하는 테스트를 별도 target에 둔다.

수정 방향:

- acceptance test 이름 예시:
  - `testPairingSuccessUpdatesControllerActiveIPhoneName`
  - `testToolbarChipStateTurnsConnectedAfterWelcome`
  - `testIOSDoesNotShowConnectedWithPendingSessionOnly`
  - `testWelcomeThenDisconnectMovesBothSidesToDisconnected`

## Claude에게 전달할 진단 순서

아래 순서대로 보면 시간을 가장 적게 쓴다.

1. iOS가 실제 연결 모드인지 확인한다. Mock/Review 모드면 비교 자체가 무효다.
2. iOS 연결 직후 session id를 확인한다. `ses_pending`이면 아직 진짜 연결 확정으로 보면 안 된다.
3. Mac harness에서 `mobilePilotPairingSuccess` 이벤트가 찍혔는지 확인한다.
4. 같은 타임라인에서 `mobilePilotDisconnected`가 바로 이어지는지 확인한다.
5. Mac `MobileRelayController.activeIPhoneName`이 non-nil로 변하는지 확인한다.
6. `server.currentDeviceName()`은 non-nil인데 `activeIPhoneName`만 nil인지 확인한다.
7. `MobileRelayBootstrap`과 `MobileRelayStatusChip`이 같은 controller instance를 보는지 object identity 로그로 확인한다.
8. Mac 앱 build number/commit이 현재 소스와 일치하는지 확인한다.
9. Mac packaged app의 실제 plist/entitlements를 확인한다.
10. Wi-Fi 환경, macOS Firewall, Local Network 권한을 확인한다.

## 권장 수정 방침

구현은 Claude가 이어서 하되, 방향은 아래가 안전하다.

1. 연결 상태를 optimistic UI가 아니라 authoritative handshake로 통일한다.
   - 기준: 실제 `session.welcome.sessionId`.
   - `ses_pending`은 제거하거나 "확인 중" 상태로만 사용한다.

2. iOS와 Mac이 같은 session id를 사용자/개발자 UI에서 확인할 수 있게 한다.
   - iOS: 연결 상세에 `Mac name`, `host:port`, `sessionId suffix`, `last telemetry age`.
   - Mac: toolbar popover에 `iPhone name`, `sessionId suffix`, `connectedAt`, `last heartbeat`.

3. Mac controller state를 문자열 하나가 아니라 명시적 state machine으로 바꾼다.
   - `.advertising`, `.handshaking`, `.paired`, `.reconnecting`, `.disconnected`, `.error`.
   - 이렇게 해야 UX 문구도 자연스럽게 바뀐다.

4. 권한/Bonjour 선언을 packaging 기준으로 검증한다.
   - source plist가 아니라 빌드된 `.app/Contents/Info.plist`를 확인한다.
   - iOS/Mac 양쪽 `_darwinforge._tcp`, `/mobile-relay`, protocol version을 하나의 체크리스트로 묶는다.

5. 회귀 테스트를 실제 사용자 증상 기준으로 작성한다.
   - "iOS 연결됨이면 Mac도 1초 안에 연결됨으로 표시"를 acceptance 기준으로 둔다.
   - "welcome 직후 disconnect면 iOS/Mac 둘 다 연결 끊김 또는 다시 연결 중으로 표시"를 acceptance 기준으로 둔다.

## 사용자가 직접 확인할 수 있는 빠른 체크

1. iPhone 앱에서 "실제 연결" 모드인지 확인한다.
2. Mac 오른쪽 아래 Mobile Relay 패널의 pairing code와 iPhone 입력 code가 같은지 확인한다.
3. iPhone 연결 직후 Mac 툴바 chip이 1초 뒤에도 계속 "대기중"인지 본다.
4. Mac 앱을 완전히 종료 후 최신 빌드로 다시 실행한다.
5. macOS 시스템 설정에서 DarwinForge의 Local Network/Firewall 허용을 확인한다.
6. iPhone과 Mac이 같은 Wi-Fi에 있고 VPN, 핫스팟 isolation, 게스트 Wi-Fi가 아닌지 확인한다.

## 아카이브 업로드 절차

현재 로컬에서 확인된 최신 archive 후보:

```text
/Users/bbikiming/Documents/vibe_coding/Darwin/app/mobile/DarwinForgeMobile/Xcode/.build/OPPilot-0.1.0-6.xcarchive
```

주의: 파일명은 `0.1.0-6`이지만 archive 내부 `CFBundleVersion`은 `7`로 확인된다. Xcode Organizer에서는 `0.1.0 (7)`처럼 보일 수 있다.

Apple 공식 문서 기준, App Store Connect 업로드 권한은 Account Holder, Admin, App Manager, Developer 역할 중 하나가 필요하다. 업로드 방법은 Xcode, Transporter, altool, App Store Connect API가 가능하다.  
출처: https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/

가장 쉬운 업로드 방법:

1. archive 열기

```bash
open /Users/bbikiming/Documents/vibe_coding/Darwin/app/mobile/DarwinForgeMobile/Xcode/.build/OPPilot-0.1.0-6.xcarchive
```

2. Xcode Organizer에서 `OPPilot 0.1.0 (7)` archive 선택
3. `Distribute App` 클릭
4. `App Store Connect` 선택
5. `Upload` 선택
6. signing은 우선 `Automatically manage signing` 선택
7. Validate/Upload 진행
8. 업로드 완료 후 App Store Connect의 TestFlight build processing 완료 메일을 기다린다.

CLI 업로드를 다시 시도하려면 먼저 Xcode > Settings > Accounts에서 App Store Connect 접근 권한이 있는 계정이 로그인되어 있어야 한다. 이전에 CLI 업로드가 "App Store Connect access 계정을 찾지 못함" 유형으로 실패했다면, Xcode Organizer 업로드가 더 빠른 우회 경로다.

## 최종 판단

현재 소스만 보면 iOS-Mac 연결 프로토콜은 성립 가능하고 방향도 맞다. 다만 UI가 보여주는 "연결됨"의 기준이 iOS와 Mac에서 완전히 같지 않다.

Claude가 가장 먼저 확인해야 할 한 줄은 이것이다.

```text
iOS가 표시하는 연결됨의 sessionId와 Mac 서버의 currentSessionId가 같은가?
```

같으면 Mac UI 반영 문제다. 다르면 iOS의 optimistic 연결 표시 문제다. 같았다가 바로 끊기면 transport disconnect/reset 문제다.
