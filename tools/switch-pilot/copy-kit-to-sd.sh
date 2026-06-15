#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${ROOT_DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT_DIR}/sd-root-lib.sh"
OUT_DIR="${REPO_DIR}/dist/switch-pilot"
VERSION="$(python3 - "${ROOT_DIR}/src/darwin_switch_agent/__init__.py" <<'PY'
import pathlib
import sys
text = pathlib.Path(sys.argv[1]).read_text()
for line in text.splitlines():
    if line.startswith("__version__"):
        print(line.split("=")[1].strip().strip('"'))
        break
PY
)"
KIT_NAME="darwin-switch-install-kit-${VERSION}"
KIT_DIR="${OUT_DIR}/${KIT_NAME}"
KIT_TARBALL="${OUT_DIR}/${KIT_NAME}.tar.gz"
KIT_CHECKSUM="${KIT_TARBALL}.sha256"
SD_ROOT=""
COPY_TARBALL=1
COPY_FOLDER=1
STAGE="any"

usage() {
  cat <<'EOF'
Usage: copy-kit-to-sd.sh [--folder-only|--tarball-only] [--stage before-flash|after-flash|any] <sd-fat32-root|auto>

Copy the Darwin Switch install kit to a mounted SD FAT32 root for physical
transfer. This is useful when Switchroot Wi-Fi/SSH is not ready yet. After
confirming the target looks like a writable Switchroot SD root, it copies the
kit and runs check-switchroot-sd.sh --require-darwin-kit.
EOF
}

precheck_sd_root() {
  local code=0
  set +e
  "${ROOT_DIR}/check-switchroot-sd.sh" --write-check --stage "${STAGE}" "${SD_ROOT}"
  code="$?"
  set -e
  case "${code}" in
    0)
      echo "SD layout precheck passed."
      ;;
    1)
      echo "WARN: SD layout precheck reported warnings but no BAD items; continuing with copy."
      ;;
    *)
      echo "ERROR: SD layout precheck failed; refusing to copy Darwin kit to this path." >&2
      exit "${code}"
      ;;
  esac
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --folder-only)
      COPY_FOLDER=1
      COPY_TARBALL=0
      shift
      ;;
    --tarball-only)
      COPY_FOLDER=0
      COPY_TARBALL=1
      shift
      ;;
    --stage)
      [[ "$#" -ge 2 ]] || { echo "ERROR: --stage needs a value" >&2; exit 2; }
      STAGE="$2"
      shift 2
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

if [[ ! -d "${SD_ROOT}" ]]; then
  if [[ "${SD_ROOT}" == "auto" ]]; then
    SD_ROOT="$(darwin_switch_resolve_sd_root "${SD_ROOT}")"
  fi
fi

if [[ ! -d "${SD_ROOT}" ]]; then
  echo "ERROR: SD root does not exist: ${SD_ROOT}" >&2
  exit 2
fi

precheck_sd_root

if [[ ! -d "${KIT_DIR}" || ! -f "${KIT_TARBALL}" || ! -f "${KIT_CHECKSUM}" ]]; then
  echo "Darwin install kit is missing or stale. Building it first..."
  "${ROOT_DIR}/make-install-kit.sh" >/dev/null
fi

if [[ "${COPY_FOLDER}" -eq 1 ]]; then
  rm -rf "${SD_ROOT:?}/${KIT_NAME}"
  cp -R "${KIT_DIR}" "${SD_ROOT}/${KIT_NAME}"
  echo "Copied folder: ${SD_ROOT}/${KIT_NAME}"
fi

if [[ "${COPY_TARBALL}" -eq 1 ]]; then
  cp "${KIT_TARBALL}" "${SD_ROOT}/${KIT_NAME}.tar.gz"
  cp "${KIT_CHECKSUM}" "${SD_ROOT}/${KIT_NAME}.tar.gz.sha256"
  echo "Copied tarball: ${SD_ROOT}/${KIT_NAME}.tar.gz"
  echo "Copied checksum: ${SD_ROOT}/${KIT_NAME}.tar.gz.sha256"
fi

"${ROOT_DIR}/check-switchroot-sd.sh" \
  --stage "${STAGE}" \
  --require-darwin-kit \
  "${SD_ROOT}"

cat <<EOF

Darwin install kit is on the SD root.

If using the folder copy after booting Switchroot:
  cd /path/to/sd/${KIT_NAME}
  ./install-on-switch.sh

If using the tarball after booting Switchroot:
  tar -xzf /path/to/sd/${KIT_NAME}.tar.gz
  cd ${KIT_NAME}
  ./install-on-switch.sh

To validate, sync, and safely eject this SD from the host:
  ${ROOT_DIR}/eject-day0-sd.sh --stage ${STAGE} --require-darwin-kit "${SD_ROOT}"
EOF
