#!/usr/bin/env bash
# Phase 0 macOS USB-Serial driver health check.
# Reports the state of:
#   - FTDI VCP                 (CM-730 / CM-740 USB chip)
#   - Silicon Labs CP210x      (U2D2 dongle)
#   - Apple In-Kernel USB-Serial
# Lists candidate device nodes for OP1/OP2.
#
# Safe to run on Linux too — just reports "macOS only" for the kext checks.
set -uo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
    echo "이 스크립트는 macOS 전용입니다. (현재: $(uname))"
    echo "Mac에서 실행하면 FTDI / CP210x 드라이버 상태를 점검합니다."
    exit 0
fi

echo "=== macOS USB-Serial driver health ==="
echo

echo "[1/4] kextstat — FTDI/CP210x 커널 익스텐션"
if command -v kextstat >/dev/null 2>&1; then
    kextstat 2>/dev/null | grep -iE 'ftdi|silabs|cp210|usbserial' || echo "  (none loaded — Apple In-Kernel driver를 사용 중일 수 있음)"
else
    echo "  kextstat 미사용 가능 — Sequoia 이상에서는 시스템 확장 사용"
fi

echo
echo "[2/4] systemextensionsctl — 시스템 확장 (Sequoia+)"
if command -v systemextensionsctl >/dev/null 2>&1; then
    systemextensionsctl list 2>/dev/null | grep -iE 'ftdi|silabs|cp210' || echo "  (FTDI/CP210x 시스템 확장 없음)"
fi

echo
echo "[3/4] /dev/cu.* 후보 디바이스"
ls /dev/cu.usbserial* /dev/cu.usbmodem* /dev/cu.SLAB* /dev/cu.wchusbserial* 2>/dev/null \
    | sed 's/^/  /' || echo "  (USB-Serial 디바이스 없음 — 로봇 USB 케이블을 연결하세요)"

echo
echo "[4/4] system_profiler — USB 트리에서 ROBOTIS / FTDI 식별"
system_profiler SPUSBDataType 2>/dev/null \
    | awk '/Product ID|Vendor ID|Manufacturer|Product/{print}' \
    | grep -iB2 -A2 'ftdi\|robotis\|silicon labs\|silabs' \
    | head -40 \
    || echo "  (FTDI / ROBOTIS / Silicon Labs 디바이스 없음)"

echo
cat <<'EOF'
=== 권장 다음 단계 ===
- /dev/cu.usbserial-XXXXXX 가 보이면 → forge ping --port /dev/cu.usbserial-XXXXXX
- 보이지 않으면:
  1) 케이블·전원 확인
  2) 시스템 설정 → 개인정보 보호 및 보안 → 시스템 확장 허용
  3) 첫 연결 시 "이 케이블 USB 디바이스를 허용할 것인가?" 다이얼로그 응답
- Apple Silicon은 Apple In-Kernel FTDI를 우선 사용. 필요 시:
    https://ftdichip.com/drivers/vcp-drivers/
EOF
