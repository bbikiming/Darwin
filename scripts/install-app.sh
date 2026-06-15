#!/usr/bin/env bash
# DarwinForge.app 빌드 + /Applications 설치.
#
# 동작:
#   1. build-app.sh 를 호출해 release binary + .app bundle 생성
#      (source plist 그대로 복사 — bundle id / version 하드코딩 없음).
#   2. .build/release/DarwinForge.app 을 /Applications 으로 rsync.
#   3. LaunchServices DB 갱신 + open.
#
# 의존성: swift 6+, iconutil, sips (macOS 기본).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_ROOT="$REPO_ROOT/app/ui/DarwinForge"
APP_NAME="DarwinForge"
DEST_DIR="/Applications"
BUILD_DIR="$PKG_ROOT/.build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# ===== Step 1: build-app.sh 위임 =====
echo "▶ build-app.sh 호출..."
bash "$REPO_ROOT/scripts/build-app.sh" "$@"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: .app bundle 없음 — $APP_BUNDLE" >&2
    exit 1
fi

# ===== Step 2: source plist 키 확인 (검증) =====
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)"

echo "  ✓ CFBundleIdentifier        : $BUNDLE_ID"
echo "  ✓ CFBundleShortVersionString: $VERSION"
echo "  ✓ CFBundleVersion (build)   : $BUILD_NUM"

# ===== Step 3: /Applications 설치 =====
echo "▶ /Applications/$APP_NAME.app 설치..."
if [ -d "$DEST_DIR/$APP_NAME.app" ]; then
    BACKUP="$DEST_DIR/$APP_NAME.app.backup-$(date +%Y%m%d-%H%M%S)"
    mv "$DEST_DIR/$APP_NAME.app" "$BACKUP"
    echo "  기존 버전 backup: $BACKUP"
fi
cp -R "$APP_BUNDLE" "$DEST_DIR/"

# macOS Quarantine 제거.
xattr -dr com.apple.quarantine "$DEST_DIR/$APP_NAME.app" 2>/dev/null || true

# Finder 가 새 아이콘 인식하도록 LaunchServices DB 갱신.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f "$DEST_DIR/$APP_NAME.app" 2>/dev/null || true

echo ""
echo "✅ 설치 완료: $DEST_DIR/$APP_NAME.app"
echo "   • 버전: $VERSION (build $BUILD_NUM)"
echo "   • Bundle ID: $BUNDLE_ID"
echo ""
echo "실행:"
echo "   open '$DEST_DIR/$APP_NAME.app'"
