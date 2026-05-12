#!/usr/bin/env bash
# probe.sh v2 — Mac ↔ DARwIn-OP/OP2 연결 진단 (6단계 + TCP 분기).
#
# Sprint 9-13 신규 명령 (connect / walk-ready / motion catalog) 반영.
#
# Usage:
#   bash scripts/harness/probe.sh                              # 포트 자동 탐지
#   bash scripts/harness/probe.sh /dev/cu.usbserial-A1B2       # USB 직결
#   bash scripts/harness/probe.sh --tcp 192.168.123.1:5530     # 이더넷
#
# 통과 조건: 6/6 모두 ✓ → make run 진입 가능.
#
# 자세히: docs/harness/v2-mac-ui-handoff.md

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; PASS=$((PASS+1)); }
warn() { printf "  \033[33m!\033[0m %s\n" "$*"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$*"; FAIL=$((FAIL+1)); }

# 인자 해석
PORT=""
TCP=""
if [[ $# -ge 1 ]]; then
    if [[ "$1" == "--tcp" ]]; then
        TCP="${2:-}"
    else
        PORT="$1"
    fi
fi

echo "=== probe.sh v2 — DarwinForge 연결 진단 ==="
echo

# ── [1/6] /dev/cu.* 후보 ────────────────────────────────────────────
echo "[1/6] /dev/cu.* USB 직렬 후보"
if [[ "$(uname)" == "Darwin" ]]; then
    PORTS=$(ls /dev/cu.usbserial* /dev/cu.usbmodem* 2>/dev/null)
    if [[ -n "$PORTS" ]]; then
        echo "$PORTS" | sed 's/^/    /'
        ok "USB 포트 ${#PORTS} 후보 감지"
        # 자동 선택 (사용자가 명시 안 했을 때)
        if [[ -z "$PORT" && -z "$TCP" ]]; then
            PORT=$(echo "$PORTS" | head -1)
            warn "포트 자동 선택: $PORT (변경: 인자로 명시)"
        fi
    else
        warn "USB 포트 없음 — TCP 또는 케이블/CM 전원 확인"
    fi
else
    warn "Linux 컨테이너 — USB 진단 생략 (Mac에서 의미)"
fi

# ── [2/6] (옵션) TCP 192.168.123.1 reachability ──────────────────────
echo
echo "[2/6] 이더넷 TCP reachability"
if [[ -n "$TCP" ]]; then
    HOST="${TCP%%:*}"
    if ping -c 1 -W 2 "$HOST" >/dev/null 2>&1; then
        ok "$HOST ping 응답"
    else
        fail "$HOST ping 무응답 — 어댑터 / 서브넷 점검 (docs/harness/v2-mac-ui-handoff.md §1.C)"
    fi
else
    warn "TCP 경로 미사용 (USB 경로 진행)"
fi

# ── [3/6] forge CLI 사용 가능 ───────────────────────────────────────
echo
echo "[3/6] forge CLI 가용성"
FORGE=""
for cand in "$ROOT/app/core/target/release/forge" "$ROOT/app/core/target/debug/forge" forge; do
    if command -v "$cand" >/dev/null 2>&1 || [[ -x "$cand" ]]; then
        FORGE="$cand"
        break
    fi
done
if [[ -n "$FORGE" ]]; then
    VERSION=$("$FORGE" --version 2>&1 | head -1)
    ok "$VERSION ($FORGE)"
else
    fail "forge 미빌드 — make app 후 재시도"
    echo
    echo "=== 결과: PASS=$PASS / FAIL=$FAIL (조기 종료) ==="
    exit 1
fi

# 통신 인자 구성
ARGS=()
if [[ -n "$TCP" ]]; then
    ARGS=(--tcp "$TCP")
    LABEL="TCP $TCP"
elif [[ -n "$PORT" ]]; then
    ARGS=(--port "$PORT")
    LABEL="USB $PORT"
else
    warn "통신 경로 미지정 — [4..6] 단계 생략"
    echo
    echo "=== 결과: PASS=$PASS / FAIL=$FAIL ==="
    exit 0
fi

# ── [4/6] forge connect — 모델 + 매핑 검증 ────────────────────────────
echo
echo "[4/6] forge connect ($LABEL)"
if OUTPUT=$("$FORGE" connect "${ARGS[@]}" 2>&1); then
    echo "$OUTPUT" | sed 's/^/    /' | head -10
    ok "Connected — board snapshot 정상"
else
    fail "connect 실패: $(echo "$OUTPUT" | tail -3)"
fi

# ── [5/6] forge scan — 16 모터 ID 응답 ────────────────────────────────
echo
echo "[5/6] forge scan (1..20)"
if OUTPUT=$("$FORGE" scan "${ARGS[@]}" --range 1-20 --timeout 50 2>&1); then
    COUNT=$(echo "$OUTPUT" | grep -cE "^\s*[0-9]+\s+OK")
    if [[ $COUNT -ge 16 ]]; then
        ok "$COUNT/20 모터 응답"
    elif [[ $COUNT -ge 12 ]]; then
        warn "$COUNT/20 모터 응답 — 일부 누락 (daisy chain 점검)"
    else
        fail "$COUNT/20 모터만 응답 — 케이블 / 펌웨어 점검"
    fi
else
    fail "scan 실패: $(echo "$OUTPUT" | tail -3)"
fi

# ── [6/6] forge walk-ready --dry-run — raw 위치 검증 ────────────────
echo
echo "[6/6] forge walk-ready --dry-run (자세 raw 검증)"
if OUTPUT=$("$FORGE" walk-ready "${ARGS[@]}" --dry-run 2>&1); then
    # ini_pose.yaml 기준값과 비교 (r_hip_pitch=1308, r_knee=3527, r_ankle_pitch=2844)
    if echo "$OUTPUT" | grep -qE "r_hip_pitch.*1308|RHipPitch.*1308"; then
        ok "walk-ready raw 위치 = ini_pose.yaml 일치"
    else
        warn "walk-ready raw 출력 형식 변경됨 — 수동 검증 권고"
    fi
else
    fail "walk-ready --dry-run 실패: $(echo "$OUTPUT" | tail -3)"
fi

# ── 결과 종합 + 안전 체크리스트 ─────────────────────────────────────
echo
echo "=== 결과: PASS=$PASS / FAIL=$FAIL ==="
if [[ $FAIL -eq 0 ]]; then
    echo "✅ 모든 단계 통과 — make run 진입 가능"
else
    echo "❌ FAIL 항목 해결 후 재시도 (docs/HARDWARE_VERIFICATION.md 참조)"
    exit 1
fi

echo
echo "── 안전 체크리스트 (수동 확인) ──"
sed -n '/## 매번/,/## 모션/p' "$ROOT/harness/shared/safety.md" 2>/dev/null \
    | head -10 \
    | sed 's/^/  /'

echo
echo "다음 단계:"
echo "  forge motion catalog     # 16 카탈로그 확인"
echo "  make run                 # SwiftUI 앱 실행"
echo "  → docs/HARDWARE_VERIFICATION.md §3 진입"
