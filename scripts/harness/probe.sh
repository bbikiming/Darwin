#!/usr/bin/env bash
# Phase 3 — 연결 테스트. 다음을 보고:
#   1) /dev/cu.* 후보 디바이스
#   2) 각 디바이스에 ID 200 PING (forge가 빌드되어 있을 때)
#   3) LiPo 전압 (가능하면)
#   4) MX-28 모터 ID 스캔 (forge 있을 때)
#
# Usage:  bash scripts/harness/probe.sh
#         bash scripts/harness/probe.sh /dev/cu.usbserial-A1B2
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=== probe.sh — Mac ↔ DARwIn-OP/OP2 연결 진단 ==="
echo

# Mac/Linux 양쪽 모두에서 의미 있게 동작
if [[ "$(uname)" == "Darwin" ]]; then
    echo "[1/4] /dev/cu.* 후보"
    ls /dev/cu.usbserial* /dev/cu.usbmodem* 2>/dev/null | sed 's/^/  /' \
        || echo "  (없음 — USB 케이블/CM 전원 확인)"
else
    echo "[1/4] /dev/cu.* 후보"
    echo "  (Linux 컨테이너 — Mac에서 의미 있음)"
fi

echo
echo "[2/4] forge CLI 사용 가능 여부"
if command -v forge >/dev/null 2>&1; then
    forge --version
    PORT="${1:-}"
    if [[ -n "$PORT" ]]; then
        echo "  → ID 200 (CM) PING"
        forge ping --port "$PORT" --id 200 --timeout 200ms || echo "    (응답 없음)"
        echo "  → 모터 ID 1..20 스캔"
        forge scan --port "$PORT" --range 1-20 --timeout 50ms || echo "    (스캔 실패)"
    else
        echo "  포트를 인자로 전달하면 PING + scan 수행: bash $0 /dev/cu.usbserial-XXXX"
    fi
else
    echo "  forge CLI 미빌드 — Sprint 1 완료 후 사용 가능"
    echo "  설치: cargo install --path app/core/forge-cli"
fi

echo
echo "[3/4] LiPo 전압 (manual)"
echo "  cell checker 또는 forge로 측정. 셀당 3.7 V 이상 권장."

echo
echo "[4/4] 안전 체크리스트 (수동)"
sed -n '/## 매번/,/## 모션/p' "$ROOT/harness/shared/safety.md" \
    | head -10 \
    | sed 's/^/  /'

echo
echo "=== 끝 ==="
