#!/usr/bin/env bash
# DarwinForge 앱을 .app 번들로 패키징한 뒤 open 명령으로 실행한다.
# `swift run`만으로는 macOS가 activation policy를 잡지 못해 윈도우가 가려질 수
# 있다. .app 번들 + Info.plist가 있어야 dock·메뉴·전면 활성화가 정상 동작.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/app/ui/DarwinForge"
APP_NAME="DarwinForge"
APP_PATH="$PKG/.build/$APP_NAME.app"

# 1) Rust 코어 + Vendor + Swift 빌드 (이미 되어 있으면 빠름)
echo "▶ Rust + Swift 빌드…"
bash "$ROOT/scripts/build-mac.sh" --swift >/dev/null

# 2) Swift binary 위치 확인
BIN="$PKG/.build/arm64-apple-macosx/debug/${APP_NAME}App"
if [[ ! -x "$BIN" ]]; then
    BIN="$PKG/.build/debug/${APP_NAME}App"
fi
[[ -x "$BIN" ]] || { echo "✗ binary 없음: $BIN" ; exit 1 ; }

# 3) .app 번들 layout
echo "▶ .app 번들 생성: $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$BIN" "$APP_PATH/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_PATH/Contents/MacOS/${APP_NAME}"

cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.bbikiming.darwinforge</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.7.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# 4) 정리: 이전 인스턴스 종료 후 open
echo "▶ 이전 인스턴스 종료"
pkill -x "${APP_NAME}" 2>/dev/null || true
pkill -x "${APP_NAME}App" 2>/dev/null || true

echo "▶ 앱 실행"
open -n "$APP_PATH"
echo "✓ DarwinForge 실행됨 — Dock 또는 ⌘Tab으로 확인"
echo "   PID: $(pgrep -x "${APP_NAME}" | head -1 || echo 'not yet')"
echo "   .app: $APP_PATH"
