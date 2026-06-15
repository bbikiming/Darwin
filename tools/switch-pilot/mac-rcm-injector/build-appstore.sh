#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
OUT_DIR="${REPO_DIR}/dist/switch-pilot/appstore"
PROJECT_PATH="${SCRIPT_DIR}/DarwinSwitchRCMInjector.xcodeproj"
SCHEME="DarwinSwitchRCMInjector"
ARCHIVE_PATH="${OUT_DIR}/DarwinSwitchRCMInjector.xcarchive"
EXPORT_PATH="${OUT_DIR}/export"
EXPORT_OPTIONS="${OUT_DIR}/ExportOptions.plist"
ICON_SOURCE="${SCRIPT_DIR}/assets/app-icon-source.png"
ROUNDED_ICON="${OUT_DIR}/AppIconRounded.png"
ICONSET="${OUT_DIR}/AppIcon.iconset"
ASSET_CATALOG="${SCRIPT_DIR}/Assets.xcassets"
APPICONSET="${ASSET_CATALOG}/AppIcon.appiconset"
RESOURCE_ICON="${SCRIPT_DIR}/build/AppIcon.icns"
TEAM_ID="${DARWIN_ASC_TEAM_ID:-JM4LJMU49Q}"
BUNDLE_ID="${DARWIN_ASC_BUNDLE_ID:-com.darwin.switch.rcminjector}"
VERSION="${DARWIN_ASC_VERSION:-1.0}"
BUILD_NUMBER="${DARWIN_ASC_BUILD_NUMBER:-4}"
UPLOAD="${DARWIN_ASC_UPLOAD:-0}"

usage() {
  cat <<'EOF'
Usage: build-appstore.sh [--upload]

Builds a Mac App Store archive/export package for Darwin Switch RCM Injector.

Environment for upload:
  If no App Store Connect CLI credential variables are set, --upload tries
  Xcode account based upload with xcodebuild -exportArchive.

  API key auth:
    ASC_API_KEY=<key id>
    ASC_API_ISSUER=<issuer id>
    ASC_API_KEY_PATH=/path/to/AuthKey_<key id>.p8   # optional if in default dirs
    ASC_APPLE_ID=<numeric app Apple ID>             # required for --upload-package

  Apple ID app-password auth:
    ASC_USERNAME=<apple id email>
    ASC_APP_PASSWORD=<app-specific password or @keychain:item>
    ASC_PROVIDER_PUBLIC_ID=<provider public id>
    ASC_APPLE_ID=<numeric app Apple ID>

Overrides:
  DARWIN_ASC_TEAM_ID=JM4LJMU49Q
  DARWIN_ASC_BUNDLE_ID=com.darwin.switch.rcminjector
  DARWIN_ASC_VERSION=1.0
  DARWIN_ASC_BUILD_NUMBER=4

Without --upload, this script stops after archive/export.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --upload)
      UPLOAD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v xcodegen >/dev/null 2>&1 || {
  echo "ERROR: xcodegen is required. Install it with 'brew install xcodegen'." >&2
  exit 2
}

command -v xcodebuild >/dev/null 2>&1 || {
  echo "ERROR: xcodebuild is required." >&2
  exit 2
}

command -v xcrun >/dev/null 2>&1 || {
  echo "ERROR: xcrun is required." >&2
  exit 2
}

mkdir -p "${OUT_DIR}" "${SCRIPT_DIR}/build"

python3 - "${SCRIPT_DIR}/Info.plist" "${SCRIPT_DIR}/project.yml" "${VERSION}" "${BUILD_NUMBER}" <<'PY'
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

info_path = Path(sys.argv[1])
project_path = Path(sys.argv[2])
version = sys.argv[3]
build_number = sys.argv[4]

info = plistlib.loads(info_path.read_bytes())
info["CFBundleShortVersionString"] = version
info["CFBundleVersion"] = build_number
info_path.write_bytes(plistlib.dumps(info, sort_keys=False))

text = project_path.read_text(encoding="utf-8")
text = re.sub(r'MARKETING_VERSION: "[^"]+"', f'MARKETING_VERSION: "{version}"', text)
text = re.sub(r'CURRENT_PROJECT_VERSION: "[^"]+"', f'CURRENT_PROJECT_VERSION: "{build_number}"', text)
project_path.write_text(text, encoding="utf-8")
PY

if [[ -f "${ICON_SOURCE}" ]]; then
  rm -rf "${ICONSET}" "${APPICONSET}"
  mkdir -p "${ICONSET}" "${APPICONSET}" "${ASSET_CATALOG}"
  python3 "${SCRIPT_DIR}/round-app-icon-source.py" "${ICON_SOURCE}" "${ROUNDED_ICON}" --size 1024 --radius-ratio 0.205
  cat > "${ASSET_CATALOG}/Contents.json" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF
  cat > "${APPICONSET}/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF
  sips -z 16 16 "${ROUNDED_ICON}" --out "${ICONSET}/icon_16x16.png" >/dev/null
  sips -z 32 32 "${ROUNDED_ICON}" --out "${ICONSET}/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "${ROUNDED_ICON}" --out "${ICONSET}/icon_32x32.png" >/dev/null
  sips -z 64 64 "${ROUNDED_ICON}" --out "${ICONSET}/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "${ROUNDED_ICON}" --out "${ICONSET}/icon_128x128.png" >/dev/null
  sips -z 256 256 "${ROUNDED_ICON}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "${ROUNDED_ICON}" --out "${ICONSET}/icon_256x256.png" >/dev/null
  sips -z 512 512 "${ROUNDED_ICON}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "${ROUNDED_ICON}" --out "${ICONSET}/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "${ROUNDED_ICON}" --out "${ICONSET}/icon_512x512@2x.png" >/dev/null
  cp "${ICONSET}"/*.png "${APPICONSET}/"
  iconutil -c icns "${ICONSET}" -o "${RESOURCE_ICON}"
  rm -rf "${ICONSET}"
else
  python3 "${SCRIPT_DIR}/generate-app-icon.py" "${ICONSET}"
  iconutil -c icns "${ICONSET}" -o "${RESOURCE_ICON}"
  rm -rf "${ICONSET}"
fi

xcodegen generate --spec "${SCRIPT_DIR}/project.yml" --project "${SCRIPT_DIR}"

rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}"

xcodebuild archive \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "${ARCHIVE_PATH}" \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  -allowProvisioningUpdates

cat > "${EXPORT_OPTIONS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>export</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_PATH}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -allowProvisioningUpdates

PACKAGE="$(find "${EXPORT_PATH}" -maxdepth 1 -type f \( -name '*.pkg' -o -name '*.ipa' \) -print | head -n 1)"
if [[ -z "${PACKAGE}" ]]; then
  echo "ERROR: no exported package was produced under ${EXPORT_PATH}" >&2
  exit 2
fi

echo "Exported package:"
echo "  ${PACKAGE}"

if [[ "${UPLOAD}" != "1" ]]; then
  echo "Upload skipped. Re-run with --upload after App Store Connect credentials and app Apple ID are available."
  exit 0
fi

if [[ -n "${ASC_API_KEY:-}" && -n "${ASC_API_ISSUER:-}" ]]; then
  [[ -n "${ASC_APPLE_ID:-}" ]] || {
    echo "ERROR: ASC_APPLE_ID is required for altool --upload-package." >&2
    exit 2
  }
  ALTOOL_ARGS=(
    --upload-package "${PACKAGE}"
    --platform macos
    --apple-id "${ASC_APPLE_ID}"
    --bundle-version "${BUILD_NUMBER}"
    --bundle-short-version-string "${VERSION}"
    --bundle-id "${BUNDLE_ID}"
    --api-key "${ASC_API_KEY}"
    --api-issuer "${ASC_API_ISSUER}"
    --show-progress
    --output-format json
  )
  if [[ -n "${ASC_API_KEY_PATH:-}" ]]; then
    ALTOOL_ARGS+=(--p8-file-path "${ASC_API_KEY_PATH}")
  fi
  xcrun altool "${ALTOOL_ARGS[@]}"
elif [[ -n "${ASC_USERNAME:-}" && -n "${ASC_APP_PASSWORD:-}" && -n "${ASC_PROVIDER_PUBLIC_ID:-}" ]]; then
  [[ -n "${ASC_APPLE_ID:-}" ]] || {
    echo "ERROR: ASC_APPLE_ID is required for altool --upload-package." >&2
    exit 2
  }
  xcrun altool \
    --upload-package "${PACKAGE}" \
    --platform macos \
    --apple-id "${ASC_APPLE_ID}" \
    --bundle-version "${BUILD_NUMBER}" \
    --bundle-short-version-string "${VERSION}" \
    --bundle-id "${BUNDLE_ID}" \
    --username "${ASC_USERNAME}" \
    --password "${ASC_APP_PASSWORD}" \
    --provider-public-id "${ASC_PROVIDER_PUBLIC_ID}" \
    --show-progress \
    --output-format json
else
  UPLOAD_OPTIONS="${OUT_DIR}/ExportOptionsUpload.plist"
  cat > "${UPLOAD_OPTIONS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
EOF

  echo "No App Store Connect CLI credentials were provided."
  echo "Trying Xcode account upload with xcodebuild -exportArchive..."
  xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportOptionsPlist "${UPLOAD_OPTIONS}" \
    -allowProvisioningUpdates
fi
