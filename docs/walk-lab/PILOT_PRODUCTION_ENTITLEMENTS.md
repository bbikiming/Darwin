# Pilot Input Sources — Production Deployment Entitlements

> **v1.22.0 (2026-05-22) — 사이클 63 코덱스 MEDIUM-4 보강**
>
> SwiftPM executable target (개발 환경) 에서는 sandbox 기본 비활성이라 본 문서의
> 대부분 키가 무관. **배포 (notarization / app store / TestFlight) 시 필수.**
>
> **MEDIUM-4 변경 사항**:
> - Hardened Runtime + Code Signing 섹션 신규 (notarization 필수 키)
> - USB serial (DARwIn-OP2) — "future phase" 에서 **active** 섹션 으로 승격
> - Bluetooth pairing (Gamepad / 미래 IMU) 섹션 신규 — macOS 14+ BT 요구사항
> - NSLocalNetworkUsageDescription 메시지 명확화 — "Tello 드론과 통신" 명시
> - CI/CD audit chain 섹션 신규 — codesign verify + manual QA checklist

## 비유

스마트폰의 권한 동의 화면 — 카메라 켤 때 "사진 접근 허용?" 묻듯, macOS 도 마이크 /
네트워크 / 카메라 접근 시 사용자 동의를 받아야 한다. 본 문서는 DarwinForge 의 5개
pilot input source 가 production 환경에서 동의를 받기 위해 필요한 plist 키 + entitlement
key 의 매핑.

## 결론 한 줄

**3개 source 가 entitlement 필요**: Tello state UDP, Voice (Speech.framework),
미래 카메라 비전. 나머지 2개 (Keyboard / Gamepad / UI) 는 entitlement 불요.

**+ MEDIUM-4 보강**: USB serial (DARwIn-OP2 실 hardware) 은 deferred 아닌 **active 필수**,
Bluetooth pairing 은 macOS 14+ 다이얼로그 요구, Hardened Runtime 은 notarization 강제 요건.

---

## 1. TelloStateListener — UDP 8890 listen

### 위치

- `Sources/DarwinForgeUI/WalkLab/Pilot/Tello/TelloStateListener.swift` (170 lines)
- `NWListener` 가 UDP socket bind → port 8890 에서 Tello drone 의 state broadcast 수신.

### Info.plist 키

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>DarwinForge 가 Tello 드론과 통신 (비행 명령 전송 + 상태 수신) 하기 위해 로컬 네트워크 사용을 요청합니다.</string>
```

**MEDIUM-4 변경 (사이클 63)**: 기존 "device 검색" 표현은 사용자 다이얼로그에서 의미
불명확 (어떤 device? 왜 검색?). 새 메시지는 (1) **DarwinForge 주체 명시**, (2) **Tello
드론 대상 명시**, (3) **통신 양방향** 명시 → 거부 시 사용자도 영향 이해 가능.

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
2. 처음 실행 시 macOS 다이얼로그: "DarwinForge 가 Tello 드론과 통신하기 위해 로컬 네트워크 사용을 요청합니다".
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

**GameController API 자체는 권한 불요.** macOS 14+ 의 GameController.framework 는
표준 API — Gamepad 입력 polling 만으로는 다이얼로그 없음.

**단, Bluetooth 페어링 사용 시 NSBluetoothAlwaysUsageDescription 필수** — 5번
section 참조.

### 검증 절차

1. PS4 컨트롤러를 Mac 에 USB 연결 또는 Bluetooth 페어링 (BT 시 5번 section 권한 적용).
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

## 공통 인프라 (5개 source 횡단)

> **사이클 63 MEDIUM-4 보강**: 위 5개 source 매트릭스 외 **app 전체** 에 적용되는
> production 인프라 4종 — Hardened Runtime, USB serial (실 hardware), Bluetooth
> pairing, CI/CD audit chain. 누락 시 notarization 또는 hardware 통신 즉시 실패.

---

## A. Hardened Runtime + Code Signing (notarization 강제 요건)

### 비유

자동차의 안전벨트 의무화 — notarization 은 "이 앱이 안전벨트 (= Hardened Runtime) 를
매고 있는지" 검사. 미착용 차량은 출고 금지.

### 결론 한 줄

**Hardened Runtime 미적용 시 notarization 자동 거부** — DarwinForge 의 Speech /
Audio 사용 특성상 3개 `com.apple.security.cs.*` 키 필수.

### Entitlements (Hardened Runtime 필수 키)

```xml
<!-- Hardened Runtime — notarization 강제 요건 -->
<key>com.apple.security.cs.allow-jit</key>
<true/>

<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<false/>

<key>com.apple.security.cs.disable-library-validation</key>
<false/>

<!-- 음성 인식 / 마이크 입력 — Speech.framework + AVAudioEngine 가 audio buffer 처리 -->
<key>com.apple.security.cs.allow-dyld-environment-variables</key>
<false/>
```

### 각 키 의미

| 키 | 권장 값 | 이유 |
|---|---|---|
| `allow-jit` | `true` | SwiftUI / Combine 내부에서 JIT 필요 시 (대부분 미사용 but 안전 default) |
| `allow-unsigned-executable-memory` | `false` | 미서명 메모리 실행 허용 = 보안 약화. Speech.framework 는 불필요 |
| `disable-library-validation` | `false` | 외부 dylib 로딩 차단 — 제3자 라이브러리 부재 |
| `allow-dyld-environment-variables` | `false` | dyld 환경 변수 injection 차단 (보안) |

**핵심**: `allow-jit` 만 `true`, 나머지는 모두 `false` 가 minimum-privilege 원칙.

### Code Signing 절차

```bash
# 1. Developer ID Application 인증서로 서명
codesign --force --options runtime \
  --entitlements DarwinForge.entitlements \
  --sign "Developer ID Application: Your Org (TEAMID)" \
  DarwinForge.app

# 2. Hardened Runtime 활성 검증
codesign --display --verbose=4 DarwinForge.app | grep -i 'runtime'
# 출력: "flags=0x10000(runtime)" 가 있어야 함

# 3. notarization 제출
xcrun notarytool submit DarwinForge.zip \
  --apple-id YOUR_APPLE_ID --team-id TEAMID --keychain-profile NOTARY \
  --wait

# 4. staple ticket 부착
xcrun stapler staple DarwinForge.app
```

### 실패 시 증상

- Hardened Runtime 비활성 (`--options runtime` 누락) → notarization 거부, 사유
  "The binary is not signed with a valid Developer ID certificate."
- `allow-unsigned-executable-memory=true` → notarization 통과되지만 Apple 의 자동 보안
  경고에서 감점 → Gatekeeper 가 사용자에게 추가 경고 표시.

---

## B. USB Serial — DARwIn-OP2 실 hardware 통신

### 비유

집 전화선을 외부에서 사용하는 권한 — USB 포트 접근은 sandbox 안에서 "외부 장치
연결 허용" 명시 동의가 필요한 자원.

### 결론 한 줄

**DARwIn-OP2 는 실 hardware target — deferred 아닌 즉시 필수.** 미커밋 시 sandbox
빌드에서 USB ROBOTIS bus 연결 즉시 실패 (`IOServiceOpen` 가 `kIOReturnNotPermitted` 반환).

### Info.plist 키

```xml
<key>NSUSBUsageDescription</key>
<string>DarwinForge 가 ROBOTIS DARwIn-OP2 로봇과 시리얼 통신 (모터 제어 + 센서 수신) 하기 위해 USB 장치 접근을 요청합니다.</string>
```

### Entitlements (sandbox 활성 시)

```xml
<!-- USB serial (ROBOTIS DARwIn-OP2 — FTDI 또는 CP210x USB-to-serial bridge) -->
<key>com.apple.security.device.usb</key>
<true/>
```

### IOKit usage (Sandboxed UDP I/O 대안)

DARwIn-OP2 의 ROBOTIS bus 는 `/dev/cu.usbserial-*` 가상 시리얼 포트로 노출 — 따라서
다음 두 가지 접근 방식 중 택일:

| 방식 | 권한 | 비고 |
|---|---|---|
| `/dev/cu.usbserial-*` POSIX `open()` | `com.apple.security.device.usb` | 표준 — 추천 |
| IOKit `IOServiceMatching("IOUSBDevice")` 저수준 | + IOKit usage description | 고급 — 펌웨어 직접 접근 시 |

**권장**: POSIX serial — DARwIn-OP2 ROBOTIS 프로토콜은 시리얼 패킷이라 IOKit 불요.

### 실패 시 증상

- `com.apple.security.device.usb` 미설정 → `open("/dev/cu.usbserial-XXX", O_RDWR)`
  가 `EACCES (13)` 반환 → 로봇 연결 buttons 가 모두 회색 비활성.
- `NSUSBUsageDescription` 미설정 → 사용자 다이얼로그 미표시 → silently 거부 →
  사용자가 "USB 케이블 문제로 오인".

### 검증 절차

1. DARwIn-OP2 USB 케이블 연결 → `ls /dev/cu.usbserial-*` 로 device 노드 확인.
2. DarwinForge 실행 → 처음 USB 접근 시점에 macOS 다이얼로그 표시.
3. 사용자 "허용" → ROBOTIS bus 연결 성공.

---

## C. Bluetooth Pairing — Gamepad / 미래 IMU

### 비유

집에 새 가전을 들일 때 Wi-Fi 비밀번호 알려주는 절차 — BT 페어링도 macOS 14+ 부터
"이 앱이 페어링된 장치와 통신해도 되는지" 명시 동의 필요.

### 결론 한 줄

**케이블 USB 만 지원 가정은 잘못** — 실제 PS4/Xbox 컨트롤러 사용자의 80%+ 가 BT
페어링 사용. `NSBluetoothAlwaysUsageDescription` 미설정 시 macOS 14+ 에서 BT 페어링된
컨트롤러 입력 callback 미발화.

### Info.plist 키

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>DarwinForge 가 Bluetooth 게임패드 (PS4/Xbox/Nimbus) 와 통신하여 로봇을 조종하기 위해 Bluetooth 접근을 요청합니다.</string>
```

**macOS 13 (Ventura) 이하 호환**: 과거 `NSBluetoothPeripheralUsageDescription` 도 있으나
deprecated → `NSBluetoothAlwaysUsageDescription` 만 사용.

### Entitlements (sandbox 활성 시)

```xml
<!-- Bluetooth (Gamepad BT 페어링 + 미래 IMU BLE) -->
<key>com.apple.security.device.bluetooth</key>
<true/>
```

### 미래 IMU BLE 연동 (사이클 80+ 예정)

DARwIn-OP2 외부 IMU 모듈 (예: BNO055 BLE breakout) 연결 시 동일 권한 재사용. 따라서
이번 사이클에 미리 entitlement 추가 → 향후 별도 사용자 동의 다이얼로그 재요청 회피.

### 실패 시 증상

- macOS 14+ 에서 `NSBluetoothAlwaysUsageDescription` 미설정 → `GCController.controllers()`
  가 USB-연결 컨트롤러만 반환, BT-페어링 컨트롤러 누락 → 사용자가 "내 컨트롤러가 인식
  안됨" 으로 오인.
- macOS 13 이하 → 권한 누락이어도 자동 동작 (BT 권한 무관) → 호환성 안전.

---

## D. CI/CD Audit Chain — Codesign Verify + Manual QA

### 비유

공장 출하 검사 — `swift test` 는 부품 검사, `codesign --verify` 는 완성차 검사. 둘 다
필요.

### 결론 한 줄

**GitHub Actions CI 는 sandbox 시뮬레이션 부재** — `swift test` 만으로는 production
권한 회귀 검출 불가. **prebuilt `.app` 의 codesign 검증 step + manual QA checklist**
가 production 회귀 안전망.

### CI 한계 명시

| 검출 가능 | 검출 불가능 |
|---|---|
| Swift 컴파일 오류 | Info.plist 키 누락 |
| 단위 테스트 실패 | Entitlement 키 오타 |
| 모듈 경계 위반 | Hardened Runtime 미적용 |
| Mock 기반 로직 회귀 | 실 macOS 권한 다이얼로그 동작 |
| | Bluetooth/USB 실 hardware 연결 |

**근본 원인**: `swift test` 는 SwiftPM 환경 → sandbox 자동 비활성 → 권한 검사
완전 우회. Xcode 빌드 + notarization 단계에서만 production 환경 시뮬레이션 가능.

### 권장 CI step — codesign 검증

```yaml
# .github/workflows/release-verify.yml (배포 시점에만 실행)
jobs:
  codesign-audit:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Build .app (xcodebuild)
        run: |
          xcodebuild -scheme DarwinForge \
            -configuration Release \
            -derivedDataPath ./build \
            CODE_SIGN_IDENTITY="Developer ID Application: ..." \
            archive

      - name: Verify codesign + Hardened Runtime
        run: |
          codesign --verify --deep --strict --verbose=4 \
            ./build/Build/Products/Release/DarwinForge.app
          codesign --display --verbose=4 \
            ./build/Build/Products/Release/DarwinForge.app | \
            grep -q 'flags=0x10000(runtime)' || \
            (echo "ERROR: Hardened Runtime not active" && exit 1)

      - name: Verify entitlements presence
        run: |
          codesign -d --entitlements - \
            ./build/Build/Products/Release/DarwinForge.app | \
            grep -q 'com.apple.security.app-sandbox' || \
            (echo "ERROR: Sandbox entitlement missing" && exit 1)

      - name: Verify Info.plist keys
        run: |
          for key in NSLocalNetworkUsageDescription \
                     NSSpeechRecognitionUsageDescription \
                     NSMicrophoneUsageDescription \
                     NSUSBUsageDescription \
                     NSBluetoothAlwaysUsageDescription; do
            /usr/libexec/PlistBuddy -c "Print :$key" \
              ./build/Build/Products/Release/DarwinForge.app/Contents/Info.plist \
              || (echo "ERROR: Missing Info.plist key: $key" && exit 1)
          done
```

### Manual QA Checklist (release 직전 사람 검수)

CI 가 검출 못 하는 항목 — release manager 가 macOS 14+ clean install 환경에서 손으로 확인:

- [ ] DarwinForge.app 첫 실행 → "로컬 네트워크 사용" 다이얼로그 표시. 메시지가 "Tello
      드론과 통신" 명시되어 있음을 확인.
- [ ] "마이크 접근" 다이얼로그 → 메시지가 "음성 명령 수신" 명시.
- [ ] "음성 인식" 다이얼로그 → 메시지가 "걸어/정지/비상" 키워드 예시 포함.
- [ ] DARwIn-OP2 USB 케이블 연결 → "USB 장치 접근" 다이얼로그 표시. 메시지가 "ROBOTIS
      DARwIn-OP2 로봇과 통신" 명시.
- [ ] PS4 컨트롤러 BT 페어링 후 DarwinForge 실행 → "Bluetooth 사용" 다이얼로그 표시.
      메시지가 "게임패드와 통신" 명시.
- [ ] 모든 다이얼로그에서 "거부" 선택 시 앱 crash 하지 않음. UI 에 "권한 거부됨" 안내 표시.
- [ ] `xcrun spctl --assess --type execute DarwinForge.app` 출력이 "accepted" 인지 확인
      (Gatekeeper 통과).
- [ ] Apple Silicon (M1+) 과 Intel Mac 양쪽에서 동일 절차 반복.

### 회귀 발견 시 처리

- CI codesign step 실패 → 배포 차단 (자동).
- Manual QA checklist 항목 실패 → 본 문서 갱신 + 사이클 추가하여 fix.
- 권한 메시지 misleading 발견 → 본 문서 1-5 + A-D 섹션의 메시지 갱신 후 재배포.

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
    <string>DarwinForge 가 Tello 드론과 통신 (비행 명령 전송 + 상태 수신) 하기 위해 로컬 네트워크 사용을 요청합니다.</string>

    <!-- Voice keyword spotting — VoicePilotAdapter -->
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>음성으로 로봇에게 "걸어", "정지", "비상" 등을 명령할 수 있도록 음성 인식 사용을 허용합니다.</string>

    <key>NSMicrophoneUsageDescription</key>
    <string>음성 명령을 수신하기 위해 마이크 접근이 필요합니다.</string>

    <!-- USB serial (ROBOTIS DARwIn-OP2) — 실 hardware 통신 (사이클 63 active) -->
    <key>NSUSBUsageDescription</key>
    <string>DarwinForge 가 ROBOTIS DARwIn-OP2 로봇과 시리얼 통신 (모터 제어 + 센서 수신) 하기 위해 USB 장치 접근을 요청합니다.</string>

    <!-- Bluetooth — Gamepad BT 페어링 + 미래 IMU BLE (사이클 63 active) -->
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>DarwinForge 가 Bluetooth 게임패드 (PS4/Xbox/Nimbus) 와 통신하여 로봇을 조종하기 위해 Bluetooth 접근을 요청합니다.</string>

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

    <!-- robot USB serial (ROBOTIS DARwIn-OP2) — 실 hardware target, 사이클 63 active -->
    <key>com.apple.security.device.usb</key>
    <true/>

    <!-- Bluetooth — Gamepad BT 페어링 + 미래 IMU BLE -->
    <key>com.apple.security.device.bluetooth</key>
    <true/>

    <!-- Hardened Runtime — notarization 강제 요건 (minimum-privilege) -->
    <key>com.apple.security.cs.allow-jit</key>
    <true/>

    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>

    <key>com.apple.security.cs.disable-library-validation</key>
    <false/>

    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <false/>

    <!-- 카메라 (vision-based 보행 보정) — 미래 phase (사이클 80+) -->
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

**production 전 체크리스트** (사이클 63 MEDIUM-4 보강):

- [ ] `Info.plist` 생성 — **5개** usage description 키 포함 (Local Network / Speech /
      Microphone / USB / Bluetooth).
- [ ] `DarwinForge.entitlements` 생성 — sandbox 활성 시 **9개** entitlement 포함
      (sandbox / network.server / network.client / audio-input / usb / bluetooth +
      Hardened Runtime 4종).
- [ ] Xcode 빌드 설정에 두 파일 link.
- [ ] `--options runtime` 플래그로 codesign (Hardened Runtime 활성).
- [ ] notarization 전 `codesign --verify --deep --strict --verbose=4 DarwinForge.app` 통과 확인.
- [ ] `codesign --display --verbose=4 DarwinForge.app | grep 'flags=0x10000(runtime)'`
      통과 (Hardened Runtime 검증).
- [ ] D 섹션의 CI codesign-audit job 통과.
- [ ] D 섹션의 Manual QA Checklist 8 항목 모두 통과.
- [ ] 권한 다이얼로그 사용자 메시지 (한국어) 검수 — 거부 사용자도 의미 이해.
- [ ] 메시지가 "DarwinForge" 주체 + 통신 대상 (Tello / DARwIn-OP2 / Gamepad) 명시 확인.

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
- Apple: [Hardened Runtime Entitlements](https://developer.apple.com/documentation/security/hardened_runtime) — `com.apple.security.cs.*` 키 정의.
- Apple: [Notarizing macOS Software Before Distribution](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution).
- Apple: [Core Bluetooth — Privacy](https://developer.apple.com/documentation/corebluetooth) — `NSBluetoothAlwaysUsageDescription`.
- Apple: [IOKit — USB Device Access](https://developer.apple.com/documentation/iokit) — `com.apple.security.device.usb`.
- Apple: [GameController Framework](https://developer.apple.com/documentation/gamecontroller) — BT 페어링과 권한 상호작용.
