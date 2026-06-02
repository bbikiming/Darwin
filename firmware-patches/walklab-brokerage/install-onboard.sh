#!/bin/bash
# DarwinForge — WalkLab 온보드 브로커리지 설치 (이 로봇의 demo main.cpp 전용, 2026-06-01)
#
# 사용법 (로봇 VNC 터미널에서):
#   1) Mac 에서 SMB 로 이 폴더의 파일들(install-onboard.sh, WalkLabBrokerage.cpp,
#      WalkLabBrokerage.h)을 로봇의 demo 폴더(/robotis/Linux/project/demo/)에 복사
#   2) 로봇 VNC 터미널:  cd /robotis/Linux/project/demo && sudo bash install-onboard.sh
#
# 안전: main.cpp / Makefile 을 백업(.df-orig)하고, 멱등(이미 적용 시 skip)하며,
#       빌드 실패 시 원본 복구. 원본 demo 빌드도 언제든 가능.
set -e

DEMO="$(pwd)"
if [ ! -f "$DEMO/main.cpp" ] || [ ! -f "$DEMO/Makefile" ]; then
  echo "✗ 여기는 demo 폴더가 아닙니다. cd /robotis/Linux/project/demo 후 다시 실행."
  exit 1
fi
echo "▶ demo: $DEMO"

# 0) 브로커리지 소스 존재 확인
for f in WalkLabBrokerage.cpp WalkLabBrokerage.h; do
  if [ ! -f "$DEMO/$f" ]; then
    echo "✗ $f 없음 — Mac 에서 SMB 로 이 폴더에 복사하세요."
    exit 1
  fi
done

# 1) 백업
cp -p main.cpp main.cpp.df-orig 2>/dev/null || true
cp -p Makefile Makefile.df-orig 2>/dev/null || true

# 2) include 주입 (StatusCheck.h 다음, 멱등)
if ! grep -q 'WalkLabBrokerage.h' main.cpp; then
  sed -i '/#include "StatusCheck.h"/a #include "WalkLabBrokerage.h"' main.cpp
fi

# 3) walklab 분기 주입 — while(1) 메인 루프 직전 (멱등)
if ! grep -q 'DarwinForge WalkLab onboard' main.cpp; then
  cat > /tmp/df_walklab_inject.cpp <<'EOF_INJECT'
    // === DarwinForge WalkLab onboard brokerage (2026-06-01) ===
    // /tmp/df-pilot-mode == "walklab" 이면 공식 Walking 엔진을 Mac 명령(/tmp/df-walklab-cmd)
    // 으로 제어. SOCCER 메인 루프 우회. 미설정이면 기존 데모 그대로.
    {
        char df_mode[16] = {0};
        FILE* df_fp = fopen("/tmp/df-pilot-mode", "r");
        if (df_fp) {
            if (fgets(df_mode, sizeof(df_mode)-1, df_fp) == NULL) df_mode[0] = 0;
            fclose(df_fp);
            char* df_nl = strchr(df_mode, '\n'); if (df_nl) *df_nl = 0;
            char* df_cr = strchr(df_mode, '\r'); if (df_cr) *df_cr = 0;
            if (strcmp(df_mode, "walklab") == 0) {
                fprintf(stderr, "[df] entering WalkLab onboard brokerage\n");
                Head::GetInstance()->m_Joint.SetEnableHeadOnly(true, true);
                Walking::GetInstance()->m_Joint.SetEnableBodyWithoutHead(true, true);
                Robotis::WalkLabBrokerage().Run();   // 무한 루프 — SIGTERM 까지
                return 0;
            }
        }
    }
    // === end DarwinForge injection ===
EOF_INJECT
  # while(1) 가 처음 나오는 줄 앞에 삽입.
  sed -i '0,/while(1)/{/while(1)/e cat /tmp/df_walklab_inject.cpp
}' main.cpp || {
    # 일부 sed 는 e 명령 미지원 — awk fallback
    awk '/while\(1\)/ && !done {while((getline line < "/tmp/df_walklab_inject.cpp")>0) print line; done=1} {print}' main.cpp > main.cpp.new && mv main.cpp.new main.cpp
  }
fi

if ! grep -q 'DarwinForge WalkLab onboard' main.cpp; then
  echo "✗ 분기 주입 실패 — main.cpp 에 while(1) anchor 없음. 원본 복구."
  cp main.cpp.df-orig main.cpp
  exit 1
fi

# 4) Makefile OBJECTS 에 WalkLabBrokerage.o 추가 (멱등)
if ! grep -q 'WalkLabBrokerage.o' Makefile; then
  sed -i 's/^OBJECTS = \(.*\)$/OBJECTS = \1 WalkLabBrokerage.o/' Makefile
fi

# 5) 빌드 (GNU make 암묵 규칙이 WalkLabBrokerage.cpp 컴파일)
echo "▶ make ..."
rm -f main.o WalkLabBrokerage.o demo   # 강제 재컴파일 (구 바이너리 잔존 방지)
if make 2>build.log; then
  tail -8 build.log
  if [ ! -f demo ]; then
    echo "✗ make 가 에러 없이 끝났으나 demo 바이너리 없음 — build.log 확인"; exit 1
  fi
  echo "✅ 빌드 완료 — ./demo 가 walklab 분기 포함 ($(ls -la demo | awk '{print $6,$7,$8}'))"
else
  echo "----- 빌드 에러 (build.log) -----"; tail -25 build.log
  echo "✗ 빌드 실패 — 원본 복구"
  cp main.cpp.df-orig main.cpp
  [ -f Makefile.df-orig ] && cp Makefile.df-orig Makefile
  exit 1
fi

rm -f /tmp/df_walklab_inject.cpp
echo ""
echo "=== 다음 단계 (검증) ==="
echo "  echo walklab > /tmp/df-pilot-mode"
echo "  chmod 0666 /tmp/df-walklab-cmd 2>/dev/null; : > /tmp/df-walklab-cmd"
echo "  sudo ./demo &"
echo "  # 제자리 걸음 테스트:"
echo '  echo "1 0 0 0 600 40 13" > /tmp/df-walklab-cmd'
echo "  # 전진:    echo \"1 20 0 0 600 40 13\" > /tmp/df-walklab-cmd"
echo "  # 정지:    echo \"0 0 0 0 600 40 13\" > /tmp/df-walklab-cmd"
echo "  # 종료:    sudo killall demo"
echo ""
echo "  원본 데모로 되돌리기:  cp main.cpp.df-orig main.cpp && cp Makefile.df-orig Makefile && make"
