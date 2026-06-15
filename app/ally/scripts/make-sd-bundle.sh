#!/usr/bin/env bash
# Darwin 리포 → microSD 오프라인 전달용 git bundle 생성 (Mac에서 실행).
#
# 작업 폴더 복사(17GB, 산출물 오염) 대신 git bundle(≈130MB 단일 파일)을 쓴다 —
# 전 브랜치·히스토리가 보존되어 Ally 도착 즉시 정상 git 작업 트리가 되고,
# 이후 `git remote set-url origin <GitHub>` 로 네트워크 동기화로 전환한다.
#
# 사용법:
#   bash app/ally/scripts/make-sd-bundle.sh [출력 디렉터리=/Volumes/<SD> 또는 ~/Desktop]
#
# Ally 쪽 사용법은 출력 마지막에 표시 (상세: app/ally/docs/05_ALLY_DEV_SETUP.md §3.4)

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
out_dir="${1:-$HOME/Desktop}"
stamp="$(date +%Y%m%d-%H%M)"
bundle="$out_dir/darwin-$stamp.bundle"
branch="$(git branch --show-current)"

if [ ! -d "$out_dir" ]; then
    echo "오류: 출력 디렉터리가 없습니다: $out_dir (SD 카드가 마운트됐는지 확인)" >&2
    exit 1
fi

echo "→ bundle 생성 중 (전 브랜치+태그)…"
git bundle create "$bundle" --all
git bundle verify "$bundle"

size="$(du -h "$bundle" | cut -f1)"
cat <<EOF

생성 완료: $bundle ($size)

Ally(Windows)에서 — SD가 D: 라고 가정:
  git clone D:\\darwin-$stamp.bundle C:\\dev\\Darwin
  cd C:\\dev\\Darwin
  git checkout $branch
  git remote set-url origin https://github.com/bbikiming/Darwin.git

도착 후 W0 스모크: app/ally/docs/05_ALLY_DEV_SETUP.md §5
EOF
