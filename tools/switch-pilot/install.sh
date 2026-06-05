#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/darwin-switch-agent"
CONFIG_DIR="/etc/darwin-switch-agent"
SERVICE_PATH="/etc/systemd/system/darwin-switch-agent.service"
LAUNCHER_PATH="/usr/local/bin/darwin-switch-cockpit"
CAMERA_TUNNEL_PATH="/usr/local/bin/darwin-switch-camera-tunnel"
AUTOSTART_PATH="/etc/xdg/autostart/darwin-switch-cockpit.desktop"
APP_DESKTOP_PATH="/usr/share/applications/darwin-switch.desktop"

if [[ "${EUID}" -ne 0 ]]; then
  echo "install.sh must be run with sudo" >&2
  exit 1
fi

install -d "${INSTALL_DIR}" "${CONFIG_DIR}"
find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a "${ROOT_DIR}/." "${INSTALL_DIR}/"
find "${INSTALL_DIR}" -name "__pycache__" -type d -prune -exec rm -rf {} +

if [[ ! -f "${CONFIG_DIR}/config.json" ]]; then
  install -m 0644 "${ROOT_DIR}/config.example.json" "${CONFIG_DIR}/config.json"
fi

install -m 0644 "${ROOT_DIR}/systemd/darwin-switch-agent.service" "${SERVICE_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-cockpit" "${LAUNCHER_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-camera-tunnel" "${CAMERA_TUNNEL_PATH}"
install -m 0644 "${ROOT_DIR}/desktop/darwin-switch-cockpit.desktop" "${AUTOSTART_PATH}"
install -m 0644 "${ROOT_DIR}/desktop/darwin-switch.desktop" "${APP_DESKTOP_PATH}"

python3 -m compileall -q "${INSTALL_DIR}/src"

systemctl daemon-reload

echo "Installed Darwin Switch Agent."
echo "Edit: sudo nano ${CONFIG_DIR}/config.json"
echo "Start: sudo systemctl enable --now darwin-switch-agent"
echo "Logs:  journalctl -u darwin-switch-agent -f"
echo "GUI:   http://127.0.0.1:8765/ opens automatically on desktop login"
echo "Camera tunnel: ROBOT_HOST=192.168.123.1 darwin-switch-camera-tunnel"
