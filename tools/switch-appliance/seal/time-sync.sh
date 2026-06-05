#!/usr/bin/env bash
set -euo pipefail

# time-sync.sh — enable NTP at boot on the Darwin Switch appliance.
#
# WHY THIS EXISTS (Switch-specific, load-bearing):
#   The Nintendo Switch has NO usable RTC for Linux. After a power-off the
#   clock can read ~19 years off, which breaks TLS handshakes, scrambles
#   journald ordering, and corrupts any time-based logic. The only fix is to
#   sync over the network every boot. Evidence: L4T community (NX-ntpc /
#   QuickNTP exist precisely for this) and
#   docs/reports/2026-06-05-switch-appliance-evidence-based-architecture.md
#   §3.6 ("Switch L4T RTC 문제").
#
# This enables systemd-timesyncd when present (the L4T default), else tries to
# install chrony via apt (non-fatal when offline). Timezone is set only when it
# is still unset, and never interactively. Idempotent: safe to re-run.
#
# IMPORTANT FOR THE AGENT / COCKPIT: because the wall-clock is garbage until
# NTP lands, the agent and cockpit MUST NOT gate any behaviour on wall-clock
# time. Use CLOCK_MONOTONIC for deadman/stop/estop/watchdog timing. This script
# only makes the eventual clock correct; it does not make early-boot time
# trustworthy. (See the printed NOTE at the end.)

if [[ "${EUID}" -ne 0 ]]; then
  echo "time-sync.sh must be run with sudo" >&2
  exit 1
fi

# enable_timesyncd — turn on the systemd-timesyncd path. Returns 0 on success.
enable_timesyncd() {
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd\.service'; then
    return 1
  fi
  # `timedatectl set-ntp true` is the canonical, idempotent enable; fall back
  # to enabling the unit directly if timedatectl is unavailable.
  if command -v timedatectl >/dev/null 2>&1 && timedatectl set-ntp true >/dev/null 2>&1; then
    echo "Enabled NTP via systemd-timesyncd (timedatectl set-ntp true)."
  elif systemctl enable --now systemd-timesyncd >/dev/null 2>&1; then
    echo "Enabled systemd-timesyncd (systemctl enable --now)."
  else
    echo "WARNING: systemd-timesyncd present but could not be enabled." >&2
    return 1
  fi
  return 0
}

# enable_chrony — fallback NTP daemon. apt install is non-fatal when offline.
enable_chrony() {
  if ! command -v chronyd >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      echo "systemd-timesyncd absent; installing chrony (offline-tolerant)..."
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y chrony >/dev/null 2>&1; then
        echo "WARNING: apt-get install chrony failed (offline?); no NTP enabled." >&2
        return 1
      fi
    else
      echo "WARNING: no systemd-timesyncd, no chronyd, no apt-get; cannot enable NTP." >&2
      return 1
    fi
  fi
  if systemctl enable --now chrony >/dev/null 2>&1 \
    || systemctl enable --now chronyd >/dev/null 2>&1; then
    echo "Enabled chrony NTP service."
    return 0
  fi
  echo "WARNING: chrony installed but its service could not be enabled." >&2
  return 1
}

# set_timezone_if_unset — only act when no zone is configured, never prompt.
set_timezone_if_unset() {
  if ! command -v timedatectl >/dev/null 2>&1; then
    echo "WARNING: timedatectl absent; leaving timezone as-is." >&2
    return 0
  fi
  local current
  current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [[ -n "${current}" && "${current}" != "n/a" && "${current}" != "Etc/UTC" ]]; then
    echo "Timezone already set (${current}); leaving it unchanged."
    return 0
  fi
  # Default to UTC: unambiguous, never interactive, correct for journald/TLS.
  if timedatectl set-timezone Etc/UTC >/dev/null 2>&1; then
    echo "Timezone was unset; defaulted to Etc/UTC (non-interactive)."
  else
    echo "WARNING: could not set timezone to Etc/UTC; leaving as-is." >&2
  fi
}

if ! enable_timesyncd; then
  enable_chrony || echo "WARNING: NTP not enabled — clock will stay wrong until fixed." >&2
fi

set_timezone_if_unset

cat <<'NOTE'

----------------------------------------------------------------------
NOTE — Switch RTC is unreliable; NTP at boot is REQUIRED.
  The Switch has no usable RTC for Linux: after power-off the clock can be
  ~19 years off, breaking TLS, journald ordering and time-based logic. This
  seal enables network time sync so the clock becomes correct once online.

  The agent and cockpit MUST NOT gate any logic on the wall-clock. All
  deadman / stop / estop / watchdog timing uses CLOCK_MONOTONIC, which is
  immune to the bogus wall-clock. Until NTP lands, treat wall-clock as
  untrusted.
----------------------------------------------------------------------
NOTE

echo "time-sync seal applied."
