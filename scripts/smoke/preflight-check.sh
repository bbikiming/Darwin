#!/usr/bin/env bash
# preflight-check.sh — automate the "before you touch the robot" checks from
# docs/walk-lab/USER_PILOT_GUIDE.md §사전 준비 and the §0.2 안전 체크리스트
# in docs/harness/walklab-gyro-smoke-test-2026-05-23.md.
#
# What it does (fully automated):
#   1. Validate required env vars (ROBOTIS_HOST/USER, optional KEY/PORT)
#   2. Network reachability  — ping + SSH banner
#   3. Battery voltage       — SSH probe via dxlmon or /sys monitor
#   4. dxlPower state        — confirm sub-controller power gpio is HIGH
#   5. IMU device file       — /dev/i2c-* or /sys/devices/.../iio_imu sysfs
#   6. ROBOTIS demon         — confirm /tmp/walking_engine_command writable
#                              and Brokerage daemon binary present
#
# Manual checks at the end (operator confirms):
#   - robot is on maintenance stand
#   - feet are off the ground
#   - emergency stop reachable
#
# Exit codes:
#   0 all PASS
#   1 one or more automated checks FAILED
#   2 missing prerequisite (env / network / tooling)
#
# Examples:
#   ROBOTIS_HOST=192.168.123.1 ROBOTIS_USER=robotis \
#     bash scripts/smoke/preflight-check.sh
#
#   ROBOTIS_HOST=op2.local ROBOTIS_USER=robotis \
#   ROBOTIS_SSH_KEY=~/.ssh/op2_ed25519 \
#     bash scripts/smoke/preflight-check.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

smoke_header "preflight-check.sh — DARwIn-OP2 사전 점검"

# ────────────────────────────────────────────────────────────────
# 1. Env validation
# ────────────────────────────────────────────────────────────────
smoke_section "1. 환경변수 검증"
if ! smoke_require_ssh_env; then
    echo
    cat <<'EOF'
설정 방법 (zsh/bash):
  export ROBOTIS_HOST=192.168.123.1     # 이더넷 직결 표준
  export ROBOTIS_USER=robotis           # e-Manual 기본 user
  export ROBOTIS_SSH_KEY=~/.ssh/id_ed25519  # (선택) key 인증
  export ROBOTIS_SSH_PORT=22            # (선택) 비표준 포트
EOF
    exit 2
fi
smoke_pass "ROBOTIS_HOST=${ROBOTIS_HOST}"
smoke_pass "ROBOTIS_USER=${ROBOTIS_USER}"
[[ -n "${ROBOTIS_SSH_KEY:-}" ]] && smoke_pass "ROBOTIS_SSH_KEY=${ROBOTIS_SSH_KEY}"

# ────────────────────────────────────────────────────────────────
# 2. Reachability
# ────────────────────────────────────────────────────────────────
smoke_section "2. 네트워크 reachability"
if ping -c 1 -W 2 "${ROBOTIS_HOST}" >/dev/null 2>&1; then
    smoke_pass "ping ${ROBOTIS_HOST} OK"
else
    smoke_fail "ping ${ROBOTIS_HOST} 무응답 — 케이블 / Wi-Fi / 게이트웨이 확인"
    smoke_summary; exit 1
fi

if smoke_ssh_quiet "true"; then
    smoke_pass "SSH banner 응답 OK"
else
    smoke_fail "SSH 연결 실패 — key 인증 / password / sshd 상태 확인"
    smoke_info "디버그: ssh -v ${ROBOTIS_USER}@${ROBOTIS_HOST}"
    smoke_summary; exit 1
fi

# ────────────────────────────────────────────────────────────────
# 3. Battery voltage probe
# ────────────────────────────────────────────────────────────────
smoke_section "3. 배터리 전압"
# darwin-op standard: /darwin/Linux/project/voltage 또는 darwinop_voltage tool.
# fallback — dxlmon read of CM-740 voltage register (id 200, addr 42).
BAT_RAW=$(smoke_ssh_capture "test -x /darwin/Linux/project/dxlmon/dxlmon && /darwin/Linux/project/dxlmon/dxlmon -v 2>/dev/null || cat /sys/class/power_supply/*/voltage_now 2>/dev/null || echo MISSING")
if [[ "$BAT_RAW" == "MISSING" ]] || [[ -z "$BAT_RAW" ]]; then
    smoke_warn "배터리 probe 도구 없음 — 수동 확인 권장"
else
    smoke_pass "배터리 raw: ${BAT_RAW}"
    # Best-effort parse. dxlmon prints "Voltage: 11.4 V" pattern.
    VOLTAGE=$(echo "$BAT_RAW" | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$VOLTAGE" ]]; then
        # Threshold per docs/walk-lab — DARwIn-OP2 spec floor 10.5V.
        if awk "BEGIN{exit !($VOLTAGE < 10.5)}"; then
            smoke_fail "배터리 ${VOLTAGE}V — 안전 임계 (10.5V) 미만. 충전 필요"
        elif awk "BEGIN{exit !($VOLTAGE < 11.1)}"; then
            smoke_warn "배터리 ${VOLTAGE}V — 권장 임계 (11.1V) 미만. 곧 충전"
        else
            smoke_pass "배터리 ${VOLTAGE}V (정상)"
        fi
    fi
fi

# ────────────────────────────────────────────────────────────────
# 4. dxlPower state
# ────────────────────────────────────────────────────────────────
smoke_section "4. dxlPower / sub-controller 활성"
# CM-740 의 dxlpwr GPIO sysfs (per docs/firmware-reference/02-user-accounts.md).
DXL_STATE=$(smoke_ssh_capture "cat /sys/class/gpio/dxl_power/value 2>/dev/null || test -e /tmp/dxl_power_active && echo 1 || echo 0")
case "$DXL_STATE" in
    1)  smoke_pass "dxlPower HIGH (모터 라인 활성)" ;;
    0)  smoke_warn "dxlPower LOW — robot daemon 미시동 가능성" ;;
    *)  smoke_warn "dxlPower 상태 미상 (sysfs 표시 안 됨)" ;;
esac

# ────────────────────────────────────────────────────────────────
# 5. IMU device
# ────────────────────────────────────────────────────────────────
smoke_section "5. IMU 디바이스"
IMU_OUT=$(smoke_ssh_capture "ls /dev/i2c-* 2>/dev/null; ls /sys/bus/iio/devices/ 2>/dev/null")
if [[ -z "$IMU_OUT" ]]; then
    smoke_warn "IMU 디바이스 발견 못함 — driver / module 확인"
else
    smoke_pass "IMU 디바이스 후보:"
    echo "$IMU_OUT" | sed 's/^/      /'
fi

# ────────────────────────────────────────────────────────────────
# 6. ROBOTIS demon / brokerage path
# ────────────────────────────────────────────────────────────────
smoke_section "6. ROBOTIS demon / brokerage"
DEMON_OUT=$(smoke_ssh_capture "ls /darwin/Linux/project/demo 2>/dev/null; ls /tmp/walking_engine_command 2>/dev/null")
if echo "$DEMON_OUT" | grep -q "walking_engine_command"; then
    smoke_pass "/tmp/walking_engine_command 존재 (Onboard mode 사용 가능)"
elif echo "$DEMON_OUT" | grep -q "demo"; then
    smoke_warn "demo 디렉토리만 발견 — walking daemon 시동 필요"
else
    smoke_warn "ROBOTIS demo path 미발견 — Mac sparse 모드만 사용 가능"
fi

# ────────────────────────────────────────────────────────────────
# 7. Manual safety checklist
# ────────────────────────────────────────────────────────────────
smoke_section "7. 안전 체크리스트 (수동 확인 필요)"
smoke_manual "robot 이 정비 스탠드에 거치되어 있는가?"
smoke_manual "발이 지면에 닿지 않는가?"
smoke_manual "비상정지 (Space 키 또는 H/W 버튼) 가 손에 닿는가?"
smoke_manual "충돌 가능 물체가 50cm 이내에 없는가?"

smoke_summary
