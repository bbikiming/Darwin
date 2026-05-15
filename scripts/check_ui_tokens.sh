#!/usr/bin/env bash
# DarwinForge UI Token Lint Gate
#
# 디자인 시스템 토큰을 우회한 raw 패턴을 검출하고, baseline 대비 회귀를 방지한다.
# Codex 감사 문서(2026-05-13-uiux-design-system-audit.md) 기반.
#
# 사용:
#   bash scripts/check_ui_tokens.sh             # 기본 — baseline 대비 검사
#   bash scripts/check_ui_tokens.sh --report    # 위반 세부 출력 (파일/라인)
#   bash scripts/check_ui_tokens.sh --baseline  # 현재 위반을 새 baseline 으로 저장
#   bash scripts/check_ui_tokens.sh --strict    # 모든 위반 즉시 fail (CI prod)
#
# 종료 코드:
#   0 = baseline 이하 (회귀 없음, 감소 가능)
#   1 = baseline 초과 (회귀 발생)
#   2 = 사용법 오류

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT/app/ui/DarwinForge/Sources"
BASELINE_FILE="$ROOT/.ui-tokens-baseline"

# 검사 대상 파일 화이트리스트 — DS / Visualization 폴더는 raw 값 허용.
EXCLUDE_DIRS=(
    "DesignSystem"
    "Visualization"
)
EXCLUDE_PATTERN=$(IFS='|'; echo "${EXCLUDE_DIRS[*]}")

# 검사 패턴 — Codex 권장 + 우리 조정.
PATTERNS=(
    "raw_color:Color\.(red|green|blue|orange|yellow|gray|secondary|primary)\b"
    "ns_color:NSColor\.(control|window)BackgroundColor"
    "rounded_rect:RoundedRectangle\(cornerRadius:\s*[0-9]"
    "corner_radius_int:cornerRadius:\s*[0-9]+\)"
    "padding_int:\.padding\(\s*[0-9]+\s*\)"
    "padding_h_int:\.padding\(\s*\.horizontal\s*,\s*[0-9]+"
    "padding_v_int:\.padding\(\s*\.vertical\s*,\s*[0-9]+"
    "raw_font:\.font\(\.(title|title2|title3|headline|caption|caption2|body)\)"
    "raw_fg_secondary:\.foregroundStyle\(\.secondary\)"
)

MODE="check"
case "${1:-}" in
    --report)   MODE="report" ;;
    --baseline) MODE="baseline" ;;
    --strict)   MODE="strict" ;;
    --help|-h)  grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    "")         ;;
    *)          echo "Unknown arg: $1" >&2; exit 2 ;;
esac

# 한 패턴 위반 라인 검색 (예외 주석 제외).
count_pattern() {
    local pattern="$1"
    local results
    results=$(
        grep -rEn "$pattern" "$SRC_DIR" --include="*.swift" 2>/dev/null \
            | grep -vE "/($EXCLUDE_PATTERN)/" \
            | grep -v "// design-system-exception:" \
            || true
    )
    if [[ -z "$results" ]]; then
        echo "0"
    else
        echo "$results" | wc -l | tr -d ' '
    fi
}

# 한 패턴 위반 라인 출력 (--report 모드).
list_pattern() {
    local pattern="$1"
    grep -rEn "$pattern" "$SRC_DIR" --include="*.swift" 2>/dev/null \
        | grep -vE "/($EXCLUDE_PATTERN)/" \
        | grep -v "// design-system-exception:" \
        || true
}

# 현재 위반 카운트 수집.
collect_counts() {
    for p in "${PATTERNS[@]}"; do
        local name="${p%%:*}"
        local pattern="${p#*:}"
        local n
        n=$(count_pattern "$pattern")
        echo "$name=$n"
    done
}

# Baseline 파일 읽기 (없으면 모두 0).
read_baseline() {
    if [[ ! -f "$BASELINE_FILE" ]]; then
        for p in "${PATTERNS[@]}"; do
            local name="${p%%:*}"
            echo "$name=0"
        done
        return
    fi
    cat "$BASELINE_FILE"
}

# Baseline 파일 쓰기.
write_baseline() {
    {
        echo "# DarwinForge UI Token Baseline"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "# 각 패턴의 현재 위반 카운트. PR 이 본 숫자를 늘리면 CI fail."
        echo ""
        collect_counts
    } > "$BASELINE_FILE"
    echo "✓ Baseline written: $BASELINE_FILE"
}

if [[ "$MODE" == "baseline" ]]; then
    write_baseline
    exit 0
fi

# 카운트 + baseline 비교. (bash 3.x 호환 — associative array 미사용)
# 헬퍼: name=value 형식의 줄 묶음에서 name 에 해당하는 value 추출.
lookup_value() {
    local key="$1"
    local data="$2"
    echo "$data" | grep -E "^${key}=" | head -1 | cut -d'=' -f2
}

CURRENT_DATA="$(collect_counts)"
BASELINE_DATA="$(read_baseline)"

# 보고서 출력.
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DarwinForge UI Token Lint  ─  $(date '+%Y-%m-%d %H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  %-25s  %8s  %8s  %s\n" "PATTERN" "CURRENT" "BASELINE" "STATUS"
printf "  %-25s  %8s  %8s  %s\n" "-------" "-------" "--------" "------"

FAIL=0
TOTAL_CURRENT=0
TOTAL_BASELINE=0
for p in "${PATTERNS[@]}"; do
    name="${p%%:*}"
    cur="$(lookup_value "$name" "$CURRENT_DATA")"
    base="$(lookup_value "$name" "$BASELINE_DATA")"
    cur="${cur:-0}"
    base="${base:-0}"
    TOTAL_CURRENT=$((TOTAL_CURRENT + cur))
    TOTAL_BASELINE=$((TOTAL_BASELINE + base))
    if [[ "$MODE" == "strict" ]]; then
        if (( cur > 0 )); then
            status="✗ FAIL"
            FAIL=1
        else
            status="✓ PASS"
        fi
    else
        if (( cur > base )); then
            status="✗ REGRESSION (+$((cur - base)))"
            FAIL=1
        elif (( cur < base )); then
            status="↓ improvement (-$((base - cur)))"
        else
            status="= baseline"
        fi
    fi
    printf "  %-25s  %8s  %8s  %s\n" "$name" "$cur" "$base" "$status"
done
echo "  ----------------------------------------------------"
printf "  %-25s  %8s  %8s\n" "TOTAL" "$TOTAL_CURRENT" "$TOTAL_BASELINE"
echo ""

if [[ "$MODE" == "report" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  DETAIL — 위반 위치 (예외 주석: // design-system-exception:)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for p in "${PATTERNS[@]}"; do
        name="${p%%:*}"
        pattern="${p#*:}"
        cur="$(lookup_value "$name" "$CURRENT_DATA")"
        cur="${cur:-0}"
        if (( cur > 0 )); then
            echo ""
            echo "▶ $name  ($cur건)"
            list_pattern "$pattern" | sed 's|^|    |'
        fi
    done
fi

if (( FAIL == 1 )); then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ "$MODE" == "strict" ]]; then
        echo "  ✗ STRICT MODE FAIL — 모든 raw 패턴을 토큰으로 교체 필요."
    else
        echo "  ✗ REGRESSION — baseline 보다 위반이 증가했다."
        echo ""
        echo "  대응:"
        echo "  1) 신규 위반을 DS 토큰으로 치환 (DFSpace / DFRadius / DFColor.* 등)."
        echo "  2) 디자인 시스템 내부 raw 값이라면 라인에 // design-system-exception: <이유> 주석 추가."
        echo "  3) 의도된 baseline 갱신이라면: bash scripts/check_ui_tokens.sh --baseline"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi

if (( TOTAL_CURRENT < TOTAL_BASELINE )); then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ↓ 위반이 감소했다 ($TOTAL_BASELINE → $TOTAL_CURRENT). Baseline 갱신 권장:"
    echo "      bash scripts/check_ui_tokens.sh --baseline"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo "  ✓ baseline 유지. 변경 없음."
fi
exit 0
