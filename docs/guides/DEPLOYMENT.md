# DarwinForge 배포 가이드

> 사이클 259-2 — `.app` 번들 빌드 + 배포 워크플로.
> end-user macOS 머신에 설치 가능한 standalone bundle 생성.

## 결론 (한 줄)

```bash
bash scripts/build-app.sh
```

산출: `app/ui/DarwinForge/.build/release/DarwinForge.app` (ad-hoc 사인, 약 39MB).

## 배경

`swift build` 만으로는 CLI binary (`DarwinForgeApp`, 31MB) 만 생성. 이를 end-user macOS
에 배포하면:

- macOS Gatekeeper: "확인되지 않은 개발자" 차단.
- Dock / 메뉴바 활성화 실패 — `LSUIElement` 인식 못 함.
- 아이콘 / Info.plist 메타데이터 없음.

`.app` bundle 은 macOS 가 인식하는 표준 단위. Info.plist + 코드 사인 + 리소스 번들이
필요.

## 빌드 파이프라인

### 사전 준비 (one-time)

```bash
xcode-select --install              # swift, iconutil, sips, codesign
make doctor                          # 도구 점검 — bash scripts/bootstrap-tools.sh
```

### 빌드

```bash
# 표준 (release + ad-hoc 사인)
bash scripts/build-app.sh

# Rust 재빌드 스킵 (Vendor/CForgeCore 이미 채워짐 — 반복 빌드 시 빠름)
bash scripts/build-app.sh --skip-rust

# 사인 스킵 (codesign 수동 후처리)
bash scripts/build-app.sh --no-sign

# 배포용 Developer ID 사인 (entitlements + hardened runtime)
bash scripts/build-app.sh --sign="Developer ID Application: ROBOTIS (TEAMID)"
```

옵션 전체: `bash scripts/build-app.sh --help`.

### 빌드 흐름

1. `scripts/build-mac.sh` 위임 — Rust core / FFI 빌드, Vendor/CForgeCore 채움 (`--skip-rust` 로 생략 가능).
2. `swift build -c release --product DarwinForgeApp` → 31MB CLI binary.
3. `.app` bundle 어셈블:
   - `Contents/MacOS/DarwinForgeApp` — executable.
   - `Contents/Info.plist` — `Sources/DarwinForgeApp/Info.plist` 복사 (source of truth).
   - `Contents/Resources/AppIcon.icns` — `app/icon/AppIcon.png` 에서 sips → iconset → icns.
   - `Contents/Resources/DarwinForge_*.bundle` — SwiftPM module resource bundle (Bundle.module 자산).
4. `codesign --force --deep --sign -` (ad-hoc) 또는 Developer ID 사인.
5. `codesign --verify` + bundle 구조 sanity check.

## 산출물

```
app/ui/DarwinForge/.build/release/DarwinForge.app/
├── Contents/
│   ├── Info.plist                            # CFBundleIdentifier=com.robotis.darwinforge
│   ├── MacOS/
│   │   └── DarwinForgeApp                    # 31MB executable
│   ├── Resources/
│   │   ├── AppIcon.icns                      # 1.7MB
│   │   ├── DarwinForge_DarwinForgeApp.bundle
│   │   └── DarwinForge_DarwinForgeUI.bundle  # Branding SVG, STL meshes
│   └── _CodeSignature/
│       └── CodeResources
```

| 항목 | 값 |
|---|---|
| Bundle ID | `com.robotis.darwinforge` |
| Executable | `DarwinForgeApp` |
| Version | `CFBundleShortVersionString=1.22.0`, `CFBundleVersion=<git-sha>` |
| Min macOS | `14.0` (Sonoma) |
| Architecture | arm64 (현재 호스트) — universal 은 `build-mac.sh -u` 와 결합 |

## 설치

### 개발자 로컬 (자동 install + LaunchServices 갱신)

```bash
bash scripts/install-app.sh           # build + install + open
```

### Standalone bundle 배포 (이 가이드의 주 use-case)

```bash
bash scripts/build-app.sh
cp -R app/ui/DarwinForge/.build/release/DarwinForge.app /Applications/
xattr -dr com.apple.quarantine /Applications/DarwinForge.app   # Gatekeeper 우회
open /Applications/DarwinForge.app
```

### end-user 배포 (Developer ID 사인 + notarization)

ad-hoc 사인은 로컬 실행만 가능 — 다른 머신에 복사 시 Gatekeeper 차단.
정식 배포는 Developer ID 사인 + Apple notarization 필수.

```bash
# 1. Developer ID 사인 + hardened runtime
bash scripts/build-app.sh --sign="Developer ID Application: ROBOTIS (TEAMID)"

# 2. ZIP 으로 패키징 (notarytool 입력)
ditto -c -k --keepParent \
    app/ui/DarwinForge/.build/release/DarwinForge.app \
    DarwinForge.zip

# 3. Apple notarization (Apple Developer 계정 필수)
xcrun notarytool submit DarwinForge.zip \
    --apple-id "you@example.com" \
    --team-id "TEAMID" \
    --password "@keychain:AC_PASSWORD" \
    --wait

# 4. Staple notarization ticket
xcrun stapler staple app/ui/DarwinForge/.build/release/DarwinForge.app

# 5. 검증
spctl --assess --type execute --verbose \
    app/ui/DarwinForge/.build/release/DarwinForge.app
```

### DMG 패키징 (선택)

```bash
hdiutil create -volname "DarwinForge" \
    -srcfolder app/ui/DarwinForge/.build/release/DarwinForge.app \
    -ov -format UDZO DarwinForge.dmg
```

## 검증

빌드 직후 자동 검증:

- `codesign --verify --verbose` — 사인 무결성.
- `Contents/MacOS/DarwinForgeApp` 존재 + executable bit.
- `Contents/Info.plist` 의 `CFBundleExecutable` == binary 이름.
- `CFBundleIdentifier` 표시.

수동 검증:

```bash
# 실행 가능성 (가장 중요)
open app/ui/DarwinForge/.build/release/DarwinForge.app

# Gatekeeper 평가 (배포 사인 후)
spctl --assess --type execute --verbose \
    app/ui/DarwinForge/.build/release/DarwinForge.app

# 사인 detail
codesign --display --verbose=4 \
    app/ui/DarwinForge/.build/release/DarwinForge.app

# entitlements 확인 (Developer ID 사인 후)
codesign --display --entitlements - \
    app/ui/DarwinForge/.build/release/DarwinForge.app
```

## 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| `input file ... was modified during the build` | swift build cache 충돌 | `cd app/ui/DarwinForge && swift package clean` |
| `Invalid Iconset` (iconutil) | iconset 디렉토리명이 `*.iconset` 아님 | 스크립트가 자동 처리 (`AppIcon.iconset` suffix) |
| `Another instance of SwiftPM is already running` | `.build` lock | 다른 swift 프로세스 종료 후 재시도 |
| Gatekeeper "확인되지 않은 개발자" 차단 | ad-hoc 사인은 다른 머신 신뢰 못 함 | Developer ID + notarization (위 절차) |
| `spctl --assess` 가 `rejected` | ad-hoc 사인은 Gatekeeper 정책 불만족 (정상) | 로컬 실행은 `open ...` 또는 우클릭 → 열기. 배포는 Developer ID 필수 |
| `Vendor/CForgeCore/lib/libforge_core.a` 비어 있음 | Rust core 미빌드 | `--skip-rust` 제거 후 재빌드 |
| Dock 활성화 실패, 윈도우 가려짐 | Info.plist 누락 / CFBundleExecutable 불일치 | 자동 검증이 fail-fast (Step 6) |

## 관련 파일

- `scripts/build-app.sh` — 본 가이드의 빌드 파이프라인 (CI / 배포 친화).
- `scripts/install-app.sh` — 개발자 로컬 install + /Applications + LaunchServices 갱신.
- `scripts/build-mac.sh` — Rust core + Vendor/CForgeCore 준비 (build-app.sh 가 위임).
- `scripts/run-app.sh` — 개발 중 빠른 실행 (debug bundle + open).
- `app/ui/DarwinForge/Sources/DarwinForgeApp/Info.plist` — Info.plist source of truth.
- `app/ui/DarwinForge/Sources/DarwinForgeApp/DarwinForge.entitlements` — Developer ID 사인 시 첨부.
- `app/icon/AppIcon.png` — AppIcon 영구 자산 (변경 금지 — feedback_app_icon.md).

## RPO / RTO (배포 관점)

- **RPO**: 0 — bundle 은 git 에서 source-driven, 언제든 재현 가능.
- **RTO**: 신규 머신 setup + Rust 빌드 포함 약 5분, `--skip-rust` 빠른 빌드는 2분 이내.
