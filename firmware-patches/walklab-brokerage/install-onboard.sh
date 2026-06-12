#!/bin/bash
# DarwinForge — WalkLab 온보드 브로커리지 설치 (이 로봇의 demo main.cpp 전용, 2026-06-01)
#
# 사용법 (로봇 VNC 터미널에서):
#   1) Mac 에서 SMB 로 이 폴더의 파일들(install-onboard.sh, WalkLabBrokerage.cpp,
#      WalkLabBrokerage.h, balltrack.ini)을 로봇의 demo 폴더(/robotis/Linux/project/demo/)에 복사
#      (balltrack.ini = 볼 트래킹 HSV 색 + 헤드 tilt 상한 + 카메라 조도. 없으면 공 검출 실패.)
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

# 0) 브로커리지 소스 + 볼 트래킹 config 존재 확인
for f in WalkLabBrokerage.cpp WalkLabBrokerage.h WalkLabTransport.cpp WalkLabTransport.h balltrack.ini; do
  if [ ! -f "$DEMO/$f" ]; then
    echo "✗ $f 없음 — Mac 에서 SMB 로 이 폴더에 복사하세요."
    exit 1
  fi
done

# 1) 백업 (2026-06-08 — StatusCheck.h/.cpp 도 후면 MODE 버튼 패치 위해 추가)
cp -p main.cpp main.cpp.df-orig 2>/dev/null || true
cp -p Makefile Makefile.df-orig 2>/dev/null || true
[ -f StatusCheck.h ]   && cp -p StatusCheck.h   StatusCheck.h.df-orig   2>/dev/null || true
[ -f StatusCheck.cpp ] && cp -p StatusCheck.cpp StatusCheck.cpp.df-orig 2>/dev/null || true

# 1b) balltrack.ini (볼 트래킹 HSV 색 + 헤드 tilt 상한 + 카메라 조도) 설치.
#     WalkLabBrokerage 가 런타임에 BALLCOLOR_INI 절대경로로 읽음(ReloadBallColor).
#     없으면 ColorFinder 기본값(공 색 불일치) + 카메라 미설정 → 볼 트래킹 실패.
#     멱등 — 로봇에 이미 튜닝된 ini 가 있으면 보존(덮어쓰지 않음). 없을 때만 baseline 설치.
BALLCOLOR_INI="/robotis/Linux/project/demo/balltrack.ini"
if [ "$DEMO/balltrack.ini" -ef "$BALLCOLOR_INI" ]; then
  echo "▶ balltrack.ini 이미 demo 경로에 위치 — 그대로 사용 ($BALLCOLOR_INI)"
elif [ -f "$BALLCOLOR_INI" ]; then
  echo "▶ balltrack.ini 이미 존재 — 로봇 튜닝본 보존, 복사 skip ($BALLCOLOR_INI)"
else
  mkdir -p "$(dirname "$BALLCOLOR_INI")"
  cp -p "$DEMO/balltrack.ini" "$BALLCOLOR_INI"
  echo "▶ balltrack.ini → $BALLCOLOR_INI 설치 (볼 색/조도 baseline)"
fi

# 2) include 주입 (StatusCheck.h 다음, 멱등)
if ! grep -q 'WalkLabBrokerage.h' main.cpp; then
  sed -i '/#include "StatusCheck.h"/a #include "WalkLabBrokerage.h"' main.cpp
fi

# 3) walklab 분기 주입 — while(1) 메인 루프 직전 (멱등 + 업데이트 재주입)
# 기존 주입 블록(마커 사이)이 있으면 먼저 제거한다. 이렇게 하면 주입 코드(예: 느린
# 기립 시퀀스)를 바꾼 뒤 재설치해도 옛 블록이 남지 않고 항상 최신 버전이 반영된다.
if grep -q '=== DarwinForge WalkLab onboard brokerage' main.cpp; then
  sed -i '/=== DarwinForge WalkLab onboard brokerage/,/=== end DarwinForge injection ===/d' main.cpp
  echo "▶ 기존 walklab 주입 블록 제거 — 최신 버전으로 재주입."
fi
if ! grep -q 'DarwinForge WalkLab onboard' main.cpp; then
  cat > /tmp/df_walklab_inject.cpp <<'EOF_INJECT'
    // === DarwinForge WalkLab onboard brokerage (2026-06-07 Switch fix) ===
    // /tmp/df-pilot-mode == "walklab" 이면 공식 Walking 엔진을 Mac/Switch 명령 파일로 제어.
    // 명령 파일을 읽기 전에 DarwinForge 조종 시뮬의 onboard 경로와 같은 준비 시퀀스
    // (MotionManager 재초기화, walk-ready, gyro calibration, Walking 초기화)를 끝내야
    // head servo만 움직이고 다리 보행은 미동 없는 상태를 피할 수 있다.
    {
        FILE* dfMode = fopen("/tmp/df-pilot-mode", "r");
        if (dfMode) {
            char dfBuf[32] = {0};
            if (fgets(dfBuf, sizeof(dfBuf)-1, dfMode) == NULL) dfBuf[0] = 0;
            fclose(dfMode);
            size_t dfLen = strlen(dfBuf);
            while (dfLen > 0 && (dfBuf[dfLen-1]=='\n' || dfBuf[dfLen-1]=='\r' || dfBuf[dfLen-1]==' ')) {
                dfBuf[--dfLen] = '\0';
            }

            #define DF_PROGRESS(stage) do { \
                FILE* dfP = fopen("/tmp/df-pilot-progress", "w"); \
                if (dfP) { fprintf(dfP, "%s\n", (stage)); fclose(dfP); } \
                fprintf(stderr, "[df-pilot] progress=%s\n", (stage)); \
            } while(0)

            if (strcmp(dfBuf, "walklab") == 0) {
                fprintf(stderr, "[df-pilot] auto-mode: walklab (ROBOTIS onboard brokerage, switch fix)\n");
                DF_PROGRESS("walklab-init");
                cm730.WriteByte(CM730::P_LED_PANNEL, 0x05, NULL);
                LinuxActionScript::PlayMP3((char*)"../../../Data/mp3/Autonomous soccer mode.mp3");
                usleep(500*1000);

                MotionManager::GetInstance()->Reinitialize();
                MotionManager::GetInstance()->SetEnable(true);
                Action::GetInstance()->m_Joint.SetEnableBody(true, true);

                DF_PROGRESS("walk-ready");
                // DarwinForge 부팅 데모: 검증된 walkready(page 9, TIME_BASE) 궤적은 그대로
                // 두고 header.speed 만 키워(32→96) 약 3배 천천히·안정적으로 토크를 인가하며
                // 기립한다. Start(int,PAGE*) 는 체크섬을 검증하지 않으므로 수정 페이지를 그대로
                // 재생할 수 있다. LoadPage 실패 시 표준 walk-ready 로 폴백.
                {
                    Action::PAGE dfWR;
                    if (Action::GetInstance()->LoadPage(9, &dfWR)) {
                        int dfSp = (int)dfWR.header.speed * 3;   // TIME_BASE: speed↑ = 느림
                        dfWR.header.speed = (unsigned char)(dfSp > 255 ? 255 : dfSp);
                        Action::GetInstance()->Start(9, &dfWR);
                    } else {
                        Action::GetInstance()->Start(9);
                    }
                }
                while (Action::GetInstance()->IsRunning() == true) usleep(8000);

                Head::GetInstance()->m_Joint.SetEnableHeadOnly(true, true);
                Walking::GetInstance()->m_Joint.SetEnableBodyWithoutHead(true, true);

                DF_PROGRESS("gyro-calibration");
                MotionManager::GetInstance()->ResetGyroCalibration();
                { int dfW = 0;
                  while (dfW < 30) {
                      int s = MotionManager::GetInstance()->GetCalibrationStatus();
                      if (s == 1) { LinuxActionScript::PlayMP3((char*)"../../../Data/mp3/Sensor calibration complete.mp3"); break; }
                      if (s == -1) MotionManager::GetInstance()->ResetGyroCalibration();
                      usleep(100*1000); dfW++;
                  } }

                Walking::GetInstance()->Initialize();
                StatusCheck::m_is_started = 1;
                cm730.WriteWord(CM730::ID_BROADCAST, MX28::P_MOVING_SPEED_L, 0, 0);

                DF_PROGRESS("walklab-active");
                unlink("/tmp/df-pilot-mode");
                fprintf(stderr, "[df-pilot] entering WalkLabBrokerage.Run()\n");
                // C1 (2026-06-12) — streamer 전달: walklab 중에도 8080 MJPEG 펌프 동작.
                Robotis::WalkLabBrokerage().Run(DF_RUN_ARGS_PLACEHOLDER);
                return 0;
            }
        }
    }
    // === end DarwinForge injection ===
EOF_INJECT
  # C1 (2026-06-12) — 카메라 스트림: demo main.cpp 의 mjpg_streamer 지역변수(streamer)를
  # brokerage 에 전달해 walklab 중에도 8080 프레임 펌프가 돌게 한다. streamer 변수가 없는
  # 데모 변종에서는 종전 시그니처(Run(&cm730))로 폴백 — 컴파일 항상 보장.
  if grep -q 'mjpg_streamer\*[[:space:]]*streamer' main.cpp; then
    sed -i 's/Run(DF_RUN_ARGS_PLACEHOLDER)/Run(\&cm730, streamer)/' /tmp/df_walklab_inject.cpp
    echo "▶ C1: Run(&cm730, streamer) — 카메라 스트림 펌프 활성 주입."
  else
    sed -i 's/Run(DF_RUN_ARGS_PLACEHOLDER)/Run(\&cm730)/' /tmp/df_walklab_inject.cpp
    echo "⚠ C1: main.cpp 에 mjpg_streamer 변수 없음 — 스트림 없이 Run(&cm730) 폴백."
  fi
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

# === 3b) 후면 버튼 모드 (2026-06-08) =================================
# 표준 데모의 MODE 버튼 순환에 'WALKLAB' 한 칸을 추가해, 로봇 단독(DarwinForge/Switch
# 없이도)으로 MODE 7번 + START 로 WalkLab 모드를 켤 수 있게 한다. 자동기동 경로
# (/tmp/df-pilot-mode == "walklab") 는 그대로 유지 — 둘 다 같은 WalkLabBrokerage.Run().
#
# 멱등 표시:
#   StatusCheck.h  : ',WALKLAB,'   marker (enum 끝에 삽입)
#   StatusCheck.cpp: 'WalkLab mode (button)' marker (MODE LED + START 케이스)
#   main.cpp       : 'WalkLab button mode' marker (switch case WALKLAB)
# 각 단계는 grep 으로 적용 여부를 확인 — 두 번 돌려도 안전.
#
# 후면 버튼 모드는 표준 데모의 'ROBOPLUS' 모드 케이스를 anchor 로 삽입한다.
# ROBOPLUS 모드가 없는 데모 변종(예: SOCCER/MOTION/VISION 만 순환하는 펌웨어)에서는
# 버튼 기능을 통째로 건너뛰고, 자동기동 경로(/tmp/df-pilot-mode == "walklab") 만
# 유지한다. head_tilt/WalkLabBrokerage 빌드는 그대로 진행 — 핵심 기능은 손상 없음.
DF_BUTTON_MODE=1
if [ ! -f StatusCheck.cpp ] || ! grep -q 'm_cur_mode == ROBOPLUS' StatusCheck.cpp; then
  echo "⚠ ROBOPLUS 모드 없는 데모 — 후면 MODE 버튼 기능 건너뜀(자동기동 경로만 유지)."
  DF_BUTTON_MODE=0
fi
if [ "$DF_BUTTON_MODE" = 1 ]; then

# (a) StatusCheck.h — enum 끝에 WALKLAB 추가 (기존 인덱스 보존)
if [ -f StatusCheck.h ] && ! grep -q 'WALKLAB,' StatusCheck.h; then
  # ',\s*MAX_MODE' 직전에 'WALKLAB,' 삽입 (모드 순환의 새 항목, MAX_MODE 자동 증가).
  sed -i 's/\([[:space:]]*\)\(MAX_MODE\)/\1WALKLAB,\n\1\2/' StatusCheck.h
fi
if [ -f StatusCheck.h ] && ! grep -q 'WALKLAB,' StatusCheck.h; then
  echo "✗ StatusCheck.h: WALKLAB enum 삽입 실패 — MAX_MODE anchor 없음."
  [ -f StatusCheck.h.df-orig ] && cp StatusCheck.h.df-orig StatusCheck.h
  exit 1
fi

# (b) StatusCheck.cpp — MODE 버튼 LED + START 버튼 케이스 추가
if [ -f StatusCheck.cpp ] && ! grep -q 'WalkLab mode (button)' StatusCheck.cpp; then
  # (b1) MODE 버튼 LED 분기 — ROBOPLUS case 다음에 WALKLAB case 삽입.
  #      LED 패턴 0x07 = R+G+B 모두 ON (다른 모드와 시각적으로 분리).
  cat > /tmp/df_walklab_led.cpp <<'EOF_LED'
        else if(m_cur_mode == WALKLAB)
        {
            // WalkLab mode (button) — DarwinForge WalkLab onboard brokerage.
            // LED 0x07(R+G+B all on) 으로 다른 모드와 명확히 구분.
            cm730.WriteByte(CM730::P_LED_PANNEL, 0x07, NULL);
            // 오디오는 사용자가 별도 mp3 추가 시 활성화 (없으면 stderr 만 로그).
            FILE* dfMp3 = fopen("../../../Data/mp3/WalkLab pilot ready.mp3", "r");
            if (dfMp3) { fclose(dfMp3); LinuxActionScript::PlayMP3("../../../Data/mp3/WalkLab pilot ready.mp3"); }
            else { fprintf(stderr, "WalkLab pilot mode selected (no mp3 cue installed)\n"); }
        }
EOF_LED
  # ROBOPLUS LED 케이스의 닫는 '}' 다음에 위 블록 삽입.
  awk 'BEGIN { applied=0 }
       /m_cur_mode == ROBOPLUS/ { roboplus=1 }
       roboplus && /^\t\}|^        \}/ && !applied {
           print
           while ((getline line < "/tmp/df_walklab_led.cpp") > 0) print line
           applied=1; roboplus=0; next
       }
       { print }' StatusCheck.cpp > StatusCheck.cpp.new && mv StatusCheck.cpp.new StatusCheck.cpp

  # (b2) START 버튼 분기 — ROBOPLUS START case 다음에 WALKLAB case 삽입.
  # WalkLab 진입 자체는 main.cpp 의 switch case 가 처리 — 여기서는 m_is_started=1
  # 만 세팅(MotionManager 초기화 등은 main.cpp 의 WALKLAB case 안에서).
  cat > /tmp/df_walklab_start.cpp <<'EOF_START'
            else if(m_cur_mode == WALKLAB)
            {
                // WalkLab mode (button) — main.cpp 의 switch case 가 walklab-init →
                // walk-ready → gyro → WalkLabBrokerage().Run() 시퀀스 처리.
                MotionManager::GetInstance()->Reinitialize();
                MotionManager::GetInstance()->SetEnable(true);
                m_is_started = 1;
                fprintf(stderr, "Start button pressed (WALKLAB) — entering WalkLabBrokerage\n");
            }
EOF_START
  # ROBOPLUS START 케이스의 닫는 '}' 다음에 위 블록 삽입. START 케이스는 더 깊은
  # 들여쓰기(16 spaces) 라 패턴이 LED 분기와 다름.
  awk 'BEGIN { applied=0; in_start=0 }
       /m_old_btn & BTN_START/ { in_start=1 }
       in_start && /m_cur_mode == ROBOPLUS/ { roboplus_start=1 }
       roboplus_start && /^            \}/ && !applied {
           print
           while ((getline line < "/tmp/df_walklab_start.cpp") > 0) print line
           applied=1; roboplus_start=0; next
       }
       { print }' StatusCheck.cpp > StatusCheck.cpp.new && mv StatusCheck.cpp.new StatusCheck.cpp

  rm -f /tmp/df_walklab_led.cpp /tmp/df_walklab_start.cpp
fi
if [ -f StatusCheck.cpp ] && ! grep -q 'WalkLab mode (button)' StatusCheck.cpp; then
  echo "✗ StatusCheck.cpp: WALKLAB 분기 삽입 실패 — ROBOPLUS anchor 미발견."
  [ -f StatusCheck.cpp.df-orig ] && cp StatusCheck.cpp.df-orig StatusCheck.cpp
  [ -f StatusCheck.h.df-orig ]   && cp StatusCheck.h.df-orig   StatusCheck.h
  exit 1
fi

# (c) main.cpp — switch(m_cur_mode) 안에 case WALKLAB 삽입.
# 자동기동 경로(/tmp/df-pilot-mode) 는 이미 위에서 while(1) 직전에 주입돼 있고,
# 이건 그것과 별개로 후면 버튼 → m_is_started=1 → switch 분기 진입 경로.
if ! grep -q 'WalkLab button mode' main.cpp; then
  cat > /tmp/df_walklab_case.cpp <<'EOF_CASE'
        case WALKLAB:
            // === WalkLab button mode (DarwinForge 2026-06-08) ===
            // 후면 MODE 버튼으로 선택 + START 로 시작된 경로. m_is_started 는 이미 1.
            // 자동기동(/tmp/df-pilot-mode) 경로와 같은 부팅 시퀀스를 거쳐 WalkLab 진입.
            {
                static bool df_walklab_booted = false;
                if (!df_walklab_booted) {
                    df_walklab_booted = true;
                    fprintf(stderr, "[df-pilot] button-mode: walklab (back-panel MODE+START)\n");
                    cm730.WriteByte(CM730::P_LED_PANNEL, 0x07, NULL);

                    MotionManager::GetInstance()->Reinitialize();
                    MotionManager::GetInstance()->SetEnable(true);
                    Action::GetInstance()->m_Joint.SetEnableBody(true, true);

                    {   // 느린 안정 기립 — auto-mode 와 동일 (walkready page speed 3x)
                        Action::PAGE dfWR;
                        if (Action::GetInstance()->LoadPage(9, &dfWR)) {
                            int dfSp = (int)dfWR.header.speed * 3;
                            dfWR.header.speed = (unsigned char)(dfSp > 255 ? 255 : dfSp);
                            Action::GetInstance()->Start(9, &dfWR);
                        } else {
                            Action::GetInstance()->Start(9);
                        }
                    }
                    while (Action::GetInstance()->IsRunning() == true) usleep(8000);

                    Head::GetInstance()->m_Joint.SetEnableHeadOnly(true, true);
                    Walking::GetInstance()->m_Joint.SetEnableBodyWithoutHead(true, true);

                    MotionManager::GetInstance()->ResetGyroCalibration();
                    { int dfW = 0;
                      while (dfW < 30) {
                          int s = MotionManager::GetInstance()->GetCalibrationStatus();
                          if (s == 1) { LinuxActionScript::PlayMP3((char*)"../../../Data/mp3/Sensor calibration complete.mp3"); break; }
                          if (s == -1) MotionManager::GetInstance()->ResetGyroCalibration();
                          usleep(100*1000); dfW++;
                      } }

                    Walking::GetInstance()->Initialize();
                    cm730.WriteWord(CM730::ID_BROADCAST, MX28::P_MOVING_SPEED_L, 0, 0);
                    fprintf(stderr, "[df-pilot] entering WalkLabBrokerage.Run() via button mode\n");
                    Robotis::WalkLabBrokerage().Run(DF_RUN_ARGS_PLACEHOLDER);
                    // Run() 종료(MODE 버튼) 후 boot 플래그 리셋 — 다시 START 누르면 재진입 가능.
                    df_walklab_booted = false;
                }
            }
            break;
EOF_CASE
  # C1 — 버튼 모드 경로도 동일하게 streamer 전달(변종 폴백 포함).
  if grep -q 'mjpg_streamer\*[[:space:]]*streamer' main.cpp; then
    sed -i 's/Run(DF_RUN_ARGS_PLACEHOLDER)/Run(\&cm730, streamer)/' /tmp/df_walklab_case.cpp
  else
    sed -i 's/Run(DF_RUN_ARGS_PLACEHOLDER)/Run(\&cm730)/' /tmp/df_walklab_case.cpp
  fi
  # `case ROBOPLUS:` 블록의 끝(`break;`) 다음에 위 case 삽입. ROBOPLUS case 는
  # `roboplus_exec(...);` 한 줄 + `break;` 패턴.
  awk 'BEGIN { applied=0; in_roboplus=0 }
       /case ROBOPLUS:/ { in_roboplus=1 }
       in_roboplus && /^[[:space:]]+break;[[:space:]]*$/ && !applied {
           print
           while ((getline line < "/tmp/df_walklab_case.cpp") > 0) print line
           applied=1; in_roboplus=0; next
       }
       { print }' main.cpp > main.cpp.new && mv main.cpp.new main.cpp
  rm -f /tmp/df_walklab_case.cpp
fi
if ! grep -q 'WalkLab button mode' main.cpp; then
  echo "✗ main.cpp: WALKLAB switch case 삽입 실패 — ROBOPLUS case anchor 미발견."
  cp main.cpp.df-orig main.cpp
  [ -f StatusCheck.cpp.df-orig ] && cp StatusCheck.cpp.df-orig StatusCheck.cpp
  [ -f StatusCheck.h.df-orig ]   && cp StatusCheck.h.df-orig   StatusCheck.h
  exit 1
fi

fi  # === end DF_BUTTON_MODE (후면 버튼 모드 — ROBOPLUS 데모에서만) ===

# 4) Makefile OBJECTS 에 WalkLabBrokerage.o + WalkLabTransport.o 추가 (멱등)
if ! grep -q 'WalkLabBrokerage.o' Makefile; then
  sed -i 's/^OBJECTS = \(.*\)$/OBJECTS = \1 WalkLabBrokerage.o/' Makefile
fi
# O1 (2026-06-12) — 순수 transport 로직 오브젝트(별도 컴파일 단위). 멱등.
if ! grep -q 'WalkLabTransport.o' Makefile; then
  sed -i 's/^OBJECTS = \(.*\)$/OBJECTS = \1 WalkLabTransport.o/' Makefile
fi

# 5) 빌드 (GNU make 암묵 규칙이 *.cpp 컴파일 — WalkLabTransport.o 도 자동)
echo "▶ make ..."
rm -f main.o WalkLabBrokerage.o WalkLabTransport.o demo   # 강제 재컴파일 (구 바이너리 잔존 방지)
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
  [ -f Makefile.df-orig ]        && cp Makefile.df-orig        Makefile
  [ -f StatusCheck.h.df-orig ]   && cp StatusCheck.h.df-orig   StatusCheck.h
  [ -f StatusCheck.cpp.df-orig ] && cp StatusCheck.cpp.df-orig StatusCheck.cpp
  exit 1
fi

# 6) 부팅 walklab 자동기동 훅 (멱등) — /etc/rc.local 이 데모 실행 전에 영구 pilot-mode 를
#    /tmp 로 복원한다. /tmp 는 재부팅 시 비워지므로 이 복원이 없으면 부팅 데모가 walklab 으로
#    들어가지 못한다. 영구 pilot-mode 가 "walklab" 일 때만 동작 = 선택형 토글
#    (켜기: echo walklab > ~/.config/darwinforge/pilot-mode / 끄기: 파일 삭제·다른 값).
#    느린 안정 기립은 데모 바이너리의 walkready(page9 speed×3) 시퀀스가 처리.
if [ -f /etc/rc.local ] && ! grep -q 'DarwinForge boot walklab' /etc/rc.local; then
  if grep -q '/robotis/Linux/project/demo/demo' /etc/rc.local; then
    awk '
      /\/robotis\/Linux\/project\/demo\/demo/ && !df_done {
        print "# === DarwinForge boot walklab === (영구 pilot-mode=walklab 이면 부팅 시 walklab 진입)"
        print "if [ \"$(cat /home/robotis/.config/darwinforge/pilot-mode 2>/dev/null)\" = \"walklab\" ]; then"
        print "  rm -f /tmp/df-walklab-estop"
        print "  echo walklab > /tmp/df-pilot-mode"
        print "  : > /tmp/df-walklab-cmd; chmod 0666 /tmp/df-walklab-cmd"
        print "fi"
        df_done=1
      }
      { print }
    ' /etc/rc.local > /tmp/rc.local.df && cat /tmp/rc.local.df > /etc/rc.local && rm -f /tmp/rc.local.df
    echo "▶ 부팅 walklab 훅을 /etc/rc.local 에 추가 (토글: ~/.config/darwinforge/pilot-mode)."
  else
    echo "⚠ /etc/rc.local 에 데모 실행 줄이 없어 부팅 walklab 훅을 건너뜀."
  fi
else
  echo "▶ 부팅 walklab 훅 이미 설치됨(또는 /etc/rc.local 없음)."
fi

rm -f /tmp/df_walklab_inject.cpp
echo ""
echo "=== 다음 단계 (검증) ==="
echo ""
echo "  [A] 자동기동 경로 (DarwinForge / Switch 트리거):"
echo "    echo walklab > /tmp/df-pilot-mode"
echo "    chmod 0666 /tmp/df-walklab-cmd 2>/dev/null; : > /tmp/df-walklab-cmd"
echo "    sudo ./demo &"
echo "    # 제자리 걸음:  echo \"1 0 0 0 600 40 13\" > /tmp/df-walklab-cmd"
echo "    # 전진:         echo \"1 20 0 0 600 40 13\" > /tmp/df-walklab-cmd"
echo "    # 정지:         echo \"0 0 0 0 600 40 13\" > /tmp/df-walklab-cmd"
echo "    # 종료:         sudo killall demo"
echo ""
echo "  [B] 후면 버튼 경로 (2026-06-08 추가 — 로봇 단독):"
echo "    sudo ./demo &           # 또는 /etc/rc.local 이 부팅 시 자동 실행"
echo "    # MODE 버튼 6회 → LED 0x07(R+G+B) 점등 = WALKLAB 모드"
echo "    # START 버튼     → walk-ready 자세 + gyro calibration → WalkLab 진입"
echo "    # MODE 버튼 1회 → walking->Stop() + READY 복귀 (정중한 정지)"
echo ""
echo "  원본 데모로 되돌리기:"
echo "    cp main.cpp.df-orig       main.cpp"
echo "    cp Makefile.df-orig       Makefile"
echo "    cp StatusCheck.h.df-orig  StatusCheck.h    # 2026-06-08 추가"
echo "    cp StatusCheck.cpp.df-orig StatusCheck.cpp # 2026-06-08 추가"
echo "    make"
