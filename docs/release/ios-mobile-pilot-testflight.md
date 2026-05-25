# iOS Mobile Pilot TestFlight 배포 Runbook

상태: Active (첫 빌드 land 완료 — Xcode wrapper 작업 진행 중)  
범위: DarwinForge Mobile Pilot 첫 베타 배포  
대상: iOS 구현자, Mac relay 구현자, UI/UX 테스터, 로봇 안전 관찰자

## 0. 이 빌드 (0.1.0 build 5) 의 실제 값

| 항목 | 값 |
|---|---|
| SwiftPM 루트 | `app/mobile/DarwinForgeMobile/` |
| App library | `DarwinForgeMobileApp` (target), `RootView` (entry view) |
| Kit module | `MobilePilotKit` |
| Mac relay 코드 | `app/ui/DarwinForge/Sources/DarwinForgeUI/MobileRelay/` |
| Mac relay scheme | 기존 `DarwinForgeApp` (relay 는 module 으로 흡수) |
| **Bundle ID** | `com.yuseok.oppilot` (App Store Connect 등록 완료) |
| **App Store Connect Apple ID** | `6772933457` (앱 이름: OP Pilot) |
| Xcode scheme | `OPPilot` (`app/mobile/DarwinForgeMobile/Xcode/DarwinForgeMobile.xcodeproj`) |
| Marketing version | `0.1.0` |
| **Build number** | `5` (build 3 은 TestFlight 업로드 완료, build 5 가 truth-gap fix 반영 후보) |
| Team ID | `JM4LJMU49Q` |
| Signing | Apple Development (auto-managed Xcode profile) |
| Relay WebSocket path | `ws://<mac-host>:17370/mobile-relay` |
| Bonjour service | `_darwinforge._tcp` |
| Heartbeat / Watchdog | 100ms / 500ms |

## 0.1 Build 검증 결과 (build 5 기준)

- iOS `swift test` → **31 passed / 0 failed** (이전 26 → +5 head/checklist/telemetryHistory 회귀 테스트)
- Mac `swift test --filter MobileRelay --jobs 1` → **42 passed / 0 failed**
- `xcodebuild -sdk iphonesimulator build CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**

상세는 [docs/handoff/ios-mobile-pilot-first-build.md](../handoff/ios-mobile-pilot-first-build.md) 참조.

## 0.2 Truth-gap fix 반영 (2026-05-25, build 5)

[docs/handoff/2026-05-25-claude-ios-robot-control-fix-report.md](../handoff/2026-05-25-claude-ios-robot-control-fix-report.md) 의 P0~P2 항목 모두 land:

- P0-4: `bow` (slot 41 ≠ "절") 제거
- P0-1: Mac `MobileRelayBootstrap` 가 라이브 `WalkLabSession` 주입
- P0-3: `WebSocketRelayClient.connect()` handshake race 제거 (single receive owner)
- P0-2: real relay 모드에서 freeform joystick 차단 (`AppState.streamWalk`)
- P1-1: Bonjour discovery tap → 실제 6자리 코드 입력 sheet (자동 `000000` 제거)
- P1-2: Mac toolbar status chip 이 `currentDeviceName()` 폴링으로 1Hz 동기화
- P1-3: server `handleWalk` 가 accepted 즉시 `activeCommandId` 설정 → heartbeat 누락에도 watchdog 발동
- P1-4: ARM 3-toggle (cradle / 물리 E-stop / 시야) 실제 사용자 확인 강제
- P2-2: `TestRunRecord` JSON / summary export (테스트 탭)
- 추가: real relay 에서 `pilot.head` 도 `headUnsupportedInMVP` 로 reject (UI/server 일관)
- 추가: walk integration 테스트 5종 신설 (mapper + dxlPower + whitelist + walkSession + stop)
- 추가: telemetry rolling history 48 frames (조종기 상단 latency mini-graph 용 데이터 소스)

## 1. 목적

이 문서는 iOS Mobile Pilot 앱을 TestFlight에 올리고, 제한된 베타 테스터가 실제 iPhone에서 설치해 검증할 수 있도록 하는 최소 절차를 정의한다.

첫 TestFlight 빌드는 공개 제품 출시가 아니다. 목적은 iPhone이 Mac DarwinForge Relay를 통해 안전한 로봇 조종기 역할을 할 수 있는지 검증하는 hardware-in-the-loop 베타다.

## 2. 업로드 전 차단 조건

아래 항목이 준비되지 않으면 TestFlight 후보로 올리지 않는다.

- 앱에 `Mock Relay` 또는 `Review Mode`가 있다.
- `NSLocalNetworkUsageDescription`이 로컬 네트워크 탐색 이유를 설명한다.
- `NSBonjourServices`에 `_darwinforge._tcp`가 포함되어 있다.
- E-stop이 모든 주요 화면, modal, sheet, active command 상태에서 접근 가능하다.
- background, disconnect, heartbeat timeout이 모두 stop으로 이어진다.
- P0 unit test가 통과한다.
- P0 XCUITest가 통과한다.
- 내부 TestFlight 전 HIL-0~HIL-5가 통과한다.
- 외부 TestFlight 전 HIL-6~HIL-7이 통과한다.

No-Go:

- ARM 없이 실제 로봇 명령이 가능한 빌드
- E-stop의 optimistic UI를 제외하고 ACK 전에 성공으로 표시하는 빌드
- iPhone 두 대가 동시에 command authority를 갖는 빌드
- Apple reviewer가 robot hardware 없이 기본 flow를 열어볼 수 없는 빌드
- App Store Connect 상태가 `Missing Compliance`로 남아 있는 빌드

## 3. Apple 준비 사항

계정과 권한:

- Apple Developer Program 멤버십이 활성 상태다.
- App Store Connect 접근 권한이 있다.
- 업로더에게 app record 생성/수정, build upload, TestFlight 관리, feedback 확인 권한이 있다.
- iOS bundle id가 등록되어 있다.
- Xcode signing team이 Apple Developer Program 팀으로 설정되어 있다.
- Archive upload용 distribution signing이 동작한다.

App Store Connect app record:

- Platform: iOS
- App name: `DarwinForge Mobile Pilot` 또는 최종 확정 이름
- Bundle ID: 최종 mobile bundle id
- SKU: 내부에서 안정적으로 쓰는 식별자
- Primary language: 첫 테스터 그룹 기준 Korean 또는 English
- Category: 앱 목적을 과장하지 않는 가장 가까운 카테고리

## 4. 빌드 구성

첫 베타 권장 버전:

- Marketing version: `0.1.0`
- Build number: archive upload마다 증가
- Configuration: Release 또는 별도 `Beta` configuration
- Runtime mode: real relay 사용 가능, mock/review mode도 함께 제공

필수 capability와 plist:

- Local Network permission description
- Bonjour services: `_darwinforge._tcp`
- iOS 앱은 일반 네트워킹 외 별도 로봇 명령 entitlement를 요구하지 않는다.
- iOS 앱은 Mac USB/serial에 직접 의존하지 않는다.

권장 beta flag:

- `MOCK_RELAY_AVAILABLE=true`
- `REVIEW_MODE_AVAILABLE=true`
- `RAW_MOTOR_COMMANDS=false`
- `MULTI_CONTROLLER_AUTHORITY=false`

## 5. Archive와 Upload 절차

> 사전 조건: `docs/handoff/ios-mobile-pilot-first-build.md` §5 의 Xcode wrapper 가 생성돼 있다. 그 wrapper 의 app target 가 `DarwinForgeMobileApp` library 와 `MobilePilotKit` library 를 import 하고 `Info.plist.template` 의 키들을 모두 가지고 있다.

1. `app/mobile/DarwinForgeMobile/DarwinForgeMobile.xcodeproj` 를 연다.
2. `DarwinForgeMobileApp` scheme을 선택한다.
3. destination을 `Any iOS Device` 또는 generic iOS device로 설정한다.
4. signing team과 bundle id를 확인한다.
5. version과 build number를 확인한다.
6. release test suite를 실행한다.
7. 실제 iPhone에 한 번 설치해 실행한다.
8. `Product > Archive`를 실행한다.
9. Xcode Organizer에서 archive를 선택한다.
10. App Store Connect 배포 경로를 선택한다.
11. crash symbolication을 위해 symbols upload를 포함한다.
12. build를 upload한다.
13. App Store Connect processing이 끝날 때까지 기다린다.
14. TestFlight tab에 build가 표시되는지 확인한다.

Build가 upload 후 보이지 않으면:

- Xcode Organizer에서 upload 성공 여부를 확인한다.
- bundle id와 version이 App Store Connect app record와 일치하는지 확인한다.
- Apple processing 완료 이메일을 기다린다.
- App Store Connect build processing 상태를 확인한다.
- 이전 upload가 실패했거나 사용할 수 없다는 점을 확인한 뒤에만 build number를 올려 다시 upload한다.

## 6. App Store Connect Test Information

테스터 초대 전에 Test Information을 작성한다.

필수 항목:

- Beta App Description
- Feedback Email
- What to Test
- App Review contact
- Review notes
- 필요한 경우 Export compliance information

Beta App Description 템플릿:

```text
DarwinForge Mobile Pilot은 Mac relay를 통해 ROBOTIS DARWIN 계열 로봇 제어를 검증하는 iPhone 베타 조종기입니다. 이 빌드는 제한된 하드웨어 테스트용입니다. Mac relay pairing, ARM, E-stop, safe action, 느린 deadman walking, status, logs를 포함합니다.
```

What to Test 템플릿:

```text
1. Bonjour, QR, manual host로 Mac DarwinForge Relay에 연결합니다.
2. Local network permission 거부/복구를 확인합니다.
3. ARM checklist와 disabled reason을 확인합니다.
4. safe action만 실행합니다: walk ready, sit, greeting, stop.
5. 느린 deadman walking을 테스트합니다: 누르는 동안 이동, 손을 떼면 stop.
6. walking 중 E-stop, app background, Wi-Fi disconnect, Mac relay disconnect를 테스트합니다.
7. 이해하기 어려운 UI는 screenshot feedback으로, 앱 종료는 crash feedback으로 제출합니다.
```

Tester safety note 템플릿:

```text
이 빌드는 robot을 cradle 또는 tether 상태에 둔 경우에만 사용합니다. 물리 E-stop을 손 닿는 곳에 두세요. 고속 보행, raw motor command, kick action, untethered movement는 테스트하지 않습니다. iPhone 앱은 Mac DarwinForge Relay를 통해서만 robot을 제어합니다.
```

Reviewer note 템플릿:

```text
이 베타는 Mac DarwinForge Relay와 pairing된 경우에만 robot hardware를 제어합니다. hardware 없이 검토하려면 Connect 화면에서 Review Mode를 여세요. Review Mode는 relay, robot telemetry, ARM flow, safe action ACK, E-stop, disconnect behavior를 시뮬레이션하며 hardware command를 보내지 않습니다.
```

## 7. Export Compliance

앱은 iPhone과 Mac relay 사이의 로컬 네트워크 통신을 사용한다. TestFlight 배포 전에 해당 build에 대한 App Store Connect export compliance 질문에 답해야 한다.

Release owner는 아래를 기록한다.

- 앱이 encryption을 사용하는지
- 표준 Apple networking/TLS API 사용에 해당하는지
- 추가 문서가 필요한지
- Apple 답변 승인 후 Info.plist에 compliance key/value를 넣어야 하는지

App Store Connect에 `Missing Compliance`가 표시되는 build는 배포하지 않는다.

## 8. 내부 TestFlight

내부 베타 목표:

- 소규모 신뢰 그룹에서 install, connection, ARM, E-stop, deadman stop, logs를 검증한다.

내부 테스터 그룹:

- `DarwinForge Mobile - Internal`

권장 역할:

- iOS 구현자
- Mac relay 구현자
- UI/UX 테스터
- 로봇 안전 관찰자

내부 build 추가 전:

- HIL-0~HIL-5 결과가 `docs/handoff/ios-mobile-pilot-hil.md`에 기록되어 있다.
- release note에 Mac relay 호환 버전이 적혀 있다.
- release note에 known limitations가 적혀 있다.
- feedback email을 확인할 담당자가 정해져 있다.

내부 테스트 스크립트:

1. TestFlight 앱을 설치한다.
2. 초대를 수락한다.
3. 베타 앱을 설치한다.
4. Review Mode를 한 번 열어 mock flow를 확인한다.
5. Mac relay와 pairing한다.
6. robot status를 확인한다.
7. ARM한다.
8. E-stop을 실행한다.
9. 다시 ARM한다.
10. safe action 1개를 실행한다.
11. slow forward를 2초간 누른다.
12. 손을 떼고 stop을 확인한다.
13. turn left와 turn right를 반복한다.
14. active walk 중 앱을 background로 보내고 stop을 확인한다.
15. active walk 중 Wi-Fi를 끊고 stop을 확인한다.
16. 혼란스러운 화면은 screenshot feedback으로 제출한다.
17. iOS Logs 화면 증거와 Mac relay event log를 저장한다.

## 9. 외부 TestFlight

외부 베타는 내부 베타가 통과하기 전에는 허용하지 않는다.

외부 gate:

- HIL-6~HIL-7 통과
- 첫 외부 build의 TestFlight beta testing 승인
- 외부 그룹을 하드웨어 안전 요구사항을 이해한 테스터로 제한
- public link 사용 시 device/OS criteria와 tester count limit 설정
- invite text에 controlled hardware beta임을 명확히 표시

외부 테스터 그룹:

- `DarwinForge Mobile - Hardware Beta`

외부 테스터 조건:

- 승인된 테스트 robot이 있거나 Review Mode만 테스트한다.
- DarwinForge Relay를 실행할 수 있는 Mac이 있다.
- 물리 E-stop을 손 닿는 곳에 둘 수 있다.
- 관찰 기록과 feedback 제출이 가능하다.

## 10. Feedback Triage

Feedback 경로:

- App Store Connect TestFlight screenshot feedback
- App Store Connect crash feedback
- Feedback email
- HIL result markdown
- Mac relay event logs

심각도:

| Severity | 의미 | 대응 |
|---|---|---|
| P0 | 안전 정지 실패, 권한 없는 명령, active control 중 crash | build expire 또는 tester group pause 즉시 실행 |
| P1 | Connect/ARM/ACK 실패로 테스트 불가 | 테스터 확대 전 수정 |
| P2 | 혼란스러운 UI, disabled reason 누락, log clarity 문제 | 안전 이슈가 아니면 다음 beta에서 수정 |
| P3 | 문구, 레이아웃, polish | 후속 backlog |

Feedback 기록 템플릿:

```text
Build:
Tester:
Device:
iOS version:
Mac relay version:
Robot mode: Mock / Cradle / Tether / Untethered
Scenario:
Expected:
Actual:
Command id:
ACK latency:
Screenshot/crash link:
Severity:
Decision:
Retest result:
```

## 11. Stop Testing과 Rollback

아래 상황이면 build를 expire하거나 테스트를 중지한다.

- P0 safety issue 발견
- ARM 없이 hardware command 가능
- disconnect/background stop 실패
- App Store Connect feedback에서 active control 중 반복 crash 확인
- Mac relay protocol version이 beta와 호환되지 않음

중지 절차:

1. tester group 초대를 일시 중지한다.
2. 필요한 경우 TestFlight에서 해당 build를 expire한다.
3. 테스터에게 build 사용 중지를 공지한다.
4. release note에 중지 사유를 기록한다.
5. 문제를 수정한다.
6. build number를 증가시킨다.
7. gate를 다시 실행한다.
8. 새 build를 upload한다.

테스터 공지 템플릿:

```text
DarwinForge Mobile Pilot build <build> 사용을 중지해 주세요. 안전한 robot control에 영향을 줄 수 있는 문제가 발견되었습니다. 물리 E-stop을 계속 준비하고, 이 build로 robot test를 진행하지 마세요. 검증 후 대체 build를 전달하겠습니다.
```

## 12. Release Checklist

Upload 전:

- [ ] P0 unit tests passed
- [ ] P0 XCUITests passed
- [ ] Network fault tests passed
- [ ] HIL-0~HIL-5 passed
- [ ] Review Mode verified without robot hardware
- [ ] Version/build number incremented
- [ ] Bundle id and signing team confirmed
- [ ] App icon present
- [ ] Local network permission copy reviewed
- [ ] TestFlight release notes written

Upload 후:

- [ ] Build processing complete
- [ ] Build visible in TestFlight
- [ ] Export compliance completed
- [ ] Test Information completed
- [ ] Internal tester group created
- [ ] Build assigned to group
- [ ] Invite received on tester iPhone
- [ ] TestFlight install succeeds
- [ ] Crash/screenshot feedback visible in App Store Connect

외부 테스터 전:

- [ ] Internal feedback triaged
- [ ] HIL-6~HIL-7 passed
- [ ] Beta App Review approved
- [ ] External tester safety criteria confirmed
- [ ] Public link criteria configured, if used
- [ ] Stop testing owner assigned

## 13. 참고 근거

- Apple TestFlight: https://developer.apple.com/testflight/
- TestFlight overview: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- Upload builds: https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds
- Provide test information: https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/
- View tester feedback: https://developer.apple.com/help/app-store-connect/test-a-beta-version/view-tester-feedback
- Export compliance for beta builds: https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds
