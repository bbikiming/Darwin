# Pilot Input Sources — Production Deployment Entitlements

> **v1.21.0 (2026-05-22) — 사이클 63 코덱스 MEDIUM 대응**
>
> SwiftPM executable target (개발 환경) 에서는 sandbox 기본 비활성이라 본 문서의
> 대부분 키가 무관. **배포 (notarization / app store / TestFlight) 시 필수.**

## 비유

스마트폰의 권한 동의 화면 — 카메라 켤 때 "사진 접근 허용?" 묻듯, macOS 도 마이크 /
네트워크 / 카메라 접근 시 사용자 동의를 받아야 한다. 본 문서는 DarwinForge 의 5개
pilot input source 가 production 환경에서 동의를 받기 위해 필요한 plist 키 + entitlement
key 의 매핑.

## 결론 한 줄

**3개 source 가 entitlement 필요**: Tello state UDP, Voice (Speech.framework),
미래 카메라 비전. 나머지 2개 (Keyboard / Gamepad / UI) 는 entitlement 불요.

---

## 1. TelloStateListener — UDP 8890 listen

### 위치

- `Sources/DarwinForgeUI/WalkLab/Pilot/Tello/TelloStateListener.swift` (170 lines)
- `NWListener` 가 UDP socket bind → port 8890 에서 Tello drone 의 state broadcast 수신.

### Info.plist 키

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Tello 드론에서 비행 상태 (배터리, 고도, 자세) 를 실시간으로 수신하기 위해 로컬 네트워크 접근이 필요합니다.</string>
```

**핵심**: macOS 14 (Sonoma) 부터 로컬 네트워크 접근에 사용자 동의 필요. 미설정 시
`NWListener` 가 silently 실패 — log 만 남기고 callback 미발화 → 사용자는 robot 의
state UI 가 비어있는 것을 보고 "버그" 로 인식.

### Entitlements (sandbox 활성 시)

```xml
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

- `network.server`: UDP `NWListener` 가 incoming 패킷 받음 (8890).
- `network.client`: Tello SDK 의 outgoing UDP 8889 (command port).

### 개발 환경 (SwiftPM)

`swift run` / `swift test` 는 sandbox 비활성 → entitlement 무관. 모든 권한 자동 부여.

### Production 검증 절차

1. notarized .app 으로 빌드.
2. 처음 실행 시 macOS 다이얼로그: "DarwinForge 가 네트워크 장치를 검색하려고 합니다".
3. 사용자가 "허용" → 다음 실행부터 자동 허용.
4. "거부" → `NWListener.start()` 가 던지지 않지만 callback 미발화 → UI 가 "Tello 상태 미수신" 표시.

---

## 2. VoicePilotAdapter — SFSpeechRecognizer

### 위치

- `Sources/DarwinForgeUI/WalkLab/Pilot/Voice/VoicePilotAdapter.swift` (322 lines)
- `SFSpeechRecognizer` 로 한/영 keyword 인식 → bridge 호출.

### Info.plist 키 (필수 2개)

```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>음성으로 로봇에게 "걸어", "정지", "비상" 등을 명령할 수 있도록 음성 인식 사용을 허용합니다.</string>

<key>NSMicrophoneUsageDescription</key>
<string>음성 명령을 수신하기 위해 마이크 접근이 필요합니다.</string>
```

**경고**: 두 키 모두 필요. `NSSpeechRecognitionUsageDescription` 만 있으면 마이크
시작 시점에 crash. `NSMicrophoneUsageDescription` 만 있으면
`SFSpeechRecognizer.requestAuthorization` 호출 즉시 crash.

### Entitlements (sandbox 활성 시)

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

### 개발 환경 (SwiftPM)

SwiftPM 은 sandbox 미적용 → entitlement 무관. 단, `SFSpeechRecognizer.authorizationStatus()`
가 `.notDetermined` 인 첫 호출 시 macOS 다이얼로그 띄움 (info.plist 키 없으면 즉시 crash).

**테스트 우회**: `MockVoiceRecognizer` 를 사용하면 실 SFSpeechRecognizer 호출 안 함 →
CI / GitHub Actions 에서 안전.

---

## 3. GamepadPilotAdapter — GCController

### 위치

- `Sources/DarwinForgeUI/WalkLab/Pilot/Gamepad/GamepadPilotAdapter.swift` (424 lines)
- `GCController` + `GCExtendedGamepad` profile 으로 PS4/Xbox/Nimbus 컨트롤러 polling.

### Info.plist / Entitlements

**불요.** macOS 14+ 의 GameController.framework 는 표준 API — 별도 권한 없음.

USB / Bluetooth 페어링 후 즉시 사용 가능. 사용자 동의 다이얼로그 없음.

### 검증 절차

1. PS4 컨트롤러를 Mac 에 USB 연결 또는 Bluetooth 페어링.
2. DarwinForge 실행 → "Gamepad" 패널에 컨트롤러 이름 자동 표시 (예: "Wireless Controller").
3. △ 버튼 → emergency.

---

## 4. KeyboardPilotMapper

### 위치

- `Sources/DarwinForgeUI/WalkLab/Pilot/KeyboardPilotMapper.swift`
- `WalkLabView` 의 `.onKeyPress` modifier 로 SwiftUI 가 키 이벤트 전달.

### Info.plist / Entitlements

**불요.** Keyboard input 은 SwiftUI 의 first-party feature.

---

## 5. UI 버튼 / Risk Sheet

### 위치

- `Sources/DarwinForgeUI/WalkLab/WalkLabView.swift`
- 사용자가 마우스 / trackpad 로 직접 클릭.

### Info.plist / Entitlements

**불요.** Pure UI input.

---

## 통합 Info.plist 예제 (Production)

`app/ui/DarwinForge/Sources/DarwinForgeApp/Info.plist` (현재 부재 — 배포 시 생성):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Tello UDP state (port 8890) — TelloStateListener -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Tello 드론에서 비행 상태 (배터리, 고도, 자세) 를 실시간으로 수신하기 위해 로컬 네트워크 접근이 필요합니다.</string>

    <!-- Voice keyword spotting — VoicePilotAdapter -->
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>음성으로 로봇에게 "걸어", "정지", "비상" 등을 명령할 수 있도록 음성 인식 사용을 허용합니다.</string>

    <key>NSMicrophoneUsageDescription</key>
    <string>음성 명령을 수신하기 위해 마이크 접근이 필요합니다.</string>

    <!-- 표준 app 메타데이터 -->
    <key>CFBundleIdentifier</key>
    <string>com.robotis.darwinforge</string>
    <key>CFBundleName</key>
    <string>DarwinForge</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
```

## 통합 Entitlements 예제 (Production sandbox)

`app/ui/DarwinForge/Sources/DarwinForgeApp/DarwinForge.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Sandbox 활성 -->
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <!-- Tello UDP receive (8890) + send (8889) — TelloStateListener + TelloLink -->
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- Voice — SFSpeechRecognizer + audio input -->
    <key>com.apple.security.device.audio-input</key>
    <true/>

    <!-- robot USB serial (ROBOTIS DARwIn-OP2) — 미래 phase -->
    <!--
    <key>com.apple.security.device.usb</key>
    <true/>
    -->

    <!-- 카메라 (vision-based 보행 보정) — 미래 phase -->
    <!--
    <key>com.apple.security.device.camera</key>
    <true/>
    -->
</dict>
</plist>
```

---

## CI / 테스트 안전 가드

**현황**: SwiftPM `swift test` 는 sandbox 비활성 → 모든 entitlement 무관. 테스트는
mock source (`MockTelloStateListener`, `MockVoiceRecognizer`, `MockGamepad`) 만 사용 →
실제 권한 요청 안 일어남.

**production 전 체크리스트**:

- [ ] `Info.plist` 생성 — 3개 usage description 키 포함.
- [ ] `DarwinForge.entitlements` 생성 — sandbox 활성 시 4개 entitlement 포함.
- [ ] Xcode 빌드 설정에 두 파일 link.
- [ ] notarization 전 `codesign --verify --deep --strict --verbose=4 DarwinForge.app` 통과 확인.
- [ ] 권한 다이얼로그 사용자 메시지 (한국어) 검수 — 거부 사용자도 의미 이해.

## 회귀 가드

본 문서는 deployment guide — 실 production 빌드 시 발견될 권한 결함의 사전 차단.
SwiftPM 개발 환경에서는 자동 검증 불가 (Xcode 빌드 + notarization 단계에서 검출).

향후 Xcode project 또는 SwiftPM resources/plist 통합 시 본 문서를 source-of-truth 로
참조.

---

## 참고

- Apple: [Network Framework — Local Network Privacy](https://developer.apple.com/documentation/network/preventing_insecure_network_connections)
- Apple: [Speech.framework — Authorization](https://developer.apple.com/documentation/speech/sfspeechrecognizer/requesting_authorization_to_recognize_speech)
- Apple: [App Sandbox Entitlements](https://developer.apple.com/documentation/security/app_sandbox)
- macOS 14 (Sonoma) [Local Network Privacy 추가](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
