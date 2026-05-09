#!/usr/bin/env bash
# Quick discovery sweep: pings every Dynamixel ID 1..253 on the bus and
# reports who answers. Wraps the future `darwinforge` CLI; useful before
# the Swift CLI lands.
#
# Usage: scripts/dxl_scan.sh /dev/cu.usbserial-XXXX
set -euo pipefail

PORT="${1:-/dev/cu.usbserial-A1B2C3}"
echo "Scanning $PORT for Dynamixel devices (Protocol 1.0, 1 Mbps)…"

if command -v darwinforge >/dev/null 2>&1; then
  darwinforge ping --port "$PORT"
  exit 0
fi

echo "darwinforge CLI not yet built. Once Sources/DarwinForgeCLI compiles," \
     "this script will delegate to it."
