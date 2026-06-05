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

# --- Preflight (non-fatal, idempotent) ---------------------------------------
# warn if python3 is missing: the agent and the compileall step below need it.
if ! command -v python3 >/dev/null 2>&1; then
  echo "WARNING: python3 not found — the agent and 'compileall' will fail." >&2
  echo "         Install it:  sudo apt-get install python3" >&2
fi

# joycond merges paired Joy-Cons into one virtual gamepad the agent can read.
# Enable it when present; never fatal (offline / image without it).
if systemctl list-unit-files 2>/dev/null | grep -q '^joycond\.service'; then
  systemctl enable --now joycond >/dev/null 2>&1 \
    && echo "Enabled joycond.service (Joy-Con pairing)." \
    || echo "WARNING: joycond present but could not be enabled." >&2
else
  echo "NOTE: joycond not installed — install it for Joy-Con support:" >&2
  echo "      sudo apt-get install joycond" >&2
fi

# Give the operator account that invoked sudo /dev/input access (evtest, etc).
# The agent service runs as root, so this is only for the interactive admin.
# Guarded: skip when run as plain root (no SUDO_USER) or the group is absent.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] \
  && getent group input >/dev/null 2>&1; then
  if id -nG "${SUDO_USER}" 2>/dev/null | tr ' ' '\n' | grep -qx input; then
    echo "User ${SUDO_USER} already in group input."
  else
    usermod -aG input "${SUDO_USER}" \
      && echo "Added ${SUDO_USER} to group input (re-login to apply)." \
      || echo "WARNING: could not add ${SUDO_USER} to group input." >&2
  fi
fi

install -d "${INSTALL_DIR}" "${CONFIG_DIR}"
find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a "${ROOT_DIR}/." "${INSTALL_DIR}/"
find "${INSTALL_DIR}" -name "__pycache__" -type d -prune -exec rm -rf {} +

# Drop the offline GLB-bake tooling from the installed cockpit — the robot model
# ships pre-baked as web/assets/darwin.glb, so the STL assembler, GLTF exporter
# and bake page are never needed at runtime on the Switch.
for _build_only in \
  web/build-glb.html \
  web/robot3d-rig.js \
  web/robot3d-test.html \
  web/vendor/STLLoader.js \
  web/vendor/GLTFExporter.js \
  web/vendor/TextureUtils.js \
  assets/decimate_glb.py; do
  rm -f "${INSTALL_DIR}/${_build_only}"
done

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
