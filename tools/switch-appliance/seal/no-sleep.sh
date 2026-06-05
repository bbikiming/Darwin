#!/usr/bin/env bash
set -euo pipefail

# no-sleep.sh — HARD-block all power-saving on the Darwin Switch appliance.
#
# Robot safety: a suspend/sleep while the operator is driving the robot is
# dangerous — the control loop, deadman and watchdog all freeze mid-motion.
# This script masks the sleep targets and tells logind to ignore every
# power/lid/idle event. Idempotent: safe to re-run any number of times.

if [[ "${EUID}" -ne 0 ]]; then
  echo "no-sleep.sh must be run with sudo" >&2
  exit 1
fi

LOGIND_DROPIN_DIR="/etc/systemd/logind.conf.d"
LOGIND_DROPIN="${LOGIND_DROPIN_DIR}/darwin-no-sleep.conf"

SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)

# Mask the sleep targets so nothing (UI, logind, scripts) can trigger them.
# `systemctl mask` is itself idempotent, but we guard so an already-masked
# unit never aborts the run.
for target in "${SLEEP_TARGETS[@]}"; do
  if systemctl mask "${target}" >/dev/null 2>&1; then
    echo "Masked ${target}."
  else
    echo "WARNING: could not mask ${target} (already masked or unavailable)." >&2
  fi
done

# Drop-in config instead of editing /etc/systemd/logind.conf in place.
# NOTE: the power/sleep key is intentionally ignored here so the
# power-button-stop handler can turn it into a robot STOP instead of a
# silent suspend.
install -d -m 0755 "${LOGIND_DROPIN_DIR}"
cat > "${LOGIND_DROPIN}" <<'EOF'
# Managed by darwin-switch-appliance seal/no-sleep.sh — do not edit by hand.
# Power-saving is hard-disabled for robot safety (no suspend during control).
# The power/sleep key is intentionally ignored here so the power-button-stop
# handler can turn it into a robot STOP instead of a silent suspend.
[Login]
HandleSuspendKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandlePowerKey=ignore
IdleAction=ignore
EOF
chmod 0644 "${LOGIND_DROPIN}"
echo "Wrote ${LOGIND_DROPIN}."

# Apply the new logind policy. Restarting logind is safe on a kiosk box.
if systemctl restart systemd-logind >/dev/null 2>&1; then
  echo "Restarted systemd-logind."
else
  echo "WARNING: failed to restart systemd-logind; reboot to apply." >&2
fi

echo "no-sleep seal applied."
