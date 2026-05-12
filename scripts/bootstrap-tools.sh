#!/usr/bin/env bash
# Phase 0 toolchain audit. Reports presence/version of every tool the
# protocol mentions. Does NOT install anything — emits install hints.
#
# Exit code: 0 if all required tools present, 1 if any required tool missing.
set -uo pipefail

REQUIRED=(git python3 node cargo rustc)
MAC_REQUIRED=(swift xcode-select brew)
OPTIONAL=(shellcheck tree jq yq pip3)

ok=0
warn=0
fail=0

check() {
    local tool="$1" tier="$2"
    if command -v "$tool" >/dev/null 2>&1; then
        local ver
        ver=$("$tool" --version 2>&1 | head -1)
        printf "  \033[32m✓\033[0m  %-15s %s\n" "$tool" "$ver"
        ok=$((ok+1))
    else
        case "$tier" in
            required)
                printf "  \033[31m✗\033[0m  %-15s MISSING (required)\n" "$tool"
                fail=$((fail+1))
                ;;
            mac)
                printf "  \033[33m!\033[0m  %-15s MISSING — Mac에서 필요\n" "$tool"
                warn=$((warn+1))
                ;;
            optional)
                printf "  \033[33m!\033[0m  %-15s MISSING (optional)\n" "$tool"
                warn=$((warn+1))
                ;;
        esac
    fi
}

echo "=== Required tools (build/test) ==="
for t in "${REQUIRED[@]}"; do check "$t" required; done

echo
echo "=== macOS-only tools (앱 빌드용) ==="
for t in "${MAC_REQUIRED[@]}"; do check "$t" mac; done

echo
echo "=== Optional tools ==="
for t in "${OPTIONAL[@]}"; do check "$t" optional; done

echo
echo "=== Summary ==="
echo "  OK: $ok    WARN: $warn    FAIL: $fail"

if [[ $fail -gt 0 ]]; then
    cat <<'EOF'

설치 가이드 (macOS):
  Xcode + Command Line Tools : https://developer.apple.com/xcode/
  Homebrew                   : /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  Rust                       : curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  Node.js                    : brew install node
  Python                     : brew install python@3.11
EOF
    exit 1
fi
exit 0
