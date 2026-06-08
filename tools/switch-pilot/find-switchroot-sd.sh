#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/sd-root-lib.sh"

usage() {
  cat <<'EOF'
Usage: find-switchroot-sd.sh [--path-only]

List mounted volumes that look like a Switchroot SD FAT32 root.
Auto-detection requires both bootloader/ and switchroot/ at the volume root.

Test-only environment:
  DARWIN_SWITCH_SD_SCAN_ROOTS=/path/a:/path/b overrides scan roots.
EOF
}

PATH_ONLY=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --path-only)
      PATH_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

candidates=()
while IFS= read -r candidate; do
  [[ -n "${candidate}" ]] && candidates+=("${candidate}")
done < <(darwin_switch_sd_candidates)

if [[ "${PATH_ONLY}" -eq 1 ]]; then
  if [[ "${#candidates[@]}" -eq 1 ]]; then
    printf '%s\n' "${candidates[0]}"
    exit 0
  fi
  exit 2
fi

echo "Switchroot SD candidate scan roots:"
darwin_switch_sd_scan_roots | sed 's/^/  /'
echo ""

case "${#candidates[@]}" in
  0)
    echo "RESULT: NONE"
    echo "No mounted volume currently contains both bootloader/ and switchroot/."
    ;;
  1)
    echo "RESULT: ONE"
    echo "Auto-detect path: ${candidates[0]}"
    ;;
  *)
    echo "RESULT: MULTIPLE"
    printf '  %s\n' "${candidates[@]}"
    echo "Pass --sd-root explicitly."
    exit 1
    ;;
esac
