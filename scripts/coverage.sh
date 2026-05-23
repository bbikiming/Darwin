#!/bin/bash
# 사이클 270 (V270-1) — code coverage 측정 + 80% threshold gate.
# 사용법: bash scripts/coverage.sh
# 환경 변수: COVERAGE_THRESHOLD (기본값 80)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../app/ui/DarwinForge" && pwd)"
cd "${PROJECT_DIR}"

THRESHOLD="${COVERAGE_THRESHOLD:-80}"

echo "==> 1. Running tests with coverage..."
swift test --enable-code-coverage 2>&1 | tail -5

echo ""
echo "==> 2. Generating coverage report..."
XCTEST_BUNDLE=$(find .build -name "DarwinForgePackageTests.xctest" -type d | head -1)
if [ -z "${XCTEST_BUNDLE}" ]; then
    echo "ERROR: DarwinForgePackageTests.xctest not found in .build/"
    exit 1
fi

EXEC="${XCTEST_BUNDLE}/Contents/MacOS/DarwinForgePackageTests"

# Discover profdata dynamically (handles arm64-apple-macosx, x86_64-apple-macosx, etc.)
PROFDATA=$(find .build -name "default.profdata" -path "*/codecov/*" | head -1)

if [ -z "${PROFDATA}" ] || [ ! -f "${PROFDATA}" ]; then
    echo "ERROR: profdata not found in .build/*/codecov/. Run 'swift test --enable-code-coverage' first."
    exit 1
fi

echo "    profdata: ${PROFDATA}"

if [ ! -f "${EXEC}" ]; then
    echo "ERROR: test executable not found at ${EXEC}"
    exit 1
fi

REPORT=$(xcrun llvm-cov report "${EXEC}" \
    -instr-profile="${PROFDATA}" \
    -ignore-filename-regex="Tests|\.build|Mocks" \
    2>&1)

echo "${REPORT}" | tail -40

# Extract line coverage percentage from TOTAL row (column 10 = Lines Cover%)
TOTAL_PCT=$(echo "${REPORT}" | awk '/^TOTAL/ {
    pct=$10
    gsub(/%/, "", pct)
    print pct
}')

if [ -z "${TOTAL_PCT}" ]; then
    echo "ERROR: Could not parse total coverage percentage from report."
    exit 1
fi

echo ""
echo "==> 3. Coverage gate check"
echo "    Line coverage : ${TOTAL_PCT}%"
echo "    Threshold     : ${THRESHOLD}%"

if (( $(echo "${TOTAL_PCT} < ${THRESHOLD}" | bc -l) )); then
    echo ""
    echo "FAIL: Coverage ${TOTAL_PCT}% is below threshold ${THRESHOLD}%."
    exit 1
fi

echo ""
echo "PASS: Coverage ${TOTAL_PCT}% >= threshold ${THRESHOLD}%."
