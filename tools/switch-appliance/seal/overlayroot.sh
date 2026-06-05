#!/usr/bin/env bash
set -euo pipefail

# overlayroot.sh — OPT-IN: make the rootfs read-only with a tmpfs overlay.
#
# This is post-MVP hardening. Once enabled, every write to / is discarded on
# reboot, so misconfiguring a persistent mount can make the box look "stuck"
# (changes silently vanish). Because that is easy to get wrong, this script
# REFUSES to run unless you pass --confirm. It is intentionally NOT called by
# apply-appliance.sh by default. Idempotent: re-running re-copies the conf.

if [[ "${EUID}" -ne 0 ]]; then
  echo "overlayroot.sh must be run with sudo" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_CONF="${ROOT_DIR}/overlayroot.conf"
DST_CONF="/etc/overlayroot.conf"

CONFIRM="${1:-}"
if [[ "${CONFIRM}" != "--confirm" ]]; then
  echo "overlayroot.sh refuses to run without --confirm." >&2
  echo "Reason: this makes the rootfs READ-ONLY (writes discarded on reboot)." >&2
  echo "        It is post-MVP hardening only and is NOT part of the default" >&2
  echo "        apply-appliance.sh flow. Re-run with:" >&2
  echo "          sudo ${BASH_SOURCE[0]} --confirm" >&2
  exit 2
fi

if [[ ! -f "${SRC_CONF}" ]]; then
  echo "ERROR: ${SRC_CONF} not found next to this script; cannot continue." >&2
  exit 1
fi

# Install the overlayroot package. Non-fatal if offline / already installed.
if command -v apt-get >/dev/null 2>&1; then
  echo "Installing overlayroot..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y overlayroot >/dev/null 2>&1; then
    echo "WARNING: apt-get install overlayroot failed (offline?); continuing." >&2
  fi
else
  echo "WARNING: no apt-get; assuming overlayroot is provided by the image." >&2
fi

# Copy our managed conf into place (drop-in style: replace the whole file).
install -m 0644 "${SRC_CONF}" "${DST_CONF}"
echo "Installed ${DST_CONF}:"
grep -v '^#' "${DST_CONF}" | grep -v '^$' || true

echo
echo "overlayroot is configured but NOT active until you reboot."
echo "Before rebooting, confirm /etc/darwin-switch-agent and the agent log"
echo "directory live on a persistent writable mount, or their data is LOST."
echo "When ready: sudo reboot"
