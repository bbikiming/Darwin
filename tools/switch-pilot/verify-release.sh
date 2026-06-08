#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${ROOT_DIR}/../.." && pwd)"
PKG_PATH=""
KIT_PATH=""

check_sha256_file() {
  local checksum_file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c "${checksum_file}"
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "${checksum_file}"
  else
    echo "ERROR: no SHA-256 checksum tool found" >&2
    return 127
  fi
}

echo "== Darwin Switch release verification =="
echo "Root: ${ROOT_DIR}"
echo ""

echo "== 1/10 Shell syntax =="
bash -n \
  "${ROOT_DIR}/install.sh" \
  "${ROOT_DIR}/uninstall.sh" \
  "${ROOT_DIR}/package.sh" \
  "${ROOT_DIR}/simulate-install-tree.sh" \
  "${ROOT_DIR}/make-install-kit.sh" \
  "${ROOT_DIR}/check-switchroot-sd.sh" \
  "${ROOT_DIR}/check-day0-host.sh" \
  "${ROOT_DIR}/prepare-day0-host.sh" \
  "${ROOT_DIR}/copy-kit-to-sd.sh" \
  "${ROOT_DIR}/eject-day0-sd.sh" \
  "${ROOT_DIR}/find-switchroot-sd.sh" \
  "${ROOT_DIR}/sd-root-lib.sh" \
  "${ROOT_DIR}/mac-rcm-injector/darwin-switch-rcm-inject.sh" \
  "${ROOT_DIR}/mac-rcm-injector/make-macos-app.sh" \
  "${ROOT_DIR}/mac-rcm-injector/Darwin Switch RCM Injector.command" \
  "${ROOT_DIR}/bin/darwin-switch-cockpit" \
  "${ROOT_DIR}/bin/darwin-switch-camera-tunnel" \
  "${ROOT_DIR}/bin/darwin-switch-bootstrap-os" \
  "${ROOT_DIR}/bin/darwin-switch-collect-diagnostics" \
  "${ROOT_DIR}/bin/darwin-switch-day0-acceptance" \
  "${ROOT_DIR}/bin/darwin-switch-input-check" \
  "${ROOT_DIR}/bin/darwin-switch-network-check" \
  "${ROOT_DIR}/bin/darwin-switch-native-acceptance" \
  "${ROOT_DIR}/bin/darwin-switch-native-cockpit" \
  "${ROOT_DIR}/bin/darwin-switch-preflight" \
  "${ROOT_DIR}/bin/darwin-switch-smoke-test" \
  "${ROOT_DIR}/bin/darwin-switch-onepass-install"
if [[ "$(uname -s)" == "Darwin" ]] && command -v swiftc >/dev/null 2>&1; then
  MACOSX_DEPLOYMENT_TARGET=12.0 swiftc \
    -swift-version 5 \
    -parse-as-library \
    -target "$(uname -m)-apple-macos12.0" \
    -typecheck \
    "${ROOT_DIR}/mac-rcm-injector/DarwinSwitchRCMInjector.swift" \
    -framework AppKit
fi
rg 'Collecting source diagnostics' "${ROOT_DIR}/bin/darwin-switch-onepass-install" >/dev/null
rg 'Collecting installed diagnostics' "${ROOT_DIR}/bin/darwin-switch-onepass-install" >/dev/null
rg 'bootstrap\.log' "${ROOT_DIR}/bin/darwin-switch-bootstrap-os" >/dev/null
rg 'bootstrap-logs' "${ROOT_DIR}/bin/darwin-switch-collect-diagnostics" >/dev/null
rg 'launcher\.log' "${ROOT_DIR}/bin/darwin-switch-cockpit" >/dev/null
rg 'native-launcher\.log' "${ROOT_DIR}/bin/darwin-switch-native-cockpit" >/dev/null
rg 'web cockpit fallback' "${ROOT_DIR}/bin/darwin-switch-native-cockpit" >/dev/null
rg 'launcher-logs' "${ROOT_DIR}/bin/darwin-switch-collect-diagnostics" >/dev/null
rg 'native-launcher\.log' "${ROOT_DIR}/bin/darwin-switch-collect-diagnostics" >/dev/null
rg 'native-acceptance-json' "${ROOT_DIR}/bin/darwin-switch-collect-diagnostics" >/dev/null
rg 'cockpit-api-state' "${ROOT_DIR}/bin/darwin-switch-collect-diagnostics" >/dev/null
rg 'cockpit-api-robot-command' "${ROOT_DIR}/bin/darwin-switch-collect-diagnostics" >/dev/null

echo "== 2/10 Python compile =="
python3 -m compileall -q "${ROOT_DIR}/src" "${ROOT_DIR}/tests"
python3 -m py_compile "${ROOT_DIR}/summarize-diagnostics.py"
python3 -m py_compile "${ROOT_DIR}/mac-rcm-injector/generate-app-icon.py"
python3 -m py_compile "${ROOT_DIR}/mac-rcm-injector/round-app-icon-source.py"

echo "== 3/10 Python tests =="
PYTHONPATH="${ROOT_DIR}/src" python3 -m unittest discover -s "${ROOT_DIR}/tests"

echo "== 4/10 Web syntax =="
node --check "${ROOT_DIR}/web/app.js"
node --check "${ROOT_DIR}/web/setup.js"
node --check "${ROOT_DIR}/web/sw.js"

echo "== 5/10 Web runtime tests =="
node "${ROOT_DIR}/tests/test_web_runtime.mjs"

echo "== 6/10 Source bundle preflight =="
PYTHONPATH="${ROOT_DIR}/src" python3 -m darwin_switch_agent.preflight \
  --root "${ROOT_DIR}" \
  --config "${ROOT_DIR}/config.example.json" \
  --bundle-only \
  --strict

echo "== 7/10 Simulated install tree =="
"${ROOT_DIR}/simulate-install-tree.sh" >/dev/null

echo "== 8/10 Package build + checksum =="
PKG_PATH="$("${ROOT_DIR}/package.sh")"
PKG_DIR="$(dirname "${PKG_PATH}")"
PKG_FILE="$(basename "${PKG_PATH}")"
CHECKSUM="${PKG_PATH}.sha256"
(cd "${PKG_DIR}" && check_sha256_file "${PKG_FILE}.sha256")
PKG_SHA="$(awk '{print $1; exit}' "${CHECKSUM}")"

echo "== 9/10 Tarball content =="
tar -tzf "${PKG_PATH}" | rg \
  'bin/darwin-switch-onepass-install|bin/darwin-switch-bootstrap-os|bin/darwin-switch-collect-diagnostics|bin/darwin-switch-day0-acceptance|bin/darwin-switch-input-check|bin/darwin-switch-network-check|bin/darwin-switch-native-acceptance|bin/darwin-switch-preflight|bin/darwin-switch-smoke-test|src/darwin_switch_agent/input_check.py|src/darwin_switch_agent/network_check.py|src/darwin_switch_agent/native_acceptance.py|src/darwin_switch_agent/preflight.py|web/index.html|web/setup.html|web/model-check.html|web/sw.js|web/assets/darwin.glb|systemd/darwin-switch-agent.service|systemd/darwin-switch-camera-tunnel.service' \
  >/dev/null
if tar -tzf "${PKG_PATH}" | rg 'build-glb|robot3d-test|robot3d-rig|STLLoader|GLTFExporter|TextureUtils|decimate_glb|add_glb_normals|mac-rcm-injector|package\.sh|verify-release\.sh|simulate-install-tree\.sh|summarize-diagnostics\.py|make-install-kit\.sh|check-switchroot-sd\.sh|check-day0-host\.sh|prepare-day0-host\.sh|copy-kit-to-sd\.sh|eject-day0-sd\.sh|find-switchroot-sd\.sh|sd-root-lib\.sh|/tests/|__pycache__|\.pyc$|\.DS_Store$' >/dev/null; then
  echo "ERROR: runtime tarball contains build-only or generated files" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
tar -xzf "${PKG_PATH}" -C "${TMP_DIR}"
PKG_ROOT="${TMP_DIR}/${PKG_FILE%.tar.gz}"
"${PKG_ROOT}/bin/darwin-switch-preflight" \
  --root "${PKG_ROOT}" \
  --config "${PKG_ROOT}/config.example.json" \
  --bundle-only \
  --strict

BOOTSTRAP_LOG="${TMP_DIR}/bootstrap.log"
DARWIN_SWITCH_BOOTSTRAP_LOG="${BOOTSTRAP_LOG}" \
  XDG_CACHE_HOME="${TMP_DIR}/bootstrap-cache" \
  "${ROOT_DIR}/bin/darwin-switch-bootstrap-os" --dry-run --if-needed >/dev/null
rg 'Darwin Switch OS bootstrap starting' "${BOOTSTRAP_LOG}" >/dev/null
rg 'missing_packages=' "${BOOTSTRAP_LOG}" >/dev/null

LAUNCHER_FAKE_BIN="${TMP_DIR}/launcher-fake-bin"
LAUNCHER_HOME="${TMP_DIR}/launcher-home"
LAUNCHER_LOG="${LAUNCHER_HOME}/launcher.log"
mkdir -p "${LAUNCHER_FAKE_BIN}" "${LAUNCHER_HOME}"
cat > "${LAUNCHER_FAKE_BIN}/python3" <<'EOF'
#!/usr/bin/env sh
cat >/dev/null
exit 0
EOF
cat > "${LAUNCHER_FAKE_BIN}/firefox" <<'EOF'
#!/usr/bin/env sh
printf 'fake firefox %s\n' "$*"
exit 0
EOF
chmod 0755 "${LAUNCHER_FAKE_BIN}/python3" "${LAUNCHER_FAKE_BIN}/firefox"
PATH="${LAUNCHER_FAKE_BIN}:${PATH}" \
  HOME="${LAUNCHER_HOME}" \
  XDG_CACHE_HOME="${LAUNCHER_HOME}/.cache" \
  DARWIN_SWITCH_COCKPIT_LOG="${LAUNCHER_LOG}" \
  DARWIN_SWITCH_COCKPIT_URL="http://127.0.0.1:8765/" \
  "${ROOT_DIR}/bin/darwin-switch-cockpit"
rg 'Darwin Switch cockpit launcher starting' "${LAUNCHER_LOG}" >/dev/null
rg 'cockpit URL responded' "${LAUNCHER_LOG}" >/dev/null
rg 'launching firefox kiosk' "${LAUNCHER_LOG}" >/dev/null

ACCEPT_ROOT="${TMP_DIR}/accept-root"
ACCEPT_LOG="${TMP_DIR}/acceptance.log"
mkdir -p "${ACCEPT_ROOT}/bin" "${ACCEPT_ROOT}/src/darwin_switch_agent"
cat > "${ACCEPT_ROOT}/bin/darwin-switch-preflight" <<'EOF'
#!/usr/bin/env sh
echo "fake preflight"
exit 0
EOF
cat > "${ACCEPT_ROOT}/bin/darwin-switch-smoke-test" <<'EOF'
#!/usr/bin/env sh
echo "fake smoke"
exit 0
EOF
cat > "${ACCEPT_ROOT}/bin/darwin-switch-input-check" <<'EOF'
#!/usr/bin/env sh
echo "fake input warn"
exit 1
EOF
cat > "${ACCEPT_ROOT}/bin/darwin-switch-network-check" <<'EOF'
#!/usr/bin/env sh
echo "fake network"
exit 0
EOF
cat > "${ACCEPT_ROOT}/bin/darwin-switch-native-acceptance" <<'EOF'
#!/usr/bin/env sh
echo "fake native acceptance"
exit 0
EOF
cat > "${ACCEPT_ROOT}/bin/darwin-switch-collect-diagnostics" <<'EOF'
#!/usr/bin/env sh
echo "fake diagnostics"
exit 0
EOF
chmod 0755 "${ACCEPT_ROOT}"/bin/darwin-switch-*
DARWIN_SWITCH_ACCEPTANCE_LOG="${ACCEPT_LOG}" \
  "${ROOT_DIR}/bin/darwin-switch-day0-acceptance" \
    --root "${ACCEPT_ROOT}" \
    --config "${ACCEPT_ROOT}/config.json" \
    --base-url "http://127.0.0.1:8765" >/dev/null
rg 'RESULT: WARN' "${ACCEPT_LOG}" >/dev/null
if DARWIN_SWITCH_ACCEPTANCE_LOG="${TMP_DIR}/acceptance-strict.log" \
  "${ROOT_DIR}/bin/darwin-switch-day0-acceptance" \
    --root "${ACCEPT_ROOT}" \
    --config "${ACCEPT_ROOT}/config.json" \
    --base-url "http://127.0.0.1:8765" \
    --strict >/dev/null 2>&1; then
  echo "ERROR: day-0 acceptance strict mode accepted a WARN result" >&2
  exit 2
fi

echo "== 10/10 Install kit =="
KIT_PATH="$("${ROOT_DIR}/make-install-kit.sh")"
KIT_DIR="$(dirname "${KIT_PATH}")"
KIT_FILE="$(basename "${KIT_PATH}")"
(cd "${KIT_DIR}" && check_sha256_file "${KIT_FILE}.sha256")
tar -tzf "${KIT_PATH}" | rg \
  'INSTALL_ON_SWITCH\.md|install-on-switch\.sh|copy-to-switch\.sh|manifest\.json|darwin-switch-agent-[0-9.]+\.tar\.gz|darwin-switch-agent-[0-9.]+\.tar\.gz\.sha256' \
  >/dev/null
tar -xzf "${KIT_PATH}" -C "${TMP_DIR}"
KIT_ROOT="${TMP_DIR}/${KIT_FILE%.tar.gz}"
bash -n "${KIT_ROOT}/install-on-switch.sh"
bash -n "${KIT_ROOT}/copy-to-switch.sh"
rg 'agentΔ|robotΔ|periodΔ|/tmp/df-walklab-cmd' "${KIT_ROOT}/INSTALL_ON_SWITCH.md" >/dev/null
rg 'Manifest package cross-check' "${KIT_ROOT}/install-on-switch.sh" >/dev/null
EARLY_FAIL_KIT="${TMP_DIR}/early-fail-kit"
mkdir -p "${EARLY_FAIL_KIT}"
cp "${KIT_ROOT}/install-on-switch.sh" "${EARLY_FAIL_KIT}/install-on-switch.sh"
if HOME="${EARLY_FAIL_KIT}" "${EARLY_FAIL_KIT}/install-on-switch.sh" >/dev/null 2>&1; then
  echo "ERROR: install-on-switch accepted a kit with no package" >&2
  exit 2
fi
rg 'missing package or checksum' "${EARLY_FAIL_KIT}"/darwin-switch-install-*.log >/dev/null
KIT_PKG_SHA="$(awk '{print $1; exit}' "${KIT_ROOT}/${PKG_FILE}.sha256")"
python3 - "${KIT_ROOT}/manifest.json" "${KIT_FILE%.tar.gz}" "${PKG_FILE}" "${KIT_PKG_SHA}" <<'PY'
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
expected_kit = sys.argv[2]
expected_pkg = sys.argv[3]
expected_sha = sys.argv[4]
data = json.loads(manifest_path.read_text(encoding="utf-8"))
package_path = manifest_path.parent / expected_pkg

assert data["schema_version"] == 1
assert data["name"] == expected_kit
assert data["package"]["file"] == expected_pkg
assert data["package"]["sha256"] == expected_sha
assert data["package"]["size_bytes"] == package_path.stat().st_size
entry_count = len(subprocess.check_output(["tar", "-tzf", str(package_path)], text=True).splitlines())
assert data["package"]["tar_entry_count"] == entry_count
assert data["switch_entrypoint"] == "./install-on-switch.sh"

checks = set(data["release_gate"]["checks"])
for required in (
    "simulated installed filesystem tree",
    "systemd and desktop path reference checks",
    "runtime tarball content allow/deny checks",
    "field install kit validation",
):
    assert required in checks

post_install = set(data["post_install_commands"])
for command in (
    "darwin-switch-preflight --installed",
    "darwin-switch-smoke-test --installed",
    "darwin-switch-day0-acceptance --input-seconds 8 --strict",
    "darwin-switch-input-check --seconds 8",
    "darwin-switch-network-check",
    "darwin-switch-native-cockpit",
    "darwin-switch-native-acceptance",
    "darwin-switch-native-acceptance --sample-seconds 6 --strict",
):
    assert command in post_install

exclusions = set(data["runtime_exclusions"])
for item in (
    "tests",
    "package.sh",
    "simulate-install-tree.sh",
    "summarize-diagnostics.py",
    "make-install-kit.sh",
    "check-switchroot-sd.sh",
    "check-day0-host.sh",
    "prepare-day0-host.sh",
    "copy-kit-to-sd.sh",
    "eject-day0-sd.sh",
    "find-switchroot-sd.sh",
    "sd-root-lib.sh",
    "web/build-glb.html",
):
    assert item in exclusions
PY

FAKE_DIAG_DIR="${TMP_DIR}/darwin-switch-diagnostics-20000101-000000"
mkdir -p "${FAKE_DIAG_DIR}"
mkdir -p "${FAKE_DIAG_DIR}/install-logs" "${FAKE_DIAG_DIR}/install-kit" "${FAKE_DIAG_DIR}/bootstrap-logs" "${FAKE_DIAG_DIR}/launcher-logs"
cat > "${FAKE_DIAG_DIR}/summary.txt" <<'EOF'
created_at=2000-01-01T00:00:00+00:00
root=/opt/darwin-switch-agent
config=/etc/darwin-switch-agent/config.json
kernel=Linux switchroot-test
EOF
cat > "${FAKE_DIAG_DIR}/install-logs/darwin-switch-install-20000101-000000.log" <<'EOF'
== Darwin Switch field install ==
ERROR: fake failure
EOF
cat > "${FAKE_DIAG_DIR}/launcher-logs/launcher.log" <<'EOF'
2000-01-01T00:00:00+00:00 Darwin Switch cockpit launcher starting
EOF
cat > "${FAKE_DIAG_DIR}/bootstrap-logs/bootstrap.log" <<'EOF'
2000-01-01T00:00:00+00:00 Darwin Switch OS bootstrap starting
EOF
cp "${KIT_ROOT}/manifest.json" "${FAKE_DIAG_DIR}/install-kit/manifest.json"
cat > "${FAKE_DIAG_DIR}/preflight-json.txt" <<'EOF'
+ darwin-switch-preflight --json
{
  "level": "warn",
  "checks": [
    {"id": "bundle", "level": "good", "title": "Runtime bundle", "detail": "OK"},
    {"id": "joycond", "level": "warn", "title": "Joy-Con merge", "detail": "inactive", "fix": "enable joycond"}
  ]
}
EOF
cat > "${FAKE_DIAG_DIR}/input-check-json.txt" <<'EOF'
+ darwin-switch-input-check --json
{
  "level": "warn",
  "device_count": 0,
  "selected": null,
  "capture": {"roles": {}, "axes": {}},
  "error": ""
}
EOF
cat > "${FAKE_DIAG_DIR}/network-check-json.txt" <<'EOF'
+ darwin-switch-network-check --json
{
  "level": "warn",
  "checks": [
    {"id": "cockpit_api", "level": "warn", "title": "Cockpit API", "detail": "URLError", "fix": "start service"}
  ]
}
EOF
cat > "${FAKE_DIAG_DIR}/native-acceptance-json.txt" <<'EOF'
+ darwin-switch-native-acceptance --json
{
  "level": "good",
  "checks": [
    {"id": "gtk", "level": "good", "title": "GTK native runtime", "detail": "OK"},
    {"id": "robot_side_token", "level": "good", "title": "Robot side token", "detail": "side_mm=4.0"}
  ],
  "sample_summary": {
    "state_drive_span": 12.0,
    "robot_drive_span": 12.0,
    "robot_stride_span": 12.0,
    "robot_side_span": 4.0,
    "robot_period_span": 160.0,
    "robot_foot_span": 9.0,
    "robot_head_nonzero_count": 2,
    "robot_head_hold_count": 1
  }
}
EOF
cat > "${FAKE_DIAG_DIR}/cockpit-api-state.txt" <<'EOF'
+ api state
{
  "mode": "ssh",
  "target": "robotis@192.168.0.33",
  "connected": true,
  "ssh_connected": true,
  "input_status": "/dev/input/event8",
  "controller": {"left_x": 0.2, "left_y": 0.5, "right_x": 0.1, "right_y": -0.1},
  "command": {"stride_mm": 12.0, "side_mm": 4.0, "turn_deg": 2.0, "head_pan_deg": 8.0, "head_tilt_deg": -4.0}
}
EOF
cat > "${FAKE_DIAG_DIR}/cockpit-api-robot-command.txt" <<'EOF'
+ api robot-command
{
  "ok": true,
  "status": {
    "mode": "walklab",
    "parsed": {
      "enabled": true,
      "stride_mm": 12.0,
      "side_mm": 4.0,
      "turn_deg": 2.0,
      "period_ms": 620.0,
      "foot_mm": 31.0,
      "head_pan_deg": 8.0,
      "head_tilt_deg": -4.0
    }
  }
}
EOF
FAKE_DIAG="${TMP_DIR}/darwin-switch-diagnostics-20000101-000000.tar.gz"
tar -C "${TMP_DIR}" -czf "${FAKE_DIAG}" "$(basename "${FAKE_DIAG_DIR}")"
"${ROOT_DIR}/summarize-diagnostics.py" "${FAKE_DIAG}" >/dev/null
SUMMARY_LEVEL="$("${ROOT_DIR}/summarize-diagnostics.py" "${FAKE_DIAG}" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["overall_level"])')"
test "${SUMMARY_LEVEL}" = "warn"
SUMMARY_NATIVE_LEVEL="$("${ROOT_DIR}/summarize-diagnostics.py" "${FAKE_DIAG}" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["native"]["level"])')"
test "${SUMMARY_NATIVE_LEVEL}" = "good"
SUMMARY_NATIVE_PROPAGATION="$("${ROOT_DIR}/summarize-diagnostics.py" "${FAKE_DIAG}" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["native"]["sample_summary"]["propagation"])')"
test "${SUMMARY_NATIVE_PROPAGATION}" = "agent_to_robot"
SUMMARY_NATIVE_SPEED="$("${ROOT_DIR}/summarize-diagnostics.py" "${FAKE_DIAG}" --json | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["native"]["sample_summary"]["speed_variable"]))')"
test "${SUMMARY_NATIVE_SPEED}" = "1"
SUMMARY_NATIVE_HEAD_HOLD="$("${ROOT_DIR}/summarize-diagnostics.py" "${FAKE_DIAG}" --json | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["native"]["sample_summary"]["head_hold"]))')"
test "${SUMMARY_NATIVE_HEAD_HOLD}" = "1"
SUMMARY_COCKPIT_MODE="$("${ROOT_DIR}/summarize-diagnostics.py" "${FAKE_DIAG}" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["cockpit_api"]["mode"])')"
test "${SUMMARY_COCKPIT_MODE}" = "ssh"
SUMMARY_ROBOT_SIDE="$("${ROOT_DIR}/summarize-diagnostics.py" "${FAKE_DIAG}" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["cockpit_api"]["robot_parsed"]["side_mm"])')"
test "${SUMMARY_ROBOT_SIDE}" = "4.0"
SUMMARY_HAS_EVIDENCE="$("${ROOT_DIR}/summarize-diagnostics.py" "${FAKE_DIAG}" --json | python3 -c 'import json,sys; data=json.load(sys.stdin)["install_evidence"]; print(int(data["has_install_log"] and data["has_manifest"]))')"
test "${SUMMARY_HAS_EVIDENCE}" = "1"
SUMMARY_HAS_LAUNCHER="$("${ROOT_DIR}/summarize-diagnostics.py" "${FAKE_DIAG}" --json | python3 -c 'import json,sys; data=json.load(sys.stdin)["install_evidence"]; print(int(data["has_launcher_log"]))')"
test "${SUMMARY_HAS_LAUNCHER}" = "1"
SUMMARY_HAS_BOOTSTRAP="$("${ROOT_DIR}/summarize-diagnostics.py" "${FAKE_DIAG}" --json | python3 -c 'import json,sys; data=json.load(sys.stdin)["install_evidence"]; print(int(data["has_bootstrap_log"]))')"
test "${SUMMARY_HAS_BOOTSTRAP}" = "1"

FAKE_DIAG_HOME="${TMP_DIR}/diag-home"
FAKE_DIAG_KIT="${FAKE_DIAG_HOME}/darwin-switch-install-kit-test"
mkdir -p "${FAKE_DIAG_HOME}" "${FAKE_DIAG_KIT}"
FAKE_INSTALL_LOG="${FAKE_DIAG_HOME}/darwin-switch-install-20000102-000000.log"
FAKE_BOOTSTRAP_LOG="${FAKE_DIAG_HOME}/bootstrap.log"
FAKE_LAUNCHER_LOG="${FAKE_DIAG_HOME}/launcher.log"
printf 'field install log\n' > "${FAKE_INSTALL_LOG}"
printf 'field bootstrap log\n' > "${FAKE_BOOTSTRAP_LOG}"
printf 'field launcher log\n' > "${FAKE_LAUNCHER_LOG}"
cp "${KIT_ROOT}/manifest.json" "${FAKE_DIAG_KIT}/manifest.json"
REAL_DIAG="$(
  HOME="${FAKE_DIAG_HOME}" \
  DARWIN_SWITCH_INSTALL_LOG="${FAKE_INSTALL_LOG}" \
  DARWIN_SWITCH_INSTALL_KIT_DIR="${FAKE_DIAG_KIT}" \
  DARWIN_SWITCH_BOOTSTRAP_LOG="${FAKE_BOOTSTRAP_LOG}" \
  DARWIN_SWITCH_COCKPIT_LOG="${FAKE_LAUNCHER_LOG}" \
  "${ROOT_DIR}/bin/darwin-switch-collect-diagnostics" \
    --root "${ROOT_DIR}" \
    --config "${ROOT_DIR}/config.example.json" \
    --out-dir "${TMP_DIR}"
)"
tar -tzf "${REAL_DIAG}" | rg 'install-logs/darwin-switch-install-20000102-000000\.log' >/dev/null
tar -tzf "${REAL_DIAG}" | rg 'install-kit/manifest\.json' >/dev/null
tar -tzf "${REAL_DIAG}" | rg 'bootstrap-logs/bootstrap\.log' >/dev/null
tar -tzf "${REAL_DIAG}" | rg 'launcher-logs/launcher\.log' >/dev/null
REAL_DIAG_JSON="${TMP_DIR}/real-diagnostics-summary.json"
"${ROOT_DIR}/summarize-diagnostics.py" "${REAL_DIAG}" --json > "${REAL_DIAG_JSON}" || true
REAL_DIAG_EVIDENCE="$(python3 -c 'import json,sys; data=json.load(sys.stdin)["install_evidence"]; print(int(data["has_install_log"] and data["has_manifest"]))' < "${REAL_DIAG_JSON}")"
test "${REAL_DIAG_EVIDENCE}" = "1"
REAL_DIAG_LAUNCHER="$(python3 -c 'import json,sys; data=json.load(sys.stdin)["install_evidence"]; print(int(data["has_launcher_log"]))' < "${REAL_DIAG_JSON}")"
test "${REAL_DIAG_LAUNCHER}" = "1"
REAL_DIAG_BOOTSTRAP="$(python3 -c 'import json,sys; data=json.load(sys.stdin)["install_evidence"]; print(int(data["has_bootstrap_log"]))' < "${REAL_DIAG_JSON}")"
test "${REAL_DIAG_BOOTSTRAP}" = "1"

FAKE_SD="${TMP_DIR}/fake-sd"
mkdir -p "${FAKE_SD}/bootloader/ini" "${FAKE_SD}/switchroot/install" "${FAKE_SD}/switchroot/ubuntu"
touch "${FAKE_SD}/bootloader/ini/L4T-UBUNTU.ini"
touch "${FAKE_SD}/switchroot/install/l4t.00"
touch "${FAKE_SD}/switchroot/ubuntu/boot.scr"
cp -R "${KIT_ROOT}" "${FAKE_SD}/${KIT_FILE%.tar.gz}"
cp "${KIT_PATH}" "${FAKE_SD}/${KIT_FILE}"
cp "${KIT_PATH}.sha256" "${FAKE_SD}/${KIT_FILE}.sha256"
"${ROOT_DIR}/check-switchroot-sd.sh" --stage any --require-darwin-kit "${FAKE_SD}" >/dev/null
"${ROOT_DIR}/check-switchroot-sd.sh" --write-check --stage any --require-darwin-kit "${FAKE_SD}" >/dev/null
BAD_KIT_SD="${TMP_DIR}/bad-kit-sd"
mkdir -p "${BAD_KIT_SD}/bootloader/ini" "${BAD_KIT_SD}/switchroot/install" "${BAD_KIT_SD}/switchroot/ubuntu"
touch "${BAD_KIT_SD}/bootloader/ini/L4T-UBUNTU.ini"
touch "${BAD_KIT_SD}/switchroot/install/l4t.00"
touch "${BAD_KIT_SD}/switchroot/ubuntu/boot.scr"
cp "${KIT_PATH}" "${BAD_KIT_SD}/${KIT_FILE}"
cp "${KIT_PATH}.sha256" "${BAD_KIT_SD}/${KIT_FILE}.sha256"
printf '\ncorrupt\n' >> "${BAD_KIT_SD}/${KIT_FILE}"
if "${ROOT_DIR}/check-switchroot-sd.sh" --stage any --require-darwin-kit "${BAD_KIT_SD}" >/dev/null 2>&1; then
  echo "ERROR: SD checker accepted a corrupted Darwin install kit tarball" >&2
  exit 2
fi
BAD_SD="${TMP_DIR}/bad-sd"
mkdir -p "${BAD_SD}/nested/bootloader" "${BAD_SD}/nested/switchroot"
if "${ROOT_DIR}/check-switchroot-sd.sh" --stage before-flash "${BAD_SD}" >/dev/null 2>&1; then
  echo "ERROR: SD checker accepted a nested extraction layout" >&2
  exit 2
fi
AUTO_SCAN_ROOT="${TMP_DIR}/auto-scan"
AUTO_SD="${AUTO_SCAN_ROOT}/SWITCHSD"
mkdir -p "${AUTO_SD}/bootloader/ini" "${AUTO_SD}/switchroot/install" "${AUTO_SD}/switchroot/ubuntu"
touch "${AUTO_SD}/bootloader/ini/L4T-UBUNTU.ini"
touch "${AUTO_SD}/switchroot/install/l4t.00"
touch "${AUTO_SD}/switchroot/ubuntu/boot.scr"
test "$(DARWIN_SWITCH_SD_SCAN_ROOTS="${AUTO_SCAN_ROOT}" "${ROOT_DIR}/find-switchroot-sd.sh" --path-only)" = "${AUTO_SD}"
DARWIN_SWITCH_SD_SCAN_ROOTS="${AUTO_SCAN_ROOT}" "${ROOT_DIR}/check-switchroot-sd.sh" --stage any auto >/dev/null
DARWIN_SWITCH_SD_SCAN_ROOTS="${AUTO_SCAN_ROOT}" "${ROOT_DIR}/copy-kit-to-sd.sh" --stage any auto >/dev/null
test -d "${AUTO_SD}/darwin-switch-install-kit-0.1.0"
AUTO_MULTI_ROOT="${TMP_DIR}/auto-multi"
mkdir -p "${AUTO_MULTI_ROOT}/A/bootloader" "${AUTO_MULTI_ROOT}/A/switchroot" "${AUTO_MULTI_ROOT}/B/bootloader" "${AUTO_MULTI_ROOT}/B/switchroot"
if DARWIN_SWITCH_SD_SCAN_ROOTS="${AUTO_MULTI_ROOT}" "${ROOT_DIR}/find-switchroot-sd.sh" --path-only >/dev/null 2>&1; then
  echo "ERROR: SD auto finder accepted multiple candidates" >&2
  exit 2
fi
if DARWIN_SWITCH_SD_SCAN_ROOTS="${AUTO_MULTI_ROOT}" "${ROOT_DIR}/check-switchroot-sd.sh" --stage any auto >/dev/null 2>&1; then
  echo "ERROR: SD checker auto accepted multiple candidates" >&2
  exit 2
fi
FAKE_HOST="${TMP_DIR}/host"
mkdir -p "${FAKE_HOST}"
touch "${FAKE_HOST}/hekate_ctcaer_6.0.6.bin" "${FAKE_HOST}/switchroot-l4t-ubuntu-noble-24.04.7z"
printf '#!/usr/bin/env sh\nexit 0\n' > "${FAKE_HOST}/7zz"
printf '#!/usr/bin/env sh\nexit 0\n' > "${FAKE_HOST}/fusee-launcher"
cat > "${FAKE_HOST}/uname" <<'SH'
#!/usr/bin/env sh
printf 'Darwin\n'
SH
cat > "${FAKE_HOST}/diskutil" <<'SH'
#!/usr/bin/env sh
: "${DARWIN_SWITCH_FAKE_EJECT_LOG:=/dev/null}"
printf '%s\n' "$*" >> "${DARWIN_SWITCH_FAKE_EJECT_LOG}"
exit 0
SH
chmod 0755 "${FAKE_HOST}/7zz" "${FAKE_HOST}/fusee-launcher" "${FAKE_HOST}/uname" "${FAKE_HOST}/diskutil"
PATH="${FAKE_HOST}:${PATH}" "${ROOT_DIR}/check-day0-host.sh" \
  --hekate-payload "${FAKE_HOST}/hekate_ctcaer_6.0.6.bin" \
  --rcm-injector "${FAKE_HOST}/fusee-launcher" \
  --switchroot-archive "${FAKE_HOST}/switchroot-l4t-ubuntu-noble-24.04.7z" \
  --sd-root "${FAKE_SD}" \
  --require-darwin-kit \
  --strict >/dev/null
FAKE_SHA_PATH="${TMP_DIR}/sha256-only-path"
mkdir -p "${FAKE_SHA_PATH}"
ln -s "$(command -v bash)" "${FAKE_SHA_PATH}/bash"
ln -s "$(command -v python3)" "${FAKE_SHA_PATH}/python3"
ln -s "$(command -v tar)" "${FAKE_SHA_PATH}/tar"
ln -s "$(command -v ssh)" "${FAKE_SHA_PATH}/ssh"
ln -s "$(command -v scp)" "${FAKE_SHA_PATH}/scp"
ln -s "$(command -v awk)" "${FAKE_SHA_PATH}/awk"
ln -s "$(command -v basename)" "${FAKE_SHA_PATH}/basename"
ln -s "$(command -v dirname)" "${FAKE_SHA_PATH}/dirname"
ln -s "$(command -v tr)" "${FAKE_SHA_PATH}/tr"
ln -s "$(command -v find)" "${FAKE_SHA_PATH}/find"
ln -s "$(command -v df)" "${FAKE_SHA_PATH}/df"
if command -v sha256sum >/dev/null 2>&1; then
  ln -s "$(command -v sha256sum)" "${FAKE_SHA_PATH}/sha256sum"
else
  ln -s "$(command -v shasum)" "${FAKE_SHA_PATH}/sha256sum"
fi
printf '#!/usr/bin/env sh\nexit 0\n' > "${FAKE_SHA_PATH}/7zz"
chmod 0755 "${FAKE_SHA_PATH}/7zz"
PATH="${FAKE_SHA_PATH}:/bin" "${ROOT_DIR}/check-day0-host.sh" \
  --hekate-payload "${FAKE_HOST}/hekate_ctcaer_6.0.6.bin" \
  --rcm-injector "${FAKE_HOST}/fusee-launcher" \
  --switchroot-archive "${FAKE_HOST}/switchroot-l4t-ubuntu-noble-24.04.7z" \
  --sd-root "${FAKE_SD}" \
  --strict >/dev/null
FAKE_SD_PREP="${TMP_DIR}/fake-sd-prep"
mkdir -p "${FAKE_SD_PREP}/bootloader/ini" "${FAKE_SD_PREP}/switchroot/install" "${FAKE_SD_PREP}/switchroot/ubuntu"
touch "${FAKE_SD_PREP}/bootloader/ini/L4T-UBUNTU.ini"
touch "${FAKE_SD_PREP}/switchroot/install/l4t.00"
touch "${FAKE_SD_PREP}/switchroot/ubuntu/boot.scr"
PREP_LOG="${TMP_DIR}/day0-host-prep.log"
PREP_EJECT_LOG="${TMP_DIR}/day0-host-prep-eject.log"
PATH="${FAKE_HOST}:${PATH}" \
  DARWIN_SWITCH_PREP_SKIP_RELEASE=1 \
  DARWIN_SWITCH_PREP_LOG="${PREP_LOG}" \
  DARWIN_SWITCH_FAKE_EJECT_LOG="${PREP_EJECT_LOG}" \
  DARWIN_SWITCH_ALLOW_NON_VOLUME_EJECT=1 \
  "${ROOT_DIR}/prepare-day0-host.sh" \
    --hekate-payload "${FAKE_HOST}/hekate_ctcaer_6.0.6.bin" \
    --rcm-injector "${FAKE_HOST}/fusee-launcher" \
    --switchroot-archive "${FAKE_HOST}/switchroot-l4t-ubuntu-noble-24.04.7z" \
    --sd-root "${FAKE_SD_PREP}" \
    --copy-kit-to-sd \
    --eject-sd \
    --strict >/dev/null
rg 'Day-0 host preparation complete' "${PREP_LOG}" >/dev/null
rg "eject ${FAKE_SD_PREP}" "${PREP_EJECT_LOG}" >/dev/null
test -d "${FAKE_SD_PREP}/darwin-switch-install-kit-0.1.0"
test -f "${FAKE_SD_PREP}/darwin-switch-install-kit-0.1.0.tar.gz"
FAKE_SD_COPY="${TMP_DIR}/fake-sd-copy"
mkdir -p "${FAKE_SD_COPY}/bootloader/ini" "${FAKE_SD_COPY}/switchroot/install" "${FAKE_SD_COPY}/switchroot/ubuntu"
touch "${FAKE_SD_COPY}/bootloader/ini/L4T-UBUNTU.ini"
touch "${FAKE_SD_COPY}/switchroot/install/l4t.00"
touch "${FAKE_SD_COPY}/switchroot/ubuntu/boot.scr"
"${ROOT_DIR}/copy-kit-to-sd.sh" --stage any "${FAKE_SD_COPY}" >/dev/null
test -d "${FAKE_SD_COPY}/darwin-switch-install-kit-0.1.0"
test -f "${FAKE_SD_COPY}/darwin-switch-install-kit-0.1.0.tar.gz"
test -f "${FAKE_SD_COPY}/darwin-switch-install-kit-0.1.0.tar.gz.sha256"
FAKE_EJECT_BIN="${TMP_DIR}/fake-eject-bin"
FAKE_EJECT_LOG="${TMP_DIR}/fake-eject.log"
mkdir -p "${FAKE_EJECT_BIN}"
cat > "${FAKE_EJECT_BIN}/uname" <<'SH'
#!/usr/bin/env sh
printf 'Darwin\n'
SH
cat > "${FAKE_EJECT_BIN}/diskutil" <<'SH'
#!/usr/bin/env sh
: "${DARWIN_SWITCH_FAKE_EJECT_LOG:=/dev/null}"
printf '%s\n' "$*" >> "${DARWIN_SWITCH_FAKE_EJECT_LOG}"
exit 0
SH
chmod 0755 "${FAKE_EJECT_BIN}/uname" "${FAKE_EJECT_BIN}/diskutil"
PATH="${FAKE_EJECT_BIN}:${PATH}" \
  DARWIN_SWITCH_FAKE_EJECT_LOG="${FAKE_EJECT_LOG}" \
  "${ROOT_DIR}/eject-day0-sd.sh" --dry-run --allow-non-volume-root --stage any "${FAKE_SD_COPY}" >/dev/null
PATH="${FAKE_EJECT_BIN}:${PATH}" \
  DARWIN_SWITCH_FAKE_EJECT_LOG="${FAKE_EJECT_LOG}" \
  "${ROOT_DIR}/eject-day0-sd.sh" --allow-non-volume-root --stage any "${FAKE_SD_COPY}" >/dev/null
rg "eject ${FAKE_SD_COPY}" "${FAKE_EJECT_LOG}" >/dev/null
READONLY_SD_COPY="${TMP_DIR}/readonly-sd-copy"
mkdir -p "${READONLY_SD_COPY}/bootloader/ini" "${READONLY_SD_COPY}/switchroot/install" "${READONLY_SD_COPY}/switchroot/ubuntu"
touch "${READONLY_SD_COPY}/bootloader/ini/L4T-UBUNTU.ini"
touch "${READONLY_SD_COPY}/switchroot/install/l4t.00"
touch "${READONLY_SD_COPY}/switchroot/ubuntu/boot.scr"
chmod -w "${READONLY_SD_COPY}"
if "${ROOT_DIR}/copy-kit-to-sd.sh" --stage any "${READONLY_SD_COPY}" >/dev/null 2>&1; then
  chmod +w "${READONLY_SD_COPY}"
  echo "ERROR: copy-kit-to-sd accepted a non-writable SD path" >&2
  exit 2
fi
chmod +w "${READONLY_SD_COPY}"
if find "${READONLY_SD_COPY}" -maxdepth 1 -name 'darwin-switch-install-kit-*' -print -quit | rg . >/dev/null; then
  echo "ERROR: copy-kit-to-sd wrote Darwin kit files after failed write precheck" >&2
  exit 2
fi
BAD_COPY_TARGET="${TMP_DIR}/bad-copy-target"
mkdir -p "${BAD_COPY_TARGET}"
if "${ROOT_DIR}/copy-kit-to-sd.sh" --stage any "${BAD_COPY_TARGET}" >/dev/null 2>&1; then
  echo "ERROR: copy-kit-to-sd accepted a non-Switchroot SD path" >&2
  exit 2
fi
if find "${BAD_COPY_TARGET}" -maxdepth 1 -name 'darwin-switch-install-kit-*' -print -quit | rg . >/dev/null; then
  echo "ERROR: copy-kit-to-sd wrote Darwin kit files after failed SD precheck" >&2
  exit 2
fi

echo ""
echo "OK: ${PKG_PATH}"
echo "OK: ${CHECKSUM}"
echo "OK: ${KIT_PATH}"
echo "OK: ${KIT_PATH}.sha256"
