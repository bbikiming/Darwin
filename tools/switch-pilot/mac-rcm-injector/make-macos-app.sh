#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
OUT_DIR="${DARWIN_RCM_APP_OUT_DIR:-${REPO_DIR}/dist/switch-pilot}"
APP_PATH="${OUT_DIR}/Darwin Switch RCM Injector.app"
CONTENTS_DIR="${APP_PATH}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SOURCE="${SCRIPT_DIR}/DarwinSwitchRCMInjector.swift"
INFO_PLIST="${SCRIPT_DIR}/Info.plist"
INJECTOR_SCRIPT="${SCRIPT_DIR}/darwin-switch-rcm-inject.sh"
ICON_GENERATOR="${SCRIPT_DIR}/generate-app-icon.py"
ICON_ROUNDER="${SCRIPT_DIR}/round-app-icon-source.py"
ICON_SOURCE="${SCRIPT_DIR}/assets/app-icon-source.png"
ICONSET="${OUT_DIR}/AppIcon.iconset"
ICON_FILE="${RESOURCES_DIR}/AppIcon.icns"
EXECUTABLE="${MACOS_DIR}/DarwinSwitchRCMInjector"
ARCH="$(uname -m)"
SIGN_IDENTITY="${DARWIN_RCM_SIGN_IDENTITY:--}"
ENTITLEMENTS="${SCRIPT_DIR}/DarwinSwitchRCMInjector.entitlements"

command -v swiftc >/dev/null 2>&1 || {
  echo "ERROR: swiftc is required to build the native macOS app." >&2
  echo "Install Xcode Command Line Tools, then rerun this script." >&2
  exit 2
}

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required to generate the app icon." >&2
  exit 2
}

command -v iconutil >/dev/null 2>&1 || {
  echo "ERROR: iconutil is required to package the macOS app icon." >&2
  exit 2
}

command -v sips >/dev/null 2>&1 || {
  echo "ERROR: sips is required to crop and resize the macOS app icon." >&2
  exit 2
}

[[ -f "${SOURCE}" ]] || {
  echo "ERROR: missing Swift source: ${SOURCE}" >&2
  exit 2
}

[[ -f "${INFO_PLIST}" ]] || {
  echo "ERROR: missing Info.plist: ${INFO_PLIST}" >&2
  exit 2
}

[[ -f "${INJECTOR_SCRIPT}" ]] || {
  echo "ERROR: missing injector script: ${INJECTOR_SCRIPT}" >&2
  exit 2
}

[[ -f "${ICON_GENERATOR}" ]] || {
  echo "ERROR: missing icon generator: ${ICON_GENERATOR}" >&2
  exit 2
}

[[ -f "${ICON_ROUNDER}" ]] || {
  echo "ERROR: missing icon rounder: ${ICON_ROUNDER}" >&2
  exit 2
}

if [[ -e "${APP_PATH}" ]]; then
  chmod -R u+w "${APP_PATH}" 2>/dev/null || true
fi
rm -rf "${APP_PATH}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${OUT_DIR}"

MACOSX_DEPLOYMENT_TARGET=12.0 swiftc \
  -swift-version 5 \
  -O \
  -parse-as-library \
  -target "${ARCH}-apple-macos12.0" \
  "${SOURCE}" \
  -framework AppKit \
  -o "${EXECUTABLE}"

cp "${INFO_PLIST}" "${CONTENTS_DIR}/Info.plist"
cp "${INJECTOR_SCRIPT}" "${RESOURCES_DIR}/darwin-switch-rcm-inject.sh"
chmod 0755 "${EXECUTABLE}"
chmod 0755 "${RESOURCES_DIR}/darwin-switch-rcm-inject.sh"

rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"

if [[ -f "${ICON_SOURCE}" ]]; then
  TMP_ICON_DIR="$(mktemp -d)"
  cleanup_icon_tmp() {
    rm -rf "${TMP_ICON_DIR}"
  }
  trap cleanup_icon_tmp EXIT

  SQUARE_ICON="${TMP_ICON_DIR}/app-icon-rounded.png"
  python3 "${ICON_ROUNDER}" "${ICON_SOURCE}" "${SQUARE_ICON}" --size 1024 --radius-ratio 0.205

  sips -z 16 16 "${SQUARE_ICON}" --out "${ICONSET}/icon_16x16.png" >/dev/null
  sips -z 32 32 "${SQUARE_ICON}" --out "${ICONSET}/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "${SQUARE_ICON}" --out "${ICONSET}/icon_32x32.png" >/dev/null
  sips -z 64 64 "${SQUARE_ICON}" --out "${ICONSET}/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "${SQUARE_ICON}" --out "${ICONSET}/icon_128x128.png" >/dev/null
  sips -z 256 256 "${SQUARE_ICON}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "${SQUARE_ICON}" --out "${ICONSET}/icon_256x256.png" >/dev/null
  sips -z 512 512 "${SQUARE_ICON}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "${SQUARE_ICON}" --out "${ICONSET}/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "${SQUARE_ICON}" --out "${ICONSET}/icon_512x512@2x.png" >/dev/null
else
  python3 "${ICON_GENERATOR}" "${ICONSET}"
fi

iconutil -c icns "${ICONSET}" -o "${ICON_FILE}"
rm -rf "${ICONSET}"

if command -v codesign >/dev/null 2>&1; then
  CODESIGN_ARGS=(--force --deep --sign "${SIGN_IDENTITY}")
  if [[ "${SIGN_IDENTITY}" != "-" && -f "${ENTITLEMENTS}" ]]; then
    CODESIGN_ARGS+=(--options runtime --entitlements "${ENTITLEMENTS}")
  fi
  codesign "${CODESIGN_ARGS[@]}" "${APP_PATH}" >/dev/null 2>&1 || {
    echo "WARN: codesign failed for identity '${SIGN_IDENTITY}'. Falling back to ad-hoc signing." >&2
    codesign --force --deep --sign - "${APP_PATH}" >/dev/null 2>&1 || true
  }
fi

cat <<EOF
Created native macOS app:
  ${APP_PATH}

Open it with:
  open "${APP_PATH}"
EOF
