# iOS Mobile Pilot — 첫 빌드 핸드오프

작성일: 2026-05-25 (truth-gap fix 반영)
상태: First build landed, truth-gap fix 반영. 첫 탭 = 검증된 「동작」(preset+action) — 「조종기」 탭은 Mock/Review 시뮬레이션 보조 화면
관련 문서:
- [docs/prd/ios-robot-control-mvp.md](../prd/ios-robot-control-mvp.md)
- [docs/protocols/mobile-relay-v1.md](../protocols/mobile-relay-v1.md)
- [docs/handoff/ios-mobile-pilot-hil.md](ios-mobile-pilot-hil.md)
- [docs/release/ios-mobile-pilot-testflight.md](../release/ios-mobile-pilot-testflight.md)

## 1. 무엇이 이번 빌드에 포함됐는가

이번 핸드오프에서 들어간 것:

- `docs/protocols/mobile-relay-v1.md` — iOS ↔ Mac WebSocket JSON 프로토콜 v1 단일 source-of-truth.
- 새 iOS Swift Package `app/mobile/DarwinForgeMobile`
  - `MobilePilotKit` — 모델/state machine/relay client/heartbeat 컨트롤러
  - `MockRelayClient` / `ScriptedRelayClient` / `WebSocketRelayClient`
  - `DarwinForgeMobileApp` — SwiftUI 4 화면 (`Pilot`, `Connect`, `Test`, `Logs`)
  - `Info.plist.template` (Xcode wrapper용)
- Mac 측 `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/`
  - `MobileRelayCommand.swift` — wire protocol types
  - `MobileRelayPairing.swift` — 6자리 코드 + 3회 실패 lockout
  - `MobileRelayServer.swift` — actor-isolated 명령 라우터, single authority, heartbeat watchdog
  - `MobileRelayWebSocket.swift` — `NWListener` 기반 최소 WebSocket 서버
  - `MobileRelayController.swift` — SwiftUI 라이프사이클 facade + `MobileRelayPanel` view
  - `RobotSafetyPort.swift` — 추상 안전 포트 + `InMemorySafetyPort` 테스트용
  - `ConnectionStoreSafetyPort.swift` — 라이브 `ConnectionStore`/`TeleopChannel`/WalkLab 연결 어댑터 (hook 주입)
- iOS 단위 테스트 26개, Mac 단위 테스트 12개 — 모두 통과

## 2. 빌드 / 테스트 명령

### iOS 패키지

```bash
cd app/mobile/DarwinForgeMobile

# 호스트 macOS 빌드 (MobilePilotKit + SwiftUI App library)
swift build

# 단위 테스트 26개
swift test

# iOS Simulator 빌드 (Xcode 16+)
xcrun xcodebuild -scheme DarwinForgeMobileApp \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcodebuild \
  build
```

### Mac 패키지

```bash
cd app/ui/DarwinForge

# DarwinForgeUI (MobileRelay 모듈 포함) 빌드
swift build --target DarwinForgeUI

# MobileRelay 단위 테스트 12개
swift test --filter MobileRelay
```

### 검증 결과 (이 빌드 기준)

- `swift test` (DarwinForgeMobile): **26 passed / 0 failed**
- `swift test --filter MobileRelay` (DarwinForgeUI): **12 passed / 0 failed**
- `xcodebuild -destination 'generic/platform=iOS Simulator'`: **BUILD SUCCEEDED** (arm64 + x86_64)

## 3. 아직 남은 작업 (HIL 진입 전 차단 항목)

| ID | 항목 | 위치 |
|---|---|---|
| F-A | Xcode iOS app wrapper project 생성 (`.xcodeproj`) | `app/mobile/DarwinForgeMobile/` |
| F-B | App icon, bundle id (`com.<your-org>.darwinforge.mobile`), signing team 설정 | Xcode target settings |
| F-C | `Info.plist` 에 template 값 반영 | Xcode target settings |
| F-D | `MobileRelayController` 를 Mac `RootView` 또는 `ConnectionDashboard` 에 wire | `Sources/DarwinForgeUI/RootView.swift` |
| F-E | `ConnectionStoreSafetyPort.Hooks` 의 7개 클로저를 라이브 store/teleop/walkSession 으로 채우기 | Mac 통합 지점 (아래 §4 참조) |
| F-F | Mac advertised host 가 자동 LAN IP 가 아니라 사용자 선택 가능한 인터페이스 picker 가 되도록 확장 | `MobileRelayController` |
| F-G | iOS QR 카메라 스캔 (현재는 paste-only) | `Sources/DarwinForgeMobileApp/Screens/ConnectScreen.swift` |
| F-H | iOS 시뮬레이터에서 mock relay flow XCUITest 자동화 | `Tests/DarwinForgeMobileUITests/` (Xcode UI test target 생성 필요) |

이 8개 항목이 닫히기 전까지는 TestFlight 외부 배포는 차단.

## 4. Mac 측 hook 연결 가이드

`ConnectionStoreSafetyPort.Hooks` 7개 클로저는 다음과 같이 채운다.

```swift
let port = ConnectionStoreSafetyPort(hooks: .init(
    armAsync: { @MainActor in
        await teleopChannel.arm()
        return teleopChannel.isArmed  // your existing flag
    },
    disarmSync: { @MainActor in teleopChannel.disarm() },
    emergencyStopSync: { @MainActor in connectionStore.emergencyStop() },
    sendMotion: { @MainActor slot, confirmRisk in
        await teleopChannel.sendMotion(slot: slot, confirmRisk: confirmRisk)
    },
    sendWalk: { @MainActor payload in
        await walkLabOnboardBridge.send(
            enabled: payload.enabled,
            xMm: payload.xMm, yMm: payload.yMm, aDeg: payload.aDeg,
            periodMs: payload.periodMs, footMm: payload.footMm,
            hipPitchDeg: payload.hipPitchDeg)
    },
    sendStop: { @MainActor _ in
        await walkLabOnboardBridge.send(enabled: false,
                                        xMm: 0, yMm: 0, aDeg: 0,
                                        periodMs: 700, footMm: 35, hipPitchDeg: 13)
    },
    snapshot: { @MainActor in
        MobileRelayTelemetryFactory.make(
            macConnected: true,
            robotConnected: connectionStore.bus != nil,
            armed: teleopChannel.isArmed,
            dxlPower: connectionStore.dxlPowerOn,
            busBusy: connectionStore.demoBusBusy,
            endpoint: connectionStore.bus?.endpointDescription,
            batteryV: connectionStore.lastTelemetry?.batteryV,
            maxTempC: connectionStore.lastTelemetry?.maxTempC,
            latencyMs: connectionStore.lastTelemetry?.latencyMs ?? 30,
            lastAckAgeMs: nil,
            estopActive: connectionStore.isEmergencyStopped)
    }))

@StateObject var relay = MobileRelayController(port: port, listenPort: 17370)
```

> 주의: 정확한 메서드 시그니처는 ConnectionStore/TeleopChannel/WalkLabOnboardBridge 최신 버전에 맞춰 위 클로저를 조정한다. 현재 어댑터는 시그니처 진화에 견디도록 protocol 가 아닌 closure 주입을 채택했다.

## 5. iOS Xcode wrapper 만들기 (15분 가이드)

1. `app/mobile/DarwinForgeMobile/` 에서 Xcode 열기 → "iOS App" 새 프로젝트 생성, location 은 같은 폴더.
2. 생성된 `.xcodeproj` 에 `Package.swift` 를 추가:
   - File → Add Package Dependencies → "Add Local..." → 같은 폴더 선택.
   - `DarwinForgeMobileApp` 와 `MobilePilotKit` 라이브러리를 app target 의 "Frameworks, Libraries, and Embedded Content" 에 추가.
3. App target 의 `Info.plist` 를 `Sources/DarwinForgeMobileApp/Resources/Info.plist.template` 내용으로 채움.
4. App target 의 `@main` entry 를 다음 4줄로 교체:
   ```swift
   import SwiftUI
   import DarwinForgeMobileApp

   @main
   struct DarwinForgeMobileEntry: App {
       var body: some Scene { WindowGroup { RootView() } }
   }
   ```
5. Bundle Identifier, Signing Team, App Icon 설정.
6. Simulator 에서 빌드/실행 → Mock Relay 모드로 모든 화면 동작 확인.

## 6. 알려진 제약 / 결정 사항 (truth-gap fix 반영)

- **Mock relay** 가 iOS app Mock 모드. Apple reviewer 가 robot/Mac 없이 흐름 확인 가능.
- **첫 탭** = 검증된 preset/action 중심 「동작」 (PilotScreen). 「조종기」 (RemotePilotScreen) 는 Mock/Review 시뮬레이션 보조 화면이며 라벨이 "조종기 (Mock)" 으로 표기.
- **Freeform 조이스틱** 은 real relay 모드에서 비활성 — `AppState.streamWalk` 가 `freeformUnsupportedInMVP` 로 거부하고 명령을 보내지 않는다. 화면에는 빨간 banner 로 안내.
- **`bow` 액션 제거** — slot 41 은 `talk2` long-chain. 정확한 slot 확인 + HIL 후 재추가.
- **QR 스캔** 은 paste-only 로 명확히 표기 ("QR JSON 붙여넣기"). 카메라 스캐너는 후속.
- **Bonjour discovery 후 pairing** — 발견된 Mac tap 시 6자리 코드 입력 시트가 뜬다 (자동 "000000" 제거).
- **ARM 체크리스트** — cradle / 물리 E-stop / 시야 확보 세 토글 모두 사용자가 직접 ON 해야 real relay 에서 `armChecklistPassed` 가 true.
- **단일 권한** 은 Mac 측에서 강제 — 두 번째 iPhone hello 는 즉시 `session.rejected(alreadyOwned)`.
- **Heartbeat 100ms / Watchdog 500ms** — server 가 walk accepted 즉시 `activeCommandId` 설정 → heartbeat 누락이어도 watchdog 가 stop 발동.
- **Walk** 는 4개 preset(`slowForward`, `turnLeft`, `turnRight`, `stop`)만 real relay 통과. WalkLab 어댑터는 `MobileRelayBootstrap` 가 라이브 주입.
- **App background → stop** — `RootView` 의 `scenePhase` 관찰이 `pilot.stop` 을 보낸다. Mac watchdog 도 동시에 안전망.
- **Mac toolbar status chip** — `MobileRelayController.activeIPhoneName` 이 server `currentDeviceName()` 폴링으로 1Hz 동기화 → 실제 session 상태 정확히 표시.
- **WebSocket handshake** — single receive owner: `connect()` 가 `sendHello → awaitWelcome → mark connected → start receiveLoop` 순서. handshake race 제거.
- **TestRunRecord 내보내기** — 「테스트」 탭에서 JSON/summary export 가능. HIL 증거로 사용.
- **Re-pair on app restart** — Mac 측 pairing code 는 영속화 (PersistedPairingStore). iOS 는 매 실행마다 새 hello.

## 7. 의도적으로 제외한 항목 (PRD §4.1 와 일치)

- iPhone direct USB/serial 제어
- iPhone raw Dynamixel packet
- 고속 보행 / free-form joystick streaming
- 다중 iPhone 동시 조종
- kick 등 highRisk motion (UI skeleton 만, MVP server 가 reject)
- TLS / mTLS (protocol v2 검토)

## 8. 다음 핸드오프 (HIL)

`docs/handoff/ios-mobile-pilot-hil.md` 참조. HIL-0 ~ HIL-5 를 통과한 뒤에만 첫 내부 TestFlight 빌드를 올린다.
