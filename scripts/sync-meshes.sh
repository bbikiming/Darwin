#!/usr/bin/env bash
# 로봇 3D 모델 STL 메시 동기화 — vendor(SSOT) → SwiftPM 리소스 디렉터리.
#
# 왜 필요한가:
#   `app/ui/DarwinForge/Sources/DarwinForgeUI/Resources/Meshes/*.stl` 는 .gitignore
#   대상이라 fresh clone / git worktree 체크아웃에는 존재하지 않는다. 이 메시가 없으면
#   `STLLoader` 가 21개 로드를 전부 실패 → 3D 뷰포트에 로봇이 안 보이고 바닥만 렌더된다.
#   메시 원본(SSOT)은 `vendor/robotis-op2-common/meshes/` (Apache 2.0, git-tracked).
#
# 멱등(idempotent): 이미 동기화돼 있으면 동일 파일을 덮어쓸 뿐 부작용 없음.
# 빌드 파이프라인(build-mac.sh --swift, build-app.sh)이 swift build 전에 호출하며,
# `swift run` / `make run` 으로 직접 빌드하기 전 수동으로 실행해도 된다:
#   bash scripts/sync-meshes.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MESH_SRC="$REPO_ROOT/vendor/robotis-op2-common/meshes"
MESH_DST="$REPO_ROOT/app/ui/DarwinForge/Sources/DarwinForgeUI/Resources/Meshes"

if [ ! -d "$MESH_SRC" ]; then
    echo "  ⚠ vendor 메시 디렉터리 없음: $MESH_SRC — 로봇 3D 모델 누락 위험" >&2
    exit 0
fi

mkdir -p "$MESH_DST"
cp -f "$MESH_SRC"/*.stl "$MESH_DST"/ 2>/dev/null || true

MESH_N="$(find "$MESH_DST" -maxdepth 1 -name '*.stl' | wc -l | tr -d ' ')"
echo "  ✓ STL 메시 동기화: $MESH_N 개 (vendor → Resources/Meshes)"
if [ "$MESH_N" -eq 0 ]; then
    echo "  ⚠ Resources/Meshes 가 비어 있음 — 로봇 3D 모델이 렌더되지 않습니다" >&2
fi
