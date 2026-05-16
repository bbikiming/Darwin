#!/usr/bin/env bash
# DarwinForge Mac 빌드 스크립트 — 사용자 친화 버전.
#
# 흐름:
#   1) forge-core / forge-ffi / forge-cli 빌드 (release 또는 debug).
#   2) Vendor/CForgeCore/{include,lib} 채움.
#   3) (옵션) swift build로 SwiftUI 앱 빌드.
#
# Vendor/CForgeCore/include/forge_core.h:
#   - cbindgen이 build.rs에서 자동 생성한 결과 우선.
#   - 실패하면 repo에 체크인된 forge-ffi/forge_core.h.in을 fallback.
#
# Usage:
#   bash scripts/build-mac.sh                # release, 호스트 아키
#   bash scripts/build-mac.sh -u              # universal (arm64 + x86_64)
#   bash scripts/build-mac.sh -d              # debug
#   bash scripts/build-mac.sh --swift         # 추가로 swift build
#   bash scripts/build-mac.sh --swift -u      # universal + swift build
#   bash scripts/build-mac.sh --skip-rust     # Rust 빌드 스킵 (Vendor가 이미 채워져 있을 때)
#   bash scripts/build-mac.sh --run           # 빌드 후 swift run DarwinForgeApp
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CARGO_DIR="$ROOT/app/core"
SWIFT_PKG="$ROOT/app/ui/DarwinForge"
SWIFT_VENDOR="$SWIFT_PKG/Vendor/CForgeCore"

PROFILE="release"
PROFILE_FLAG="--release"
UNIVERSAL=0
SWIFT_BUILD=0
SWIFT_RUN=0
SKIP_RUST=0

for arg in "$@"; do
  case "$arg" in
    -d|--debug)     PROFILE="debug";   PROFILE_FLAG="" ;;
    -u|--universal) UNIVERSAL=1 ;;
    --swift)        SWIFT_BUILD=1 ;;
    --run)          SWIFT_BUILD=1; SWIFT_RUN=1 ;;
    --skip-rust)    SKIP_RUST=1 ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 64 ;;
  esac
done

mkdir -p "$SWIFT_VENDOR/include" "$SWIFT_VENDOR/lib"

if [[ $SKIP_RUST -eq 0 ]]; then
  echo "▶ forge-core / forge-ffi / forge-cli — $PROFILE 빌드"
  cd "$CARGO_DIR"

  if [[ $UNIVERSAL -eq 1 ]]; then
    if [[ "$(uname)" != "Darwin" ]]; then
      echo "  warning: -u (universal)는 macOS에서만 의미 있음. 현재: $(uname)" >&2
    fi
    rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true

    echo "  ▷ aarch64-apple-darwin"
    cargo build $PROFILE_FLAG --target aarch64-apple-darwin -p forge-core -p forge-ffi -p forge-cli
    echo "  ▷ x86_64-apple-darwin"
    cargo build $PROFILE_FLAG --target x86_64-apple-darwin  -p forge-core -p forge-ffi -p forge-cli

    A="$CARGO_DIR/target/aarch64-apple-darwin/$PROFILE/libforge_core.a"
    X="$CARGO_DIR/target/x86_64-apple-darwin/$PROFILE/libforge_core.a"
    if [[ ! -f "$A" || ! -f "$X" ]]; then
      echo "  error: arch별 libforge_core.a 일부 없음." >&2
      exit 1
    fi
    mkdir -p "$CARGO_DIR/target/universal/$PROFILE"
    UNI="$CARGO_DIR/target/universal/$PROFILE/libforge_core.a"
    if ! command -v lipo >/dev/null 2>&1; then
      echo "  error: lipo (Apple Xcode CLT 일부) 없음. -u 옵션은 macOS 전용." >&2
      exit 1
    fi
    echo "  ▷ lipo → universal"
    lipo -create -output "$UNI" "$A" "$X"
    STATIC_FINAL="$UNI"
  else
    cargo build $PROFILE_FLAG -p forge-core -p forge-ffi -p forge-cli
    STATIC_FINAL="$CARGO_DIR/target/$PROFILE/libforge_core.a"
  fi

  echo "▶ Vendor/CForgeCore/lib/libforge_core.a 복사"
  cp "$STATIC_FINAL" "$SWIFT_VENDOR/lib/libforge_core.a"

  # 헤더: cbindgen 산출물 우선, fallback으로 forge-ffi/forge_core.h.in.
  # 다중 stale 빌드 dir (구 universal target, 옛 debug) 이 남아 있을 때
  # `find | head -1` 는 filesystem 순서로 stale 헤더를 픽업할 수 있다.
  # → `-exec ls -t1 {} +` 로 paths 일괄 모아 mtime 내림차순 정렬 후 최신 1건.
  HEADER=$(find "$CARGO_DIR/target" -name "forge_core.h" -path "*/build/forge-ffi-*/out/*" \
           -exec ls -t1 {} + 2>/dev/null | head -1)
  if [[ -n "${HEADER:-}" && -f "$HEADER" ]]; then
    cp "$HEADER" "$SWIFT_VENDOR/include/forge_core.h"
    echo "  ▷ forge_core.h ← cbindgen 자동 생성 (latest by mtime)"
  elif [[ -f "$CARGO_DIR/forge-ffi/forge_core.h.in" ]]; then
    cp "$CARGO_DIR/forge-ffi/forge_core.h.in" "$SWIFT_VENDOR/include/forge_core.h"
    echo "  ▷ forge_core.h ← forge-ffi/forge_core.h.in fallback"
  else
    echo "  error: forge_core.h 출처 없음" >&2
    exit 1
  fi
else
  echo "▶ Rust 빌드 스킵 (--skip-rust). Vendor/ 그대로 사용."
  if [[ ! -s "$SWIFT_VENDOR/lib/libforge_core.a" || ! -s "$SWIFT_VENDOR/include/forge_core.h" ]]; then
    echo "  error: Vendor/CForgeCore/{lib,include}이 비어 있음. --skip-rust 제거 후 재시도." >&2
    exit 1
  fi
fi

# module.modulemap (항상 갱신)
cat > "$SWIFT_VENDOR/include/module.modulemap" <<'EOF'
module CForgeCore {
    header "forge_core.h"
    link "forge_core"
    export *
}
EOF

echo
echo "✓ Vendor/CForgeCore 준비 완료:"
echo "  $SWIFT_VENDOR/include/forge_core.h"
echo "  $SWIFT_VENDOR/include/module.modulemap"
echo "  $SWIFT_VENDOR/lib/libforge_core.a ($(du -h "$SWIFT_VENDOR/lib/libforge_core.a" 2>/dev/null | cut -f1))"

if [[ $SWIFT_BUILD -eq 1 ]]; then
  echo
  echo "▶ swift build"
  cd "$SWIFT_PKG"
  if ! command -v swift >/dev/null 2>&1; then
    echo "  error: swift 미설치 — 'xcode-select --install' 후 재시도" >&2
    exit 1
  fi
  swift build
  echo "✓ Swift Package 빌드 완료"

  if [[ $SWIFT_RUN -eq 1 ]]; then
    echo
    echo "▶ swift run DarwinForgeApp"
    swift run DarwinForgeApp
  else
    echo
    echo "▶ 다음 명령으로 앱 실행:"
    echo "    swift run --package-path app/ui/DarwinForge DarwinForgeApp"
    echo "  또는 Xcode에서:"
    echo "    xed app/ui/DarwinForge/Package.swift"
  fi
fi

echo
echo "✓ 끝"
