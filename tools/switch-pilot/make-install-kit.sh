#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${ROOT_DIR}/../.." && pwd)"
VERSION="$(python3 - "${ROOT_DIR}/src/darwin_switch_agent/__init__.py" <<'PY'
import pathlib
import sys
text = pathlib.Path(sys.argv[1]).read_text()
for line in text.splitlines():
    if line.startswith("__version__"):
        print(line.split("=")[1].strip().strip('"'))
        break
PY
)"
OUT_DIR="${REPO_DIR}/dist/switch-pilot"
PKG_NAME="darwin-switch-agent-${VERSION}"
PKG_FILE="${PKG_NAME}.tar.gz"
PKG_CHECKSUM="${PKG_FILE}.sha256"
KIT_NAME="darwin-switch-install-kit-${VERSION}"
KIT_DIR="${OUT_DIR}/${KIT_NAME}"
KIT_TARBALL="${OUT_DIR}/${KIT_NAME}.tar.gz"
KIT_CHECKSUM="${KIT_TARBALL}.sha256"

PKG_PATH="$("${ROOT_DIR}/package.sh")"
PKG_DIR="$(dirname "${PKG_PATH}")"

if [[ "$(basename "${PKG_PATH}")" != "${PKG_FILE}" ]]; then
  echo "ERROR: unexpected package output: ${PKG_PATH}" >&2
  exit 2
fi

rm -rf "${KIT_DIR}" "${KIT_TARBALL}" "${KIT_CHECKSUM}"
mkdir -p "${KIT_DIR}"
cp "${PKG_DIR}/${PKG_FILE}" "${KIT_DIR}/${PKG_FILE}"
cp "${PKG_DIR}/${PKG_CHECKSUM}" "${KIT_DIR}/${PKG_CHECKSUM}"

PKG_SHA="$(awk '{print $1; exit}' "${KIT_DIR}/${PKG_CHECKSUM}")"
PKG_SIZE_BYTES="$(wc -c < "${KIT_DIR}/${PKG_FILE}" | tr -d ' ')"
PKG_FILE_COUNT="$(COPYFILE_DISABLE=1 tar -tzf "${KIT_DIR}/${PKG_FILE}" 2>/dev/null | grep -Ev '(^|/)(\\._|PaxHeaders\\.)' | wc -l | tr -d ' ')"
CREATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_COMMIT="$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_STATUS="$(git -C "${REPO_DIR}" status --short 2>/dev/null | wc -l | tr -d ' ')"

cat > "${KIT_DIR}/install-on-switch.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

KIT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
PKG_FILE="${PKG_FILE}"
PKG_CHECKSUM="${PKG_CHECKSUM}"
PKG_ROOT="${PKG_NAME}"
LOG="\${HOME}/darwin-switch-install-\$(date +%Y%m%d-%H%M%S).log"

cd "\${KIT_DIR}"

echo "Darwin Switch install log: \${LOG}"
set +e
(
  set -euo pipefail

  echo "== Darwin Switch field install =="
  echo "Kit: \${KIT_DIR}"
  echo "Package: \${PKG_FILE}"
  echo "Started: \$(date -Iseconds)"
  export DARWIN_SWITCH_INSTALL_LOG="\${LOG}"
  export DARWIN_SWITCH_INSTALL_KIT_DIR="\${KIT_DIR}"
  export DARWIN_SWITCH_NO_AUTORUN=1

  if [[ ! -f "\${PKG_FILE}" || ! -f "\${PKG_CHECKSUM}" ]]; then
    echo "ERROR: missing package or checksum in \${KIT_DIR}" >&2
    exit 2
  fi

  echo ""
  echo "== Package checksum =="
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "\${PKG_CHECKSUM}"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c "\${PKG_CHECKSUM}"
  else
    echo "ERROR: no sha256 tool found. Install coreutils or perl Digest::SHA." >&2
    exit 2
  fi

  if [[ -f "manifest.json" ]] && command -v python3 >/dev/null 2>&1; then
    echo ""
    echo "== Manifest package cross-check =="
    python3 - "manifest.json" "\${PKG_FILE}" "\${PKG_CHECKSUM}" <<'PY'
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
pkg_file = Path(sys.argv[2])
checksum_file = Path(sys.argv[3])
data = json.loads(manifest_path.read_text(encoding="utf-8"))
package = data.get("package", {})

def fail(message: str) -> None:
    print(f"ERROR: install kit manifest mismatch: {message}", file=sys.stderr)
    raise SystemExit(2)

if package.get("file") != str(pkg_file):
    fail(f"package.file={package.get('file')!r}, expected {pkg_file}")
if package.get("checksum_file") != str(checksum_file):
    fail(f"package.checksum_file={package.get('checksum_file')!r}, expected {checksum_file}")

checksum_text = checksum_file.read_text(encoding="utf-8").split()
if not checksum_text:
    fail("checksum file is empty")
if package.get("sha256") != checksum_text[0]:
    fail("package.sha256 does not match checksum file")

actual_size = pkg_file.stat().st_size
if int(package.get("size_bytes", -1)) != actual_size:
    fail(f"package.size_bytes={package.get('size_bytes')}, actual {actual_size}")

entry_output = subprocess.check_output(
    ["tar", "-tzf", str(pkg_file)],
    text=True,
    stderr=subprocess.DEVNULL,
)
entry_count = sum(
    1
    for entry in entry_output.splitlines()
    if "/._" not in entry and not entry.rsplit("/", 1)[-1].startswith("._") and "PaxHeaders." not in entry
)
if int(package.get("tar_entry_count", -1)) != entry_count:
    fail(f"package.tar_entry_count={package.get('tar_entry_count')}, actual {entry_count}")

print(f"Manifest package cross-check: OK ({entry_count} entries, {actual_size} bytes)")
PY
  elif [[ -f "manifest.json" ]]; then
    echo "NOTE: python3 not found; manifest cross-check skipped before OS bootstrap."
  fi

  if [[ "\${EUID}" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "ERROR: sudo not found. Run from a Switchroot admin account." >&2
      exit 2
    fi
    sudo -v
  fi

  echo ""
  echo "== Extract runtime package =="
  rm -rf "\${PKG_ROOT}"
  tar -xzf "\${PKG_FILE}"

  if [[ -f "\${KIT_DIR}/manifest.json" ]]; then
    echo ""
    echo "== Install kit manifest =="
    sed -n '1,220p' "\${KIT_DIR}/manifest.json"
  fi
  echo ""
  cd "\${PKG_ROOT}"
  ./bin/darwin-switch-onepass-install
  echo ""
  echo "== Final manual-start checks =="
  /usr/local/bin/darwin-switch-preflight \
    --root /opt/darwin-switch-agent \
    --config /etc/darwin-switch-agent/config.json
  /usr/local/bin/darwin-switch-input-check || true
  /usr/local/bin/darwin-switch-network-check || true
) 2>&1 | tee "\${LOG}"
install_status="\${PIPESTATUS[0]}"
set -e
if [[ "\${install_status}" -ne 0 ]]; then
  echo ""
  echo "Install failed with exit \${install_status}."
  echo "Log: \${LOG}"
  exit "\${install_status}"
fi

echo ""
echo "Install completed."
echo "Log: \${LOG}"
echo "Cockpit: darwin-switch-cockpit"
echo "Setup URL: http://127.0.0.1:8765/setup.html"
echo "Manual agent start: sudo systemctl start darwin-switch-agent"
echo "Robot SSH ready: darwin-switch-robot-ready plan"
EOF
chmod 0755 "${KIT_DIR}/install-on-switch.sh"

cat > "${KIT_DIR}/copy-to-switch.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$#" -ne 1 ]]; then
  echo "Usage: \$0 <switch-user>@<switch-ip>" >&2
  exit 2
fi

DEST="\$1"
SRC_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
scp -r "\${SRC_DIR}" "\${DEST}:~"

cat <<MSG

Copied Darwin Switch install kit.
On the Switch, run:

  cd ~/${KIT_NAME}
  ./install-on-switch.sh

MSG
EOF
chmod 0755 "${KIT_DIR}/copy-to-switch.sh"

cat > "${KIT_DIR}/deploy-to-switch.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$#" -ne 1 ]]; then
  echo "Usage: \$0 <switch-user>@<switch-ip>" >&2
  exit 2
fi

DEST="\$1"
SRC_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
KIT_BASENAME="\$(basename "\${SRC_DIR}")"

echo "== Copy install kit to Switch =="
scp -r "\${SRC_DIR}" "\${DEST}:~"

echo ""
echo "== Run Switch install =="
ssh -t "\${DEST}" "cd ~/\${KIT_BASENAME} && ./install-on-switch.sh"

echo ""
echo "== Robot SSH readiness plan =="
ssh -t "\${DEST}" "darwin-switch-robot-ready plan"

echo ""
echo "== Native cockpit readiness =="
ssh -t "\${DEST}" "darwin-switch-native-acceptance || true"

cat <<MSG

Deploy completed.

Before real robot piloting, power the robot and use the native cockpit buttons:

  darwin-switch-native-cockpit

Recommended terminal fallback on the Switch:

  darwin-switch-robot-ready all
  darwin-switch-native-acceptance --sample-seconds 6 --strict

The final step updates /etc/darwin-switch-agent/config.json to mode=ssh and
restarts darwin-switch-agent. It may ask for the Switch sudo password.

MSG
EOF
chmod 0755 "${KIT_DIR}/deploy-to-switch.sh"

cat > "${KIT_DIR}/INSTALL_ON_SWITCH.md" <<EOF
# Darwin Switch Install Kit ${VERSION}

Created: ${CREATED_AT}

This folder is the field install kit for a Switch that has already booted
Switchroot L4T Ubuntu.

If Switchroot has not booted yet, follow the repository runbook first:
\`docs/guides/switchroot-darwin-day0-runbook.md\`.

## Mac To Switch

From the Mac:

\`\`\`bash
dist/switch-pilot/${KIT_NAME}/copy-to-switch.sh <switch-user>@<switch-ip>
\`\`\`

To copy, install, and print the robot SSH readiness plan in one pass:

\`\`\`bash
dist/switch-pilot/${KIT_NAME}/deploy-to-switch.sh <switch-user>@<switch-ip>
\`\`\`

Alternative single-file transfer:

\`\`\`bash
scp dist/switch-pilot/${KIT_NAME}.tar.gz <switch-user>@<switch-ip>:~
\`\`\`

Then on the Switch:

\`\`\`bash
tar -xzf ~/${KIT_NAME}.tar.gz
cd ~/${KIT_NAME}
./install-on-switch.sh
\`\`\`

## Robot SSH Readiness

After the robot is powered and on the same network, run on the Switch:

\`\`\`bash
darwin-switch-robot-ready plan
darwin-switch-robot-ready keygen
darwin-switch-robot-ready copy-key
darwin-switch-robot-ready probe
darwin-switch-robot-ready status
darwin-switch-robot-ready start-walklab
darwin-switch-robot-ready enable-agent-ssh
\`\`\`

\`darwin-switch-robot-ready all\` runs the same flow up to the first actionable
stop. It refuses to claim readiness when the robot-side DarwinForge WalkLab
brokerage patch is missing. On success it updates the Switch agent config to
\`mode=ssh\` and restarts \`darwin-switch-agent.service\`; it may ask for the
Switch sudo password.

## Native Cockpit Acceptance

This field kit installs Darwin without automatic launch. Start the native
cockpit manually:

\`\`\`bash
darwin-switch-native-cockpit
\`\`\`

Before moving the robot, run the read-only native readiness check:

\`\`\`bash
darwin-switch-native-acceptance
\`\`\`

After the robot is powered, WalkLab is started, and SSH mode is applied, use the
native cockpit \`조종 검증 6초\` button. Terminal equivalent:

\`\`\`bash
darwin-switch-native-acceptance --sample-seconds 6 --strict
\`\`\`

During the 6-second sample, press \`A\` once to arm, hold \`ZL/ZR\`, then move
the left stick gently and strongly in several directions. Move the right stick
once and release it to confirm head-hold. A successful control path shows:

- \`agentΔ\` non-zero: Joy-Con input is reaching the Switch agent.
- \`robotΔ\` non-zero and close to \`agentΔ\`: SSH writes are reaching the robot
  \`/tmp/df-walklab-cmd\` file.
- \`periodΔ\` non-zero: gait cadence changes with stick strength, so speed is
  not stuck at one fixed value.
- \`speedVar=true\`: the sampled robot command file shows gait period/foot
  variation, so stick strength is changing robot-side gait values.
- \`headHold=true\`: after the right stick is released, the robot command file
  still carries the last head pan/tilt value instead of snapping to center.

If \`agentΔ\` is large but \`robotΔ\` is near zero, the Switch UI/input layer is
working and the problem is SSH write/auth, robot file permissions, or WalkLab
brokerage state. If both are near zero, check A/ZL/ZR, Joy-Con pairing, and
\`/dev/input/event*\` selection first.

If the native GTK app fails to start, the launcher falls back to the web cockpit
and writes:

\`\`\`text
~/.cache/darwin-switch-cockpit/logs/native-launcher.log
\`\`\`

## What The Installer Does

1. Verifies ${PKG_FILE} with ${PKG_CHECKSUM}.
2. Cross-checks \`manifest.json\` against package SHA-256, size, and runtime
   entry count when \`python3\` is available.
3. Extracts ${PKG_NAME}.
4. Runs OS bootstrap for missing runtime packages and joycond/input setup.
5. Runs source preflight, installs runtime files, skips Darwin service/desktop
   autostart, then records a manual-start preflight, a read-only input device
   report, and a network/camera report.
6. Writes a timestamped install log under \`~/darwin-switch-install-*.log\`.
7. If the one-pass installer fails, it attempts to write
   \`~/darwin-switch-diagnostics-*.tar.gz\`.

## Package

- File: \`${PKG_FILE}\`
- SHA-256: \`${PKG_SHA}\`
- Size: ${PKG_SIZE_BYTES} bytes
- Runtime entries: ${PKG_FILE_COUNT}

## Manifest

\`manifest.json\` is printed into the Switch install log. It records the package
SHA-256, package size, runtime entry count, release-gate checks, install
sequence, runtime-only exclusion rules, and post-install commands to run when a
hardware-specific failure needs triage.
EOF

python3 - "${KIT_DIR}/manifest.json" <<PY
from __future__ import annotations

import json
import sys

manifest = {
    "schema_version": 1,
    "name": "${KIT_NAME}",
    "version": "${VERSION}",
    "created_at": "${CREATED_AT}",
    "generated_by": "tools/switch-pilot/make-install-kit.sh",
    "source": {
        "git_commit": "${GIT_COMMIT}",
        "dirty_file_count": int("${GIT_STATUS}" or "0"),
    },
    "package": {
        "file": "${PKG_FILE}",
        "checksum_file": "${PKG_CHECKSUM}",
        "sha256": "${PKG_SHA}",
        "size_bytes": int("${PKG_SIZE_BYTES}" or "0"),
        "tar_entry_count": int("${PKG_FILE_COUNT}" or "0"),
    },
    "switch_entrypoint": "./install-on-switch.sh",
    "mac_deploy_entrypoint": "./deploy-to-switch.sh",
    "expected_install_log": "~/darwin-switch-install-YYYYMMDD-HHMMSS.log",
    "failure_diagnostics_glob": "~/darwin-switch-diagnostics-*.tar.gz",
    "release_gate": {
        "command": "tools/switch-pilot/verify-release.sh",
        "checks": [
            "shell syntax",
            "python compile",
            "python unittest discovery",
            "web syntax",
            "web runtime tests",
            "source bundle preflight",
            "simulated installed filesystem tree",
            "systemd and desktop path reference checks",
            "package checksum",
            "runtime tarball content allow/deny checks",
            "extracted bundle preflight",
            "field install kit validation",
        ],
    },
    "runtime_exclusions": [
        "tests",
        "package.sh",
        "verify-release.sh",
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
        "web/robot3d-rig.js",
        "web/robot3d-test.html",
        "web/vendor/STLLoader.js",
        "web/vendor/GLTFExporter.js",
        "web/vendor/TextureUtils.js",
        "assets/decimate_glb.py",
        "assets/add_glb_normals.py",
    ],
    "switch_install_sequence": [
        "verify package checksum",
        "extract runtime package",
        "run OS bootstrap",
        "run source bundle preflight",
        "install runtime to /opt, /etc, /usr/local/bin, systemd, desktop entries",
        "skip desktop autostart",
        "leave darwin-switch-agent.service disabled/stopped",
        "run manual-start preflight",
        "record input check",
        "record network/camera check",
        "print robot SSH readiness entrypoint",
    ],
    "post_install_commands": [
        "darwin-switch-preflight --installed",
        "darwin-switch-smoke-test --installed",
        "darwin-switch-day0-acceptance --input-seconds 8 --strict",
        "darwin-switch-input-check --seconds 8",
        "darwin-switch-network-check",
        "darwin-switch-robot-ready plan",
        "darwin-switch-robot-ready all",
        "darwin-switch-robot-ready enable-agent-ssh",
        "darwin-switch-native-cockpit",
        "darwin-switch-native-acceptance",
        "darwin-switch-native-acceptance --sample-seconds 6 --strict",
        "darwin-switch-cockpit",
    ],
}

with open(sys.argv[1], "w", encoding="utf-8") as fp:
    json.dump(manifest, fp, ensure_ascii=False, indent=2)
    fp.write("\\n")
PY

tar -C "${OUT_DIR}" -czf "${KIT_TARBALL}" "${KIT_NAME}"
if command -v shasum >/dev/null 2>&1; then
  (cd "${OUT_DIR}" && shasum -a 256 "${KIT_NAME}.tar.gz") > "${KIT_CHECKSUM}"
elif command -v sha256sum >/dev/null 2>&1; then
  (cd "${OUT_DIR}" && sha256sum "${KIT_NAME}.tar.gz") > "${KIT_CHECKSUM}"
fi

echo "${KIT_TARBALL}"
