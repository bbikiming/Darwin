#!/usr/bin/env bash
# Mac → Ally 원격 브링업(헤드리스): pull + build + selftest + probe.
#
# GUI 콕핏·axis-dump(게임패드)·실로봇 connect 는 SSH 로 못 한다(GUI/패드는 Ally 데스크톱).
# 그래서 이 래퍼는 빌드·로봇불요 검증·도달성까지만 원격으로 돌리고, 나머지는 안내한다.
#
# 사용:  bash app/ally/scripts/ally-fpv-remote.sh [ssh-host]   (기본 host = ally)
set -euo pipefail

ALLY="${1:-ally}"
PS1='C:\dev\Darwin\app\ally\scripts\ally-fpv-bringup.ps1'

echo "== Mac → ${ALLY} 원격 헤드리스 브링업 (pull+build+selftest+probe) =="
ssh -o BatchMode=yes "$ALLY" \
  "powershell -NoProfile -ExecutionPolicy Bypass -File ${PS1} -Pull -Build -Selftest -Probe"

cat <<'EOF'

── 다음 (Ally 데스크톱에서 직접 — GUI/패드/실조종) ──────────────────
  .\app\ally\scripts\ally-fpv-bringup.ps1 -AxisDump      # 게임패드 축/트리거 현장 보정
  .\app\ally\scripts\ally-fpv-bringup.ps1 -Connect       # 실로봇 W1 게이트(eff_hz>=19·RTT)
  .\app\ally\scripts\ally-fpv-bringup.ps1 -Run           # 콕핏 + Edge

  ※ 실로봇 단계 전: 로봇 walklab-active · Mac DarwinForge 앱 OFF.
─────────────────────────────────────────────────────────────────
EOF
