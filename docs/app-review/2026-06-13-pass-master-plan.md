# App Store 심사 통과 마스터 플랜 — v1.24.0 기준

**작성일**: 2026-06-13
**기준 코드**: `claude/robotis-darwin-op-setup-oyzTi` (v1.24.0, HEAD `94b4866`) + PR #43 entitlements fix
**목적**: 구현 터미널이 본 문서만으로 모든 수정을 실행할 수 있도록, 항목별 [근거 가이드라인 / 현재 상태 증거 / 정확한 수정 방법 / 검증 명령] 을 명시한다.
**전제**: 1차 반려 (2026-06-11, Guideline 2.4.5(i), submission `66cb634a`) 의 entitlements 이슈는 PR #43 에서 조치 완료. 본 문서는 **그 다음 단계 — 휴먼 리뷰 + 기능 검증까지 통과**하기 위한 전체 계획.

---

## 0. Executive Summary

| # | 항목 | 우선순위 | 유형 | 상태 |
|---|---|---|---|---|
| 1 | entitlements cs.* false 5개 제거 | P0 | 자동 검사 반려 | ✅ 조치됨 (PR #43, 본 브랜치 체리픽 `8d62550`) |
| 2 | **`com.apple.security.device.serial` 추가** | **P0** | **샌드박스 기능 파손 (robot 연결 불가)** | ✅ 조치됨 (`be8ab20` — AppStore/DevID/default 3개) |
| 3 | **CFBundleVersion 자동 bump** | **P0** | 업로드 거부 (build 579 < 새 build 필요) | ✅ 조치됨 (`be8ab20` — archive Step 0.5, git count+600=1297) |
| 4 | **샌드박스 활성 상태 통합 기능 검증** | **P0** | 검증 공백 (한 번도 수행 안 됨 추정) | ⬜ 미조치 (archive 빌드 + 실기 robot 필요 — §3 체크리스트) |
| 5 | **ROBOTIS 상표/사칭 (bundle ID + 저작권)** | **P1** | 휴먼 리뷰 반려 위험 (5.2.1) | 🟡 **코드 완료 (시나리오 B)** — bundle ID·저작권·상표 고지 변경됨. **포털 작업 잔여** (아래 §5 결정 블록) |
| 6 | Claude CLI 외부 프로세스 의존 기능 gate | P1 | 2.1 완성도 (리뷰어 환경에서 깨진 기능) | ✅ 조치됨 — App Store 빌드에서 숨김 (`#if APPSTORE`) |
| 7 | SynthBridge `cargo` 의존 gate | P1 | 2.1 완성도 | ✅ 조치됨 — App Store 빌드에서 숨김 (`#if APPSTORE`) |
| 8 | SSH/scp/ping 서브프로세스 샌드박스 검증 | P1 | 기능 파손 가능 | ⬜ 미조치 (§4 와 함께 archive 빌드에서 실측) |
| 9 | ComingSoonOverlay 사용처 정리 | P1 | 2.1 placeholder | ⬜ 미조치 (Pilot 화면 3곳 — 별도 차수) |
| 10 | App Review Notes + 데모 영상 (하드웨어 의존) | P1 | 2.1 리뷰 진행 불가 방지 | ⬜ 템플릿 있음, 영상 필요 (사용자 작업) |
| 11 | App Privacy 라벨 (음성/Claude 데이터) | P1 | 메타데이터 | ⬜ 미조치 (App Store Connect UI — Claude 숨김으로 "Audio Data" 단일화 가능) |
| 12 | NSAllowsLocalNetworking (ATS 명시) | P2 | 방어적 | ⬜ 권장 |
| 13 | App Store Connect 메타데이터 (스크린샷/URL) | P2 | 제출 요건 | ⬜ 확인 필요 (사용자 작업) |
| 14 | 앱 아이콘 | P2 | — | ✅ 확인 완료 (1254×1254, build-app.sh 가 icns 생성) |
| 15 | Info.plist 필수 키 | P2 | — | ✅ 확인 완료 (Bonjour/카테고리/암호화 모두 존재) |

**예상 리뷰 시나리오**: 1차 반려는 *자동 binary 검사* 단계였다. entitlements 수정 후 재제출하면 다음은 **휴먼 리뷰** — 이때 #5 (상표), #6/#7 (깨진 기능), #10 (하드웨어) 가 새 반려 사유로 등장할 가능성이 높다. P0 만 고치고 재제출하면 **2차 반려 가능성이 상당**하므로, P1 까지 일괄 처리 후 제출을 권장한다.

---

## 진행 현황 — 2026-06-13 구현 세션 (브랜치 `claude/robotis-darwin-op-setup-oyzTi`)

**완료 (코드)**: #1(체리픽) · #2 device.serial · #3 build bump · #6/#7 Claude·Synth App Store 숨김 · #5 코드 변경.

**#5 ROBOTIS 상표 — 사용자 결정 = 시나리오 B (순수 서드파티)**. 코드 변경 완료:
- `CFBundleIdentifier` : `com.robotis.darwinforge` → **`com.yuseokkim.darwinforge`** (Info.plist + AppStore entitlements `application-identifier` + build/archive/install 스크립트 3개 + OSLog subsystem 4개 일관 변경)
- `NSHumanReadableCopyright` : `© 2026 ROBOTIS` → **`© 2026 YUSEOK KIM. All rights reserved.`**
- README 상표 고지 강화 ("ROBOTIS·DARwIn-OP 는 ROBOTIS 상표, 본 앱은 비공식 서드파티 도구")

> ⚠️ **포털 작업 잔여 (개발자 수작업 — 코드로 불가)**: bundle ID 변경은 Apple Developer 포털에서 ① 새 App ID(`com.yuseokkim.darwinforge`) 등록 ② macOS App Store provisioning profile 재발급 → `~/Library/MobileDevice/Provisioning Profiles/` 에 설치 ③ App Store Connect 에 새 앱 레코드 생성(기존 submission 이력과 분리)이 선행돼야 archive·업로드가 성립한다. (archive-app.sh Step 1.5 가 새 ID 의 profile 을 자동 검색하므로, profile 만 설치하면 됨.)

**#4/#8 샌드박스 검증 — 잔여 (다음 단계)**: `bash scripts/archive-app.sh --method app-store --team-id JM4LJMU49Q` 로 sandbox 빌드 생성 후 §3 체크리스트 12항목(특히 robot USB 연결 — device.serial 실효 확인)을 실기로 전수. 이건 App Store 빌드 + 실 robot 이 있어야 가능.

**검증(이번 세션)**: swift build 기본·APPSTORE 양 구성 컴파일 성공, plutil -lint 3개 OK, 풀 테스트 스위트 통과.

---

## 1. P0-2 — `com.apple.security.device.serial` entitlement 추가

### 근거
- App Sandbox Design Guide: POSIX serial 디바이스 노드 (`/dev/cu.*`, `/dev/tty.*`) open 은 `com.apple.security.device.serial` 이 필요. `com.apple.security.device.usb` 는 IOUSBHost/IOKit USB 인터페이스용이며 **serial 디바이스 파일은 커버하지 않는다**.

### 현재 상태 (증거)
- `app/core/forge-core/src/serial/posix.rs:51` — `serialport::new(path, baud)` 로 `/dev/cu.*` 직접 open (`serialport` crate 4.7, `forge-core/Cargo.toml:24`)
- `DarwinForge-AppStore.entitlements` — `device.usb` 만 존재, `device.serial` 부재
- 개발 환경은 sandbox 비활성 (`swift run` / NoSandbox entitlements) 이므로 **이 문제가 한 번도 드러난 적이 없다**. App Store 빌드 (sandbox 활성) 에서 robot USB 연결 시도 → `open(/dev/cu.usbserial-*)` 가 `EPERM` 으로 거부 → **앱의 핵심 기능 (robot 연결) 전체 불가**.

### 수정 방법
3개 파일 (`DarwinForge-AppStore.entitlements`, `DarwinForge-DevID.entitlements`, `DarwinForge.entitlements`) 의 `device.usb` 항목 아래에 추가:

```xml
    <!-- USB-Serial 디바이스 노드 (/dev/cu.usbserial-*) — ROBOTIS CM-730/740 통신.
         device.usb 는 IOUSBHost 용이며 POSIX serial open 은 본 키가 별도 필요. -->
    <key>com.apple.security.device.serial</key>
    <true/>
```

### 검증
```sh
# 1. 서명된 앱의 실효 entitlements 확인
codesign -d --entitlements - dist/.../DarwinForge.app | grep -A1 serial
# 2. (필수) sandbox 빌드로 실 robot USB 연결 — Walk Lab 연결 성공 확인
# 3. sandbox denial 실시간 확인:
log stream --predicate 'process == "DarwinForgeApp" AND eventMessage CONTAINS "deny"' --style compact
```

### 리뷰 노트 영향
`device.serial` 도 `device.usb` 처럼 App Review 가 정당성을 물을 수 있음 → §6 의 Review Notes 에 "USB-Serial (FTDI/CP210x) 로 ROBOTIS 로봇과 통신" 한 줄 추가.

---

## 2. P0-3 — CFBundleVersion 자동 bump

### 근거
- App Store Connect 는 동일/이하 build number 재업로드를 거부. 반려된 빌드 = **579**, 현재 소스 `Info.plist:40` = **2**.

### 현재 상태 (증거)
- `scripts/archive-app.sh` — bump 단계 **없음** (Step 3 에서 읽기만 함)
- `scripts/upload-app.sh` — bump 단계 **없음**
- `Info.plist:36-38` 주석에 bump 방법만 적혀 있고 자동화 미구현 → 과거 579 는 수동 조작이었을 것 → **재발 위험**

### 수정 방법
`scripts/archive-app.sh` 의 Step 1 (build-app.sh 호출) **이전**에 삽입:

```sh
# ===== Step 0.5: CFBundleVersion 자동 bump =====
# git commit count 기반 — 단조 증가 보장. 반려 빌드 579 < 새 값 필수.
INFO_SRC="$PKG_ROOT/Sources/DarwinForgeApp/Info.plist"
GIT_COUNT=$(git -C "$REPO_ROOT" rev-list --count HEAD)
# 과거 수동 빌드 번호 (579) 추월 보장 — base offset.
NEW_BUILD=$((GIT_COUNT + 600))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_SRC"
echo "▶ Step 0.5: CFBundleVersion → $NEW_BUILD (git count $GIT_COUNT + 600)"
```

> offset 600 은 "어떤 git 히스토리 깊이에서도 579 를 넘는다" 를 보장하기 위함. 한 번 적용 후엔 단조 증가.

### 검증
```sh
bash scripts/archive-app.sh --method app-store --team-id JM4LJMU49Q
# 출력의 "Version : 1.24.0 (build NNN)" 에서 NNN > 579 확인
```

---

## 3. P0-4 — 샌드박스 활성 상태 통합 기능 검증 (검증 공백 해소)

### 근거
- 모든 개발/테스트가 sandbox 비활성 환경 (swift run, NoSandbox) 에서 수행됨. `archive-app.sh` 의 스모크 테스트 (line 304-330) 는 **launch 생존만 확인** — 기능 검증 0.
- Guideline 2.1: 리뷰 중 깨진 기능 발견 시 반려.

### 검증 체크리스트 (구현 터미널에서 archive 빌드 후 수행)

| # | 기능 | sandbox 위험 요소 | 합격 기준 |
|---|---|---|---|
| 1 | 앱 실행 + 전 메뉴 진입 (⌘1~⌘8) | resource bundle 경로 | crash 0 |
| 2 | **robot USB 연결** | `/dev/cu.*` open (→ §1 의 device.serial) | 연결 성공 + 텔레메트리 수신 |
| 3 | Walk Lab 시뮬 + 모니터링 (⌘⇧M) | — | 정상 |
| 4 | 모션 import/export | NSOpenPanel/NSSavePanel (user-selected ✓ — `MotionImportActions.swift` 등 6 파일 확인됨) | 파일 저장/열기 성공 |
| 5 | 세션 로그 기록 | `WalkSessionLogger.swift:76` Application Support (컨테이너 내 ✓) | 기록 성공 |
| 6 | 음성 명령 | 마이크 TCC prompt | prompt 표시 + 인식 동작 |
| 7 | Mobile Pilot Relay (Bonjour) | network.server + NSBonjourServices ✓ | iPhone 페어링 |
| 8 | MJPEG 카메라 (`http://IP:8080`) | URLSession + cleartext — **IP literal 은 ATS 면제** (Apple 규정: ATS 는 IP 주소·.local 미적용) | 스트림 표시 |
| 9 | SSH/scp 연결 마법사 | §5 참조 — `/usr/bin/ssh` 자식 프로세스가 sandbox 상속, known_hosts 가 컨테이너로 격리 | 동작 or graceful 실패 |
| 10 | ping probe | `/sbin/ping` 자식 sandbox 상속 — ICMP 소켓 거부 가능 | 동작 or graceful 실패 |
| 11 | Claude 대화/분석 | §4 참조 | CLI 부재 안내 표시 (에러 아님) |
| 12 | Synth | §4 참조 | gate 동작 |

### sandbox denial 디버깅
```sh
# 실시간 거부 로그
log stream --style compact --predicate 'subsystem == "com.apple.sandbox.reporting" OR (process == "DarwinForgeApp" AND eventMessage CONTAINS[c] "deny")'
# 과거 거부 로그 (최근 30분)
log show --last 30m --predicate 'eventMessage CONTAINS "Sandbox: DarwinForgeApp"'
```

---

## 4. P1-6/7 — 외부 프로세스 의존 기능 gate (Claude CLI / cargo)

### 근거
- Guideline 2.1 (완성도): 리뷰어가 기능을 눌렀을 때 에러/빈 화면이면 반려.
- 샌드박스에서 외부 바이너리 `posix_spawn` 은 가능하지만 **자식이 sandbox 를 상속** — Claude CLI 는 `~/.claude` 설정·키체인 접근이 컨테이너로 격리되어 실패하고, `cargo` 는 리뷰어 머신에 아예 없음.

### 현재 상태 (증거)
| 파일 | 실행 대상 | gate 현황 |
|---|---|---|
| `Claude/ClaudeCommander.swift:106-110` | claude CLI (`locateClaudeBinary()`) | `cliNotFound` 에러 throw ✓ — **UI 가 이를 "기능 비활성 안내" 로 표시하는지 확인 필요** |
| `WalkLab/Learning/WalkSessionClaudeAnalyst.swift:41,106` | claude CLI | 동일 확인 필요 |
| `ForgeCore/SynthBridge.swift:51` | **기본값 `cargo`** (`forgePath: String = "cargo"`) | **production 에서 확정 실패** — 개발 도구 가정 |
| `Connection/SSHShell.swift:179,255` | `/usr/bin/ssh`, `/usr/bin/scp` | 시스템 바이너리 — 동작 가능성 있으나 검증 필요 |
| `Connection/NetworkProbe.swift:35` | `/sbin/ping` | ICMP — sandbox 자식에서 거부 가능 |
| `Logging/Harness/HarnessInspectorView.swift:224` | (확인 필요) | — |

### 수정 방법

**(a) Claude 기능 — runtime gate + UI 처리 (필수)**
1. 앱 시작 시 `ClaudeCommander.locateClaudeBinary()` 결과를 1회 확인 → 미설치면:
   - Conversation 메뉴(⌘5): 진입 가능하되 "Claude CLI 가 설치된 환경에서 사용 가능한 개발자 기능입니다" 안내 패널 표시 (에러 배너 ❌, 정보성 안내 ✓)
   - WalkLab Claude 분석 패널: 동일 안내 또는 패널 숨김
2. **리뷰 전략 대안 (더 안전)**: App Store 빌드에서 해당 기능을 feature flag 로 완전 숨김 (`#if APPSTORE` 또는 빌드 설정). 리뷰어가 아예 못 보는 기능은 반려 사유가 될 수 없음.

**(b) SynthBridge — cargo 경로 차단 (필수)**
```swift
// SynthBridge.executeForgeSynth 진입부에 가드 추가:
if forgePath == "cargo",
   !FileManager.default.isExecutableFile(atPath: "/usr/bin/env") || !Self.cargoAvailable() {
    return .failure(.toolUnavailable("개발 환경 전용 기능"))
}
```
+ Synth UI 를 App Store 빌드에서 숨기는 것이 최선 (개발자 도구 성격).

**(c) SSH/ping — graceful 실패 확인 (검증)**
- 코드는 이미 실패 시 `.unreachable` / 에러 반환 구조. **sandbox 빌드에서 실제 눌러보고** 에러 UI 가 "치명적으로" 보이지 않는지만 확인. 깨지면 연결 마법사에서 해당 단계 skip 처리.

### 검증
§3 체크리스트 #9-#12 와 동일.

---

## 5. P1-5 — ROBOTIS 상표/사칭 위험 ⚠️ 사용자 의사결정 필요

### 근거
- **Guideline 5.2.1 (Intellectual Property)**: 제3자 상표·브랜드를 사용하는 앱은 권리 보유 증빙 요구 가능. **Guideline 4.1 (Copycats)**: 타 기업 행세 금지.

### 현재 상태 (증거) — 모순된 신호
| 위치 | 내용 |
|---|---|
| `Info.plist:30` | `CFBundleIdentifier = com.robotis.darwinforge` ← **ROBOTIS 소유 도메인 네임스페이스** |
| `Info.plist:54` | `NSHumanReadableCopyright = © 2026 ROBOTIS. All rights reserved.` ← **저작권자를 ROBOTIS 로 표기** |
| `README.md` | "비공식(unofficial) 도구 — ROBOTIS와 직접 제휴 관계 없음" ← **정반대 선언** |
| 앱 이름 | "DarwinForge" — DARwIn-OP (ROBOTIS 등록상표) 파생 |

1차 반려는 자동 검사였으므로 이 이슈는 **아직 휴먼 리뷰를 통과한 적이 없다.**

### 의사결정 분기 (구현 전 사용자 확인 필수)

**시나리오 A — 개발자가 ROBOTIS 임직원이거나 공식 서면 권한 보유**
- 조치: ① App Review Notes 에 권한 관계 명시 ("This app is developed by/with authorization from ROBOTIS Co., Ltd.") ② 필요 시 권한 증빙 문서 준비 (Resolution Center 요청 대비) ③ README 의 "unofficial" 문구를 실제 관계에 맞게 수정 (저장소 공개 시 리뷰어가 검색 가능)
- 코드 변경: 없음

**시나리오 B — 권한 미보유 (순수 서드파티 도구)**
- `com.robotis.*` bundle ID 와 "© ROBOTIS" 저작권은 **사칭으로 해석될 위험** → 조치:
  1. `NSHumanReadableCopyright` 를 실제 개발 주체로 변경
  2. bundle ID 를 개발자 소유 도메인으로 변경 (예: `com.<your-domain>.darwinforge`) — ⚠️ **bundle ID 변경 = App Store Connect 에서 새 앱 레코드 등록** (기존 submission 이력과 분리됨). Team ID `JM4LJMU49Q` 의 provisioning profile 재발급 필요.
  3. 앱 설명에 "ROBOTIS 및 DARwIn-OP 는 ROBOTIS Co., Ltd. 의 상표이며, 본 앱은 비공식 서드파티 도구입니다" 면책 문구
  4. 앱 이름은 "DarwinForge" 유지 가능성 높음 (직접 상표 아님) — 단 리뷰어 재량 영역

> **권장**: 시나리오 확정 전 재제출하지 말 것. A 라면 변경 0, B 라면 bundle ID 작업이 가장 큰 일감.

---

## 6. P1-10 — App Review Notes + 데모 영상 (하드웨어 의존)

### 근거
- Guideline 2.1: 리뷰어가 기능을 평가할 수 없으면 정보 요청/반려. ROBOTIS-OP2 + Tello 드론 **두 종류의 외부 하드웨어** 의존.

### 현재 상태
- 영문 노트 템플릿 작성됨: `docs/app-review/app-review-notes-template.md` ✓
- 데모 영상: **미제작** ⬜

### 조치
1. 템플릿의 `[URL]` 에 들어갈 데모 영상 제작 (30초~2분):
   - ① 로봇 미연결 첫 실행 → 시뮬레이션 모드 표시 ② Walk Lab 3D 시뮬 + 모니터링 ③ Motion Studio 미리보기 ④ (별도 30초) 실 robot 연결 동작
2. 템플릿에 **Tello 드론 단락 추가** (현재 누락):
   ```
   - Tello drone control is an optional feature. Without a drone on the local
     network, the Tello panel simply shows "not connected" — no crash, no error.
   ```
3. 템플릿에 **device.serial 정당성 한 줄 추가** (§1 연동):
   ```
   - The serial-port entitlement is required to communicate with the robot's
     USB-serial adapter (FTDI). Unused when no robot is attached.
   ```

---

## 7. P1-9 — ComingSoonOverlay / placeholder 정리

### 현재 상태 (증거)
- `Pilot/ComingSoonOverlay.swift` 존재, `Pilot/PilotActionBar.swift` 에서 참조. **실 노출 범위 확인 필요** — grep 상 modifier 정의 + 1 사용처.

### 조치 (구현 터미널)
1. 실 사용처 전수 조사: `grep -rn "comingSoon\|ComingSoonOverlay" --include="*.swift" Sources/`
2. 노출되는 placeholder 가 있으면 둘 중 하나:
   - (a) 해당 컨트롤 자체를 App Store 빌드에서 숨김 (기능 없는 UI 는 없는 게 안전)
   - (b) "coming soon" 문구를 제거하고 기능 단위로 완성된 것만 노출
> Apple 은 minor 한 "coming soon" 으로 반드시 반려하진 않지만, 하드웨어 의존 + 외부 CLI 의존이 겹친 앱에서는 완성도 신호를 깨끗하게 가져가는 것이 유리.

---

## 8. P1-11 — App Privacy 라벨 (App Store Connect 메타데이터)

### 근거
- App Store Connect 제출 시 데이터 수집 선언 필수. 부정확하면 5.1.1/5.1.2 이슈.

### 선언 내용 (현 기능 기준)
| 데이터 | 흐름 | 라벨 |
|---|---|---|
| 음성 (마이크) | SFSpeechRecognizer → **Apple 서버** 처리 | "Audio Data" — 앱 기능, 미연결(Not linked), 미추적 |
| 대화 텍스트 | Claude CLI 경유 → Anthropic (단, §4 에서 gate/숨김 시 **선언 불요**) | App Store 빌드에서 기능 숨김이면 라벨 단순화 가능 |
| 분석/추적 | 없음 (OSLog 로컬만) | "Data Not Collected" 불가 — 음성이 있으므로 위 항목만 |
| 세션 로그 | 로컬 Application Support 저장만 | 선언 불요 (기기 외 전송 없음) |

> **권장**: Claude 기능을 App Store 빌드에서 숨기면 (§4-a 대안) 라벨이 "Audio Data (앱 기능)" 하나로 끝나 가장 깔끔.

---

## 9. P2 — 방어적/메타데이터 항목

### 9.1 ATS 명시 (선택, 권장)
- 현재 MJPEG (`http://<IP>:8080`) 는 **IP literal 이라 ATS 면제** (Apple: ATS 는 IP 주소·unqualified hostname·.local 도메인에 미적용) → 동작에는 문제 없음.
- 단, 향후 `robot.local` 외 hostname 사용 가능성 대비 Info.plist 에 명시 권장:
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

### 9.2 App Store Connect 메타데이터 체크
- [ ] 스크린샷 (macOS, 1280×800 이상 — 시뮬레이션 모드 화면로 충분)
- [ ] 앱 설명 (영문 필수 — 한국 외 storefront)
- [ ] 지원 URL / **개인정보처리방침 URL** (음성 권한 사용으로 사실상 필수)
- [ ] 연령 등급 (4+)
- [ ] 키워드, 카테고리 (Developer Tools — Info.plist 와 일치 ✓)

### 9.3 확인 완료 항목 (조치 불요 — 기록)
- ✅ 앱 아이콘: `app/icon/AppIcon.png` 1254×1254 → `build-app.sh` 가 iconset/icns 생성 + `CFBundleIconFile` 주입 (line 137-139)
- ✅ `NSBonjourServices` (`_darwinforge._tcp`) — macOS Sonoma+ silent block 대응 완료 (Info.plist:12-15)
- ✅ `LSApplicationCategoryType` = developer-tools (Info.plist:57)
- ✅ `ITSAppUsesNonExemptEncryption` = false (Info.plist:72)
- ✅ provisioning profile 자동 embed (archive-app.sh Step 1.5)
- ✅ quarantine xattr 정리 (archive-app.sh Step 1.7 — 과거 ITMS-91109 대응)
- ✅ resource bundle Info.plist 보강 (archive-app.sh Step 1.2 — 과거 -19241 대응)
- ✅ inside-out codesign + hardened runtime (archive-app.sh Step 2)
- ✅ 파일 I/O — user-selected (NSOpenPanel 계열 6 파일) + Application Support 컨테이너 내 (WalkSessionLogger) — sandbox 위반 경로 미발견

---

## 10. 실행 순서 (구현 터미널용)

```
Phase 1 — 코드 수정 (반나절)
  1. PR #43 merge (entitlements false 제거)
  2. §1: device.serial 3개 entitlements 추가
  3. §2: archive-app.sh 에 build bump Step 0.5 삽입
  4. §4: Claude/Synth 기능 gate (또는 App Store 빌드 숨김)
  5. §7: ComingSoon 사용처 조사 + 정리

Phase 2 — 사용자 의사결정 (병행)
  6. §5: ROBOTIS 권한 시나리오 A/B 확정
     → B 면 bundle ID + 저작권 + 면책 문구 작업 추가

Phase 3 — 빌드 + 샌드박스 검증 (반나절~1일)
  7. bash scripts/archive-app.sh --method app-store --team-id JM4LJMU49Q
  8. §3 체크리스트 12항목 전수 (특히 #2 robot USB 연결 — 실기 필수)
  9. codesign -d --entitlements - 로 최종 entitlements 육안 확인
     (cs.* false 없음 + device.serial 있음 + app-sandbox true)

Phase 4 — 메타데이터 + 제출
  10. §6: 데모 영상 제작 + Review Notes 작성 (Tello/serial 단락 포함)
  11. §8: App Privacy 라벨 입력
  12. §9.2: 스크린샷/URL 확인
  13. bash scripts/upload-app.sh → 재제출
  14. 결과를 docs/app-review/README.md dashboard 에 기록
```

---

## 11. 리스크 등급표 (재제출 시 반려 확률 추정)

| 항목 | 미조치 시 반려 확률 | 조치 후 잔여 위험 |
|---|---|---|
| entitlements false (조치됨) | 100% (자동) | 0% |
| device.serial 부재 | 직접 반려는 아님 — 단 **리뷰어가 robot 기능 테스트 불가 + 출시 후 앱이 무용지물** | 낮음 |
| build number | 100% (업로드 자체 거부) | 0% |
| ROBOTIS 상표 | 30-60% (리뷰어 재량 + 신고 리스크) | A: ~5% / B: ~10% |
| Claude CLI 깨진 기능 | 20-40% (리뷰어가 누르면) | 숨김 시 ~0% |
| 하드웨어 리뷰 불가 | 30% (정보 요청 → 지연) | 노트+영상으로 ~5% |
| 종합 (P0+P1 모두 조치 시) | — | **통과 가능성 우세, 단 상표 이슈는 시나리오 의존** |

---

## 부록 A — 최종 제출 전 원샷 검증 스크립트

```sh
#!/usr/bin/env bash
set -e
APP="dist/DarwinForge-1.24.0-*.xcarchive/Products/Applications/DarwinForge.app"
APP=$(ls -d $APP | head -1)

echo "== 1. entitlements =="
codesign -d --entitlements - "$APP" 2>/dev/null | tee /tmp/ent.txt
grep -q "device.serial" /tmp/ent.txt && echo "✅ device.serial" || echo "🔴 device.serial 누락"
grep -q "app-sandbox" /tmp/ent.txt && echo "✅ app-sandbox" || echo "🔴 app-sandbox 누락"
! grep -B1 "false" /tmp/ent.txt | grep -q "cs\." && echo "✅ cs.* false 없음" || echo "🔴 cs.* false 잔존"

echo "== 2. build number > 579 =="
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
[ "$BUILD" -gt 579 ] && echo "✅ build $BUILD" || echo "🔴 build $BUILD ≤ 579"

echo "== 3. 서명 무결성 =="
codesign --verify --deep --strict "$APP" && echo "✅ codesign"
ls "$APP/Contents/embedded.provisionprofile" >/dev/null && echo "✅ profile" || echo "🔴 profile 누락"

echo "== 4. 아이콘 =="
ls "$APP/Contents/Resources/AppIcon.icns" >/dev/null && echo "✅ icns" || echo "🔴 icns 누락"
```

## 부록 B — 관련 문서

- 1차 반려 상세: `docs/app-review/2026-06-11-rejection-2.4.5-entitlements.md`
- 재제출 체크리스트: `docs/app-review/resubmission-checklist.md`
- Review Notes 템플릿: `docs/app-review/app-review-notes-template.md`
- 배포 가이드: `docs/deploy/APP_STORE_CONNECT_GUIDE.md`
- entitlements 근거: `docs/walk-lab/PILOT_PRODUCTION_ENTITLEMENTS.md`
