#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEP=0
SIM_ROOT=""

usage() {
  cat <<'EOF'
Usage: simulate-install-tree.sh [--keep] [--root PATH]

Build a fake installed filesystem tree under a temporary directory and verify
that the runtime files, launchers, config, systemd units, and desktop files line
up without writing to /opt, /etc, or /usr/local/bin.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --keep)
      KEEP=1
      shift
      ;;
    --root)
      [[ "$#" -ge 2 ]] || { echo "ERROR: --root needs a path" >&2; exit 2; }
      SIM_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${SIM_ROOT}" ]]; then
  SIM_ROOT="$(mktemp -d)"
fi

if [[ "${KEEP}" -eq 0 ]]; then
  trap 'rm -rf "${SIM_ROOT}"' EXIT
fi

INSTALL_DIR="${SIM_ROOT}/opt/darwin-switch-agent"
CONFIG_DIR="${SIM_ROOT}/etc/darwin-switch-agent"
USR_BIN="${SIM_ROOT}/usr/local/bin"
SYSTEMD_DIR="${SIM_ROOT}/etc/systemd/system"
AUTOSTART_DIR="${SIM_ROOT}/etc/xdg/autostart"
APP_DIR="${SIM_ROOT}/usr/share/applications"

rm -rf "${INSTALL_DIR}" "${CONFIG_DIR}" "${USR_BIN}" "${SYSTEMD_DIR}" "${AUTOSTART_DIR}" "${APP_DIR}"
install -d "${INSTALL_DIR}" "${CONFIG_DIR}" "${USR_BIN}" "${SYSTEMD_DIR}" "${AUTOSTART_DIR}" "${APP_DIR}"

cp -a "${ROOT_DIR}/." "${INSTALL_DIR}/"
find "${INSTALL_DIR}" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "${INSTALL_DIR}" -name "*.pyc" -delete
find "${INSTALL_DIR}" -name ".DS_Store" -delete

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
  copy-kit-to-sd.sh \
  eject-day0-sd.sh \
  find-switchroot-sd.sh \
  sd-root-lib.sh; do
  rm -f "${INSTALL_DIR}/${_build_only}"
done
rm -rf "${INSTALL_DIR}/tests"

install -m 0644 "${ROOT_DIR}/config.example.json" "${CONFIG_DIR}/config.json"
install -m 0644 "${ROOT_DIR}/systemd/darwin-switch-agent.service" "${SYSTEMD_DIR}/darwin-switch-agent.service"
install -m 0644 "${ROOT_DIR}/systemd/darwin-switch-camera-tunnel.service" "${SYSTEMD_DIR}/darwin-switch-camera-tunnel.service"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-cockpit" "${USR_BIN}/darwin-switch-cockpit"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-native-cockpit" "${USR_BIN}/darwin-switch-native-cockpit"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-camera-tunnel" "${USR_BIN}/darwin-switch-camera-tunnel"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-bootstrap-os" "${USR_BIN}/darwin-switch-bootstrap-os"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-collect-diagnostics" "${USR_BIN}/darwin-switch-collect-diagnostics"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-day0-acceptance" "${USR_BIN}/darwin-switch-day0-acceptance"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-input-check" "${USR_BIN}/darwin-switch-input-check"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-network-check" "${USR_BIN}/darwin-switch-network-check"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-native-acceptance" "${USR_BIN}/darwin-switch-native-acceptance"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-preflight" "${USR_BIN}/darwin-switch-preflight"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-smoke-test" "${USR_BIN}/darwin-switch-smoke-test"
install -m 0755 "${ROOT_DIR}/bin/darwin-switch-robot-ready" "${USR_BIN}/darwin-switch-robot-ready"
install -m 0644 "${ROOT_DIR}/desktop/darwin-switch-cockpit.desktop" "${AUTOSTART_DIR}/darwin-switch-cockpit.desktop"
install -m 0644 "${ROOT_DIR}/desktop/darwin-switch.desktop" "${APP_DIR}/darwin-switch.desktop"
install -m 0644 "${ROOT_DIR}/desktop/darwin-switch-native.desktop" "${APP_DIR}/darwin-switch-native.desktop"

python3 -m compileall -q "${INSTALL_DIR}/src"
find "${INSTALL_DIR}" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "${INSTALL_DIR}" -name "*.pyc" -delete

PYTHONPATH="${INSTALL_DIR}/src" python3 -m darwin_switch_agent.preflight \
  --root "${INSTALL_DIR}" \
  --config "${CONFIG_DIR}/config.json" \
  --bundle-only \
  --strict >/dev/null

DARWIN_SWITCH_ROOT="${INSTALL_DIR}" "${USR_BIN}/darwin-switch-preflight" --help >/dev/null
DARWIN_SWITCH_ROOT="${INSTALL_DIR}" "${USR_BIN}/darwin-switch-input-check" --help >/dev/null
DARWIN_SWITCH_ROOT="${INSTALL_DIR}" "${USR_BIN}/darwin-switch-network-check" --help >/dev/null
DARWIN_SWITCH_ROOT="${INSTALL_DIR}" "${USR_BIN}/darwin-switch-native-acceptance" --help >/dev/null
DARWIN_SWITCH_ROOT="${INSTALL_DIR}" "${USR_BIN}/darwin-switch-bootstrap-os" --help >/dev/null
DARWIN_SWITCH_ROOT="${INSTALL_DIR}" "${USR_BIN}/darwin-switch-collect-diagnostics" --help >/dev/null
DARWIN_SWITCH_ROOT="${INSTALL_DIR}" "${USR_BIN}/darwin-switch-day0-acceptance" --help >/dev/null

find "${INSTALL_DIR}" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "${INSTALL_DIR}" -name "*.pyc" -delete

required=(
  "${INSTALL_DIR}/web/index.html"
  "${INSTALL_DIR}/web/setup.html"
  "${INSTALL_DIR}/web/model-check.html"
  "${INSTALL_DIR}/web/assets/darwin.glb"
  "${CONFIG_DIR}/config.json"
  "${SYSTEMD_DIR}/darwin-switch-agent.service"
  "${SYSTEMD_DIR}/darwin-switch-camera-tunnel.service"
  "${AUTOSTART_DIR}/darwin-switch-cockpit.desktop"
  "${APP_DIR}/darwin-switch.desktop"
  "${APP_DIR}/darwin-switch-native.desktop"
  "${USR_BIN}/darwin-switch-cockpit"
  "${USR_BIN}/darwin-switch-native-cockpit"
  "${USR_BIN}/darwin-switch-camera-tunnel"
  "${USR_BIN}/darwin-switch-bootstrap-os"
  "${USR_BIN}/darwin-switch-collect-diagnostics"
  "${USR_BIN}/darwin-switch-day0-acceptance"
  "${USR_BIN}/darwin-switch-input-check"
  "${USR_BIN}/darwin-switch-network-check"
  "${USR_BIN}/darwin-switch-native-acceptance"
  "${USR_BIN}/darwin-switch-preflight"
  "${USR_BIN}/darwin-switch-smoke-test"
  "${USR_BIN}/darwin-switch-robot-ready"
)

for path in "${required[@]}"; do
  [[ -e "${path}" ]] || { echo "ERROR: missing simulated install path: ${path}" >&2; exit 2; }
done

python3 - "${SIM_ROOT}" <<'PY'
from __future__ import annotations

import shlex
import sys
from pathlib import Path

sim = Path(sys.argv[1])


def sim_path(absolute: str) -> Path:
    if not absolute.startswith("/"):
        raise SystemExit(f"ERROR: expected absolute path, got {absolute}")
    return sim / absolute.lstrip("/")


def values(path: Path, key: str) -> list[str]:
    out: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        left, right = line.split("=", 1)
        if left.strip() == key:
            out.append(right.strip())
    return out


def require(path: Path, label: str) -> None:
    if not path.exists():
        raise SystemExit(f"ERROR: {label} path is missing in simulated tree: {path}")


agent_unit = sim_path("/etc/systemd/system/darwin-switch-agent.service")
camera_unit = sim_path("/etc/systemd/system/darwin-switch-camera-tunnel.service")
autostart = sim_path("/etc/xdg/autostart/darwin-switch-cockpit.desktop")
app_desktop = sim_path("/usr/share/applications/darwin-switch.desktop")
native_desktop = sim_path("/usr/share/applications/darwin-switch-native.desktop")

envs = values(agent_unit, "Environment")
pythonpath = next((item.split("=", 1)[1] for item in envs if item.startswith("PYTHONPATH=")), "")
if pythonpath != "/opt/darwin-switch-agent/src":
    raise SystemExit(f"ERROR: agent unit PYTHONPATH mismatch: {pythonpath}")
require(sim_path(pythonpath), "agent PYTHONPATH")
require(sim_path("/opt/darwin-switch-agent/src/darwin_switch_agent/main.py"), "agent module")

agent_execs = values(agent_unit, "ExecStart")
if len(agent_execs) != 1:
    raise SystemExit("ERROR: agent unit must have exactly one ExecStart")
agent_args = shlex.split(agent_execs[0])
if agent_args[:3] != ["/usr/bin/python3", "-m", "darwin_switch_agent.main"]:
    raise SystemExit(f"ERROR: unexpected agent ExecStart: {agent_execs[0]}")
if "--config" not in agent_args:
    raise SystemExit("ERROR: agent ExecStart lacks --config")
require(sim_path(agent_args[agent_args.index("--config") + 1]), "agent config")

part_of = values(camera_unit, "PartOf")
if "darwin-switch-agent.service" not in part_of:
    raise SystemExit("ERROR: camera unit must be PartOf darwin-switch-agent.service")

camera_execs = values(camera_unit, "ExecStart")
if len(camera_execs) != 1:
    raise SystemExit("ERROR: camera unit must have exactly one ExecStart")
camera_args = shlex.split(camera_execs[0])
require(sim_path(camera_args[0]), "camera tunnel ExecStart")
if "--from-config" not in camera_args:
    raise SystemExit("ERROR: camera tunnel ExecStart lacks --from-config")
require(sim_path(camera_args[camera_args.index("--from-config") + 1]), "camera tunnel config")

for desktop in (autostart, app_desktop, native_desktop):
    execs = values(desktop, "Exec")
    icons = values(desktop, "Icon")
    if len(execs) != 1:
        raise SystemExit(f"ERROR: {desktop.name} must have exactly one Exec")
    if len(icons) != 1:
        raise SystemExit(f"ERROR: {desktop.name} must have exactly one Icon")
    require(sim_path(shlex.split(execs[0])[0]), f"{desktop.name} Exec")
    require(sim_path(icons[0]), f"{desktop.name} Icon")
PY

if find "${INSTALL_DIR}" \( -name "__pycache__" -o -name "*.pyc" -o -name ".DS_Store" \) | rg . >/dev/null; then
  echo "ERROR: simulated install tree contains generated Python/macOS files" >&2
  exit 2
fi

if find "${INSTALL_DIR}" \( \
    -name "build-glb.html" \
    -o -name "robot3d-rig.js" \
    -o -name "robot3d-test.html" \
    -o -name "STLLoader.js" \
    -o -name "GLTFExporter.js" \
    -o -name "TextureUtils.js" \
    -o -name "decimate_glb.py" \
    -o -name "add_glb_normals.py" \
    -o -name "package.sh" \
    -o -name "verify-release.sh" \
    -o -name "simulate-install-tree.sh" \
    -o -name "summarize-diagnostics.py" \
    -o -name "make-install-kit.sh" \
    -o -name "check-switchroot-sd.sh" \
    -o -name "check-day0-host.sh" \
    -o -name "prepare-day0-host.sh" \
    -o -name "copy-kit-to-sd.sh" \
    -o -name "eject-day0-sd.sh" \
    -o -name "find-switchroot-sd.sh" \
    -o -name "sd-root-lib.sh" \
  \) | rg . >/dev/null; then
  echo "ERROR: simulated install tree contains build-only files" >&2
  exit 2
fi

if [[ -d "${INSTALL_DIR}/tests" ]]; then
  echo "ERROR: simulated install tree contains tests" >&2
  exit 2
fi

echo "OK: simulated install tree ${SIM_ROOT}"
