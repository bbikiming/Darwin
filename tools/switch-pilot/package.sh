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

# Exclude build-only assets from the runtime tarball. The robot model ships
# pre-baked as web/assets/darwin.glb, so the offline GLB-bake tooling (STL
# assembler, GLTF exporter, bake page) and the STL→GLB bake helper are not
# needed at install/runtime on the Switch. Runtime keeps three.module.min.js,
# GLTFLoader.js, BufferGeometryUtils.js, robot3d.js and the GLB.
for _build_only in \
  web/build-glb.html \
  web/robot3d-rig.js \
  web/robot3d-test.html \
  web/vendor/STLLoader.js \
  web/vendor/GLTFExporter.js \
  web/vendor/TextureUtils.js \
  assets/decimate_glb.py; do
  rm -f "${STAGE}/${_build_only}"
done

tar -C "${OUT_DIR}" -czf "${OUT_DIR}/${PKG_NAME}.tar.gz" "${PKG_NAME}"
rm -rf "${STAGE}"
echo "${OUT_DIR}/${PKG_NAME}.tar.gz"
