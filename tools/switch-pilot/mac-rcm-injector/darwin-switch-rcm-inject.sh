#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
APP_SUPPORT="${DARWIN_SWITCH_RCM_HOME:-${HOME}/Library/Application Support/DarwinSwitchRCM}"
VENV_DIR="${APP_SUPPORT}/venv"
VENDOR_DIR="${APP_SUPPORT}/switch-fusee"
LOG_DIR="${APP_SUPPORT}/logs"
FUSEE_REPO_URL="${DARWIN_SWITCH_FUSEE_REPO_URL:-https://github.com/erdzan12/switch-fusee.git}"
PAYLOAD=""
CHECK_ONLY=0
NO_WAIT=0
REFRESH_VENDOR=0

usage() {
  cat <<'EOF'
Usage: darwin-switch-rcm-inject.sh [--payload /path/to/hekate.bin] [--check-only] [--no-wait] [--refresh-vendor]

Inject a Hekate payload into an unpatched Nintendo Switch in RCM from macOS.

Default payload search:
  dist/switch-pilot/hekate_ctcaer_*.bin
  ~/Library/Application Support/DarwinSwitchRCM/payloads/hekate_ctcaer_*.bin
  /Volumes/*/hekate_ctcaer_*.bin

This wrapper bootstraps a local Python venv under:
  ~/Library/Application Support/DarwinSwitchRCM

It downloads the public fusee-launcher implementation on first run and uses
Homebrew libusb when available.
EOF
}

log() {
  printf '[Darwin RCM] %s\n' "$*"
}

fail() {
  printf '[Darwin RCM] ERROR: %s\n' "$*" >&2
  exit 2
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --payload)
      [[ "$#" -ge 2 ]] || fail "--payload needs a path"
      PAYLOAD="$2"
      shift 2
      ;;
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    --no-wait)
      NO_WAIT=1
      shift
      ;;
    --refresh-vendor)
      REFRESH_VENDOR=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      if [[ -n "${PAYLOAD}" ]]; then
        fail "only one payload path is allowed"
      fi
      PAYLOAD="$1"
      shift
      ;;
  esac
done

find_default_payload() {
  local candidate=""
  candidate="$(find "${REPO_DIR}/dist/switch-pilot" -maxdepth 1 -type f -name 'hekate_ctcaer_*.bin' -print 2>/dev/null | sort | tail -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  candidate="$(find "${APP_SUPPORT}/payloads" -maxdepth 1 -type f -name 'hekate_ctcaer_*.bin' -print 2>/dev/null | sort | tail -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  if [[ -f "/Volumes/SWITCHSD/hekate_ctcaer_6.5.2.bin" ]]; then
    printf '%s\n' "/Volumes/SWITCHSD/hekate_ctcaer_6.5.2.bin"
    return 0
  fi
  candidate="$(find /Volumes -maxdepth 2 -type f -name 'hekate_ctcaer_*.bin' -print 2>/dev/null | sort | tail -n 1 || true)"
  if [[ -n "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  candidate="$(find "${REPO_DIR}" -maxdepth 5 -type f -name 'hekate_ctcaer_*.bin' -print 2>/dev/null | sort | tail -n 1 || true)"
  [[ -n "${candidate}" ]] && printf '%s\n' "${candidate}"
}

payload_path() {
  if [[ -n "${PAYLOAD}" ]]; then
    if [[ "${PAYLOAD}" = /* ]]; then
      printf '%s\n' "${PAYLOAD}"
    else
      printf '%s\n' "${PWD}/${PAYLOAD}"
    fi
  else
    find_default_payload
  fi
}

detect_rcm() {
  python3 - <<'PY'
from __future__ import annotations

import re
import subprocess
import sys

try:
    out = subprocess.check_output(["ioreg", "-p", "IOUSB", "-l", "-w0"], text=True, stderr=subprocess.DEVNULL)
except Exception:
    sys.exit(1)

for block in out.split("+-o "):
    name_match = re.search(r'"USB Product Name"\s*=\s*"([^"]+)"', block)
    name = name_match.group(1) if name_match else ""
    vendor_match = re.search(r'"idVendor"\s*=\s*(\d+)', block)
    product_match = re.search(r'"idProduct"\s*=\s*(\d+)', block)
    vendor = int(vendor_match.group(1)) if vendor_match else None
    product = int(product_match.group(1)) if product_match else None
    if (vendor, product) == (0x0955, 0x7321) or name.upper() == "APX":
        print(f"APX RCM device detected (vendor={vendor}, product={product}, name={name or 'unknown'})")
        sys.exit(0)

sys.exit(1)
PY
}

libusb_status() {
  for path in \
    /opt/homebrew/lib/libusb-1.0.dylib \
    /usr/local/lib/libusb-1.0.dylib \
    /opt/homebrew/opt/libusb/lib/libusb-1.0.dylib \
    /usr/local/opt/libusb/lib/libusb-1.0.dylib; do
    if [[ -f "${path}" ]]; then
      printf '%s\n' "${path}"
      return 0
    fi
  done
  return 1
}

ensure_libusb() {
  if libusb_status >/dev/null; then
    log "libusb found: $(libusb_status)"
    return
  fi

  if ! command -v brew >/dev/null 2>&1; then
    fail "libusb not found and Homebrew is unavailable. Install Homebrew libusb or use CrystalRCM/WebRCM."
  fi

  if [[ "${DARWIN_SWITCH_RCM_NONINTERACTIVE:-0}" == "1" ]]; then
    fail "libusb not found. Install it with 'brew install libusb', then rerun the GUI."
  fi

  log "libusb is missing. Homebrew can install it."
  read -r -p "Install libusb with 'brew install libusb' now? [Y/n] " answer
  case "${answer:-Y}" in
    y|Y|yes|YES)
      brew install libusb
      ;;
    *)
      fail "libusb is required for USB RCM injection."
      ;;
  esac
}

ensure_venv() {
  mkdir -p "${APP_SUPPORT}" "${LOG_DIR}"
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    log "Creating local Python venv: ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  fi
  if ! "${VENV_DIR}/bin/python" - <<'PY' >/dev/null 2>&1
import usb.core
PY
  then
    log "Installing PyUSB into local venv"
    "${VENV_DIR}/bin/python" -m pip install --upgrade pip >/dev/null
    "${VENV_DIR}/bin/python" -m pip install pyusb
  fi
}

ensure_fusee_launcher() {
  if [[ "${REFRESH_VENDOR}" -eq 1 && -d "${VENDOR_DIR}/.git" ]]; then
    log "Refreshing fusee-launcher vendor checkout"
    git -C "${VENDOR_DIR}" pull --ff-only
  fi

  if [[ ! -f "${VENDOR_DIR}/fusee-launcher.py" ]]; then
    rm -rf "${VENDOR_DIR}"
    mkdir -p "$(dirname "${VENDOR_DIR}")"
    log "Downloading fusee-launcher: ${FUSEE_REPO_URL}"
    git clone --depth 1 "${FUSEE_REPO_URL}" "${VENDOR_DIR}"
  fi

  [[ -f "${VENDOR_DIR}/fusee-launcher.py" ]] || fail "fusee-launcher.py was not found after bootstrap"
}

wait_for_rcm() {
  if detect_rcm; then
    return 0
  fi

  if [[ "${NO_WAIT}" -eq 1 ]]; then
    return 1
  fi

  cat <<'EOF'

RCM APX device is not visible yet.

Prepare the Switch:
  1. Insert the SD card.
  2. Fully power off the Switch.
  3. Insert the RCM jig into the right Joy-Con rail.
  4. Hold VOL+ and press POWER once.
  5. The screen should stay black.
  6. Connect the Switch to this Mac with a data-capable USB-C cable.

EOF

  while true; do
    read -r -p "Press Enter to scan again, or type q then Enter to quit: " answer
    case "${answer}" in
      q|Q|quit|QUIT)
        return 1
        ;;
    esac
    if detect_rcm; then
      return 0
    fi
    log "Still no APX RCM device. Recheck jig seating, cable, and that the screen stayed black."
  done
}

main() {
  local payload
  payload="$(payload_path || true)"
  [[ -n "${payload}" ]] || fail "No Hekate payload found. Pass --payload /path/to/hekate_ctcaer_*.bin"
  [[ -f "${payload}" ]] || fail "Payload file does not exist: ${payload}"
  [[ -s "${payload}" ]] || fail "Payload file is empty: ${payload}"

  log "Payload: ${payload}"
  log "App support: ${APP_SUPPORT}"

  ensure_libusb
  ensure_venv
  ensure_fusee_launcher

  if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    if detect_rcm; then
      log "RCM check: APX device detected"
    else
      log "RCM check: APX device not detected yet"
    fi
    log "Check-only complete. No payload was injected."
    return 0
  fi

  wait_for_rcm || fail "RCM APX device was not detected."

  export DYLD_LIBRARY_PATH="/opt/homebrew/lib:/usr/local/lib:/opt/homebrew/opt/libusb/lib:/usr/local/opt/libusb/lib:${DYLD_LIBRARY_PATH:-}"
  local log_file="${LOG_DIR}/inject-$(date +%Y%m%d-%H%M%S).log"
  log "Injecting payload. Log: ${log_file}"
  (
    set -x
    cd "${VENDOR_DIR}"
    "${VENV_DIR}/bin/python" "${VENDOR_DIR}/fusee-launcher.py" "${payload}"
  ) 2>&1 | tee "${log_file}"

  cat <<EOF

Done.
If the injection succeeded, the Switch screen should now show Hekate/Nyx.
If the screen stayed black:
  - The console may be patched.
  - The cable may be charge-only or unstable.
  - The payload may be wrong/corrupt.
  - RCM entry may have failed if the Nintendo logo appeared earlier.

Log saved:
  ${log_file}
EOF
}

main "$@"
