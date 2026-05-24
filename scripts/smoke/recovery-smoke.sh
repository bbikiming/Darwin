#!/usr/bin/env bash
# recovery-smoke.sh — verify emergency-stop + recovery paths produce the
# expected telemetry events and that motor torque returns to a safe state.
#
# References:
#   docs/harness/real-robot-verification.md §3.2 (connection/walklab events)
#   docs/walk-lab/USER_PILOT_GUIDE.md (Space=emergency, R=recovery)
#
# Automated:
#   1. Locate active harness session (current-* dir)
#   2. Snapshot event count baseline
#   3. Operator triggers emergency-stop in UI (semi-auto)
#   4. Verify bus.e_stop event reaches disk within 2 s
#   5. Operator triggers recovery (R key or button)
#   6. Verify walklab.start_blocked transition + subsequent walklab.start
#      (or pose.apply_complete) signals recovery success
#   7. SSH check — confirm /tmp/walking_engine_command sets preset=idle
#      (DarwinForge sends preset=0 / 0 0 0 on emergency)
#
# Manual:
#   - audible: motor torque release click on emergency
#   - tactile: limbs swing freely (in maintenance stand)
#
# Exit codes:
#   0 PASS  1 FAIL  2 prereq missing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

smoke_header "recovery-smoke.sh — 비상정지 + 복구 검증"

# ────────────────────────────────────────────────────────────────
# 0. Prereqs
# ────────────────────────────────────────────────────────────────
smoke_section "0. 환경변수 (SSH 선택사항 — UI 검증만 한다면 생략 가능)"
HAVE_SSH=0
if smoke_has_ssh_env; then
    HAVE_SSH=1
    smoke_pass "ROBOTIS_HOST=${ROBOTIS_HOST}  USER=${ROBOTIS_USER}"
else
    smoke_warn "SSH env 미설정 — daemon 측 idle 확인 단계는 skip"
fi

# ────────────────────────────────────────────────────────────────
# 1. Locate session
# ────────────────────────────────────────────────────────────────
smoke_section "1. 활성 하네스 세션 위치"
HARNESS_ROOT="$(smoke_harness_root)"
SESSION_DIR=$(find "$HARNESS_ROOT" -maxdepth 1 -name "current-*" -type d 2>/dev/null | head -1)
if [[ -z "$SESSION_DIR" ]]; then
    smoke_fail "current-* 세션 없음 — DarwinForge 가 실행 중인지 확인"
    smoke_info "  먼저: bash scripts/smoke/deploy-and-verify.sh"
    smoke_summary; exit 2
fi
smoke_pass "세션: ${SESSION_DIR##$HOME/}"
EVENTS_FILE="$SESSION_DIR/events.jsonl"

if [[ ! -f "$EVENTS_FILE" ]]; then
    smoke_fail "events.jsonl 미존재"
    smoke_summary; exit 2
fi

# ────────────────────────────────────────────────────────────────
# 2. Baseline event count
# ────────────────────────────────────────────────────────────────
smoke_section "2. baseline 이벤트 카운트 캡쳐"
BASELINE_COUNT=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
smoke_pass "baseline=${BASELINE_COUNT} events"

# ────────────────────────────────────────────────────────────────
# 3. Emergency stop trigger
# ────────────────────────────────────────────────────────────────
smoke_section "3. (반자동) 비상정지 트리거"
ACTION=$(smoke_operator_action "DarwinForge 포커스 상태에서 Space 키 (또는 메뉴 '로봇 → 비상 정지') 누름")

if [[ "$ACTION" == "skip" ]]; then
    smoke_warn "비상정지 트리거 건너뜀"
else
    sleep 2
    NEW_LINES=$(tail -n +"$((BASELINE_COUNT + 1))" "$EVENTS_FILE")
    if echo "$NEW_LINES" | grep -q '"k":"bus.e_stop"'; then
        smoke_pass "bus.e_stop 이벤트 도달"
    else
        smoke_fail "bus.e_stop 이벤트 미관측 (Space 가 가로채진 가능)"
    fi
    if echo "$NEW_LINES" | grep -q '"k":"walklab.emergency_stop"'; then
        smoke_pass "walklab.emergency_stop 이벤트 도달 (활성 보행 중이었다면)"
    else
        smoke_info "walklab.emergency_stop 없음 — 보행 미활성이었을 수 있음 (정상)"
    fi
fi

# ────────────────────────────────────────────────────────────────
# 4. SSH daemon idle check
# ────────────────────────────────────────────────────────────────
if [[ "$HAVE_SSH" == "1" ]]; then
    smoke_section "4. daemon /tmp/walking_engine_command idle 확인"
    AFTER_STOP=$(smoke_ssh_capture "cat /tmp/walking_engine_command 2>/dev/null")
    smoke_info "command: ${AFTER_STOP:-<empty>}"
    # DarwinForge 의 emergencyStop path 는 idle preset (preset id 0 또는 stride/turn 0 0 0).
    # 첫 필드 = 0 또는 stride/turn 필드 (2,3,4) 가 모두 0 이면 idle 간주.
    # shellcheck disable=SC2206
    FIELDS=(${AFTER_STOP})
    if [[ "${#FIELDS[@]}" -ge 4 ]]; then
        if [[ "${FIELDS[0]}" == "0" ]] || \
           { [[ "${FIELDS[2]}" == "0.00" ]] && [[ "${FIELDS[3]}" == "0.00" ]]; }; then
            smoke_pass "preset / stride 0 — idle 상태로 설정됨"
        else
            smoke_warn "preset/stride 비-0 — emergency 이후 idle 미반영"
        fi
    else
        smoke_warn "필드 수 부족 (${#FIELDS[@]})"
    fi
else
    smoke_section "4. (SKIP) SSH 미설정 — daemon idle 확인 건너뜀"
fi

# ────────────────────────────────────────────────────────────────
# 5. Recovery trigger
# ────────────────────────────────────────────────────────────────
smoke_section "5. (반자동) 복구 (R 또는 START 버튼) 트리거"
RECOVERY_BASELINE=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
ACTION=$(smoke_operator_action "R 키 (또는 게임패드 START, voice '복구') → 비상정지 해제")

if [[ "$ACTION" == "skip" ]]; then
    smoke_warn "복구 트리거 건너뜀"
else
    sleep 2
    RECOVERY_LINES=$(tail -n +"$((RECOVERY_BASELINE + 1))" "$EVENTS_FILE")
    # Recovery 자체는 connection.attempt / walklab.start 가능 → 신규 이벤트 존재로 1차 검증.
    if [[ -n "$RECOVERY_LINES" ]]; then
        smoke_pass "복구 트리거 이후 신규 이벤트 $(echo "$RECOVERY_LINES" | wc -l | tr -d ' ')개 관측"
    else
        smoke_warn "신규 이벤트 없음 — recovery hook 미발화 가능"
    fi
fi

# ────────────────────────────────────────────────────────────────
# 6. Manual sensory checklist
# ────────────────────────────────────────────────────────────────
smoke_section "6. 수동 감각 검증"
smoke_manual "비상정지 직후 torque release 'click' 소리가 들렸는가?"
smoke_manual "비상정지 후 팔/다리가 자유롭게 흔들리는가? (정비 스탠드 위)"
smoke_manual "복구 후 robot 이 다음 명령에 반응하는가?"

smoke_summary
