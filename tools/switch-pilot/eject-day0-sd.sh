#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/sd-root-lib.sh"

SD_ROOT=""
STAGE="any"
REQUIRE_DARWIN_KIT=0
DRY_RUN=0
ALLOW_NON_VOLUME_ROOT="${DARWIN_SWITCH_ALLOW_NON_VOLUME_EJECT:-0}"

usage() {
  cat <<'EOF'
Usage: eject-day0-sd.sh [--stage before-flash|after-flash|any] [--require-darwin-kit] [--dry-run] <sd-fat32-root|auto>

Validate, sync, and safely eject/unmount a mounted Switchroot SD FAT32 root
from a Mac/PC before removing it for the Switch.

By default this first runs check-switchroot-sd.sh, then runs sync, then uses:
  macOS: diskutil eject
  Linux: udisksctl unmount/power-off, or umount fallback

Use --dry-run to print what would happen without unmounting anything.
Use --allow-non-volume-root only for tests or unusual mount setups.
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
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --allow-non-volume-root)
      ALLOW_NON_VOLUME_ROOT=1
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
  echo "ERROR: SD root does not exist: ${SD_ROOT}" >&2
  exit 2
fi

run_or_print() {
  local label="$1"
  shift
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '[DRY-RUN] %s:' "${label}"
    for arg in "$@"; do
      printf ' %q' "${arg}"
    done
    printf '\n'
  else
    "$@"
  fi
}

mounted_device() {
  df -P "${SD_ROOT}" 2>/dev/null | awk 'NR==2 {print $1; exit}'
}

mounted_at() {
  df -P "${SD_ROOT}" 2>/dev/null | awk 'NR==2 {print $6; exit}'
}

validate_eject_target() {
  local os_name="$1"
  local mount_point="$2"
  if [[ "${ALLOW_NON_VOLUME_ROOT}" == "1" ]]; then
    return 0
  fi
  if [[ "${os_name}" == "Darwin" && "${SD_ROOT}" != /Volumes/* ]]; then
    echo "ERROR: refusing to eject a non-/Volumes path on macOS: ${SD_ROOT}" >&2
    echo "Pass the mounted SD FAT32 root, usually /Volumes/<SD_NAME>." >&2
    exit 2
  fi
  if [[ "${mount_point}" == "/" ]]; then
    echo "ERROR: refusing to eject the root filesystem mount." >&2
    exit 2
  fi
}

eject_macos() {
  if ! command -v diskutil >/dev/null 2>&1; then
    return 1
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    run_or_print "diskutil" diskutil eject "${SD_ROOT}"
    return 0
  fi
  diskutil eject "${SD_ROOT}" >/dev/null
}

eject_linux() {
  local device="$1"
  if [[ -n "${device}" && -b "${device}" ]] && command -v udisksctl >/dev/null 2>&1; then
    run_or_print "udisksctl" udisksctl unmount -b "${device}"
    run_or_print "udisksctl" udisksctl power-off -b "${device}" || true
    return 0
  fi
  if command -v umount >/dev/null 2>&1; then
    run_or_print "umount" umount "${SD_ROOT}"
    return 0
  fi
  return 1
}

check_args=(--stage "${STAGE}")
if [[ "${REQUIRE_DARWIN_KIT}" -eq 1 ]]; then
  check_args+=(--require-darwin-kit)
fi

echo "== Validate SD before eject =="
"${ROOT_DIR}/check-switchroot-sd.sh" "${check_args[@]}" "${SD_ROOT}"

os_name="$(uname -s)"
device="$(mounted_device || true)"
mount_point="$(mounted_at || true)"
validate_eject_target "${os_name}" "${mount_point}"
echo ""
echo "== Sync filesystem buffers =="
echo "SD root: ${SD_ROOT}"
echo "Mount: ${mount_point:-unknown}"
echo "Device: ${device:-unknown}"
run_or_print "sync" sync

echo ""
echo "== Eject/unmount SD =="
case "${os_name}" in
  Darwin)
    eject_macos
    ;;
  Linux)
    eject_linux "${device}"
    ;;
  *)
    if ! eject_linux "${device}"; then
      echo "ERROR: unsupported host OS for automatic eject: ${os_name}" >&2
      echo "Run the OS file manager's eject/unmount action before removing the SD." >&2
      exit 2
    fi
    ;;
esac

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "RESULT: DRY-RUN"
else
  echo "RESULT: EJECTED"
fi
