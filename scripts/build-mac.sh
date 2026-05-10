#!/usr/bin/env bash
# DarwinForge Mac 빌드 스크립트.
#
# 1. forge-core, forge-ffi, forge-cli를 release 모드로 빌드 (Apple Silicon + Intel
#    universal binary 옵션 -u 지원).
# 2. cbindgen이 생성한 forge_core.h를 추출.
# 3. Swift Package가 임포트할 수 있는 위치에 .a + .h 복사:
#    app/ui/DarwinForge/Vendor/CForgeCore/include/forge_core.h
#    app/ui/DarwinForge/Vendor/CForgeCore/lib/libforge_core.a
# 4. swift build로 Swift Package 빌드 (--swift 플래그).
#
# Usage:
#   scripts/build-mac.sh            # release, 현재 호스트 아키
#   scripts/build-mac.sh -u          # universal (arm64 + x86_64)
#   scripts/build-mac.sh -d          # debug
#   scripts/build-mac.sh --swift     # 추가로 swift build 실행
#   scripts/build-mac.sh --swift -u  # universal + Swift Package 빌드
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CARGO_DIR="$ROOT/app/core"
SWIFT_VENDOR="$ROOT/app/ui/DarwinForge/Vendor/CForgeCore"

PROFILE="release"
PROFILE_FLAG="--release"
UNIVERSAL=0
SWIFT_BUILD=0

for arg in "$@"; do
  case "$arg" in
    -d|--debug)   PROFILE="debug";   PROFILE_FLAG="" ;;
    -u|--universal) UNIVERSAL=1 ;;
    --swift)      SWIFT_BUILD=1 ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 64 ;;
  esac
done

echo "=== forge-core / forge-ffi / forge-cli — $PROFILE 빌드 ==="
cd "$CARGO_DIR"

if [[ $UNIVERSAL -eq 1 ]]; then
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "warning: universal 빌드는 macOS에서만 의미 있습니다. 현재: $(uname)" >&2
  fi
  echo "→ aarch64-apple-darwin"
  cargo build $PROFILE_FLAG --target aarch64-apple-darwin -p forge-core -p forge-ffi -p forge-cli
  echo "→ x86_64-apple-darwin"
  cargo build $PROFILE_FLAG --target x86_64-apple-darwin  -p forge-core -p forge-ffi -p forge-cli

  STATIC_AARCH="$CARGO_DIR/target/aarch64-apple-darwin/$PROFILE/libforge_core.a"
  STATIC_X86="$CARGO_DIR/target/x86_64-apple-darwin/$PROFILE/libforge_core.a"
  if [[ ! -f "$STATIC_AARCH" || ! -f "$STATIC_X86" ]]; then
    echo "error: target archive 일부 없음. cargo build 결과 확인." >&2
    exit 1
  fi

  mkdir -p "$CARGO_DIR/target/universal/$PROFILE"
  STATIC_UNI="$CARGO_DIR/target/universal/$PROFILE/libforge_core.a"
  echo "→ lipo → universal"
  lipo -create -output "$STATIC_UNI" "$STATIC_AARCH" "$STATIC_X86"
  STATIC_FINAL="$STATIC_UNI"
else
  cargo build $PROFILE_FLAG -p forge-core -p forge-ffi -p forge-cli
  STATIC_FINAL="$CARGO_DIR/target/$PROFILE/libforge_core.a"
fi

# cbindgen이 생성한 헤더 위치 찾기 (build script가 OUT_DIR에 만듦).
HEADER=$(find "$CARGO_DIR/target" -name "forge_core.h" -path "*/build/forge-ffi-*/out/*" 2>/dev/null | head -1)
if [[ -z "${HEADER:-}" ]]; then
  echo "error: forge_core.h 못 찾음 — cbindgen build script 점검" >&2
  exit 1
fi

echo "=== Swift Package vendor 디렉토리에 복사 ==="
mkdir -p "$SWIFT_VENDOR/include" "$SWIFT_VENDOR/lib"
cp "$HEADER" "$SWIFT_VENDOR/include/forge_core.h"
cp "$STATIC_FINAL" "$SWIFT_VENDOR/lib/libforge_core.a"

# module map for Swift's Clang importer
cat > "$SWIFT_VENDOR/include/module.modulemap" <<'EOF'
module CForgeCore {
    header "forge_core.h"
    link "forge_core"
    export *
}
EOF

echo "  → $SWIFT_VENDOR/include/forge_core.h"
echo "  → $SWIFT_VENDOR/include/module.modulemap"
echo "  → $SWIFT_VENDOR/lib/libforge_core.a ($(du -h "$SWIFT_VENDOR/lib/libforge_core.a" | cut -f1))"

if [[ $SWIFT_BUILD -eq 1 ]]; then
  echo
  echo "=== swift build ==="
  cd "$ROOT/app/ui/DarwinForge"
  if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift 미설치 — Xcode Command Line Tools 설치 후 재시도" >&2
    exit 1
  fi
  swift build
  echo
  echo "✓ Swift Package 빌드 완료"
  echo "  실행: swift run DarwinForgeApp"
fi

echo
echo "✓ 빌드 완료. 다음 단계:"
echo "  - swift run --package-path app/ui/DarwinForge DarwinForgeApp"
echo "  - 또는: xed app/ui/DarwinForge/Package.swift  (Xcode에서 열기)"
