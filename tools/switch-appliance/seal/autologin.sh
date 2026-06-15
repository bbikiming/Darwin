#!/usr/bin/env bash
set -euo pipefail

# autologin.sh — create the unprivileged 'darwin' user and auto-login tty1.
#
# The appliance boots straight to a sealed kiosk. tty1 auto-logs-in the
# dedicated 'darwin' user, then the kiosk session (cage) is started
# separately by darwin-kiosk.service. This script never runs the agent as
# root for the session; the agent's own systemd unit handles privileged work.
# Idempotent: re-running re-asserts the user, groups and the getty drop-in.

if [[ "${EUID}" -ne 0 ]]; then
  echo "autologin.sh must be run with sudo" >&2
  exit 1
fi

DARWIN_USER="darwin"
# Groups needed for /dev/input (gamepad) and serial (/dev/ttyUSB*) access.
DARWIN_GROUPS=(input video dialout plugdev render)

GETTY_DROPIN_DIR="/etc/systemd/system/getty@tty1.service.d"
GETTY_DROPIN="${GETTY_DROPIN_DIR}/override.conf"

# Create the dedicated user only if missing.
if id -u "${DARWIN_USER}" >/dev/null 2>&1; then
  echo "User ${DARWIN_USER} already exists."
else
  useradd -m -s /bin/bash "${DARWIN_USER}"
  echo "Created user ${DARWIN_USER}."
fi

# Add to each group, guarded so a group that does not exist on this distro
# (e.g. 'render' on older kernels) does not abort the whole script.
for grp in "${DARWIN_GROUPS[@]}"; do
  if getent group "${grp}" >/dev/null 2>&1; then
    if id -nG "${DARWIN_USER}" | tr ' ' '\n' | grep -qx "${grp}"; then
      echo "User ${DARWIN_USER} already in group ${grp}."
    else
      usermod -aG "${grp}" "${DARWIN_USER}"
      echo "Added ${DARWIN_USER} to group ${grp}."
    fi
  else
    echo "WARNING: group ${grp} not present; skipping." >&2
  fi
done

# Console autologin via a systemd drop-in (no edit of the shipped unit).
# Clear ExecStart first, then re-set it with --autologin for 'darwin'.
install -d -m 0755 "${GETTY_DROPIN_DIR}"
cat > "${GETTY_DROPIN}" <<EOF
# Managed by darwin-switch-appliance seal/autologin.sh — do not edit by hand.
# Auto-login the unprivileged 'darwin' user on tty1. The kiosk session (cage)
# is started separately by darwin-kiosk.service.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${DARWIN_USER} --noclear %I \$TERM
EOF
chmod 0644 "${GETTY_DROPIN}"
echo "Wrote ${GETTY_DROPIN}."

systemctl daemon-reload
echo "autologin seal applied (reboot or restart getty@tty1 to take effect)."
