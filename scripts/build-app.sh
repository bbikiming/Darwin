#!/usr/bin/env bash
# 사이클 259-2 — DarwinForge.app bundle 빌드 파이프라인 (CI/배포 friendly).
#
# 목적:
#   end-user macOS 머신에 배포 가능한 .app bundle 생성.
#   `swift build` 만으로는 CLI binary 만 생성되어 Gatekeeper 차단 + Dock 활성화 실패.
#
# 차이점 (install-app.sh 와):
#   - install-app.sh: 빌드 + /Applications 설치 + LaunchServices 갱신 (개발자 로컬 워크플로).
#   - build-app.sh : 빌드만 — `.build/release/DarwinForge.app` 산출. CI / 배포 / 패키징 용.
#
# 흐름:
#   1. Rust core (forge-core / forge-ffi) → Vendor/CForgeCore 준비 (build-mac.sh 위임).
#   2. swift build -c release --product DarwinForgeApp → CLI binary 생성.
#   3. .build/release/DarwinForge.app/ 구조 어셈블:
#        Contents/MacOS/DarwinForgeApp        (executable)
#        Contents/Info.plist                  (Sources/DarwinForgeApp/Info.plist 복사)
#        Contents/Resources/AppIcon.icns      (app/icon/AppIcon.png → iconset → icns)
#        Contents/Resources/DarwinForge_*.bundle (SwiftPM resource bundles)
#   4. ad-hoc codesign + entitlements 첨부.
#   5. codesign --verify 검증.
#
# Usage:
#   bash scripts/build-app.sh                 # 표준 (release + ad-hoc sign)
#   bash scripts/build-app.sh --skip-rust     # Rust 빌드 스킵 (Vendor 이미 채워짐)
#   bash scripts/build-app.sh --no-sign       # codesign 스킵 (수동 후처리)
#   bash scripts/build-app.sh --sign "Developer ID Application: ..."   # 배포용 사인
#
# 산출:
#   $REPO/app/ui/DarwinForge/.build/release/DarwinForge.app
#
# 의존성: swift 5.10+, iconutil, sips, codesign (모두 macOS 기본 또는 Xcode CLT).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_ROOT="$REPO_ROOT/app/ui/DarwinForge"
APP_NAME="DarwinForge"
EXEC_NAME="DarwinForgeApp"  # Info.plist 의 CFBundleExecutable 와 일치 필수.
BUILD_DIR="$PKG_ROOT/.build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

SKIP_RUST=0
SIGN_MODE="adhoc"
SIGN_IDENTITY="-"

for arg in "$@"; do
    case "$arg" in
        --skip-rust)
            SKIP_RUST=1
            ;;
        --no-sign)
            SIGN_MODE="none"
            ;;
        --sign)
            # 다음 토큰이 identity (e.g. "Developer ID Application: ...")
            # for-loop 에서 next-arg pop 이 어려우므로 --sign=... 형태 권장.
            echo "  hint: '--sign=\"Developer ID Application: ...\"' 형태 사용 권장" >&2
            ;;
        --sign=*)
            SIGN_MODE="identity"
            SIGN_IDENTITY="${arg#--sign=}"
            ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 64
            ;;
    esac
done

# ===== 사전 검증 =====
command -v swift >/dev/null 2>&1 || {
    echo "✗ swift 미설치 — 'xcode-select --install' 후 재시도" >&2
    exit 1
}
command -v iconutil >/dev/null 2>&1 || {
    echo "✗ iconutil 미설치 — macOS 표준 도구가 누락됨 (Xcode CLT 확인)" >&2
    exit 1
}
command -v sips >/dev/null 2>&1 || {
    echo "✗ sips 미설치 — macOS 표준 도구가 누락됨" >&2
    exit 1
}

INFO_PLIST_SRC="$PKG_ROOT/Sources/DarwinForgeApp/Info.plist"
# 2026-06-01: 비샌드박스 entitlements — 샌드박스는 /usr/bin/ssh spawn + ~/.ssh 키 접근을
# 막아 로봇 SSH 연결(LAN/온보드)이 전부 실패한다. 이 앱은 로컬 실행 전용이라 비샌드박스가 맞다.
ENTITLEMENTS_SRC="$PKG_ROOT/Sources/DarwinForgeApp/DarwinForge-NoSandbox.entitlements"

if [ ! -f "$INFO_PLIST_SRC" ]; then
    echo "✗ Info.plist 누락: $INFO_PLIST_SRC" >&2
    exit 1
fi

# ===== Step 1: Rust core + Swift release build =====
echo "▶ Step 1: Rust core + Vendor 준비"
if [ "$SKIP_RUST" -eq 1 ]; then
    echo "  --skip-rust → Vendor/CForgeCore 그대로 사용"
    if [ ! -s "$PKG_ROOT/Vendor/CForgeCore/lib/libforge_core.a" ]; then
        echo "✗ Vendor/CForgeCore/lib/libforge_core.a 비어 있음 — --skip-rust 제거 후 재시도" >&2
        exit 1
    fi
else
    bash "$REPO_ROOT/scripts/build-mac.sh" >/dev/null
fi
echo "  ✓ Vendor 준비 완료"

echo "▶ Step 2: swift build -c release --product $EXEC_NAME"
cd "$PKG_ROOT"
swift build -c release --product "$EXEC_NAME" 2>&1 | tail -3

EXEC_PATH="$BUILD_DIR/$EXEC_NAME"
if [ ! -f "$EXEC_PATH" ]; then
    echo "✗ release binary 없음: $EXEC_PATH" >&2
    exit 1
fi
echo "  ✓ $(du -h "$EXEC_PATH" | cut -f1) — $EXEC_PATH"

# ===== Step 3: .app bundle 어셈블 =====
echo "▶ Step 3: $APP_NAME.app bundle 어셈블"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Executable — CFBundleExecutable 와 동일 이름 (DarwinForgeApp).
cp "$EXEC_PATH" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"

# Info.plist — source-of-truth (Sources/DarwinForgeApp/Info.plist).
# CFBundleExecutable=DarwinForgeApp, CFBundleIdentifier=com.robotis.darwinforge.
cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"

# CFBundleIconFile 명시 (Info.plist 에 없으면 추가) — AppIcon 참조.
# PlistBuddy 로 idempotent 추가 (이미 있으면 set, 없으면 add).
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP_BUNDLE/Contents/Info.plist"

# V297-10: CFBundleVersion 은 git commit count (정수) 사용.
# App Store Connect 가 정수 또는 마침표-분리 정수만 수락 (hex SHA 거부, -19239 에러).
# V297-12: BUILD_NUMBER env 로 override 가능 — 코드 변경 없이 재 archive 시 (App Store
# 는 동일 build 번호 재업로드 거부) 명시 bump 지원. 미설정 시 git commit count 기본.
GIT_COUNT="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo "1")"
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "dev")"
BUILD_NUMBER_USED="${BUILD_NUMBER:-$GIT_COUNT}"
echo "  ✓ build number    : $BUILD_NUMBER_USED ${BUILD_NUMBER:+(env override)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER_USED" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :BuildSHA string $GIT_SHA" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :BuildSHA $GIT_SHA" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

# Resource bundles (SwiftPM 가 .build/release/ 에 생성한 module bundles).
# SwiftPM executable의 Bundle.module accessor는 Bundle.main.bundleURL 바로 아래의
# DarwinForge_*.bundle을 먼저 찾는다. 일반 macOS 관례인 Contents/Resources에도
# 복사하되, 실제 런타임 크래시를 막기 위해 app root에도 반드시 둔다.
for bundle in "DarwinForge_DarwinForgeUI.bundle" "DarwinForge_DarwinForgeApp.bundle"; do
    src="$BUILD_DIR/$bundle"
    if [ -d "$src" ]; then
        cp -R "$src" "$APP_BUNDLE/"
        cp -R "$src" "$APP_BUNDLE/Contents/Resources/"
        echo "  ✓ resource bundle: $bundle (app root + Contents/Resources)"
    else
        echo "  ⚠️ resource bundle 누락: $bundle (Bundle.module 자산 fallback 가능)" >&2
    fi
done

# ===== Step 3b: Switch 에이전트 패키지 임베드 (R2 — 앱 내 자동배포) =====
# tools/switch-pilot/package.sh 산출 tarball 을 Contents/Resources 에 임베드 →
# 앱의 "에이전트 자동 배포" 카드가 Bundle.main 에서 찾아 scp 한다. codesign(Step 5)
# 전에 넣어야 봉인에 포함된다. 패키징 실패해도 앱 빌드는 계속(카드가 "패키지 없음" 표시).
echo "▶ Step 3b: Switch 에이전트 패키지 임베드"
SWITCH_PKG_SCRIPT="$REPO_ROOT/tools/switch-pilot/package.sh"
if [ -f "$SWITCH_PKG_SCRIPT" ]; then
    rm -f "$APP_BUNDLE/Contents/Resources/"darwin-switch-agent-*.tar.gz
    if SWITCH_TARBALL="$(bash "$SWITCH_PKG_SCRIPT" | tail -n1)" && [ -f "$SWITCH_TARBALL" ]; then
        cp "$SWITCH_TARBALL" "$APP_BUNDLE/Contents/Resources/"
        echo "  ✓ 에이전트 패키지: $(basename "$SWITCH_TARBALL")"
    else
        echo "  ⚠️ package.sh 실패 — 에이전트 자동배포 카드가 '패키지 없음' 표시 (앱 빌드는 계속)" >&2
    fi
else
    echo "  ⚠️ $SWITCH_PKG_SCRIPT 없음 — 에이전트 패키지 임베드 생략" >&2
fi

# ===== Step 4: AppIcon.icns 생성 =====
echo "▶ Step 4: AppIcon.icns 생성"
ICON_PNG="$REPO_ROOT/app/icon/AppIcon.png"
if [ ! -f "$ICON_PNG" ]; then
    echo "  ⚠️ $ICON_PNG 없음 — 아이콘 생략 (Finder 기본 아이콘 사용)" >&2
else
    # iconutil 은 디렉토리명이 *.iconset 이어야 인식 — mktemp 후 .iconset suffix 보장.
    ICONSET_PARENT="$(mktemp -d -t darwinforge-iconset-XXXXXX)"
    ICONSET_DIR="$ICONSET_PARENT/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    trap 'rm -rf "$ICONSET_PARENT"' EXIT

    # macOS iconset 표준 사이즈 — Apple HIG.
    ICONSET_SIZES=(
        "icon_16x16.png 16"
        "icon_16x16@2x.png 32"
        "icon_32x32.png 32"
        "icon_32x32@2x.png 64"
        "icon_128x128.png 128"
        "icon_128x128@2x.png 256"
        "icon_256x256.png 256"
        "icon_256x256@2x.png 512"
        "icon_512x512.png 512"
        "icon_512x512@2x.png 1024"
    )
    for entry in "${ICONSET_SIZES[@]}"; do
        name="${entry%% *}"
        size="${entry##* }"
        sips -s format png -z "$size" "$size" "$ICON_PNG" \
            --out "$ICONSET_DIR/$name" >/dev/null 2>&1 \
            || {
                echo "✗ sips 리사이즈 실패 ($name)" >&2
                exit 1
            }
    done
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "  ✓ AppIcon.icns ($(du -h "$APP_BUNDLE/Contents/Resources/AppIcon.icns" | cut -f1))"
fi

# ===== Step 5: Codesign =====
echo "▶ Step 5: Codesign ($SIGN_MODE)"
case "$SIGN_MODE" in
    none)
        echo "  --no-sign → codesign 스킵 (수동 후처리 필요)"
        ;;
    adhoc)
        # ad-hoc 사인: 로컬 실행 가능, 배포 시 Gatekeeper 차단 (사용자가 우클릭 → 열기).
        # 로컬 테스트에서도 com.apple.security.network.client/server entitlement 를
        # 포함해 iOS↔Mac Relay 동작 조건이 배포 빌드와 달라지지 않게 유지한다.
        if [ -f "$ENTITLEMENTS_SRC" ]; then
            codesign --force --deep \
                --sign - \
                --entitlements "$ENTITLEMENTS_SRC" \
                --no-strict \
                "$APP_BUNDLE"
            echo "  ✓ ad-hoc 사인 완료 + entitlements 포함 (로컬 실행용)"
        else
            codesign --force --deep --sign - --no-strict "$APP_BUNDLE"
            echo "  ✓ ad-hoc 사인 완료 (entitlements 파일 없음)"
        fi
        ;;
    identity)
        if [ ! -f "$ENTITLEMENTS_SRC" ]; then
            echo "✗ entitlements 누락 (배포 사인 필요): $ENTITLEMENTS_SRC" >&2
            exit 1
        fi
        codesign --force --deep \
            --sign "$SIGN_IDENTITY" \
            --entitlements "$ENTITLEMENTS_SRC" \
            --options runtime \
            --no-strict \
            "$APP_BUNDLE"
        echo "  ✓ Developer ID 사인 완료 — '$SIGN_IDENTITY'"
        ;;
esac

# ===== Step 6: 검증 =====
echo "▶ Step 6: 검증"
if [ "$SIGN_MODE" != "none" ]; then
    codesign --verify --verbose --no-strict "$APP_BUNDLE" 2>&1 | sed 's/^/  /'
fi

# bundle 구조 sanity check.
EXPECTED=(
    "Contents/MacOS/$EXEC_NAME"
    "Contents/Info.plist"
)
for path in "${EXPECTED[@]}"; do
    if [ ! -e "$APP_BUNDLE/$path" ]; then
        echo "✗ bundle 구조 검증 실패: $path 누락" >&2
        exit 1
    fi
done

# Info.plist 핵심 키 확인.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)
BUNDLE_EXEC=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)
if [ "$BUNDLE_EXEC" != "$EXEC_NAME" ]; then
    echo "✗ Info.plist CFBundleExecutable ('$BUNDLE_EXEC') ≠ binary 이름 ('$EXEC_NAME')" >&2
    exit 1
fi

echo ""
echo "✅ $APP_NAME.app 빌드 완료"
echo "   경로  : $APP_BUNDLE"
echo "   크기  : $(du -sh "$APP_BUNDLE" | cut -f1)"
echo "   ID    : $BUNDLE_ID"
echo "   Exec  : $BUNDLE_EXEC"
echo "   사인  : $SIGN_MODE"
echo ""
echo "실행:"
echo "   open '$APP_BUNDLE'"
echo "설치:"
echo "   cp -R '$APP_BUNDLE' /Applications/"
