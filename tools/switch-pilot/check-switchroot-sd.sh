#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/sd-root-lib.sh"

STAGE="any"
REQUIRE_DARWIN_KIT=0
WRITE_CHECK=0
SD_ROOT=""

usage() {
  cat <<'EOF'
Usage: check-switchroot-sd.sh [--stage before-flash|after-flash|any] [--require-darwin-kit] [--write-check] <sd-fat32-root|auto>

Validate the mounted SD FAT32 root before a Switchroot/Darwin field install.
Run this from the Mac/PC against a Hekate UMS mount or normal SD-card mount.
By default it only reads the SD layout. Use --write-check when a copy step
must prove that the mounted SD root is writable before writing larger files.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --stage)
      [[ "$#" -ge 2 ]] || { echo "ERROR: --stage needs a value" >&2; exit 2; }
      STAGE="$2"
      shift 2
      ;;
    --require-darwin-kit)
      REQUIRE_DARWIN_KIT=1
      shift
      ;;
    --write-check)
      WRITE_CHECK=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "${SD_ROOT}" ]]; then
        echo "ERROR: only one SD root path is allowed" >&2
        exit 2
      fi
      SD_ROOT="$1"
      shift
      ;;
  esac
done

case "${STAGE}" in
  before-flash|after-flash|any) ;;
  *) echo "ERROR: invalid --stage: ${STAGE}" >&2; exit 2 ;;
esac

if [[ -z "${SD_ROOT}" ]]; then
  echo "ERROR: missing SD root path" >&2
  usage >&2
  exit 2
fi

SD_ROOT="$(darwin_switch_resolve_sd_root "${SD_ROOT}")"

if [[ ! -d "${SD_ROOT}" ]]; then
  echo "BAD: SD root does not exist: ${SD_ROOT}" >&2
  exit 2
fi

bad=0
warn=0

ok() { echo "[OK] $*"; }
note() { echo "[INFO] $*"; }
mark_warn() { warn=1; echo "[WARN] $*"; }
mark_bad() { bad=1; echo "[BAD] $*"; }

has_any() {
  local pattern="$1"
  compgen -G "${pattern}" >/dev/null 2>&1
}

check_sha256_file() {
  local checksum_file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c "${checksum_file}" >/dev/null
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "${checksum_file}" >/dev/null
  else
    return 127
  fi
}

check_file_or_dir() {
  local path="$1"
  local label="$2"
  if [[ -e "${path}" ]]; then
    ok "${label}: ${path}"
  else
    mark_bad "${label} missing: ${path}"
  fi
}

check_write_access() {
  local test_path="${SD_ROOT}/.darwin-switch-write-test-$$"
  if [[ -e "${test_path}" ]]; then
    mark_bad "Write-check temp path already exists: ${test_path}"
    return
  fi
  if (printf 'darwin-switch write test\n' > "${test_path}") 2>/dev/null; then
    if rm -f "${test_path}" 2>/dev/null; then
      ok "Write access: temporary file create/remove succeeded"
    else
      mark_bad "Write access: created temp file but could not remove it: ${test_path}"
    fi
  else
    mark_bad "Write access: SD root is not writable: ${SD_ROOT}"
  fi
}

check_darwin_kit_folder() {
  local kit_dir="$1"
  local pkg=""
  local checksum=""
  ok "Darwin install kit folder: ${kit_dir}"

  check_file_or_dir "${kit_dir}/install-on-switch.sh" "Switch-side Darwin installer"
  check_file_or_dir "${kit_dir}/manifest.json" "Darwin kit manifest"
  check_file_or_dir "${kit_dir}/INSTALL_ON_SWITCH.md" "Darwin kit runbook"

  pkg="$(find "${kit_dir}" -maxdepth 1 -type f -name 'darwin-switch-agent-*.tar.gz' -print -quit 2>/dev/null || true)"
  checksum="$(find "${kit_dir}" -maxdepth 1 -type f -name 'darwin-switch-agent-*.tar.gz.sha256' -print -quit 2>/dev/null || true)"
  if [[ -z "${pkg}" ]]; then
    mark_bad "Darwin runtime package missing inside kit folder: ${kit_dir}"
  fi
  if [[ -z "${checksum}" ]]; then
    mark_bad "Darwin runtime checksum missing inside kit folder: ${kit_dir}"
  fi
  if [[ -n "${pkg}" && -n "${checksum}" ]]; then
    if (cd "${kit_dir}" && check_sha256_file "$(basename "${checksum}")"); then
      ok "Darwin kit runtime checksum verifies"
    else
      mark_bad "Darwin kit runtime checksum failed: ${checksum}"
    fi
  fi

  if [[ -f "${kit_dir}/manifest.json" && -n "${pkg}" && -n "${checksum}" ]] \
    && command -v python3 >/dev/null 2>&1 \
    && command -v tar >/dev/null 2>&1; then
    if python3 - "${kit_dir}/manifest.json" "${pkg}" "${checksum}" <<'PY'
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
pkg_path = Path(sys.argv[2])
checksum_path = Path(sys.argv[3])
data = json.loads(manifest_path.read_text(encoding="utf-8"))
package = data.get("package", {})
checksum = checksum_path.read_text(encoding="utf-8").split()[0]
entry_count = len(subprocess.check_output(["tar", "-tzf", str(pkg_path)], text=True).splitlines())

assert package.get("file") == pkg_path.name
assert package.get("checksum_file") == checksum_path.name
assert package.get("sha256") == checksum
assert int(package.get("size_bytes", -1)) == pkg_path.stat().st_size
assert int(package.get("tar_entry_count", -1)) == entry_count
assert data.get("switch_entrypoint") == "./install-on-switch.sh"
PY
    then
      ok "Darwin kit manifest cross-check verifies"
    else
      mark_bad "Darwin kit manifest does not match package/checksum: ${kit_dir}/manifest.json"
    fi
  elif [[ -f "${kit_dir}/manifest.json" ]]; then
    mark_warn "Darwin kit manifest cross-check skipped; python3 or tar unavailable."
  fi
}

check_darwin_kit_tarball() {
  local tarball="$1"
  local checksum="${tarball}.sha256"
  local listing=""
  ok "Darwin install kit tarball: ${tarball}"

  if [[ -f "${checksum}" ]]; then
    if (cd "$(dirname "${tarball}")" && check_sha256_file "$(basename "${checksum}")"); then
      ok "Darwin install kit tarball checksum verifies"
    else
      mark_bad "Darwin install kit tarball checksum failed: ${checksum}"
    fi
  else
    mark_bad "Darwin install kit tarball checksum missing: ${checksum}"
  fi

  if command -v tar >/dev/null 2>&1; then
    if listing="$(tar -tzf "${tarball}" 2>/dev/null)"; then
      for _required in \
        'install-on-switch\.sh$' \
        'manifest\.json$' \
        'darwin-switch-agent-[0-9.]+\.tar\.gz$' \
        'darwin-switch-agent-[0-9.]+\.tar\.gz\.sha256$'; do
        if printf '%s\n' "${listing}" | grep -E "${_required}" >/dev/null; then
          ok "Darwin install kit tarball entry found: ${_required}"
        else
          mark_bad "Darwin install kit tarball missing required entry: ${_required}"
        fi
      done
    else
      mark_bad "Darwin install kit tarball cannot be read: ${tarball}"
    fi
  else
    mark_warn "Cannot inspect Darwin install kit tarball; tar unavailable."
  fi
}

note "SD root: ${SD_ROOT}"
note "Stage: ${STAGE}"
if [[ "${WRITE_CHECK}" -eq 1 ]]; then
  note "Write check: enabled"
  check_write_access
else
  note "Write check: disabled"
fi

if [[ ! -d "${SD_ROOT}/bootloader" && ! -d "${SD_ROOT}/switchroot" ]]; then
  nested="$(find "${SD_ROOT}" -mindepth 1 -maxdepth 2 -type d \( -name bootloader -o -name switchroot \) -print -quit 2>/dev/null || true)"
  if [[ -n "${nested}" ]]; then
    mark_bad "Switchroot files look nested under another folder. Extract the .7z directly to the FAT32 root."
    note "First nested hit: ${nested}"
  else
    mark_bad "No bootloader/ or switchroot/ folder found at the SD root."
  fi
else
  check_file_or_dir "${SD_ROOT}/bootloader" "Hekate/Switchroot bootloader folder"
  check_file_or_dir "${SD_ROOT}/switchroot" "Switchroot folder"
fi

if [[ -d "${SD_ROOT}/bootloader/ini" ]]; then
  if has_any "${SD_ROOT}/bootloader/ini/L4T-*.ini"; then
    ok "L4T boot entry found in bootloader/ini"
  else
    mark_warn "No L4T-*.ini entry found under bootloader/ini yet."
  fi
else
  mark_warn "bootloader/ini is missing; Hekate may not show a L4T entry."
fi

if [[ "${STAGE}" == "before-flash" || "${STAGE}" == "any" ]]; then
  if has_any "${SD_ROOT}/switchroot/install/l4t.*"; then
    ok "Switchroot install payload found under switchroot/install"
  else
    if [[ "${STAGE}" == "before-flash" ]]; then
      mark_bad "No switchroot/install/l4t.* payload found before Flash Linux."
    else
      mark_warn "No switchroot/install/l4t.* payload found; OK only after Flash Linux consumed install files."
    fi
  fi
fi

if [[ "${STAGE}" == "after-flash" || "${STAGE}" == "any" ]]; then
  if [[ -f "${SD_ROOT}/switchroot/ubuntu/boot.scr" || -f "${SD_ROOT}/switchroot/ubuntu/uImage" ]]; then
    ok "Switchroot ubuntu boot files found"
  else
    if [[ "${STAGE}" == "after-flash" ]]; then
      mark_bad "No switchroot/ubuntu boot files found after Flash Linux."
    else
      mark_warn "No switchroot/ubuntu boot files found; expected only after extraction/flash layout is complete."
    fi
  fi
fi

if [[ "${REQUIRE_DARWIN_KIT}" -eq 1 ]]; then
  kit_found=0
  while IFS= read -r _kit_dir; do
    kit_found=1
    check_darwin_kit_folder "${_kit_dir}"
  done < <(find "${SD_ROOT}" -maxdepth 1 -type d -name 'darwin-switch-install-kit-*' -print 2>/dev/null | sort)
  while IFS= read -r _kit_tarball; do
    kit_found=1
    check_darwin_kit_tarball "${_kit_tarball}"
  done < <(find "${SD_ROOT}" -maxdepth 1 -type f -name 'darwin-switch-install-kit-*.tar.gz' -print 2>/dev/null | sort)
  if [[ "${kit_found}" -eq 0 ]]; then
    mark_bad "Darwin install kit not found on SD root."
  fi
fi

if command -v df >/dev/null 2>&1; then
  free_kb="$(df -k "${SD_ROOT}" | awk 'NR==2 {print $4}')"
  if [[ "${free_kb}" =~ ^[0-9]+$ ]]; then
    free_mb=$((free_kb / 1024))
    if [[ "${free_mb}" -ge 1024 ]]; then
      ok "Free space: ${free_mb} MB"
    elif [[ "${free_mb}" -ge 256 ]]; then
      mark_warn "Low free space: ${free_mb} MB"
    else
      mark_bad "Very low free space: ${free_mb} MB"
    fi
  fi
fi

if [[ "${bad}" -eq 1 ]]; then
  echo "RESULT: BAD"
  exit 2
fi

if [[ "${warn}" -eq 1 ]]; then
  echo "RESULT: WARN"
  exit 1
fi

echo "RESULT: GOOD"
