#!/bin/bash
# deploy-kick.sh — Mac→로봇 킥 빌드 배포 한방 래퍼 (F12, 2026-06-13).
#
# install-onboard.sh 의 "Mac 에서 SMB 로 복사" 수동 단계를 scp 로 자동화하고,
# 이어서 로봇에서 install-onboard.sh(main.cpp 패치 + ARM g++ make)를 원격 실행한다.
# 복사 대상 8개: install-onboard.sh + 브로커리지 소스 6(WalkLabBrokerage·WalkLabTransport·
# GamepadPilot 의 .cpp/.h) + balltrack.ini. 킥은 GamepadPilot/WalkLabBrokerage 안에 들어
# 있으므로 새 파일·Makefile 변경 불요 — 이 소스들을 복사하면 그대로 빌드된다.
#
# 사용:
#   bash deploy-kick.sh darwin@192.168.123.1                 # 유선 직결(권장)
#   bash deploy-kick.sh darwin@192.168.0.33                  # 무선
#   bash deploy-kick.sh darwin@192.168.123.1 /robotis/Linux/project/demo
#
# 전제: 로봇 전원 ON + SSH 도달 가능 + demo 폴더 존재. 요람 거치·다리 토크 차단 가능 상태.
# 안전: Mac 측은 복사만(비파괴). main.cpp/Makefile 백업·멱등·빌드실패 롤백은 모두
#       install-onboard.sh 가 소유. 빌드 실패 시 로봇은 원본 demo 로 복구된다.
set -euo pipefail

TARGET="${1:-}"
DEMO="${2:-/robotis/Linux/project/demo}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$TARGET" ]; then
  echo "사용: bash deploy-kick.sh <user@host> [demo경로]"
  echo "  예: bash deploy-kick.sh darwin@192.168.123.1"
  exit 2
fi

FILES=(install-onboard.sh \
       WalkLabBrokerage.cpp WalkLabBrokerage.h BrokerageActions.h \
       WalkLabTransport.cpp WalkLabTransport.h \
       GamepadPilot.cpp GamepadPilot.h \
       balltrack.ini)

echo "▶ 로컬 소스 검증 ($HERE)"
SRCS=()
for f in "${FILES[@]}"; do
  if [ ! -f "$HERE/$f" ]; then
    echo "✗ $f 없음 — 브로커리지 폴더(firmware-patches/walklab-brokerage)에서 실행하세요."
    exit 1
  fi
  SRCS+=("$HERE/$f")
done

HOST="${TARGET#*@}"
echo "▶ 로봇 도달성: $HOST"
if ! ping -c 1 -t 2 "$HOST" >/dev/null 2>&1; then
  echo "  ⚠ ping 무응답 — SSH 만 되면 계속(유선 123.1 권장; 무선이면 0.33)."
fi

echo "▶ 소스 복사 → $TARGET:$DEMO/"
scp "${SRCS[@]}" "$TARGET:$DEMO/"

echo "▶ 원격 빌드 — install-onboard.sh (main.cpp 패치 + ARM g++ make, 멱등·롤백)"
ssh -t "$TARGET" "cd '$DEMO' && sudo bash install-onboard.sh"

cat <<NEXT

✓ 빌드/배포 완료 — 단, ★새 바이너리는 아직 메모리에 안 올라갔습니다★.
  이 스크립트는 디스크의 ./demo 만 새로 컴파일합니다. 지금 로봇에서 돌고 있는
  데모는 여전히 구 바이너리(킥/스캔 없음)입니다. 반드시 재기동해야 적용됩니다.

  0) ★구 데모 종료 후 재기동 (필수)★ — 종료 시 토크가 풀리니 요람 거치 상태에서:
       ssh $TARGET 'sudo killall demo; sleep 1; cd "$DEMO" && sudo ./demo &'
     (또는 ssh $TARGET 'sudo reboot' — rc.local 자동기동 설정 시)

  1) (선택) 배포 신선도 확인 — 디스크 소스가 HEAD 인지 (read-only):
       ssh $TARGET "grep -c CheckAndExecuteKick '$DEMO/WalkLabBrokerage.cpp'"   # ≥2 면 킥 포함
       ssh $TARGET "grep -c SCAN_STEP '$DEMO/WalkLabBrokerage.cpp'"             # ≥1 면 스캔 포함
       ssh $TARGET "ls -l '$DEMO/demo' '$DEMO/WalkLabBrokerage.cpp'"            # demo mtime ≥ .cpp mtime
  2) evtest 로 LB=BTN_TL(310)·RB=BTN_TR(311) 확인 (실패드).
  3) forge-cli motion play --slot 12 --dry-run --follow-chain  (+ --slot 13)
     → page 12=Right / 13=Left 디코드·체크섬 정상 확인.
  4) DarwinForge → Remote → "조종기 데모 시작"  (또는 WalkLab → ROBOTIS onboard → 시작).
  5) 요람 거치·다리 토크 OFF 시작 → 안전 매트릭스:
     disarmed 킥 거부 / armed+STANDUP 킥 / 킥중 B=Action 즉시중단 / 낙상중 킥 무시 / 킥후 보행재개.
  6) 측정 세션 중에는 Mac DarwinForge 종료(호스트 폴링이 타이밍 교란).
NEXT
