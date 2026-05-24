#!/usr/bin/env bash
# Shared helpers for scripts/smoke/*.sh — color output, env validation,
# SSH wrappers, cleanup hooks.
#
# Source this from each smoke script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/_lib.sh"
#
# Required env (validated by smoke_require_env / smoke_require_ssh_env):
#   ROBOTIS_HOST     — robot IP / hostname (e.g., 192.168.123.1)
#   ROBOTIS_USER     — SSH user (typical: robotis)
#   ROBOTIS_SSH_KEY  — (optional) path to identity file; falls back to default ~/.ssh
#   ROBOTIS_SSH_PORT — (optional) SSH port; default 22
#
# Exit conventions:
#   0   pass
#   1   fail (test condition not met)
#   2   prerequisite missing (env var, tool, network)
#   130 user-interrupted (^C)

set -uo pipefail

# ---- color output ----
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
    SMOKE_RED=$'\033[31m'
    SMOKE_GREEN=$'\033[32m'
    SMOKE_YELLOW=$'\033[33m'
    SMOKE_BLUE=$'\033[34m'
    SMOKE_DIM=$'\033[2m'
    SMOKE_RESET=$'\033[0m'
else
    SMOKE_RED=""
    SMOKE_GREEN=""
    SMOKE_YELLOW=""
    SMOKE_BLUE=""
    SMOKE_DIM=""
    SMOKE_RESET=""
fi

SMOKE_PASS_COUNT=0
SMOKE_FAIL_COUNT=0
SMOKE_WARN_COUNT=0

smoke_pass() {
    printf "  %s✓%s %s\n" "$SMOKE_GREEN" "$SMOKE_RESET" "$*"
    SMOKE_PASS_COUNT=$((SMOKE_PASS_COUNT + 1))
}

smoke_fail() {
    printf "  %s✗%s %s\n" "$SMOKE_RED" "$SMOKE_RESET" "$*" >&2
    SMOKE_FAIL_COUNT=$((SMOKE_FAIL_COUNT + 1))
}

smoke_warn() {
    printf "  %s!%s %s\n" "$SMOKE_YELLOW" "$SMOKE_RESET" "$*" >&2
    SMOKE_WARN_COUNT=$((SMOKE_WARN_COUNT + 1))
}

smoke_info() {
    printf "  %s·%s %s\n" "$SMOKE_DIM" "$SMOKE_RESET" "$*"
}

smoke_section() {
    printf "\n%s==>%s %s\n" "$SMOKE_BLUE" "$SMOKE_RESET" "$*"
}

smoke_header() {
    printf "\n%s=== %s ===%s\n" "$SMOKE_BLUE" "$*" "$SMOKE_RESET"
}

smoke_manual() {
    # Prompt the operator to confirm a physical / sensory check.
    # Honors SMOKE_NONINTERACTIVE=1 — defers to a manual checklist exit.
    local prompt="$1"
    if [[ "${SMOKE_NONINTERACTIVE:-0}" == "1" ]]; then
        smoke_warn "MANUAL (non-interactive skip): $prompt"
        return 0
    fi
    printf "\n  %s? 수동 확인%s %s\n" "$SMOKE_YELLOW" "$SMOKE_RESET" "$prompt"
    printf "    [y] 통과 / [n] 실패 / [s] 건너뛰기: "
    local answer
    read -r answer || answer="s"
    case "$answer" in
        y|Y) smoke_pass "수동 OK: $prompt"; return 0 ;;
        n|N) smoke_fail "수동 FAIL: $prompt"; return 1 ;;
        *)   smoke_warn "수동 SKIP: $prompt"; return 0 ;;
    esac
}

# Prompt operator to perform a UI action (Enter when done, s to skip).
# Echoes "skip" if user types s or SMOKE_NONINTERACTIVE=1, else "ok".
smoke_operator_action() {
    local message="$1"
    if [[ "${SMOKE_NONINTERACTIVE:-0}" == "1" ]]; then
        smoke_warn "OPERATOR ACTION (non-interactive skip): $message"
        echo "skip"
        return 0
    fi
    printf "\n  %s? 사용자 동작%s %s\n" "$SMOKE_YELLOW" "$SMOKE_RESET" "$message"
    printf "    [Enter] 완료 / [s] 건너뛰기: "
    local answer
    read -r answer || answer="s"
    if [[ "$answer" == "s" ]] || [[ "$answer" == "S" ]]; then
        echo "skip"
    else
        echo "ok"
    fi
}

smoke_summary() {
    printf "\n%s--- 결과 ---%s  PASS=%d  WARN=%d  FAIL=%d\n" \
        "$SMOKE_BLUE" "$SMOKE_RESET" \
        "$SMOKE_PASS_COUNT" "$SMOKE_WARN_COUNT" "$SMOKE_FAIL_COUNT"
    if [[ $SMOKE_FAIL_COUNT -gt 0 ]]; then
        printf "%s❌ FAIL%s — 위 실패 항목 해결 후 재시도\n" "$SMOKE_RED" "$SMOKE_RESET"
        return 1
    fi
    printf "%s✅ PASS%s\n" "$SMOKE_GREEN" "$SMOKE_RESET"
    return 0
}

# Validate that a single env var is set and non-empty.
smoke_require_env() {
    local name="$1"
    local hint="${2:-}"
    if [[ -z "${!name:-}" ]]; then
        smoke_fail "환경변수 누락: $name${hint:+  (${hint})}"
        return 2
    fi
    return 0
}

# Validate the standard SSH env block. Returns 2 if anything missing.
# Increments FAIL counter — for scripts where SSH is required (preflight, walk).
smoke_require_ssh_env() {
    local rc=0
    smoke_require_env ROBOTIS_HOST "예: 192.168.123.1" || rc=2
    smoke_require_env ROBOTIS_USER "예: robotis" || rc=2
    if [[ -n "${ROBOTIS_SSH_KEY:-}" ]] && [[ ! -f "$ROBOTIS_SSH_KEY" ]]; then
        smoke_fail "ROBOTIS_SSH_KEY 파일 없음: $ROBOTIS_SSH_KEY"
        rc=2
    fi
    return $rc
}

# Non-fatal probe — returns 0 if env present, 1 if missing. Does not
# increment FAIL / PASS counters. For scripts where SSH is optional.
smoke_has_ssh_env() {
    [[ -n "${ROBOTIS_HOST:-}" ]] && [[ -n "${ROBOTIS_USER:-}" ]] || return 1
    [[ -z "${ROBOTIS_SSH_KEY:-}" ]] || [[ -f "$ROBOTIS_SSH_KEY" ]] || return 1
    return 0
}

# Compose the ssh command args from env. Echoes the args, suitable for $(...).
smoke_ssh_args() {
    local port="${ROBOTIS_SSH_PORT:-22}"
    local key_opt=""
    if [[ -n "${ROBOTIS_SSH_KEY:-}" ]]; then
        key_opt="-i ${ROBOTIS_SSH_KEY}"
    fi
    # BatchMode=yes — no password prompt (keys only) for CI-style runs.
    # StrictHostKeyChecking=accept-new — TOFU; safe per docs/walk-lab guide §SSH MITM.
    # ConnectTimeout=5 — avoid hanging on unreachable host.
    printf "%s -p %s -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 %s@%s" \
        "$key_opt" "$port" "${ROBOTIS_USER}" "${ROBOTIS_HOST}"
}

# Run a single command on the robot via SSH. Returns exit code from remote.
# Stdout/stderr passthrough.
smoke_ssh() {
    # shellcheck disable=SC2046
    ssh $(smoke_ssh_args) "$@"
}

# Run a command silently, capture only exit code. Useful for "is this reachable?"
smoke_ssh_quiet() {
    # shellcheck disable=SC2046
    ssh $(smoke_ssh_args) "$@" >/dev/null 2>&1
}

# Capture command stdout (suppress stderr). Caller may pattern-match.
smoke_ssh_capture() {
    # shellcheck disable=SC2046
    ssh $(smoke_ssh_args) "$@" 2>/dev/null
}

# Resolve the harness session directory (used by deploy-and-verify).
smoke_harness_root() {
    printf "%s/Library/Application Support/DarwinForge/Harness" "$HOME"
}

# Cleanup hook registry — scripts can append with smoke_on_exit "...".
SMOKE_CLEANUP_CMDS=()

smoke_on_exit() {
    SMOKE_CLEANUP_CMDS+=("$1")
}

smoke_run_cleanup() {
    local cmd
    # ${array[@]} 가 set -u + empty array 시 unbound 로 트리거 — :- 로 가드.
    for cmd in "${SMOKE_CLEANUP_CMDS[@]:-}"; do
        [[ -z "$cmd" ]] && continue
        eval "$cmd" || true
    done
}

trap 'smoke_run_cleanup' EXIT
trap 'echo; smoke_warn "Interrupted by user (^C)"; smoke_run_cleanup; exit 130' INT
