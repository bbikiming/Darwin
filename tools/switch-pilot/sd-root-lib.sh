#!/usr/bin/env bash

darwin_switch_sd_scan_roots() {
  if [[ -n "${DARWIN_SWITCH_SD_SCAN_ROOTS:-}" ]]; then
    local IFS=":"
    for root in ${DARWIN_SWITCH_SD_SCAN_ROOTS}; do
      [[ -n "${root}" ]] && printf '%s\n' "${root}"
    done
    return
  fi

  case "$(uname -s 2>/dev/null || printf unknown)" in
    Darwin)
      printf '%s\n' /Volumes
      ;;
    Linux)
      [[ -n "${USER:-}" ]] && printf '%s\n' "/media/${USER}" "/run/media/${USER}"
      printf '%s\n' /media /run/media /mnt
      ;;
    *)
      printf '%s\n' /Volumes /media /mnt
      ;;
  esac
}

darwin_switch_is_plausible_sd_root() {
  local path="$1"
  [[ -d "${path}/bootloader" && -d "${path}/switchroot" ]]
}

darwin_switch_sd_candidates() {
  local root=""
  local candidate=""
  while IFS= read -r root; do
    [[ -d "${root}" ]] || continue
    while IFS= read -r candidate; do
      [[ -d "${candidate}" ]] || continue
      [[ -L "${candidate}" && "$(readlink "${candidate}" 2>/dev/null || true)" == "/" ]] && continue
      if darwin_switch_is_plausible_sd_root "${candidate}"; then
        printf '%s\n' "${candidate}"
      fi
    done < <(find "${root}" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort)
  done < <(darwin_switch_sd_scan_roots)
}

darwin_switch_resolve_sd_root() {
  local requested="$1"
  if [[ "${requested}" != "auto" ]]; then
    printf '%s\n' "${requested}"
    return 0
  fi

  local candidates=()
  local candidate=""
  while IFS= read -r candidate; do
    [[ -n "${candidate}" ]] && candidates+=("${candidate}")
  done < <(darwin_switch_sd_candidates)

  case "${#candidates[@]}" in
    0)
      echo "ERROR: --sd-root auto found no mounted Switchroot SD root." >&2
      echo "Expected exactly one mounted volume containing bootloader/ and switchroot/." >&2
      return 2
      ;;
    1)
      printf '%s\n' "${candidates[0]}"
      ;;
    *)
      echo "ERROR: --sd-root auto found multiple Switchroot SD candidates:" >&2
      printf '  %s\n' "${candidates[@]}" >&2
      echo "Pass --sd-root /Volumes/<SD_NAME> explicitly." >&2
      return 2
      ;;
  esac
}
