#!/usr/bin/env bash
# V297-10 — DarwinForge .xcarchive → App Store Connect 또는 Developer ID DMG.
#
# # 사용 시나리오
#
#   ## App Store Connect (Mac App Store) 업로드
#
#     bash scripts/upload-app.sh \
#          --archive dist/DarwinForge-1.23.0-3ac17d9.xcarchive \
#          --method app-store \
#          --team-id ABCDE12345 \
#          --apple-id you@example.com \
#          --app-specific-password "xxxx-xxxx-xxxx-xxxx"
#
#   ## Developer ID notarized DMG 배포
#
#     bash scripts/upload-app.sh \
#          --archive dist/DarwinForge-1.23.0-3ac17d9.xcarchive \
#          --method developer-id \
#          --team-id ABCDE12345 \
#          --apple-id you@example.com \
#          --app-specific-password "xxxx-xxxx-xxxx-xxxx"
#
# # 흐름
#
#   ## App Store path
#     1. .xcarchive 의 .app 추출.
#     2. productbuild --component DarwinForge.app /Applications \
#                     --sign "3rd Party Mac Developer Installer" \
#                     DarwinForge.pkg
#     3. xcrun altool --upload-app --type macos -f DarwinForge.pkg \
#                     --apple-id <ID> --password <APP_PASSWORD>
#     4. → App Store Connect 에 자동 등록. TestFlight 또는 Production 빌드 분배 후속.
#
#   ## Developer ID path
#     1. .xcarchive 에서 .app 추출 후 ZIP.
#     2. xcrun notarytool submit ZIP --apple-id <ID> --password <APP_PASSWORD> \
#                       --team-id <TEAM_ID> --wait
#     3. xcrun stapler staple DarwinForge.app — notarization 티켓 부착.
#     4. hdiutil 로 DMG 생성 (사용자 다운로드용).
#
# # 의존성
#   xcrun (Xcode CLT), productbuild, altool / notarytool, stapler, hdiutil
#
# # Apple ID + App-Specific Password
#   - https://appleid.apple.com → 보안 → 앱-특정 암호 → 새로 생성.
#   - Apple ID 2FA 활성화 필수.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"

ARCHIVE_PATH=""
METHOD="app-store"
TEAM_ID=""
APPLE_ID=""
APP_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) ARCHIVE_PATH="$2"; shift 2 ;;
        --method) METHOD="$2"; shift 2 ;;
        --team-id) TEAM_ID="$2"; shift 2 ;;
        --apple-id) APPLE_ID="$2"; shift 2 ;;
        --app-specific-password) APP_PASSWORD="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//' ; exit 0 ;;
        *) echo "Unknown arg: $1" >&2 ; exit 64 ;;
    esac
done

# 검증.
[[ -z "$ARCHIVE_PATH" ]] && { echo "✗ --archive 필수" >&2 ; exit 1 ; }
[[ -d "$ARCHIVE_PATH" ]] || { echo "✗ archive 경로 없음: $ARCHIVE_PATH" >&2 ; exit 1 ; }
[[ -z "$TEAM_ID" ]] && { echo "✗ --team-id 필수" >&2 ; exit 1 ; }
[[ -z "$APPLE_ID" ]] && { echo "✗ --apple-id 필수" >&2 ; exit 1 ; }
[[ -z "$APP_PASSWORD" ]] && { echo "✗ --app-specific-password 필수" >&2 ; exit 1 ; }

APP_PATH="$ARCHIVE_PATH/Products/Applications/DarwinForge.app"
[[ -d "$APP_PATH" ]] || { echo "✗ .app 누락: $APP_PATH" >&2 ; exit 1 ; }

PLIST="$APP_PATH/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"

echo "▶ Upload preflight"
echo "   Archive: $ARCHIVE_PATH"
echo "   App    : $APP_PATH"
echo "   Bundle : $BUNDLE_ID  v${VERSION} (build $BUILD_NUM)"
echo "   Team   : $TEAM_ID"
echo "   Method : $METHOD"

case "$METHOD" in
    app-store)
        # ===== Mac App Store 업로드 =====
        PKG_PATH="$DIST_DIR/DarwinForge-${VERSION}-${BUILD_NUM}.pkg"

        echo "▶ Step 1: productbuild → .pkg"
        productbuild \
            --component "$APP_PATH" /Applications \
            --sign "3rd Party Mac Developer Installer" \
            "$PKG_PATH"
        echo "   ✓ $PKG_PATH ($(du -sh "$PKG_PATH" | cut -f1))"

        echo "▶ Step 2: altool 업로드 → App Store Connect"
        # macOS 14+/Xcode 16 altool: --apple-id/--password 는 deprecated.
        # 신규: --username/--app-password (+ --team-id 는 그대로).
        # V297-13: 사용자 Apple ID 가 multiple providers 에 attach 시 라우팅 모호.
        # PROVIDER_PUBLIC_ID 환경변수로 명시. 미설정 시 altool 가 single-provider
        # 가정 (잘못된 team 으로 라우팅될 위험).
        PROVIDER_ARG=()
        if [[ -n "${PROVIDER_PUBLIC_ID:-}" ]]; then
            PROVIDER_ARG=(--asc-public-id "$PROVIDER_PUBLIC_ID")
        fi
        # `${arr[@]+...}` — set -u 하 empty array expansion 안전 패턴.
        if ! xcrun altool --upload-app \
            --type macos \
            --file "$PKG_PATH" \
            --username "$APPLE_ID" \
            --app-password "$APP_PASSWORD" \
            --team-id "$TEAM_ID" \
            ${PROVIDER_ARG[@]+"${PROVIDER_ARG[@]}"}; then
            echo ""
            echo "✗ altool 업로드 실패 — 위 에러 메시지 확인 후 archive-app.sh 재실행"
            exit 1
        fi

        echo ""
        echo "✅ App Store Connect 업로드 완료"
        echo "   App Store Connect → My Apps → DarwinForge → TestFlight 빌드 확인"
        echo "   (대개 5-15분 후 \"Processing\" 완료 → 사용 가능)"
        ;;

    developer-id)
        # ===== Developer ID notarized + DMG =====
        STAGING="$DIST_DIR/notarize-staging"
        ZIP_PATH="$DIST_DIR/DarwinForge-${VERSION}-${BUILD_NUM}-notarize.zip"
        DMG_PATH="$DIST_DIR/DarwinForge-${VERSION}-${BUILD_NUM}.dmg"

        echo "▶ Step 1: .app → ZIP (notarize 입력)"
        rm -rf "$STAGING"
        mkdir -p "$STAGING"
        cp -R "$APP_PATH" "$STAGING/"
        (cd "$STAGING" && ditto -c -k --keepParent DarwinForge.app "$ZIP_PATH")

        echo "▶ Step 2: notarytool submit (대기)"
        xcrun notarytool submit "$ZIP_PATH" \
            --apple-id "$APPLE_ID" \
            --password "$APP_PASSWORD" \
            --team-id "$TEAM_ID" \
            --wait

        echo "▶ Step 3: stapler — notarization ticket 부착"
        xcrun stapler staple "$APP_PATH"
        xcrun stapler validate "$APP_PATH"

        echo "▶ Step 4: DMG 생성"
        hdiutil create -volname "DarwinForge ${VERSION}" \
            -srcfolder "$APP_PATH" \
            -ov -format UDZO \
            "$DMG_PATH"

        echo ""
        echo "✅ Developer ID notarized DMG 완료"
        echo "   경로: $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
        echo "   사용자: 다운로드 후 더블클릭 → /Applications 으로 드래그"
        ;;

    *)
        echo "✗ --method 는 'app-store' 또는 'developer-id'" >&2
        exit 1
        ;;
esac
