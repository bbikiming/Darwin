#!/usr/bin/env bash
# V297-10 — DarwinForge.xcarchive 직접 어셈블 (SwiftPM only).
#
# Xcode wrapper 없이 swift build 결과 + Info.plist + dSYM 으로 .xcarchive 구조를
# 직접 만든다. `xcrun altool --upload-app` / `xcodebuild -exportArchive` 양쪽 모두
# 이 .xcarchive 를 수락한다 (Apple 의 .xcarchive 는 단순 디렉토리 + Info.plist).
#
# # 흐름
#
#   1. Rust core 빌드 (build-mac.sh 위임, skip 가능).
#   2. swift build -c release -Xswiftc -g (debug info 포함).
#   3. .app bundle 어셈블 (build-app.sh 위임, codesign 단계는 우리가 재실행).
#   4. **distribution 용 codesign** — "Apple Distribution" (App Store) 또는
#      "Developer ID Application" (notarization).
#   5. dSYM 추출 + .xcarchive 구조 어셈블.
#   6. Info.plist (ArchiveInfo) 생성.
#
# # Usage
#
#   bash scripts/archive-app.sh --method app-store \
#        --team-id ABCDE12345 \
#        --signing-identity "Apple Distribution: My Org (ABCDE12345)"
#
#   bash scripts/archive-app.sh --method developer-id \
#        --team-id ABCDE12345 \
#        --signing-identity "Developer ID Application: My Org (ABCDE12345)"
#
# # 산출
#
#   $REPO/dist/DarwinForge-{version}-{build}.xcarchive
#
# # 의존성
#
#   xcode-select, swift 5.10+, codesign, plutil, /usr/libexec/PlistBuddy
#
# # 참고
#
#   docs/deploy/APP_STORE_CONNECT_GUIDE.md 의 step-by-step.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_ROOT="$REPO_ROOT/app/ui/DarwinForge"
APP_NAME="DarwinForge"
EXEC_NAME="DarwinForgeApp"
BUILD_DIR="$PKG_ROOT/.build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DIST_DIR="$REPO_ROOT/dist"

METHOD="app-store"
TEAM_ID=""
SIGNING_IDENTITY=""
SKIP_RUST=0

# arg parse
while [[ $# -gt 0 ]]; do
    case "$1" in
        --method) METHOD="$2"; shift 2 ;;
        --team-id) TEAM_ID="$2"; shift 2 ;;
        --signing-identity) SIGNING_IDENTITY="$2"; shift 2 ;;
        --skip-rust) SKIP_RUST=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//' ; exit 0 ;;
        *) echo "Unknown arg: $1" >&2 ; exit 64 ;;
    esac
done

if [[ -z "$TEAM_ID" ]]; then
    echo "✗ --team-id 필수 (예: ABCDE12345 — Apple Developer Account → Membership)" >&2
    exit 1
fi

# method 별 entitlements 자동 선택.
case "$METHOD" in
    app-store)
        ENT_FILE="$PKG_ROOT/Sources/DarwinForgeApp/DarwinForge-AppStore.entitlements"
        if [[ -z "$SIGNING_IDENTITY" ]]; then
            SIGNING_IDENTITY="Apple Distribution"
        fi
        ;;
    developer-id)
        ENT_FILE="$PKG_ROOT/Sources/DarwinForgeApp/DarwinForge-DevID.entitlements"
        if [[ -z "$SIGNING_IDENTITY" ]]; then
            SIGNING_IDENTITY="Developer ID Application"
        fi
        ;;
    *)
        echo "✗ --method 는 'app-store' 또는 'developer-id' (받음: $METHOD)" >&2
        exit 1
        ;;
esac

if [[ ! -f "$ENT_FILE" ]]; then
    echo "✗ entitlements 파일 없음: $ENT_FILE" >&2
    exit 1
fi

# ===== Step 0.5: CFBundleVersion 자동 bump (App Store 업로드 요건) =====
# App Store Connect 는 동일/이하 build number 재업로드를 거부한다. 1차 반려 빌드 =
# 579, source Info.plist 기본값 = 2 → 자동화 없으면 업로드 거부 재발. git commit
# count 기반(단조 증가) + offset 600 으로 579 추월 보장. build-app.sh 가 이 source
# Info.plist 를 .app 으로 복사(build-app.sh:89·133)하므로 호출 *이전*에 bump.
INFO_SRC="$PKG_ROOT/Sources/DarwinForgeApp/Info.plist"
GIT_COUNT="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
NEW_BUILD=$((GIT_COUNT + 600))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_SRC"
echo "▶ Step 0.5: CFBundleVersion → $NEW_BUILD (git count $GIT_COUNT + 600, 반려 579 추월)"

echo "▶ Step 1: build-app.sh 실행 — .app bundle 어셈블"
SKIP_FLAG=""
[[ "$SKIP_RUST" -eq 1 ]] && SKIP_FLAG="--skip-rust"
bash "$REPO_ROOT/scripts/build-app.sh" $SKIP_FLAG --no-sign

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "✗ .app bundle 누락: $APP_BUNDLE" >&2
    exit 1
fi

# ===== Step 1.2: SwiftPM resource bundle 의 Info.plist 에 CFBundleIdentifier 주입 =====
# SwiftPM 가 생성한 resource bundle Info.plist 는 CFBundleDevelopmentRegion 만 있고
# CFBundleIdentifier / CFBundleName / CFBundlePackageType 누락. App Store 검증 거부
# (-19241 Missing Bundle Identifier). 각 bundle 의 Info.plist 보강.
echo "▶ Step 1.2: SwiftPM resource bundle Info.plist 보강"
MAIN_BUNDLE_ID="com.robotis.darwinforge"
for B in "$APP_BUNDLE"/Contents/Resources/*.bundle; do
    [[ -d "$B" ]] || continue
    BNAME=$(basename "$B" .bundle)
    BPLIST="$B/Info.plist"
    # 일부 SwiftPM 버전은 Info.plist 를 Contents/ 안에 둠 — 둘 다 처리.
    [[ -f "$BPLIST" ]] || BPLIST="$B/Contents/Info.plist"
    [[ -f "$BPLIST" ]] || continue

    # SwiftPM convention: bundle name = <PackageName>_<TargetName>.
    # App Store bundle id 는 underscore 거부 → target 부분만 추출 + 비-영숫자 제거.
    # 예: DarwinForge_DarwinForgeApp → DarwinForgeApp.
    TARGET="${BNAME##*_}"
    SUB_ID="${MAIN_BUNDLE_ID}.${TARGET}"
    # CFBundleIdentifier 추가 또는 Set.
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $SUB_ID" "$BPLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SUB_ID" "$BPLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string $BNAME" "$BPLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CFBundleName $BNAME" "$BPLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string BNDL" "$BPLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CFBundlePackageType BNDL" "$BPLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0" "$BPLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$BPLIST" 2>/dev/null || true
    echo "   ✓ $BNAME → $SUB_ID"
done

# ===== Step 1.3: .app root 의 misplaced bundle 정리 =====
# build-app.sh 가 SwiftPM resource bundle 을 .app root + .app/Contents/Resources 양쪽에
# 복사 (legacy compat). codesign 은 root 의 sub-bundle 을 "unsealed contents" 로 거부 →
# Apple Distribution sign 실패. root 사본 제거 (Contents/Resources/ 본체는 유지).
echo "▶ Step 1.3: .app root 의 misplaced bundle 정리 (codesign 호환)"
find "$APP_BUNDLE" -maxdepth 1 -name '*.bundle' -type d | while read -r STRAY; do
    echo "   - 제거: $(basename "$STRAY")"
    rm -rf "$STRAY"
done

# ===== Step 1.5: Provisioning Profile embed (App Store 만 필수) =====
if [[ "$METHOD" == "app-store" ]]; then
    PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
    if [[ -d "$PROFILE_DIR" ]]; then
        # bundle id 매칭 + macOS 플랫폼 인 profile 자동 검색.
        FOUND_PROFILE=""
        # ls 가 file 이름 base 만 줄 수 있어 full path 로 처리.
        while IFS= read -r -d '' PP; do
            TMP=$(mktemp -t pp.plist)
            if security cms -D -i "$PP" -o "$TMP" 2>/dev/null; then
                # 키 이름이 'com.apple.application-identifier' — full key name 필수.
                APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$TMP" 2>/dev/null || true)
                PLAT=$(/usr/libexec/PlistBuddy -c "Print :Platform:0" "$TMP" 2>/dev/null || true)
                if [[ "$APP_ID" == *"com.robotis.darwinforge"* && "$PLAT" == "OSX" ]]; then
                    FOUND_PROFILE="$PP"
                    rm -f "$TMP"
                    break
                fi
            fi
            rm -f "$TMP"
        done < <(find "$PROFILE_DIR" -name '*.provisionprofile' -print0)

        if [[ -n "$FOUND_PROFILE" ]]; then
            cp "$FOUND_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
            echo "  ✓ embedded.provisionprofile : $(basename "$FOUND_PROFILE")"
        else
            echo "  ⚠ Provisioning Profile (com.robotis.darwinforge / OSX) 못 찾음 — App Store 업로드 시 거절 위험" >&2
        fi
    else
        echo "  ⚠ $PROFILE_DIR 디렉토리 없음" >&2
    fi
fi

# ===== Step 1.7: Quarantine + 모든 extended attribute 제거 =====
# V297-14 (Apple ITMS-91109 reject): provisioning profile 을 ~/Downloads/ 에서 가져오면
# macOS 가 com.apple.quarantine 자동 부착. 그 상태로 codesign 해도 attr 잔존 →
# App Store reject ("Invalid package contents").
#
# 다른 자산 (icons, resource bundles) 도 다운로드 경유면 동일 위험. `.app/` 전체에
# `xattr -cr` (clear, recursive) 로 모든 extended attribute 제거 후 codesign 진행.
# codesign 가 만드는 metadata (com.apple.cs.CodeSignature 등) 는 codesign 단계에서
# 다시 부착되므로 제거해도 안전.
echo "▶ Step 1.7: 확장 속성 (quarantine 등) 전체 제거 → App Store 호환"
xattr -cr "$APP_BUNDLE" 2>&1 | head -3 || true
# 검증 — quarantine 잔존 여부.
QUAR_COUNT=$(find "$APP_BUNDLE" -exec xattr {} \; 2>/dev/null | grep -c "com.apple.quarantine" || true)
if [[ "$QUAR_COUNT" -gt 0 ]]; then
    echo "  ⚠ quarantine 잔존 $QUAR_COUNT 파일 — 강제 재제거" >&2
    find "$APP_BUNDLE" -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true
fi
echo "  ✓ extended attributes 모두 제거됨"

# ===== Step 2: Distribution 용 codesign 재실행 =====
# Apple 공식 codesign 절차: nested content 부터 inside-out 으로 sign.
# 종전엔 .framework / .bundle 만 처리해 `unsealed contents` 경고. 모든 위치
# (Frameworks, PlugIns, Helpers, Resources 의 모든 sub-bundle) 를 깊이 우선 처리.
echo "▶ Step 2: Distribution codesign 재실행 ($SIGNING_IDENTITY)"

# Apple "Distributing your app" 가이드: bottom-up.
#   1. dylibs / executables → 2. frameworks → 3. nested .app/.appex → 4. main .app
# find ... -depth 가 deepest first 보장.
find "$APP_BUNDLE" \( \
        -name '*.dylib' -o \
        -name '*.framework' -o \
        -name '*.bundle' -o \
        -name '*.appex' -o \
        -name '*.app' \
    \) -depth | while read -r ITEM; do
    # main .app 자체는 마지막에 별도 sign — skip.
    if [[ "$ITEM" == "$APP_BUNDLE" ]]; then continue; fi
    codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$ITEM" 2>&1 | grep -v "replacing existing signature" || true
done

# main executable sign with entitlements + hardened runtime + preserve-metadata.
codesign --force --options runtime --timestamp \
    --entitlements "$ENT_FILE" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"

# 검증 — App Store 는 deep + strict 모두 통과해야.
echo "  검증:"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'
# spctl 은 ad-hoc / dev signing 시 reject 정상 — Apple Distribution 은 accepted 여야.
spctl --assess --type execute --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /' || true

# ===== Step 3: 메타데이터 추출 =====
PLIST="$APP_BUNDLE/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

echo "  ✓ Bundle ID: $BUNDLE_ID"
echo "  ✓ Version  : $VERSION (build $BUILD_NUM)"
echo "  ✓ Team ID  : $TEAM_ID"

# ===== Step 4: .xcarchive 어셈블 =====
echo "▶ Step 3: .xcarchive 어셈블"

mkdir -p "$DIST_DIR"
ARCHIVE_NAME="${APP_NAME}-${VERSION}-${BUILD_NUM}.xcarchive"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"

# 기존 archive 삭제 + 새로 구조 생성.
rm -rf "$ARCHIVE_PATH"
mkdir -p "$ARCHIVE_PATH/Products/Applications"
mkdir -p "$ARCHIVE_PATH/dSYMs"

# .app 복사.
cp -R "$APP_BUNDLE" "$ARCHIVE_PATH/Products/Applications/"

# dSYM 추출 — swift build -Xswiftc -g 로 생성된 debug 정보가 binary 안에 embedded.
# `dsymutil` 로 분리. 누락돼도 archive 자체는 유효.
DSYM_PATH="$ARCHIVE_PATH/dSYMs/${EXEC_NAME}.app.dSYM"
if command -v dsymutil >/dev/null 2>&1; then
    dsymutil "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME" -o "$DSYM_PATH" 2>/dev/null || \
        echo "  ⚠ dsymutil 실패 (Symbol upload 안 됨, archive 자체는 유효)"
fi

# ===== Step 5: Archive Info.plist 작성 =====
ARCHIVE_INFO="$ARCHIVE_PATH/Info.plist"
CREATION_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cat > "$ARCHIVE_INFO" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ApplicationProperties</key>
    <dict>
        <key>ApplicationPath</key>
        <string>Applications/${APP_NAME}.app</string>
        <key>CFBundleIdentifier</key>
        <string>${BUNDLE_ID}</string>
        <key>CFBundleShortVersionString</key>
        <string>${VERSION}</string>
        <key>CFBundleVersion</key>
        <string>${BUILD_NUM}</string>
        <key>SigningIdentity</key>
        <string>${SIGNING_IDENTITY}</string>
        <key>Team</key>
        <string>${TEAM_ID}</string>
    </dict>
    <key>ArchiveVersion</key>
    <integer>2</integer>
    <key>CreationDate</key>
    <date>${CREATION_DATE}</date>
    <key>Name</key>
    <string>${APP_NAME}</string>
    <key>SchemeName</key>
    <string>${EXEC_NAME}</string>
</dict>
</plist>
EOF

echo ""
echo "▶ Step 4: 스모크 테스트 — archive 의 .app 을 분리 위치에서 직접 launch"
# V297-11 CRASH FIX 회귀 차단. archive 의 .app 을 .build / dist 외 분리 위치에서
# 실행해 첫 화면 렌더링 후 fatalError 없이 정상 launch 되는지 확인. Bundle.module
# 의 resource bundle lookup 이 모든 environment 에서 동작하는지 검증.
SMOKE_DIR="/tmp/DarwinForge-smoke-$$"
mkdir -p "$SMOKE_DIR"
cp -R "$ARCHIVE_PATH/Products/Applications/DarwinForge.app" "$SMOKE_DIR/"
SMOKE_APP="$SMOKE_DIR/DarwinForge.app"

# launch — 별도 instance + background.
open -n -j -g "$SMOKE_APP" 2>/dev/null || true
sleep 5

# living 인지 확인 — fatalError 시 즉시 종료됐을 것.
PROC_COUNT=$(pgrep -f "$SMOKE_APP/Contents/MacOS/DarwinForgeApp" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$PROC_COUNT" -gt 0 ]]; then
    echo "  ✓ 스모크 테스트 통과 — 5초 launch 후 살아있음 (PID 개수=$PROC_COUNT)"
    pkill -TERM -f "$SMOKE_APP/Contents/MacOS/DarwinForgeApp" 2>/dev/null || true
    sleep 1
    pkill -KILL -f "$SMOKE_APP/Contents/MacOS/DarwinForgeApp" 2>/dev/null || true
else
    echo "  ✗ 스모크 테스트 실패 — 5초 내 종료. fatalError 또는 crash 의심."
    echo "    Crash log: ~/Library/Logs/DiagnosticReports/DarwinForge* 확인"
    rm -rf "$SMOKE_DIR"
    exit 2
fi
rm -rf "$SMOKE_DIR"

echo ""
echo "✅ Archive 어셈블 완료"
echo "   경로     : $ARCHIVE_PATH"
echo "   크기     : $(du -sh "$ARCHIVE_PATH" | cut -f1)"
echo "   Bundle ID: $BUNDLE_ID"
echo "   Version  : $VERSION (build $BUILD_NUM)"
echo "   Method   : $METHOD"
echo "   Signing  : $SIGNING_IDENTITY"
echo ""
echo "다음 단계 (export + 업로드):"
echo "   bash scripts/upload-app.sh --archive '$ARCHIVE_PATH' --method $METHOD --team-id $TEAM_ID"
