#!/usr/bin/env bash
# deploy-and-verify.sh — build DarwinForge.app, install to /Applications,
# launch it, and verify the telemetry harness session is created on disk.
#
# Reference: docs/harness/real-robot-verification.md §5.1-5.4 (절차 자동화).
#
# Automated:
#   1. Cleanup orphaned harness sessions (current-* archive trigger)
#   2. swift build (delegates to scripts/install-app.sh)
#   3. Launch /Applications/DarwinForge.app
#   4. Wait for harness session directory creation
#   5. Verify events.jsonl exists + first event is "app.launch"
#   6. Verify meta.json eventCount >= 1
#
# Semi-automated:
#   7. Prompt operator to perform "Auto Connect" inside the UI, then
#      verify connection.attempt + (success|failure) reaches disk
#
# Exit codes:
#   0 all checks pass
#   1 a check failed (build error, harness session missing, events absent)
#   2 prerequisite missing (swift, /Applications writable)
#
# Environment overrides (optional):
#   SMOKE_DEPLOY_SKIP_BUILD=1   reuse already-installed /Applications/DarwinForge.app
#   SMOKE_DEPLOY_WAIT_S=10      seconds to wait for app launch (default 8)
#   SMOKE_NONINTERACTIVE=1      skip step 7 (UI connection prompt)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WAIT_S="${SMOKE_DEPLOY_WAIT_S:-8}"
HARNESS_ROOT="$(smoke_harness_root)"

smoke_header "deploy-and-verify.sh — DarwinForge.app 빌드/실행/하네스 검증"

# ────────────────────────────────────────────────────────────────
# 0. Prereqs
# ────────────────────────────────────────────────────────────────
smoke_section "0. 사전 도구 점검"
if ! command -v swift >/dev/null 2>&1; then
    smoke_fail "swift 미설치 — Xcode + Command Line Tools 필요"
    exit 2
fi
smoke_pass "swift $(swift --version | head -1)"

if ! command -v jq >/dev/null 2>&1; then
    smoke_warn "jq 미설치 — JSON 검증을 grep 으로 대체 (brew install jq 권장)"
    USE_JQ=0
else
    smoke_pass "jq $(jq --version)"
    USE_JQ=1
fi

if [[ ! -w "/Applications" ]]; then
    smoke_warn "/Applications 쓰기 권한 없음 — sudo 또는 admin 권한 필요"
fi

# ────────────────────────────────────────────────────────────────
# 1. Cleanup orphaned harness sessions
# ────────────────────────────────────────────────────────────────
smoke_section "1. 진행 중 세션 archive 트리거"
if [[ -d "$HARNESS_ROOT" ]]; then
    ORPHAN_COUNT=$(find "$HARNESS_ROOT" -maxdepth 1 -name "current-*" -type d 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
        smoke_info "orphan current-* 디렉토리 ${ORPHAN_COUNT}개 — 다음 시동 시 자동 archive"
    else
        smoke_pass "잔존 current-* 세션 없음"
    fi
else
    smoke_info "하네스 root 없음 — 첫 실행"
fi

# ────────────────────────────────────────────────────────────────
# 2. Build + install
# ────────────────────────────────────────────────────────────────
if [[ "${SMOKE_DEPLOY_SKIP_BUILD:-0}" == "1" ]]; then
    smoke_section "2. (SKIP) 빌드 — SMOKE_DEPLOY_SKIP_BUILD=1"
    if [[ ! -d "/Applications/DarwinForge.app" ]]; then
        smoke_fail "/Applications/DarwinForge.app 없음 — SMOKE_DEPLOY_SKIP_BUILD 해제"
        exit 2
    fi
    smoke_pass "기존 /Applications/DarwinForge.app 재사용"
else
    smoke_section "2. swift build + /Applications 설치"
    INSTALL_LOG="$(mktemp -t darwinforge-install-XXXXXX.log)"
    smoke_on_exit "rm -f '$INSTALL_LOG'"
    if bash "$REPO_ROOT/scripts/install-app.sh" >"$INSTALL_LOG" 2>&1; then
        smoke_pass "install-app.sh 성공"
        tail -3 "$INSTALL_LOG" | sed 's/^/      /'
    else
        smoke_fail "install-app.sh 실패 — 마지막 20 줄:"
        tail -20 "$INSTALL_LOG" | sed 's/^/      /' >&2
        exit 1
    fi
fi

# ────────────────────────────────────────────────────────────────
# 3. Launch + wait
# ────────────────────────────────────────────────────────────────
smoke_section "3. 앱 시동"
# Ensure no prior instance interferes.
pkill -x "DarwinForge" 2>/dev/null || true
sleep 1
LAUNCH_START_EPOCH=$(date +%s)
open -n "/Applications/DarwinForge.app"
smoke_pass "open /Applications/DarwinForge.app 호출"

# Register cleanup so a CI run doesn't leave the app running forever.
smoke_on_exit "pkill -x 'DarwinForge' 2>/dev/null || true"

smoke_info "${WAIT_S}초 동안 하네스 세션 생성 대기..."
sleep "$WAIT_S"

# ────────────────────────────────────────────────────────────────
# 4. Harness session existence
# ────────────────────────────────────────────────────────────────
smoke_section "4. 하네스 세션 디스크 검증"
SESSION_DIR=""
if [[ -d "$HARNESS_ROOT" ]]; then
    # Pick the current-* whose mtime is after launch.
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        CAND_MTIME=$(stat -f %m "$candidate" 2>/dev/null || stat -c %Y "$candidate" 2>/dev/null)
        if [[ -n "$CAND_MTIME" ]] && [[ "$CAND_MTIME" -ge "$LAUNCH_START_EPOCH" ]]; then
            SESSION_DIR="$candidate"
            break
        fi
    done < <(find "$HARNESS_ROOT" -maxdepth 1 -name "current-*" -type d 2>/dev/null)
fi

if [[ -z "$SESSION_DIR" ]]; then
    smoke_fail "current-* 세션 생성 안 됨 (대기 ${WAIT_S}s)"
    smoke_info "확인: ls -la \"$HARNESS_ROOT\""
    smoke_summary; exit 1
fi
smoke_pass "세션 디렉토리: ${SESSION_DIR##$HOME/}"

EVENTS_FILE="$SESSION_DIR/events.jsonl"
META_FILE="$SESSION_DIR/meta.json"

if [[ ! -f "$EVENTS_FILE" ]]; then
    smoke_fail "events.jsonl 미생성"
    smoke_summary; exit 1
fi
smoke_pass "events.jsonl 존재 ($(wc -c < "$EVENTS_FILE" | tr -d ' ') bytes)"

if [[ ! -f "$META_FILE" ]]; then
    smoke_fail "meta.json 미생성"
    smoke_summary; exit 1
fi
smoke_pass "meta.json 존재"

# ────────────────────────────────────────────────────────────────
# 5. First-event content
# ────────────────────────────────────────────────────────────────
smoke_section "5. 첫 이벤트 (app.launch) 검증"
FIRST_LINE=$(head -1 "$EVENTS_FILE")
if [[ -z "$FIRST_LINE" ]]; then
    smoke_fail "events.jsonl 비어 있음"
    smoke_summary; exit 1
fi

if [[ "$USE_JQ" == "1" ]]; then
    FIRST_KIND=$(echo "$FIRST_LINE" | jq -r '.k' 2>/dev/null || echo "PARSE_ERROR")
    EVENT_COUNT=$(jq -r '.eventCount // 0' "$META_FILE" 2>/dev/null || echo "0")
else
    FIRST_KIND=$(echo "$FIRST_LINE" | grep -oE '"k":"[^"]*"' | head -1 | sed 's/.*"k":"\([^"]*\)".*/\1/')
    EVENT_COUNT=$(grep -oE '"eventCount":[0-9]+' "$META_FILE" | head -1 | sed 's/.*://')
    EVENT_COUNT="${EVENT_COUNT:-0}"
fi

if [[ "$FIRST_KIND" == "app.launch" ]]; then
    smoke_pass "첫 이벤트 kind=app.launch (정상)"
else
    smoke_fail "첫 이벤트 kind=${FIRST_KIND} (기대: app.launch)"
fi

if [[ "$EVENT_COUNT" -ge 1 ]]; then
    smoke_pass "meta.eventCount=${EVENT_COUNT}"
else
    smoke_fail "meta.eventCount=${EVENT_COUNT} (< 1)"
fi

# ────────────────────────────────────────────────────────────────
# 6. Optional UI-driven connection check (semi-automatic)
# ────────────────────────────────────────────────────────────────
smoke_section "6. (반자동) UI 'Auto Connect' 트리거 + connection.attempt 도달 검증"
ACTION=$(smoke_operator_action "DarwinForge 창에서 사이드바/toolbar 의 'Auto Connect' 클릭 (단축키 ⌘⇧C) → 연결 시도 종료까지 5-10초 대기")

if [[ "$ACTION" != "skip" ]]; then
    sleep 2
    if grep -q '"k":"connection.attempt"' "$EVENTS_FILE"; then
        smoke_pass "connection.attempt 이벤트 디스크 도달"
    else
        smoke_fail "connection.attempt 이벤트 미관측"
    fi
    if grep -qE '"k":"connection\.(success|failure)"' "$EVENTS_FILE"; then
        smoke_pass "connection.success 또는 connection.failure 이벤트 관측"
    else
        smoke_warn "connection.success/failure 미관측 — 시도 미완료 가능"
    fi
fi

# ────────────────────────────────────────────────────────────────
# 7. Summary
# ────────────────────────────────────────────────────────────────
smoke_info "세션 경로 (debugging):"
smoke_info "  $SESSION_DIR"
smoke_info "events tail 확인:"
smoke_info "  tail -5 \"$EVENTS_FILE\""

smoke_summary
