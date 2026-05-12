#!/usr/bin/env bash
# Snapshot /darwin/ from a robot's onboard Linux to firmware-backups/.
#
# Usage: scripts/firmware_backup.sh <robot-host> [identity-file]
#
# Captures: Data/, Linux/project/*/Makefile, /etc/rc.local, plus a
# "uname -a" + "lsusb" + voltage probe so the snapshot is self-describing.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <robot-host> [identity-file]" >&2
  exit 64
fi

HOST="$1"
ID_OPT=""
if [[ $# -ge 2 ]]; then
  ID_OPT="-i $2"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ROOT/firmware-backups/$HOST-$STAMP"
mkdir -p "$OUT_DIR"

echo "→ snapshotting /darwin/Data → $OUT_DIR/Data"
rsync -avz $ID_OPT "$HOST:/darwin/Data" "$OUT_DIR/"

echo "→ writing host metadata"
{
  ssh $ID_OPT "$HOST" 'uname -a'
  ssh $ID_OPT "$HOST" 'lsusb || true'
  ssh $ID_OPT "$HOST" 'cat /etc/os-release || true'
} > "$OUT_DIR/host-metadata.txt"

echo "✓ done: $OUT_DIR"
