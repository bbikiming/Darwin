#!/usr/bin/env bash
# Render every harness YAML under docs/harness/ to SVG + BOM via WireViz.
#
# Usage: scripts/render_wireviz.sh
#
# Requires: python3 with the wireviz package installed (pip install wireviz).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_DIR="$ROOT/docs/harness"

if ! command -v wireviz >/dev/null 2>&1; then
  echo "error: wireviz not found on PATH. Install with: pip install wireviz" >&2
  exit 1
fi

shopt -s globstar nullglob
for yaml in "$HARNESS_DIR"/**/*.yaml; do
  echo "→ rendering $yaml"
  wireviz "$yaml"
done
