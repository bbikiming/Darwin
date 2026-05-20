#!/usr/bin/env bash
# harness-manifest.sh — 모든 Harness 세션 한 줄 요약.
#
# 용도:
#   1. 사용자가 "어제 어떤 세션이 있었나" 빠른 overview.
#   2. Claude Code / Codex 에게 "이 manifest 보고 어떤 세션을 자세히 봐야 할지 골라줘".
#
# 사용:
#   scripts/harness-manifest.sh                  # 모든 세션
#   scripts/harness-manifest.sh --errors         # error_count > 0 만
#   scripts/harness-manifest.sh --recent 10      # 최근 10개
#   scripts/harness-manifest.sh --json           # JSON 배열 출력 (외부 도구용)
#   scripts/harness-manifest.sh --path           # session 디렉토리 경로만 출력

set -euo pipefail

ROOT="$HOME/Library/Application Support/DarwinForge/Harness/sessions"
MODE="${1:-table}"
LIMIT="${2:-0}"

if [ ! -d "$ROOT" ]; then
  echo "Harness session 디렉토리 없음: $ROOT" >&2
  echo "앱을 한 번 실행하면 자동 생성됩니다." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq 미설치 — brew install jq" >&2
  exit 1
fi

case "$MODE" in
  --json)
    # JSON 배열 출력 — 외부 LLM 이 그대로 받아 분석.
    {
      echo "["
      first=true
      for d in "$ROOT"/*/; do
        m="$d/meta.json"
        [ -f "$m" ] || continue
        if [ "$first" = "true" ]; then first=false; else echo ","; fi
        jq -c --arg path "$d" '. + {path: $path}' "$m"
      done
      echo "]"
    } | jq '.'
    ;;
  --errors)
    # error_count > 0 인 세션만, 시간 역순.
    printf "%-10s %-20s %-20s %5s %5s %5s\n" "ID8" "STARTED" "ENDED" "EV" "ERR" "CONN"
    for d in "$ROOT"/*/; do
      m="$d/meta.json"
      [ -f "$m" ] || continue
      ec=$(jq -r '.errorCount' "$m")
      [ "$ec" -gt 0 ] || continue
      jq -r '[.id[0:8], .started[0:19], (.ended[0:19] // "(unfinished)"), (.eventCount|tostring), (.errorCount|tostring), (.connectCount|tostring)] | @tsv' "$m"
    done | sort -k2 -r | awk -F'\t' '{printf "%-10s %-20s %-20s %5s %5s %5s\n", $1, $2, $3, $4, $5, $6}'
    ;;
  --recent)
    # 최근 N 개 (started 내림차순).
    N="${2:-10}"
    printf "%-10s %-20s %-20s %5s %5s %5s\n" "ID8" "STARTED" "ENDED" "EV" "ERR" "CONN"
    for d in "$ROOT"/*/; do
      m="$d/meta.json"
      [ -f "$m" ] || continue
      jq -r '[.id[0:8], .started[0:19], (.ended[0:19] // "(unfinished)"), (.eventCount|tostring), (.errorCount|tostring), (.connectCount|tostring)] | @tsv' "$m"
    done | sort -k2 -r | head -n "$N" | awk -F'\t' '{printf "%-10s %-20s %-20s %5s %5s %5s\n", $1, $2, $3, $4, $5, $6}'
    ;;
  --path)
    # 디렉토리 경로만 — 다른 스크립트 / Claude tool 호출에 파이프.
    for d in "$ROOT"/*/; do echo "$d"; done | sort
    ;;
  table|*)
    # 기본 — 모든 세션 시간순.
    printf "%-10s %-20s %-20s %5s %5s %5s  %s\n" "ID8" "STARTED" "ENDED" "EV" "ERR" "CONN" "FLAGS"
    for d in "$ROOT"/*/; do
      m="$d/meta.json"
      [ -f "$m" ] || continue
      jq -r '[
        .id[0:8],
        .started[0:19],
        (.ended[0:19] // "(unfinished)"),
        (.eventCount|tostring),
        (.errorCount|tostring),
        (.connectCount|tostring),
        ((if .pinned then "📌" else "" end) + (if .isBaseline then "🎯" else "" end))
      ] | @tsv' "$m"
    done | sort -k2 | awk -F'\t' '{printf "%-10s %-20s %-20s %5s %5s %5s  %s\n", $1, $2, $3, $4, $5, $6, $7}'
    echo ""
    echo "Tip: --errors / --recent 10 / --json / --path"
    echo "경로: $ROOT"
    ;;
esac
