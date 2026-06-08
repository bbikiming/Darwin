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
STAGE="${OUT_DIR}/${PKG_NAME}"

rm -rf "${STAGE}"
mkdir -p "${STAGE}" "${OUT_DIR}"
cp -a "${ROOT_DIR}/." "${STAGE}/"
find "${STAGE}" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "${STAGE}" -name "*.pyc" -delete
find "${STAGE}" -name ".DS_Store" -delete
find "${STAGE}" -name "._*" -delete
xattr -cr "${STAGE}" 2>/dev/null || true

# Exclude build-only assets from the runtime tarball. The robot model ships
# pre-baked as web/assets/darwin.glb, so the offline GLB-bake tooling (STL
# assembler, GLTF exporter, bake page), the decimator, and the normal injector
# are not needed at install/runtime on the Switch. Runtime keeps the cockpit,
# model-check.html, three.module.min.js, GLTFLoader.js, BufferGeometryUtils.js,
# robot3d.js, and the GLB.
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
  rm -f "${STAGE}/${_build_only}"
done
rm -rf "${STAGE}/mac-rcm-injector"
rm -rf "${STAGE}/tests"

PYTHONPATH="${STAGE}/src" python3 -m darwin_switch_agent.preflight \
  --root "${STAGE}" \
  --config "${STAGE}/config.example.json" \
  --bundle-only \
  --strict >/dev/null

# The preflight import can create Python bytecode inside the staged tree. Keep
# the shipped runtime bundle clean and reproducible after that check.
find "${STAGE}" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "${STAGE}" -name "*.pyc" -delete
find "${STAGE}" -name ".DS_Store" -delete
find "${STAGE}" -name "._*" -delete
xattr -cr "${STAGE}" 2>/dev/null || true

COPYFILE_DISABLE=1 tar -C "${OUT_DIR}" -czf "${OUT_DIR}/${PKG_NAME}.tar.gz" "${PKG_NAME}"
if command -v shasum >/dev/null 2>&1; then
  (cd "${OUT_DIR}" && shasum -a 256 "${PKG_NAME}.tar.gz") > "${OUT_DIR}/${PKG_NAME}.tar.gz.sha256"
elif command -v sha256sum >/dev/null 2>&1; then
  (cd "${OUT_DIR}" && sha256sum "${PKG_NAME}.tar.gz") > "${OUT_DIR}/${PKG_NAME}.tar.gz.sha256"
fi
rm -rf "${STAGE}"
echo "${OUT_DIR}/${PKG_NAME}.tar.gz"
