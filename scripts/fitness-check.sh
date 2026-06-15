#!/usr/bin/env bash
# 사이클 270 (V270-2) — Architectural fitness function gate.
#
# Fitness function (Ford / Parsons / Kua, "Building Evolutionary Architectures"):
#   - atomic + static
#   - 자동 enforcement via pre-commit hook 또는 CI step
#
# 검사 항목:
#   1. 신규/수정 Swift source file LOC <= 800
#      (coding-style.md / golden-principles.md §5 "작은 파일, 작은 함수" 룰)
#   2. SwiftLint custom rules (Harness.shared regex, DFSpace/DFColor 토큰 등)
#      → .swiftlint.yml 정의 그대로 실행
#   3. (placeholder) 신규 god method (>50줄 새 함수) 차단 — 향후 implement
#
# 정책 (점진 enforcement):
#   - 기존 god object 3건 (WalkLabSession / ConnectionStore / ConnectionWizard) +
#     기타 historical >800 LOC 파일은 grandfathered (Wave 4 분할 중).
#   - 신규 file 의 첫 commit 이 >800 LOC 이면 hard fail.
#   - 기존 grandfathered file 의 LOC 가 *증가* 하면 warning (성장 차단 의도).
#
# 사용:
#   $ bash scripts/fitness-check.sh                # pre-commit mode (staged only)
#   $ FITNESS_MODE=all bash scripts/fitness-check.sh   # CI mode (전체 source)
#
# 종료 코드:
#   0 — pass
#   1 — fail (신규 file >800 LOC, SwiftLint --strict 실패 등)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="${REPO_ROOT}/app/ui/DarwinForge"
SOURCES_REL="app/ui/DarwinForge/Sources"
SOURCES_DIR="${REPO_ROOT}/${SOURCES_REL}"

CEILING=800
MODE="${FITNESS_MODE:-staged}"

# Grandfathered files (>800 LOC at adoption of fitness function, 사이클 270).
# 신규 LOC 증가는 warning. Wave 4 분할 완료 후 본 list 에서 제거.
GRANDFATHERED=(
    "app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabSession.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/ConnectionStore.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/ConnectionWizard.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/Expert/WalkDiagnostics/WalkDiagnosticsView.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/WalkLabView.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/Connection/RobotSetupCommand.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Components/FallPreventionMonitor.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/RootView.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/Logging/Harness/HarnessInspectorView.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/Studio/StudioView.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/Visualization/RobotScene3D.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/DesignSystem/DesignTokens.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Learning/WalkDataView.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Components/SceneSpeedometerOverlay.swift"
    "app/ui/DarwinForge/Sources/DarwinForgeUI/Pilot/RemotePilotView.swift"
)

is_grandfathered() {
    local target="$1"
    for g in "${GRANDFATHERED[@]}"; do
        if [ "${g}" = "${target}" ]; then
            return 0
        fi
    done
    return 1
}

# --------------------------------------------------------------------
# 1. File LOC ceiling
# --------------------------------------------------------------------
echo "==> 1. File LOC ceiling check (<= ${CEILING})"

NEW_OVERSIZED=()
GRANDFATHERED_OVERSIZED=()

case "${MODE}" in
    all)
        FILES=$(find "${SOURCES_DIR}" -name "*.swift" -not -name "*.generated.swift" | sed "s|${REPO_ROOT}/||")
        ;;
    staged)
        # ACM = Added / Copied / Modified — Deleted 는 제외.
        FILES=$(cd "${REPO_ROOT}" && git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
            | grep "^${SOURCES_REL}/" \
            | grep '\.swift$' \
            | grep -v '\.generated\.swift$' \
            || true)
        ;;
    *)
        echo "❌ unknown FITNESS_MODE='${MODE}' (allowed: staged | all)"
        exit 2
        ;;
esac

if [ -z "${FILES}" ]; then
    echo "  (no source file changes — skip LOC check)"
else
    FILE_COUNT=0
    while IFS= read -r rel; do
        [ -z "${rel}" ] && continue
        FILE_COUNT=$((FILE_COUNT + 1))
        abs="${REPO_ROOT}/${rel}"
        if [ ! -f "${abs}" ]; then
            continue
        fi
        LINES=$(wc -l < "${abs}" | tr -d ' ')
        if [ "${LINES}" -gt "${CEILING}" ]; then
            if is_grandfathered "${rel}"; then
                GRANDFATHERED_OVERSIZED+=("${rel}:${LINES}")
            else
                NEW_OVERSIZED+=("${rel}:${LINES}")
            fi
        fi
    done <<< "${FILES}"
    echo "  ${FILE_COUNT} file(s) inspected"
fi

if [ ${#GRANDFATHERED_OVERSIZED[@]} -gt 0 ]; then
    echo ""
    echo "⚠️  WARNING: ${#GRANDFATHERED_OVERSIZED[@]} grandfathered file(s) over ${CEILING} LOC:"
    for entry in "${GRANDFATHERED_OVERSIZED[@]}"; do
        echo "   ${entry}"
    done
    echo "   (Wave 4 분할 중 — 신규 LOC 증가는 지양)"
fi

if [ ${#NEW_OVERSIZED[@]} -gt 0 ]; then
    echo ""
    echo "❌ FAIL: ${#NEW_OVERSIZED[@]} non-grandfathered file(s) over ${CEILING} LOC:"
    for entry in "${NEW_OVERSIZED[@]}"; do
        echo "   ${entry}"
    done
    echo ""
    echo "정책: coding-style.md / golden-principles.md §5 '작은 파일, 작은 함수' —"
    echo "      파일 800줄 한계. 분리하라."
    echo "      grandfathered list 추가 필요시 scripts/fitness-check.sh 수정 + 사이클 기록."
    exit 1
fi

# --------------------------------------------------------------------
# 2. SwiftLint custom rules
# --------------------------------------------------------------------
echo ""
echo "==> 2. SwiftLint custom rules (.swiftlint.yml)"

if command -v swiftlint >/dev/null 2>&1; then
    cd "${REPO_ROOT}"
    # --quiet: file iteration 출력 억제, --strict: warning → error
    # 사이클 270: --strict 활성. warning 만 있어도 fail.
    # 기존 코드의 warning 이 잔존하면 본 단계가 fail 할 수 있음 → 점진 제거.
    if swiftlint lint --quiet --strict; then
        echo "  ✅ SwiftLint pass"
    else
        echo ""
        echo "❌ FAIL: SwiftLint --strict 위반."
        echo "   custom rule message 참고 후 해결 (예: Harness.shared → @Environment(\\.harness))."
        exit 1
    fi
else
    echo "  ⚠️  swiftlint 미설치 — skip (brew install swiftlint)"
fi

# --------------------------------------------------------------------
# 3. (placeholder) Function body length
# --------------------------------------------------------------------
echo ""
echo "==> 3. (placeholder) 신규 god method (>50 줄) 차단"
echo "  (향후 implement — function_body_length opt-in 또는 diff 기반 측정)"

echo ""
echo "✅ Fitness function check 완료 (mode=${MODE})"
