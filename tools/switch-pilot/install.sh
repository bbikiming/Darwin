#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/darwin-switch-agent"
CONFIG_DIR="/etc/darwin-switch-agent"
SERVICE_PATH="/etc/systemd/system/darwin-switch-agent.service"
CAMERA_SERVICE_PATH="/etc/systemd/system/darwin-switch-camera-tunnel.service"
LAUNCHER_PATH="/usr/local/bin/darwin-switch-cockpit"
NATIVE_LAUNCHER_PATH="/usr/local/bin/darwin-switch-native-cockpit"
CAMERA_TUNNEL_PATH="/usr/local/bin/darwin-switch-camera-tunnel"
BOOTSTRAP_PATH="/usr/local/bin/darwin-switch-bootstrap-os"
DIAGNOSTICS_PATH="/usr/local/bin/darwin-switch-collect-diagnostics"
ACCEPTANCE_PATH="/usr/local/bin/darwin-switch-day0-acceptance"
INPUT_CHECK_PATH="/usr/local/bin/darwin-switch-input-check"
NETWORK_CHECK_PATH="/usr/local/bin/darwin-switch-network-check"
NATIVE_ACCEPTANCE_PATH="/usr/local/bin/darwin-switch-native-acceptance"
PREFLIGHT_PATH="/usr/local/bin/darwin-switch-preflight"
SMOKE_TEST_PATH="/usr/local/bin/darwin-switch-smoke-test"
ROBOT_READY_PATH="/usr/local/bin/darwin-switch-robot-ready"
AUTOSTART_PATH="/etc/xdg/autostart/darwin-switch-cockpit.desktop"
APP_DESKTOP_PATH="/usr/share/applications/darwin-switch.desktop"
NATIVE_APP_DESKTOP_PATH="/usr/share/applications/darwin-switch-native.desktop"
NO_AUTORUN="${DARWIN_SWITCH_NO_AUTORUN:-0}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "install.sh must be run with sudo" >&2
  exit 1
fi

# --- Preflight (idempotent) ---------------------------------------------------
# Fail early for primitives that the install cannot complete without.
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found — the agent and compile step require it." >&2
  echo "       Install it first:  sudo apt-get install python3" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl not found — Switchroot Ubuntu/systemd is required." >&2
  exit 1
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
# ships pre-baked as web/assets/darwin.glb, so the STL assembler, GLTF exporter,
# decimator, normal injector, and bake page are never needed at runtime on the
# Switch. Runtime keeps the cockpit, model-check.html, Three.js loader assets,
# robot3d.js, and web/assets/darwin.glb.
for _build_only in \
  web/build-glb.html \
  web/robot3d-rig.js \
  web/robot3d-test.html \
  web/vendor/STLLoader.js \
  web/vendor/GLTFExporter.js \
  web/vendor/TextureUtils.js \
  assets/decimate_glb.py \
  assets/add_glb_normals.py \
  package.sh \
  verify-release.sh \
  simulate-install-tree.sh \
  summarize-diagnostics.py \
  make-install-kit.sh \
  check-switchroot-sd.sh \
  check-day0-host.sh \
  prepare-day0-host.sh \
  copy-kit-to-sd.sh; do
  rm -f "${INSTALL_DIR}/${_build_only}"
done
rm -rf "${INSTALL_DIR}/tests"

if [[ ! -f "${CONFIG_DIR}/config.json" ]]; then
  install -m 0644 "${ROOT_DIR}/config.example.json" "${CONFIG_DIR}/config.json"
fi
chmod 0755 "${CONFIG_DIR}" 2>/dev/null || true
chmod 0644 "${CONFIG_DIR}/config.json" 2>/dev/null || true

# --- Non-interactive config writes (Mac DarwinForge "Switch Robot Link" bridge) ---
# The Mac app drives `darwin-switch-robot-ready stabilize|enable-agent-ssh` over
# BatchMode SSH (no TTY). For those to succeed without a sudo password prompt:
#   1) own the config by the operator user so robot_ready writes it directly, and
#   2) grant a *narrow* NOPASSWD rule for just the agent service lifecycle.
# Falls back silently to root-owned config (interactive sudo still works) if the
# operator user can't be determined.
INSTALL_USER="${SUDO_USER:-}"
if [[ -n "${INSTALL_USER}" && "${INSTALL_USER}" != "root" ]] && id "${INSTALL_USER}" >/dev/null 2>&1; then
  chown -R "${INSTALL_USER}":"$(id -gn "${INSTALL_USER}")" "${CONFIG_DIR}" 2>/dev/null || true
  SUDOERS_FILE="/etc/sudoers.d/darwin-switch-agent"
  SYSTEMCTL_BIN="$(command -v systemctl || echo /usr/bin/systemctl)"
  TMP_SUDOERS="$(mktemp)"
  cat > "${TMP_SUDOERS}" <<EOF
# Installed by darwin-switch-agent install.sh — lets the operator restart the
# agent non-interactively (Mac DarwinForge bridge). Narrowly scoped to one unit.
${INSTALL_USER} ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} restart darwin-switch-agent.service, ${SYSTEMCTL_BIN} start darwin-switch-agent.service, ${SYSTEMCTL_BIN} stop darwin-switch-agent.service, ${SYSTEMCTL_BIN} is-active darwin-switch-agent.service
EOF
  if visudo -cf "${TMP_SUDOERS}" >/dev/null 2>&1; then
    install -m 0440 "${TMP_SUDOERS}" "${SUDOERS_FILE}"
    echo "  ✓ NOPASSWD sudoers for agent restart: ${SUDOERS_FILE} (user=${INSTALL_USER})"
  else
    echo "  ! sudoers validation failed — skipping NOPASSWD rule (interactive sudo still works)" >&2
  fi
  rm -f "${TMP_SUDOERS}"
fi

install -m 0644 "${ROOT_DIR}/systemd/darwin-switch-agent.service" "${SERVICE_PATH}"
install -m 0644 "${ROOT_DIR}/systemd/darwin-switch-camera-tunnel.service" "${CAMERA_SERVICE_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-cockpit" "${LAUNCHER_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-native-cockpit" "${NATIVE_LAUNCHER_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-camera-tunnel" "${CAMERA_TUNNEL_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-bootstrap-os" "${BOOTSTRAP_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-collect-diagnostics" "${DIAGNOSTICS_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-day0-acceptance" "${ACCEPTANCE_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-input-check" "${INPUT_CHECK_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-network-check" "${NETWORK_CHECK_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-native-acceptance" "${NATIVE_ACCEPTANCE_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-preflight" "${PREFLIGHT_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-smoke-test" "${SMOKE_TEST_PATH}"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-robot-ready" "${ROBOT_READY_PATH}"
if [[ "${NO_AUTORUN}" == "1" || "${NO_AUTORUN}" == "true" ]]; then
  rm -f "${AUTOSTART_PATH}"
  echo "Skipped desktop autostart install (DARWIN_SWITCH_NO_AUTORUN=${NO_AUTORUN})."
else
  install -m 0644 "${ROOT_DIR}/desktop/darwin-switch-cockpit.desktop" "${AUTOSTART_PATH}"
fi
install -m 0644 "${ROOT_DIR}/desktop/darwin-switch.desktop" "${APP_DESKTOP_PATH}"
install -m 0644 "${ROOT_DIR}/desktop/darwin-switch-native.desktop" "${NATIVE_APP_DESKTOP_PATH}"

python3 -m compileall -q "${INSTALL_DIR}/src"

systemctl daemon-reload

echo "Installed Darwin Switch Agent."
echo ""
echo "Post-install readiness:"
PYTHONPATH="${INSTALL_DIR}/src" python3 -m darwin_switch_agent.preflight \
  --root "${INSTALL_DIR}" \
  --config "${CONFIG_DIR}/config.json" \
  --installed || true
echo ""
echo "Edit: sudo nano ${CONFIG_DIR}/config.json"
echo "Start: sudo systemctl enable --now darwin-switch-agent"
echo "Logs:  journalctl -u darwin-switch-agent -f"
if [[ "${NO_AUTORUN}" == "1" || "${NO_AUTORUN}" == "true" ]]; then
  echo "GUI:   manual launch only; desktop autostart was not installed"
else
  echo "GUI:   http://127.0.0.1:8765/ opens automatically on desktop login"
fi
echo "Native GUI: darwin-switch-native-cockpit"
echo "Native GUI deps: checked by preflight; bootstrap installs python3-gi gir1.2-gtk-3.0 when missing"
echo "Camera tunnel: ROBOT_HOST=192.168.123.1 darwin-switch-camera-tunnel"
echo "Camera service: sudo systemctl enable --now darwin-switch-camera-tunnel"
echo "Readiness: darwin-switch-preflight --installed"
echo "Acceptance: darwin-switch-day0-acceptance --input-seconds 8 --strict"
echo "Native acceptance: darwin-switch-native-acceptance --strict"
echo "Input check: darwin-switch-input-check --seconds 8"
echo "Network check: darwin-switch-network-check"
echo "Robot SSH ready: darwin-switch-robot-ready plan"
echo "Diagnostics: darwin-switch-collect-diagnostics"
echo "Smoke test: darwin-switch-smoke-test --installed"
