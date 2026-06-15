#!/usr/bin/env bash
# walk-cycle-smoke.sh — verify the Onboard walking-daemon command file
# behaves as expected when DarwinForge writes a walk preset.
#
# References:
#   docs/harness/walklab-gyro-smoke-test-2026-05-23.md §2.1 (10-field schema)
#   docs/harness/walklab-gyro-smoke-test-2026-05-23.md §2.2 (v1 vs v2 daemon)
#
# Automated:
#   1. SSH check — /tmp/walking_engine_command exists + readable
#   2. SSH check — Brokerage.cpp daemon source scsanf 패턴 (v1 7-field vs v2 10-field)
#   3. Operator triggers a preset in the UI (semi-auto prompt)
#   4. Re-read /tmp/walking_engine_command — verify 10 fields present
#   5. Verify field 8 (balanceGain) / 9 (balanceEnable) / 10 (correctorIntensityLevel)
#      changed from defaults when operator toggles balance ON
#
# Semi-automatic:
#   - operator presses "march" in WalkLab UI
#   - operator toggles balance ON + gain change
#
# Manual:
#   - audible/visual confirmation that motors do execute the step
#
# Safety: this script does NOT command motors directly. It only inspects what
# DarwinForge has written. If the robot is feet-on-ground, the operator's
# button-press will move it — keep on the maintenance stand.
#
# Exit codes:
#   0 all PASS
#   1 a check FAILED
#   2 prerequisite missing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

smoke_header "walk-cycle-smoke.sh — Onboard walking daemon 검증"

# ────────────────────────────────────────────────────────────────
# 0. Prereqs
# ────────────────────────────────────────────────────────────────
smoke_section "0. 환경변수"
if ! smoke_require_ssh_env; then
    exit 2
fi
smoke_pass "ROBOTIS_HOST=${ROBOTIS_HOST}  USER=${ROBOTIS_USER}"

# ────────────────────────────────────────────────────────────────
# 1. SSH reach + command-file presence
# ────────────────────────────────────────────────────────────────
smoke_section "1. /tmp/walking_engine_command 존재 + 읽기 가능"
if smoke_ssh_quiet "test -r /tmp/walking_engine_command"; then
    smoke_pass "command file 읽기 가능"
else
    # Some installs have a different brokerage path. Try to find it.
    ALT=$(smoke_ssh_capture "find /tmp /var/tmp /darwin -name 'walking_engine_command' -maxdepth 4 2>/dev/null | head -1")
    if [[ -n "$ALT" ]]; then
        smoke_warn "표준 경로 미존재. 발견: $ALT"
    else
        smoke_fail "walking_engine_command 미발견 — Onboard mode 미초기화"
        smoke_summary; exit 1
    fi
fi

INITIAL_CMD=$(smoke_ssh_capture "cat /tmp/walking_engine_command 2>/dev/null")
smoke_info "현재 command: ${INITIAL_CMD:-<empty>}"

# ────────────────────────────────────────────────────────────────
# 2. Daemon schema detection
# ────────────────────────────────────────────────────────────────
smoke_section "2. Daemon schema 감지 (v1 7-field vs v2 10-field)"
# Search a handful of likely Brokerage.cpp locations.
SCHEMA_LINE=$(smoke_ssh_capture "grep -rEh '^[[:space:]]*sscanf' /darwin/Linux/project /darwin/Linux/build 2>/dev/null | grep -i 'walking' | head -1")

if [[ -z "$SCHEMA_LINE" ]]; then
    smoke_warn "Brokerage.cpp sscanf 패턴 미발견 — 수동 확인 권장"
    smoke_info "  ssh $ROBOTIS_USER@$ROBOTIS_HOST find /darwin -name 'Brokerage.cpp'"
else
    smoke_info "daemon sscanf: $SCHEMA_LINE"
    # %f / %d 토큰 카운트로 필드 수 추정.
    FIELD_COUNT=$(echo "$SCHEMA_LINE" | grep -oE '%[fdsi]' | wc -l | tr -d ' ')
    if [[ "$FIELD_COUNT" -ge 10 ]]; then
        smoke_pass "daemon v2 (${FIELD_COUNT}-field) — balance 필드 적용 가능"
    elif [[ "$FIELD_COUNT" -ge 7 ]]; then
        smoke_warn "daemon v1 (${FIELD_COUNT}-field) — balance 필드 silent ignore"
        smoke_info "WalkLab UI: OnboardHealthIndicator 의 warning banner 가 표시됨"
    else
        smoke_warn "field count ${FIELD_COUNT} — 예상 외 패턴, 수동 확인"
    fi
fi

# ────────────────────────────────────────────────────────────────
# 3. Operator-trigger: preset
# ────────────────────────────────────────────────────────────────
smoke_section "3. (반자동) WalkLab 의 preset 트리거 → command 업데이트 확인"
ACTION=$(smoke_operator_action "WalkLab 탭 → Engine='robotisOnboard' + autoOnboardBrokering=ON → preset='march' → Start")

if [[ "$ACTION" == "skip" ]]; then
    smoke_warn "사용자 트리거 건너뜀 — 이후 단계 의미 약화"
else
    sleep 2
    NEW_CMD=$(smoke_ssh_capture "cat /tmp/walking_engine_command 2>/dev/null")
    if [[ -z "$NEW_CMD" ]]; then
        smoke_fail "트리거 후 command 비어 있음"
    elif [[ "$NEW_CMD" == "$INITIAL_CMD" ]]; then
        smoke_warn "command 변경 없음 — UI 의 Start 가 실제 발화 안 됐을 가능성"
        smoke_info "INITIAL: ${INITIAL_CMD:-<empty>}"
    else
        smoke_pass "command 업데이트 감지"
        smoke_info "NEW: $NEW_CMD"
        # 10-field 검증 (space-separated).
        # shellcheck disable=SC2206
        FIELDS=(${NEW_CMD})
        if [[ "${#FIELDS[@]}" -ge 10 ]]; then
            smoke_pass "10 필드 송신 (Mac v2 schema)"
        else
            smoke_warn "필드 수 ${#FIELDS[@]} — Mac 송신 schema 회귀 가능"
        fi
    fi
fi

# ────────────────────────────────────────────────────────────────
# 4. Operator-trigger: balance toggle
# ────────────────────────────────────────────────────────────────
smoke_section "4. (반자동) balance ON + gain 변경 → command 8/9/10 필드 변화"
ACTION=$(smoke_operator_action "WalkLab → enableBalanceCorrection=ON → balanceGain=1.5 → correctorIntensityLevel=3")

if [[ "$ACTION" != "skip" ]]; then
    sleep 2
    AFTER_BAL=$(smoke_ssh_capture "cat /tmp/walking_engine_command 2>/dev/null")
    smoke_info "AFTER balance ON: $AFTER_BAL"
    # shellcheck disable=SC2206
    FIELDS=(${AFTER_BAL})
    if [[ "${#FIELDS[@]}" -ge 10 ]]; then
        GAIN="${FIELDS[7]}"      # field 8 (0-indexed 7)
        ENABLE="${FIELDS[8]}"    # field 9
        LEVEL="${FIELDS[9]}"     # field 10
        smoke_pass "balanceGain=${GAIN}  balanceEnable=${ENABLE}  correctorIntensityLevel=${LEVEL}"
        if [[ "$ENABLE" == "1" ]]; then
            smoke_pass "balanceEnable=1 (ON 토글 반영)"
        else
            smoke_fail "balanceEnable=${ENABLE} (기대: 1)"
        fi
    else
        smoke_fail "필드 수 부족 (${#FIELDS[@]}) — schema 회귀"
    fi
fi

# ────────────────────────────────────────────────────────────────
# 5. Manual sensory checklist
# ────────────────────────────────────────────────────────────────
smoke_section "5. 수동 감각 검증"
smoke_manual "robot 의 hip / knee 가 march 리듬으로 부드럽게 움직이는가?"
smoke_manual "모터 소음 / 진동이 정상 (이상 고주파음 X)?"
smoke_manual "balance ON 토글 시 ankle/hip roll 보정 동작 관찰됨?"

smoke_summary
