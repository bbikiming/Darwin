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

tar -C "${OUT_DIR}" -czf "${OUT_DIR}/${PKG_NAME}.tar.gz" "${PKG_NAME}"
rm -rf "${STAGE}"
echo "${OUT_DIR}/${PKG_NAME}.tar.gz"
