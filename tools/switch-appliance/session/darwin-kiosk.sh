#!/usr/bin/env bash
set -euo pipefail

# darwin-kiosk.sh — kiosk entry point that the compositor execs.
#
# Idempotent and stateless: safe to re-run, holds no persistent state. The
# compositor (cage on Wayland, or openbox on X11) execs this once per session.
# Works under BOTH:
#   - cage (Wayland)  : darwin-kiosk.service runs `cage -- /usr/local/bin/darwin-kiosk.sh`
#   - openbox (X11)   : openbox-autostart execs this script directly
# The downstream launcher (darwin-switch-cockpit) auto-detects the display
# server when picking browser flags, so this script stays display-agnostic.

PROVISIONED_FLAG="/etc/darwin-switch-agent/.provisioned"
COCKPIT_URL_READY="http://127.0.0.1:8765/"
COCKPIT_URL_SETUP="http://127.0.0.1:8765/setup.html"
LAUNCHER="/usr/local/bin/darwin-switch-cockpit"

# Best-effort screen-blank / power-management off. The cockpit must never
# blank — an operator may stare at a still telemetry frame for minutes. Each
# tool is guarded so missing binaries do not abort the session (set -e safe).
if command -v xset >/dev/null 2>&1; then
  xset s off || true       # disable screensaver
  xset -dpms || true       # disable DPMS power management
  xset s noblank || true   # do not blank the video on screensaver timeout
fi

if command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.desktop.session idle-delay 0 >/dev/null 2>&1 || true
  gsettings set org.gnome.desktop.screensaver lock-enabled false >/dev/null 2>&1 || true
fi

# Choose URL by first-boot provisioning state. If the provisioned marker is
# MISSING we route to the setup page so the operator can complete provisioning;
# otherwise we open the live cockpit. Only override if the env did not already
# pin a URL (lets operators force a target for debugging).
if [[ ! -f "${PROVISIONED_FLAG}" ]]; then
  export DARWIN_SWITCH_COCKPIT_URL="${DARWIN_SWITCH_COCKPIT_URL:-${COCKPIT_URL_SETUP}}"
else
  export DARWIN_SWITCH_COCKPIT_URL="${DARWIN_SWITCH_COCKPIT_URL:-${COCKPIT_URL_READY}}"
fi

# Hand off to the existing launcher, which waits for :8765 readiness and then
# opens the browser in kiosk mode. exec replaces this process so the launcher
# becomes the session leader the compositor supervises.
if [[ ! -x "${LAUNCHER}" ]]; then
  echo "kiosk launcher not found or not executable: ${LAUNCHER}" >&2
  exit 1
fi

exec "${LAUNCHER}"
