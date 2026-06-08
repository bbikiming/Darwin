#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
OUT_DIR="${REPO_DIR}/dist/switch-pilot"
LOCAL_OUT_DIR="${OUT_DIR}/local"
APP_PATH="${LOCAL_OUT_DIR}/Darwin Switch RCM Injector.app"
PKG_PATH="${OUT_DIR}/Darwin Switch RCM Injector-local.pkg"
PKG_ROOT="${OUT_DIR}/local-pkg-root"
VERSION="${DARWIN_LOCAL_VERSION:-1.0}"
IDENTIFIER="com.darwin.switch.rcminjector.local"
SIGN_IDENTITY="${DARWIN_RCM_SIGN_IDENTITY:-}"

command -v pkgbuild >/dev/null 2>&1 || {
  echo "ERROR: pkgbuild is required." >&2
  exit 2
}

if [[ -z "${SIGN_IDENTITY}" ]] && command -v security >/dev/null 2>&1; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Apple Development:/{print $2; exit}'
  )"
fi

if [[ -n "${SIGN_IDENTITY}" ]]; then
  echo "Using local code signing identity:"
  echo "  ${SIGN_IDENTITY}"
  DARWIN_RCM_APP_OUT_DIR="${LOCAL_OUT_DIR}" \
    DARWIN_RCM_SIGN_IDENTITY="${SIGN_IDENTITY}" \
    "${SCRIPT_DIR}/make-macos-app.sh"
else
  echo "WARN: no Apple Development signing identity found. Building ad-hoc signed local app." >&2
  DARWIN_RCM_APP_OUT_DIR="${LOCAL_OUT_DIR}" "${SCRIPT_DIR}/make-macos-app.sh"
fi

rm -rf "${PKG_ROOT}" "${PKG_PATH}"
mkdir -p "${PKG_ROOT}/Applications"
COPYFILE_DISABLE=1 ditto --norsrc "${APP_PATH}" "${PKG_ROOT}/Applications/Darwin Switch RCM Injector.app"
xattr -cr "${PKG_ROOT}" 2>/dev/null || true
find "${PKG_ROOT}" -name '._*' -delete

pkgbuild \
  --root "${PKG_ROOT}" \
  --identifier "${IDENTIFIER}" \
  --version "${VERSION}" \
  --install-location "/" \
  "${PKG_PATH}"

rm -rf "${PKG_ROOT}"

cat <<EOF
Created local installer package:
  ${PKG_PATH}

This package installs:
  /Applications/Darwin Switch RCM Injector.app
EOF
