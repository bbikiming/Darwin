#!/usr/bin/env bash
# run-all-smoke.sh — orchestrate the full real-robot smoke test sequence.
#
# Phases (in order):
#   1. preflight-check.sh     — env + SSH + battery + dxlPower + IMU
#   2. deploy-and-verify.sh   — build + install + launch + harness session
#   3. walk-cycle-smoke.sh    — Onboard walking_engine_command verification
#   4. recovery-smoke.sh      — emergency-stop + recovery
#
# Aggregates pass/fail across all phases. If any phase exits non-zero,
# subsequent phases still run (so the operator gets a full picture) but the
# final exit code reflects worst result.
#
# Environment:
#   SMOKE_NONINTERACTIVE=1   skip every "press Enter" + manual prompt
#                            (good for unattended logging; many checks
#                            become skipped warnings instead of fails)
#   SMOKE_STOP_ON_FAIL=1     abort the chain at the first failing phase
#
# Output: a results table + manual-checklist reminder pointing to
#   docs/walk-lab/SMOKE_TEST_CHECKLIST.md.
#
# Exit codes:
#   0  all phases PASS
#   1  one or more phases FAILED
#   2  prerequisite missing (caught by a child phase exit 2)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKLIST_PATH="$REPO_ROOT/docs/walk-lab/SMOKE_TEST_CHECKLIST.md"

smoke_header "run-all-smoke.sh — DARwIn-OP2 통합 smoke test"

PHASES=(
    "preflight-check.sh|preflight"
    "deploy-and-verify.sh|deploy"
    "walk-cycle-smoke.sh|walk"
    "recovery-smoke.sh|recovery"
)

declare -a PHASE_RESULTS=()
WORST_EXIT=0

for entry in "${PHASES[@]}"; do
    script="${entry%%|*}"
    label="${entry##*|}"
    printf "\n%s━━━ Phase: %s ━━━%s\n" "$SMOKE_BLUE" "$label" "$SMOKE_RESET"
    if bash "$SCRIPT_DIR/$script"; then
        PHASE_RESULTS+=("PASS|$label")
    else
        rc=$?
        PHASE_RESULTS+=("FAIL($rc)|$label")
        if [[ "$rc" -gt "$WORST_EXIT" ]]; then
            WORST_EXIT="$rc"
        fi
        if [[ "${SMOKE_STOP_ON_FAIL:-0}" == "1" ]]; then
            smoke_warn "SMOKE_STOP_ON_FAIL=1 — chain 중단"
            break
        fi
    fi
done

# Final results table.
printf "\n%s════════ 종합 결과 ════════%s\n" "$SMOKE_BLUE" "$SMOKE_RESET"
for r in "${PHASE_RESULTS[@]}"; do
    status="${r%%|*}"
    label="${r##*|}"
    if [[ "$status" == "PASS" ]]; then
        printf "  %s✓%s %-12s %s\n" "$SMOKE_GREEN" "$SMOKE_RESET" "$label" "$status"
    else
        printf "  %s✗%s %-12s %s\n" "$SMOKE_RED" "$SMOKE_RESET" "$label" "$status"
    fi
done

printf "\n수동 checklist 참고:\n  %s\n" "$CHECKLIST_PATH"

exit "$WORST_EXIT"
