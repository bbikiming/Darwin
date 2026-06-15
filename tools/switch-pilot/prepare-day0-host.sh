#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${ROOT_DIR}/../.." && pwd)"
OUT_DIR="${REPO_DIR}/dist/switch-pilot"
# shellcheck source=/dev/null
source "${ROOT_DIR}/sd-root-lib.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${DARWIN_SWITCH_PREP_LOG:-${OUT_DIR}/day0-host-prep-${STAMP}.log}"

HEKATE_PAYLOAD=""
RCM_INJECTOR=""
SWITCHROOT_ARCHIVE=""
SD_ROOT=""
STAGE="any"
COPY_KIT=0
EJECT_SD=0
STRICT=0
REQUIRE_DARWIN_KIT=0

usage() {
  cat <<'EOF'
Usage: prepare-day0-host.sh [options]

Run the Mac/PC-side preparation sequence before a Switchroot + Darwin hardware
trial. By default this runs the release gate and a read-only host readiness
check. With --copy-kit-to-sd it also copies the Darwin install kit to the
mounted SD root and validates the copied kit before eject.

Options:
  --hekate-payload PATH       Hekate payload .bin to verify by filename/path.
  --rcm-injector PATH         Local RCM payload injection tool, binary, or .app.
  --switchroot-archive PATH   Switchroot L4T Ubuntu .7z archive to verify.
  --sd-root PATH|auto         Mounted SD FAT32 root, for layout/kit checks.
  --stage VALUE               before-flash|after-flash|any (default: any).
  --copy-kit-to-sd            Copy Darwin install kit to --sd-root.
  --eject-sd                  Validate, sync, and safely eject --sd-root.
  --require-darwin-kit        Require an existing Darwin kit on --sd-root.
  --strict                    Treat host-check warnings as failures.
  -h, --help                  Show this help.

Test-only environment:
  DARWIN_SWITCH_PREP_SKIP_RELEASE=1 skips verify-release.sh.
  DARWIN_SWITCH_PREP_LOG=/path/log overrides the log path.
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
    --stage)
      [[ "$#" -ge 2 ]] || { echo "ERROR: --stage needs a value" >&2; exit 2; }
      STAGE="$2"
      shift 2
      ;;
    --copy-kit-to-sd)
      COPY_KIT=1
      shift
      ;;
    --eject-sd)
      EJECT_SD=1
      shift
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

case "${STAGE}" in
  before-flash|after-flash|any) ;;
  *) echo "ERROR: invalid --stage: ${STAGE}" >&2; exit 2 ;;
esac

if [[ "${COPY_KIT}" -eq 1 && -z "${SD_ROOT}" ]]; then
  echo "ERROR: --copy-kit-to-sd needs --sd-root" >&2
  exit 2
fi

if [[ "${REQUIRE_DARWIN_KIT}" -eq 1 && -z "${SD_ROOT}" ]]; then
  echo "ERROR: --require-darwin-kit needs --sd-root" >&2
  exit 2
fi

if [[ "${EJECT_SD}" -eq 1 && -z "${SD_ROOT}" ]]; then
  echo "ERROR: --eject-sd needs --sd-root" >&2
  exit 2
fi

if [[ -n "${SD_ROOT}" ]]; then
  SD_ROOT="$(darwin_switch_resolve_sd_root "${SD_ROOT}")"
fi

mkdir -p "${OUT_DIR}"
exec > >(tee -a "${LOG}") 2>&1

host_args=()
[[ -n "${HEKATE_PAYLOAD}" ]] && host_args+=(--hekate-payload "${HEKATE_PAYLOAD}")
[[ -n "${RCM_INJECTOR}" ]] && host_args+=(--rcm-injector "${RCM_INJECTOR}")
[[ -n "${SWITCHROOT_ARCHIVE}" ]] && host_args+=(--switchroot-archive "${SWITCHROOT_ARCHIVE}")
[[ -n "${SD_ROOT}" ]] && host_args+=(--sd-root "${SD_ROOT}")
[[ "${STRICT}" -eq 1 ]] && host_args+=(--strict)

echo "== Darwin Switch day-0 host preparation =="
echo "Repo: ${REPO_DIR}"
echo "Log: ${LOG}"
echo "Stage: ${STAGE}"
echo "Copy kit to SD: ${COPY_KIT}"
echo "Eject SD: ${EJECT_SD}"
echo ""

if [[ "${DARWIN_SWITCH_PREP_SKIP_RELEASE:-0}" == "1" ]]; then
  echo "== Release gate =="
  echo "SKIP: DARWIN_SWITCH_PREP_SKIP_RELEASE=1"
else
  echo "== Release gate =="
  "${ROOT_DIR}/verify-release.sh"
fi

echo ""
echo "== Host readiness check =="
initial_args=("${host_args[@]}")
if [[ "${REQUIRE_DARWIN_KIT}" -eq 1 && "${COPY_KIT}" -eq 0 ]]; then
  initial_args+=(--require-darwin-kit)
fi
"${ROOT_DIR}/check-day0-host.sh" "${initial_args[@]}"

if [[ "${COPY_KIT}" -eq 1 ]]; then
  echo ""
  echo "== Copy Darwin install kit to SD =="
  "${ROOT_DIR}/copy-kit-to-sd.sh" --stage "${STAGE}" "${SD_ROOT}"

  echo ""
  echo "== Post-copy host readiness check =="
  post_args=("${host_args[@]}" --require-darwin-kit)
  "${ROOT_DIR}/check-day0-host.sh" "${post_args[@]}"
fi

if [[ "${EJECT_SD}" -eq 1 ]]; then
  echo ""
  echo "== Eject SD =="
  eject_args=(--stage "${STAGE}")
  if [[ "${COPY_KIT}" -eq 1 || "${REQUIRE_DARWIN_KIT}" -eq 1 ]]; then
    eject_args+=(--require-darwin-kit)
  fi
  "${ROOT_DIR}/eject-day0-sd.sh" "${eject_args[@]}" "${SD_ROOT}"
fi

echo ""
echo "Day-0 host preparation complete."
echo "Log: ${LOG}"
if [[ "${EJECT_SD}" -eq 1 ]]; then
  echo "Next hardware step: insert the ejected SD into the Switch, enter RCM, inject Hekate, then follow docs/guides/switchroot-darwin-day0-runbook.md."
else
  echo "Next hardware step: safely eject/unmount the SD, enter RCM, inject Hekate, then follow docs/guides/switchroot-darwin-day0-runbook.md."
fi
