#!/usr/bin/env bash
# DarwinForge 정식 설치 — 빌드 → 정규 식별자 → 실서명 → /Applications 설치 → 실행.
#
# 왜 (2026-06-12 실기 F9): dev 번들은 ad-hoc 서명 + com.bbikiming.darwinforge 식별자라
# 재빌드할 때마다 macOS TCC(로컬 네트워크 등) 권한이 무효화되고, 기존 허용은
# com.yuseokkim.darwinforge 에 묶여 있어 dev 번들의 모든 로봇 연결이 조용히 차단됐다.
# 이 스크립트는 ① 식별자를 정규(com.yuseokkim.darwinforge)로 통일, ② 실제 개발자
# identity 로 서명(DR 이 팀 anchored → 재빌드해도 권한 유지), ③ entitlements
# (마이크/음성) 보존, ④ /Applications 설치까지 한 번에 처리한다.
#
# 사용: bash scripts/install-app-signed.sh [서명 identity]
#   identity 생략 시 keychain 의 첫 "Apple Development" identity 자동 선택.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/app/ui/DarwinForge"
APP_NAME="DarwinForge"
DEV_APP="$PKG/.build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
BUNDLE_ID="com.yuseokkim.darwinforge"
# 실기 F9: 공증용(DarwinForge.entitlements)은 app-sandbox=true — 로컬 설치에 부착하면
# ssh 키 접근·Application Support 가 차단돼 연결이 전면 불능. 로컬은 dev entitlements.
ENTITLEMENTS="$PKG/Sources/DarwinForgeApp/DarwinForge.dev.entitlements"

# 0) 서명 identity 결정.
IDENTITY="${1:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Apple Development' | head -1 | sed 's/.*"\(.*\)"/\1/')"
fi
if [[ -z "$IDENTITY" ]]; then
    echo "✗ 서명 identity 없음 — ad-hoc 으론 재빌드마다 TCC 권한이 풀립니다." >&2
    exit 1
fi
echo "▶ 서명 identity: $IDENTITY"

# 1) 빌드 + 번들 패키징 (run-app.sh 재사용 — 마지막에 dev 인스턴스가 열리므로 종료).
bash "$ROOT/scripts/run-app.sh"
sleep 2
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

# 2) 서명 가능 형태로 정리 — 번들 루트의 미봉인 리소스 제거(Contents/Resources 사본은
#    run-app.sh 가 이미 복사; SafeResourceBundle/Bundle.module 모두 그쪽을 읽는다).
rm -rf "$DEV_APP"/*.bundle

# 3) 정규 식별자.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    "$DEV_APP/Contents/Info.plist"

# 4) 실서명 (+ entitlements — 마이크/음성 TCC 는 서명에 entitlements 가 붙어야 동작).
if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --deep --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$DEV_APP"
else
    echo "⚠︎ entitlements 없음 — 마이크/음성 기능이 크래시할 수 있음"
    codesign --force --deep --sign "$IDENTITY" "$DEV_APP"
fi
codesign --verify --deep --strict "$DEV_APP"
echo "▶ 서명 검증 OK ($(codesign -dv "$DEV_APP" 2>&1 | grep TeamIdentifier))"

# 5) 설치 (+1회 백업) 후 실행.
if [[ -d "$DEST" ]] && [[ ! -d "$DEST.backup-auto" ]]; then
    mv "$DEST" "$DEST.backup-auto"
    echo "▶ 기존 설치본 백업: $DEST.backup-auto"
else
    rm -rf "$DEST"
fi
ditto "$DEV_APP" "$DEST"
echo "▶ 설치: $DEST"
open "$DEST"
echo "✓ 설치·실행 완료 — 첫 연결 시 '로컬 네트워크' 권한 팝업이 뜨면 허용하세요."
