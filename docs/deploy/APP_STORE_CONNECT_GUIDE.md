# DarwinForge App Store Connect 배포 가이드

V297-10 (2026-05-27) — Mac App Store + Developer ID notarized 양쪽 지원

---

## 0. 개요

DarwinForge 는 SwiftPM 기반 macOS 앱이라 `.xcodeproj` 가 없다. Apple 가
`.xcarchive` 만 수락하지만, `.xcarchive` 자체는 단순 디렉토리 + Info.plist 라
**Xcode wrapper 없이도 직접 어셈블 가능**. 본 가이드는 이 직접-어셈블 흐름.

| 배포 경로 | 권장 사용처 | 제약 |
|---|---|---|
| **Mac App Store** | 일반 사용자, 자동 업데이트, 결제 통합 | USB device entitlement 가 App Review §2.4.5 트리거. 외부 하드웨어 (ROBOTIS-OP2) justification 필수 |
| **Developer ID notarized DMG** | 개발자, 외부 하드웨어 사용자 | App Store 외 직접 배포. Sparkle 자동 업데이트 가능. USB/외부 하드웨어 자유 |

---

## 1. 사전 준비

### 1.1 Apple Developer Program

- ✅ Apple Developer Program 가입 ($99/년)
- Team ID 확인: <https://developer.apple.com/account> → Membership → Team ID

### 1.2 인증서 / Provisioning

#### Mac App Store 용 (3개 필요)

| 인증서 | 용도 | 발급 |
|---|---|---|
| **Apple Distribution** | .app 코드사인 | Xcode → Settings → Accounts → Manage Certificates → "+" → Apple Distribution |
| **Mac Installer Distribution** | .pkg installer 사인 | 동일 메뉴, "+" → Mac Installer Distribution |
| **Provisioning Profile** | App Store 용 | Developer 사이트 → Profiles → "+" → Mac App Store → bundle id 선택 |

#### Developer ID 용 (1개)

| 인증서 | 용도 |
|---|---|
| **Developer ID Application** | .app 코드사인 (외부 배포) |

### 1.3 App Store Connect 에 앱 등록

1. <https://appstoreconnect.apple.com/apps> → **+** → **신규 App** → macOS
2. Bundle ID: `com.robotis.darwinforge` (Identifier 등록 안 됐으면 Developer 사이트 → Identifiers 에서 먼저 등록)
3. SKU: 임의 (예: `DARWINFORGE-MAC`)
4. 권한: 본인 또는 팀

### 1.4 Apple ID 앱-특정 암호

- <https://appleid.apple.com> → 보안 → 앱-특정 암호 → 새로 생성
- 2FA 활성화 필수
- 생성된 16자 암호를 `--app-specific-password` 인자로 사용 (예: `abcd-efgh-ijkl-mnop`)

---

## 2. 한 번의 빌드 → archive → 업로드 흐름

### 2.1 Mac App Store

```bash
# Step A: .xcarchive 어셈블 (~2분).
bash scripts/archive-app.sh \
     --method app-store \
     --team-id ABCDE12345 \
     --signing-identity "Apple Distribution: My Org (ABCDE12345)"

# Step B: .pkg 생성 + App Store Connect 업로드.
bash scripts/upload-app.sh \
     --archive dist/DarwinForge-1.23.0-3ac17d9.xcarchive \
     --method app-store \
     --team-id ABCDE12345 \
     --apple-id you@example.com \
     --app-specific-password "abcd-efgh-ijkl-mnop"
```

업로드 후 5-15분 안에 App Store Connect → **My Apps → DarwinForge → TestFlight**
에 빌드가 "Processing" 표시. 완료되면 내부 테스터 그룹에 즉시 배포 가능.

### 2.2 Developer ID notarized DMG

```bash
# Step A: archive (App Store 와 다른 entitlements 사용).
bash scripts/archive-app.sh \
     --method developer-id \
     --team-id ABCDE12345 \
     --signing-identity "Developer ID Application: My Org (ABCDE12345)"

# Step B: notarize + DMG 생성.
bash scripts/upload-app.sh \
     --archive dist/DarwinForge-1.23.0-3ac17d9.xcarchive \
     --method developer-id \
     --team-id ABCDE12345 \
     --apple-id you@example.com \
     --app-specific-password "abcd-efgh-ijkl-mnop"
```

산출: `dist/DarwinForge-1.23.0-3ac17d9.dmg` — 사용자에게 직접 공유.

---

## 3. App Store Review 통과 전략 (USB 외부 하드웨어)

DarwinForge 의 가장 큰 review 사유는 **`com.apple.security.device.usb`** entitlement.
Apple 은 일반 USB device 직접 접근을 제한적으로만 허용 (DriverKit 우선).

### 3.1 App Store Review Note (필수 작성)

App Store Connect → 빌드 제출 → **앱 정보 → 일반 → 검토 정보 → 메모** 에 다음 명시:

```text
This app communicates with ROBOTIS DARwIn-OP2 humanoid robots over USB
serial (FTDI-based). The USB entitlement is essential for the core
functionality.

DEMO without robot hardware:
- Launch the app, the "Mock / Review" mode is auto-selected
- Mobile Pilot Relay panel shows pairing QR
- All UI features work in simulation mode without actual robot

The app is targeted at robotics researchers and developers who own the
DARwIn-OP2 hardware. We have included a fully functional Mock mode for
App Review to evaluate the app without the hardware dependency.

Robot vendor: ROBOTIS Co., Ltd. (https://www.robotis.com)
Product: DARwIn-OP2 / OP3 humanoid platform
```

### 3.2 Mock 모드 자동 활성 확인

- 앱 첫 실행 시 `ConnectionStore.activeEndpoint == nil` → Mock 모드 자동
- ROBOTIS demo 없는 환경에서도 모든 UI 화면 + Mobile Pilot Relay 동작
- App Reviewer 가 robot 없이 검토 가능

### 3.3 추가 검토 항목

- **§2.5.4** — 음성 인식 (NSSpeechRecognition): 사용자 prompt + privacy policy URL
- **§5.1.1** — 사생활 보호: privacy nutrition label (App Store Connect → 앱 → 앱 개인정보 처리방침)
- **§4.5** — TestFlight: 외부 베타 테스트 (최대 10,000명) 또는 내부 테스트

---

## 4. 빌드 번호 자동 bump

각 빌드는 **App Store Connect 에 고유 CFBundleVersion** 필요. 동일 번호 재업로드 거절.

현재 `build-app.sh` 가 git short hash 를 사용 — 매 커밋마다 자동 unique.

수동 변경 시:

```bash
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 100" \
    app/ui/DarwinForge/Sources/DarwinForgeApp/Info.plist
```

또는 git commit count 사용:

```bash
BUILD=$(git rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" \
    app/ui/DarwinForge/Sources/DarwinForgeApp/Info.plist
```

---

## 5. 트러블슈팅

### 5.1 codesign 실패: "No identity found"

```bash
# 인증서 확인.
security find-identity -p codesigning -v

# 출력에 "Apple Distribution" 또는 "Developer ID Application" 없으면 Xcode 에서 발급.
```

### 5.2 productbuild 실패: "no such installer signing identity"

Mac Installer Distribution 인증서 미발급. Xcode → Settings → Accounts → "+"
→ Mac Installer Distribution.

### 5.3 altool 업로드 실패: "Invalid bundle identifier"

App Store Connect 에 bundle id (`com.robotis.darwinforge`) 등록 안 됨.
<https://appstoreconnect.apple.com/apps> → **+** → 신규 App → bundle id 선택.

### 5.4 notarytool 실패: "Status: Invalid" + log 에 "hardened runtime"

entitlements 의 `com.apple.security.cs.disable-library-validation` 등이 잘못 true.
`DarwinForge-DevID.entitlements` / `DarwinForge-AppStore.entitlements` 의 모든
`cs.*` 키가 `<false/>` 인지 재확인.

### 5.5 App Store Review §2.4.5 거부 (외부 하드웨어)

§3.1 의 review note 와 Mock 모드 시연을 보강. 부족하면:

```text
Add to Review Notes:

"To demonstrate the Mobile Pilot Relay feature WITHOUT the robot:
1. Launch DarwinForge.
2. The toolbar shows a green 'Mobile Pilot Relay' chip — tap to open
   the panel.
3. The 6-digit pairing code + QR are shown.
4. Optional: pair an iPhone running our companion 'OP Pilot' app.

The robot connectivity (USB Serial) is OFF in Mock mode by design — all
UI states (ARM slider, walk commands, telemetry, E-stop, recovery) are
exercised against a simulated robot. This satisfies App Review §2.4.5
since the app remains fully functional without external hardware."
```

---

## 6. 참고

- 프로토콜 스펙: `docs/protocols/mobile-relay-v1.md`
- entitlements ground truth: `docs/walk-lab/PILOT_PRODUCTION_ENTITLEMENTS.md`
- archive 스크립트: `scripts/archive-app.sh`
- 업로드 스크립트: `scripts/upload-app.sh`
- export options 템플릿: `dist/ExportOptions-{AppStore,DevID}.plist.template`
