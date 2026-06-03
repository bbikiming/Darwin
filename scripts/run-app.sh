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

# 3a) SwiftPM 리소스 번들 복사 — **로봇 메시 / 앱 아이콘 / 워드마크가 보이려면 필수**.
#     STLLoader·AppIcon 은 SafeResourceBundle 을 쓰는데, 이건 .app/Contents/Resources/
#     의 <module>.bundle 만 찾고 절대 .build 경로 폴백이 없다. 종전 run-app.sh 는
#     바이너리만 복사 → 메시·아이콘 미발견 → 로봇 안 보이고 아이콘이 코드생성 폴백으로
#     떨어지는 회귀(2026-06-04 확인). 번들을 표준 위치(Contents/Resources)와 .app 루트
#     (Bundle.module 의 SwiftPM dev 후보) 양쪽에 복사해 두 해석 경로 모두 충족.
BUILD_DIR="$(dirname "$BIN")"
shopt -s nullglob
RES_BUNDLES=("$BUILD_DIR"/*.bundle)
shopt -u nullglob
if (( ${#RES_BUNDLES[@]} == 0 )); then
    echo "⚠︎ 리소스 번들 없음: $BUILD_DIR/*.bundle — 메시/아이콘이 누락될 수 있음"
else
    for b in "${RES_BUNDLES[@]}"; do
        cp -R "$b" "$APP_PATH/Contents/Resources/"
        cp -R "$b" "$APP_PATH/"
    done
    echo "▶ 리소스 번들 ${#RES_BUNDLES[@]}개 복사 (메시/아이콘/워드마크)"
fi

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
    <string>1.11.2</string>
    <key>CFBundleVersion</key>
    <string>$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "dev")</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>원격 조종 화면에서 로봇의 제어 브리지와 8080 카메라 미리보기에 연결합니다.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>마이크 체크 / 음성 명령을 위해 마이크 접근이 필요합니다.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>캡처한 음성을 텍스트로 인식하기 위해 음성 인식 사용을 허용합니다.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

# 3b) ad-hoc 코드사인 + entitlements (audio-input 포함).
#     마이크/음성 인식은 TCC 가 usage description + 서명을 요구 — 미서명 시 권한
#     요청 순간 SIGABRT(TCC privacy violation)로 즉시 종료된다(2026-05-31 회귀).
ENTITLEMENTS="$PKG/Sources/DarwinForgeApp/DarwinForge.entitlements"
if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" --no-strict "$APP_PATH" \
        && echo "▶ ad-hoc 사인 + entitlements 첨부 완료"
else
    codesign --force --deep --sign - --no-strict "$APP_PATH" || true
    echo "⚠︎ entitlements 파일 없음 — 기본 서명만"
fi

# 4) 정리: 이전 인스턴스 종료 후 open
echo "▶ 이전 인스턴스 종료"
pkill -x "${APP_NAME}" 2>/dev/null || true
pkill -x "${APP_NAME}App" 2>/dev/null || true

echo "▶ 앱 실행"
open -n "$APP_PATH"
echo "✓ DarwinForge 실행됨 — Dock 또는 ⌘Tab으로 확인"
echo "   PID: $(pgrep -x "${APP_NAME}" | head -1 || echo 'not yet')"
echo "   .app: $APP_PATH"
