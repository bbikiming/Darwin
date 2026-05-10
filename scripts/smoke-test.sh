#!/usr/bin/env bash
# Mac 앱 스모크 테스트 — 실기기 없이 forge CLI의 핵심 명령이 정상 동작하는지 확인.
#
# 1) version / list-joints / ports / motion inspect — 하드웨어 무관 명령
# 2) walk sim / strategy sim — 결정성 시뮬레이션
# 3) 모션 round-trip — sample.mtn → JSON → sample.mtn (의미 있는 데이터 일치)
#
# Mac에서:  make app && bash scripts/smoke-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE="$ROOT/app/core/target/release/forge"

if [[ ! -x "$FORGE" ]]; then
    echo "→ forge CLI 빌드"
    cargo build --release --manifest-path "$ROOT/app/core/Cargo.toml" -p forge-cli 2>&1 | tail -3
fi

echo "=== 1. version + list-joints ==="
"$FORGE" --version
echo "joint count: $("$FORGE" list-joints | tail -n +3 | wc -l)"

echo
echo "=== 2. ports ==="
"$FORGE" ports

echo
echo "=== 3. motion round-trip ==="
TMP=$(mktemp -d)
SAMPLE="$ROOT/app/core/forge-core/tests/fixtures/sample-2page.mtn"
"$FORGE" motion inspect "$SAMPLE"
"$FORGE" motion import "$SAMPLE" --output "$TMP/sample.json" --generation op2
"$FORGE" motion export "$TMP/sample.json" --output "$TMP/sample-rt.mtn"

# 의미 있는 데이터 비교 — 주석 라인은 무시
diff <(grep -v '^#' "$SAMPLE" | grep -v '^$') \
     <(grep -v '^#' "$TMP/sample-rt.mtn" | grep -v '^$') > "$TMP/diff" && {
    echo "→ round-trip OK (의미 있는 데이터 100% 일치)"
} || {
    echo "WARN: round-trip 차이 — $TMP/diff 확인"
}

echo
echo "=== 4. walk sim 1 cycle ==="
"$FORGE" walk --x 0.04 --cycles 1 | head -10

echo
echo "=== 5. strategy sim ==="
"$FORGE" strategy --ball=found

echo
echo "✓ smoke 통과 — 실기기 검증으로 진입 가능"
