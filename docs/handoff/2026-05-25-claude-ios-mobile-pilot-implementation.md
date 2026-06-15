# Claude Handoff: iOS Mobile Pilot MVP 구현

Workspace root:

```text
/Users/bbikiming/Documents/vibe_coding/Darwin
```

목표:

- iPhone 앱을 로봇 조종기처럼 사용할 수 있는 첫 MVP를 구현한다.
- 구조는 `iPhone iOS app -> Mac DarwinForge MobileRelayServer -> existing DarwinForge robot control`이다.
- iPhone이 USB serial, raw Dynamixel packet, robot motor bus를 직접 제어하지 않는다.
- 첫 빌드부터 TestFlight에 올려 내부 테스터가 설치하고 검증할 수 있어야 한다.

## 1. Claude에게 반드시 전달할 파일

먼저 아래 파일을 읽게 한다.

```text
docs/prd/ios-robot-control-mvp.md
docs/release/ios-mobile-pilot-testflight.md
docs/guides/REAL_ROBOT_E2E_GUIDE.md
docs/decisions/ADR-001-mac-only-swift.md
docs/decisions/ADR-006-communication-path.md
docs/decisions/ADR-008-estop-topology.md
docs/decisions/ADR-011-serial-abstraction.md
docs/protocols/walklab-onboard-brokering.md
firmware-patches/walklab-brokerage/README.md
firmware-patches/walklab-brokerage/INTEGRATION.md
```

`ADR-011-serial-abstraction.md`가 없으면 `docs/decisions`에서 serial/endpoint 관련 ADR을 `rg -n "serial|endpoint|tcp|abstraction" docs/decisions`로 찾아서 읽는다.

## 2. Claude가 먼저 열어볼 기존 구현 파일

Mac 앱/package 구조:

```text
app/ui/DarwinForge/Package.swift
app/ui/DarwinForge/Sources/DarwinForgeApp/DarwinForgeApp.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift
```

연결/네트워크/remote shell:

```text
app/ui/DarwinForge/Sources/ForgeCore/Endpoint.swift
app/ui/DarwinForge/Sources/ForgeCore/Bus.swift
app/ui/DarwinForge/Sources/ForgeCore/BusActor.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/BonjourBrowser.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/ConnectionTransportStore.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/RemoteShell.swift
app/core/forge-core/src/serial/tcp.rs
```

기존 Remote Pilot 안전/동작 흐름:

```text
app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/RemotePilotView.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/TeleopChannel.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotSafetyGate.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotActionBar.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/PilotArmSlider.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/MotionCatalog.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/Motion/PilotMotionCatalog.swift
```

WalkLab/보행/온보드 브리지:

```text
app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession+Pilot.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession+Stop.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkPresetCatalog.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Pilot/WalkLabRCBridge.swift
app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Components/WalkLabOnboardBridge.swift
```

안전/테스트 참고:

```text
app/ui/DarwinForge/Sources/DarwinForgeUI/Components/EStopButton.swift
app/ui/DarwinForge/Tests/DarwinForgeUITests/PilotTests.swift
app/ui/DarwinForge/Tests/DarwinForgeUITests/Pilot/WalkLabRCBridgeEmergencyTests.swift
app/ui/DarwinForge/Tests/DarwinForgeUITests/RecoveryFromEStopTests.swift
app/ui/DarwinForge/Tests/DarwinForgeUITests/SafetyGapTests.swift
app/ui/DarwinForge/Tests/DarwinForgeUITests/ConnectionStoreWatchdogTests.swift
```

## 3. 권장 신규 파일 구조

기존 `app/ui/DarwinForge` SwiftPM package는 macOS 전용이다. iOS app target을 억지로 같은 package에 섞으면 AppKit/macOS-only 코드 때문에 빌드 리스크가 커진다. 첫 MVP는 아래처럼 분리한다.

```text
app/mobile/DarwinForgeMobile/
  Package.swift or DarwinForgeMobile.xcodeproj
  Sources/DarwinForgeMobileApp/
    DarwinForgeMobileApp.swift
    AppState.swift
    Screens/
      PilotScreen.swift
      ConnectScreen.swift
      TestScreen.swift
      LogsScreen.swift
    Components/
      StatusChip.swift
      EmergencyStopButton.swift
      ArmSlider.swift
      ActionButton.swift
      WalkPad.swift
      InlineBanner.swift
  Sources/MobilePilotKit/
    MobileRelayModels.swift
    MobilePilotStateMachine.swift
    MobileRelayClient.swift
    MockRelayClient.swift
    WebSocketRelayClient.swift
    ScriptedRelayClient.swift
    HeartbeatController.swift
  Tests/MobilePilotKitTests/
    MobilePilotStateMachineTests.swift
    MobileRelayModelsTests.swift
    HeartbeatControllerTests.swift
```

Mac relay는 기존 macOS app package에 추가한다.

```text
app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/
  MobileRelayServer.swift
  MobileRelayCommand.swift
  MobileRelayPairing.swift
  MobileRelayTelemetry.swift
  MobileRelayWebSocket.swift
```

테스트/문서 산출물:

```text
docs/protocols/mobile-relay-v1.md
docs/handoff/ios-mobile-pilot-first-build.md
docs/handoff/ios-mobile-pilot-hil.md
docs/release/ios-mobile-pilot-testflight.md
```

`docs/release/ios-mobile-pilot-testflight.md`는 이미 있으므로 구현하면서 실제 bundle id, scheme, version, build number, known limitations를 업데이트한다.

## 4. MVP 기능 범위

첫 빌드에 반드시 들어갈 기능:

- iOS `Connect` 화면: Bonjour `_darwinforge._tcp`, QR/manual host fallback, local network permission recovery.
- iOS `Pilot` 화면: status rail, ARM slider, global E-stop, safe action buttons, WalkPad.
- iOS `Test` 화면: mock relay, scripted relay, real relay smoke flow.
- iOS `Logs` 화면: command id, ACK latency, connection events, stop reason.
- Mac `MobileRelayServer`: iPhone pairing, single command authority, WebSocket JSON, heartbeat/watchdog, telemetry/ACK.
- Review Mode 또는 Mock Relay: Apple reviewer가 robot/Mac 없이 기본 flow를 확인 가능.
- TestFlight 준비: bundle id/signing/plist/Test Information/release note 템플릿 반영.

첫 빌드에서 제외:

- iPhone direct USB/serial 제어
- iPhone raw Dynamixel packet 생성
- 고속 보행
- 자유 조이스틱 연속 제어
- raw motion chain 편집/전송
- kick 같은 high-risk action
- 여러 iPhone 동시 조종

## 5. 안전 요구사항

절대 타협하지 말 것:

- E-stop은 모든 화면, modal, sheet, active command 상태보다 우선한다.
- active walk 중 iOS app background, app 종료, WebSocket disconnect, heartbeat timeout은 stop으로 이어진다.
- iOS heartbeat는 100ms 기준, Mac relay는 robot command send를 5Hz 이하로 제한한다.
- heartbeat timeout 500ms에서 stop을 보낸다.
- ACK 없는 성공 표시는 금지한다. 단, E-stop은 UI를 먼저 EStopped로 바꾸고 ACK는 뒤따르게 할 수 있다.
- ARM 전에는 실 로봇 action/walk command가 나가지 않는다.
- iPhone 두 대가 동시에 command authority를 갖지 않는다.
- Robot 미연결 상태와 Mock/Review Mode는 UI에서 명확히 구분한다.
- 모든 disabled button은 reason을 표시한다.

## 6. Claude에게 붙여 넣을 구현 프롬프트

아래 전체를 Claude에게 붙여 넣는다.

```text
You are implementing the iOS Mobile Pilot MVP for the DarwinForge repo.

Workspace root:
/Users/bbikiming/Documents/vibe_coding/Darwin

Read these first:
- docs/prd/ios-robot-control-mvp.md
- docs/release/ios-mobile-pilot-testflight.md
- docs/guides/REAL_ROBOT_E2E_GUIDE.md
- docs/decisions/ADR-001-mac-only-swift.md
- docs/decisions/ADR-006-communication-path.md
- docs/decisions/ADR-008-estop-topology.md
- docs/protocols/walklab-onboard-brokering.md
- firmware-patches/walklab-brokerage/README.md
- firmware-patches/walklab-brokerage/INTEGRATION.md

Important context:
- The current DarwinForge app is macOS-first and SwiftUI-based.
- Do not attempt iPhone direct USB/serial/raw Dynamixel control.
- MVP architecture is iPhone iOS app -> Mac DarwinForge MobileRelayServer -> existing robot control paths.
- Existing macOS Package.swift is macOS-only. Prefer a separate iOS app under app/mobile/DarwinForgeMobile and add only the Mac relay server to app/ui/DarwinForge.
- Preserve existing worktree changes. Do not run destructive git commands.

Implement the first usable MVP, not just a prototype.

Required implementation:
1. Create a separate iOS SwiftUI app/module under app/mobile/DarwinForgeMobile.
2. Create MobilePilotKit with:
   - MobileRelayModels
   - MobilePilotStateMachine
   - MobileRelayClient protocol
   - MockRelayClient
   - ScriptedRelayClient
   - WebSocketRelayClient
   - HeartbeatController
3. Build iOS screens:
   - Connect
   - Pilot
   - Test
   - Logs
4. Follow iOS native design from PRD section 7:
   - TabView, NavigationStack, system colors, SF Symbols, Dynamic Type
   - no decorative landing page
   - global E-stop always reachable
   - clear ARM state, disabled reasons, command pending/ACK states
5. Add Mac MobileRelayServer under DarwinForgeUI/MobileRelay:
   - Bonjour service `_darwinforge._tcp`
   - WebSocket JSON protocol
   - pairing token
   - single iPhone command authority
   - heartbeat/watchdog
   - command id ACK
   - telemetry status for Mac/Robot/ARM/latency
6. Wire first safe commands only:
   - ARM/disarm
   - E-stop
   - safe action: walkReady, sit/basic posture if already available, greeting/bow if already available, stop
   - walking presets: slowForward, turnLeft, turnRight, stop
7. Implement Review Mode / Mock Relay so Apple reviewer can open the app without robot hardware.
8. Add tests:
   - MobilePilotKit unit tests for state machine, command schema, heartbeat stop
   - iOS UI tests or at least stable accessibilityIdentifier coverage for P0 controls
   - Mac relay tests for pairing, single authority, stale heartbeat stop, ACK command id
9. Update docs:
   - docs/protocols/mobile-relay-v1.md
   - docs/handoff/ios-mobile-pilot-first-build.md
   - docs/handoff/ios-mobile-pilot-hil.md
   - docs/release/ios-mobile-pilot-testflight.md with actual build/run steps

Safety acceptance criteria:
- E-stop is accessible from every screen/modal/sheet and active command state.
- If app backgrounds, disconnects, or misses heartbeat, relay sends stop or enters stale-stop.
- ACK-less success is not allowed except optimistic E-stop UI.
- ARM is required before real robot commands.
- Mock/Review Mode cannot send hardware commands.
- Two iPhones cannot control at the same time.

Verification:
- Run the relevant Swift tests.
- Build the macOS package after Mac relay changes.
- Build the iOS app target or package.
- If iOS simulator build is possible, run it.
- Report exact commands run and exact failures if any.

When choosing between fast implementation and safety, choose safety.
```

## 7. Claude 작업 순서 제안

1. `git status --short`로 기존 변경 확인.
2. PRD와 TestFlight runbook 읽기.
3. `docs/protocols/mobile-relay-v1.md`를 먼저 작성해 command schema를 고정.
4. `MobilePilotKit` state machine과 mock/scripted relay부터 구현.
5. iOS Connect/Pilot/Test/Logs 화면을 mock relay로 완성.
6. Mac `MobileRelayServer`를 추가하고 real relay 연결.
7. heartbeat/watchdog/E-stop/ARM gate 테스트 추가.
8. TestFlight runbook을 실제 프로젝트 값으로 업데이트.
9. build/test 결과와 남은 하드웨어 HIL 항목을 `docs/handoff/ios-mobile-pilot-first-build.md`에 기록.

## 8. 완료 기준

Claude 작업이 끝났다고 볼 수 있는 조건:

- iOS 앱이 mock/review mode로 실행된다.
- iOS 앱이 Mac relay에 연결할 수 있다.
- Mac relay가 pairing, single authority, heartbeat/watchdog, ACK를 처리한다.
- Pilot 화면에서 ARM, E-stop, safe action, deadman walk UI가 있다.
- app background/disconnect/heartbeat timeout stop이 테스트 또는 명시적 시뮬레이션으로 검증된다.
- TestFlight runbook이 실제 bundle id/scheme/build 절차 기준으로 갱신되어 있다.
- 실패한 테스트나 불가능했던 HIL은 숨기지 않고 문서에 남긴다.
