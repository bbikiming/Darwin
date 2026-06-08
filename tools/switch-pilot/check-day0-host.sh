#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${ROOT_DIR}/../.." && pwd)"
OUT_DIR="${REPO_DIR}/dist/switch-pilot"
# shellcheck source=/dev/null
source "${ROOT_DIR}/sd-root-lib.sh"
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
PKG_TARBALL="${OUT_DIR}/darwin-switch-agent-${VERSION}.tar.gz"
PKG_CHECKSUM="${PKG_TARBALL}.sha256"

HEKATE_PAYLOAD=""
RCM_INJECTOR=""
SWITCHROOT_ARCHIVE=""
SD_ROOT=""
STRICT=0
REQUIRE_DARWIN_KIT=0

usage() {
  cat <<'EOF'
Usage: check-day0-host.sh [--hekate-payload PATH] [--rcm-injector PATH] [--switchroot-archive PATH] [--sd-root PATH|auto] [--require-darwin-kit] [--strict]

Validate Mac/PC-side readiness before the Switchroot + Darwin day-0 install.
This is a read-only host check. It does not inject payloads, extract archives,
write to SD, or contact the Switch.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --hekate-payload)
      [[ "$#" -ge 2 ]] || { echo "ERROR: --hekate-payload needs a path" >&2; exit 2; }
      HEKATE_PAYLOAD="$2"
      shift 2
      ;;
    --rcm-injector)
      [[ "$#" -ge 2 ]] || { echo "ERROR: --rcm-injector needs a path" >&2; exit 2; }
      RCM_INJECTOR="$2"
      shift 2
      ;;
    --switchroot-archive)
      [[ "$#" -ge 2 ]] || { echo "ERROR: --switchroot-archive needs a path" >&2; exit 2; }
      SWITCHROOT_ARCHIVE="$2"
      shift 2
      ;;
    --sd-root)
      [[ "$#" -ge 2 ]] || { echo "ERROR: --sd-root needs a path" >&2; exit 2; }
      SD_ROOT="$2"
      shift 2
      ;;
    --require-darwin-kit)
      REQUIRE_DARWIN_KIT=1
      shift
      ;;
    --strict)
      STRICT=1
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

if [[ -n "${SD_ROOT}" ]]; then
  SD_ROOT="$(darwin_switch_resolve_sd_root "${SD_ROOT}")"
fi

bad=0
warn=0

ok() { echo "[OK] $*"; }
note() { echo "[INFO] $*"; }
mark_warn() { warn=1; echo "[WARN] $*"; }
mark_bad() { bad=1; echo "[BAD] $*"; }

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

check_command() {
  local cmd="$1"
  local fix="$2"
  if command_exists "${cmd}"; then
    ok "Command ${cmd}: $(command -v "${cmd}")"
  else
    mark_bad "Command ${cmd} missing. ${fix}"
  fi
}

version_ge() {
  local have="$1"
  local want="$2"
  awk -v have="${have}" -v want="${want}" 'BEGIN {
    split(have, h, ".");
    split(want, w, ".");
    for (i = 1; i <= 3; i++) {
      hv = (h[i] == "" ? 0 : h[i]) + 0;
      wv = (w[i] == "" ? 0 : w[i]) + 0;
      if (hv > wv) exit 0;
      if (hv < wv) exit 1;
    }
    exit 0;
  }'
}

check_file() {
  local path="$1"
  local label="$2"
  if [[ -f "${path}" ]]; then
    ok "${label}: ${path}"
  else
    mark_bad "${label} missing: ${path}"
  fi
}

check_sha256_file() {
  local checksum_file="$1"
  if command_exists shasum; then
    shasum -a 256 -c "${checksum_file}" >/dev/null
  elif command_exists sha256sum; then
    sha256sum -c "${checksum_file}" >/dev/null
  else
    return 127
  fi
}

check_rcm_injector() {
  if [[ -n "${RCM_INJECTOR}" ]]; then
    if [[ -x "${RCM_INJECTOR}" ]]; then
      ok "RCM payload injector executable: ${RCM_INJECTOR}"
    elif [[ -d "${RCM_INJECTOR}" && "$(basename "${RCM_INJECTOR}")" == *.app ]]; then
      ok "RCM payload injector app: ${RCM_INJECTOR}"
    elif [[ -f "${RCM_INJECTOR}" ]]; then
      mark_warn "RCM injector exists but is not executable: ${RCM_INJECTOR}"
    else
      mark_bad "RCM injector path not found: ${RCM_INJECTOR}"
    fi
    return
  fi

  for cmd in fusee-launcher TegraRcmSmash tegrarcm; do
    if command_exists "${cmd}"; then
      ok "RCM payload injector command: $(command -v "${cmd}")"
      return
    fi
  done
  mark_warn "No --rcm-injector supplied and no known CLI injector found. Prepare and dry-run your RCM payload injection tool before hardware."
}

note "Repo: ${REPO_DIR}"
note "Version: ${VERSION}"

check_command python3 "Install Python 3."
check_command tar "Install tar."
check_command ssh "Install OpenSSH client."
check_command scp "Install OpenSSH client."
if command_exists shasum; then
  ok "Checksum command: $(command -v shasum)"
elif command_exists sha256sum; then
  ok "Checksum command: $(command -v sha256sum)"
else
  mark_bad "No SHA-256 checksum tool found. Install shasum or sha256sum."
fi

if command_exists 7zz; then
  ok "7z extractor: $(command -v 7zz)"
elif command_exists 7z; then
  ok "7z extractor: $(command -v 7z)"
elif command_exists bsdtar; then
  mark_warn "No 7z/7zz command, but bsdtar exists. Verify it can extract the Switchroot archive."
else
  mark_warn "No 7z extractor found. Install 7zip before extracting the Switchroot .7z image."
fi

check_file "${PKG_TARBALL}" "Darwin runtime package"
check_file "${PKG_CHECKSUM}" "Darwin runtime checksum"
check_file "${KIT_TARBALL}" "Darwin field kit tarball"
check_file "${KIT_CHECKSUM}" "Darwin field kit checksum"

if [[ -d "${KIT_DIR}" ]]; then
  ok "Darwin field kit folder: ${KIT_DIR}"
  check_file "${KIT_DIR}/install-on-switch.sh" "Switch-side kit installer"
  check_file "${KIT_DIR}/copy-to-switch.sh" "Mac-side kit copy helper"
  check_file "${KIT_DIR}/manifest.json" "Field kit manifest"
else
  mark_bad "Darwin field kit folder missing: ${KIT_DIR}"
fi

if [[ -f "${PKG_CHECKSUM}" ]]; then
  (cd "$(dirname "${PKG_TARBALL}")" && check_sha256_file "$(basename "${PKG_CHECKSUM}")") \
    && ok "Runtime package checksum verifies" \
    || mark_bad "Runtime package checksum failed"
fi

if [[ -f "${KIT_CHECKSUM}" ]]; then
  (cd "$(dirname "${KIT_TARBALL}")" && check_sha256_file "$(basename "${KIT_CHECKSUM}")") \
    && ok "Field kit checksum verifies" \
    || mark_bad "Field kit checksum failed"
fi

if [[ -n "${HEKATE_PAYLOAD}" ]]; then
  if [[ -f "${HEKATE_PAYLOAD}" ]]; then
    ok "Hekate payload: ${HEKATE_PAYLOAD}"
    payload_name="$(basename "${HEKATE_PAYLOAD}")"
    if [[ "${payload_name}" =~ hekate.*([0-9]+\.[0-9]+\.[0-9]+).*\.bin$ ]]; then
      hekate_version="${BASH_REMATCH[1]}"
      if version_ge "${hekate_version}" "6.0.6"; then
        ok "Hekate payload version appears >= 6.0.6: ${hekate_version}"
      else
        mark_bad "Hekate payload version appears too old for Noble: ${hekate_version}"
      fi
    else
      mark_warn "Could not infer Hekate version from filename. Confirm it is 6.0.6 or newer."
    fi
  else
    mark_bad "Hekate payload file not found: ${HEKATE_PAYLOAD}"
  fi
else
  mark_warn "No --hekate-payload supplied; cannot verify Hekate 6.0.6+ file."
fi

check_rcm_injector

if [[ -n "${SWITCHROOT_ARCHIVE}" ]]; then
  if [[ -f "${SWITCHROOT_ARCHIVE}" ]]; then
    ok "Switchroot archive: ${SWITCHROOT_ARCHIVE}"
    case "$(basename "${SWITCHROOT_ARCHIVE}")" in
      *.7z) ok "Switchroot archive extension is .7z" ;;
      *) mark_warn "Switchroot archive is not .7z; confirm it is the official extracted/downloaded image." ;;
    esac
    archive_name="$(basename "${SWITCHROOT_ARCHIVE}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${archive_name}" == *noble* || "${archive_name}" == *24.04* ]]; then
      ok "Switchroot archive name looks like Noble/24.04"
    else
      mark_warn "Switchroot archive name does not mention Noble/24.04."
    fi
  else
    mark_bad "Switchroot archive file not found: ${SWITCHROOT_ARCHIVE}"
  fi
else
  mark_warn "No --switchroot-archive supplied; cannot verify downloaded Switchroot image path."
fi

if [[ -n "${SD_ROOT}" ]]; then
  if [[ -d "${SD_ROOT}" ]]; then
    ok "SD root path exists: ${SD_ROOT}"
    sd_check_args=(--stage any)
    if [[ "${REQUIRE_DARWIN_KIT}" -eq 1 ]]; then
      sd_check_args+=(--require-darwin-kit)
    fi
    "${ROOT_DIR}/check-switchroot-sd.sh" "${sd_check_args[@]}" "${SD_ROOT}" || {
      code="$?"
      if [[ "${code}" -eq 1 ]]; then
        mark_warn "SD layout checker returned WARN for ${SD_ROOT}"
      else
        mark_bad "SD layout checker returned BAD for ${SD_ROOT}"
      fi
    }
  else
    mark_bad "SD root path not found: ${SD_ROOT}"
  fi
else
  if [[ "${REQUIRE_DARWIN_KIT}" -eq 1 ]]; then
    mark_bad "--require-darwin-kit needs --sd-root."
  else
    mark_warn "No --sd-root supplied; mounted SD layout not checked."
  fi
fi

if [[ "${bad}" -eq 1 ]]; then
  echo "RESULT: BAD"
  exit 2
fi

if [[ "${warn}" -eq 1 ]]; then
  echo "RESULT: WARN"
  [[ "${STRICT}" -eq 1 ]] && exit 1
  exit 0
fi

echo "RESULT: GOOD"
