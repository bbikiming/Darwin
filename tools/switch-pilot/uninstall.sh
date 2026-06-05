#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "uninstall.sh must be run with sudo" >&2
  exit 1
fi

systemctl disable --now darwin-switch-agent 2>/dev/null || true
rm -f /etc/systemd/system/darwin-switch-agent.service
rm -f /etc/xdg/autostart/darwin-switch-cockpit.desktop
rm -f /usr/share/applications/darwin-switch.desktop
rm -f /usr/local/bin/darwin-switch-cockpit
rm -f /usr/local/bin/darwin-switch-camera-tunnel
systemctl daemon-reload
rm -rf /opt/darwin-switch-agent

echo "Removed Darwin Switch Agent runtime."
echo "Configuration remains at /etc/darwin-switch-agent."
