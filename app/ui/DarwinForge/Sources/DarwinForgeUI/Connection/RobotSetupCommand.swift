import Foundation

/// 로봇 PC에 한 번만 입력하면 USB↔TCP bridge 가 영구히 alias `f` 로 등록되는 통합 셋업.
///
/// 다음을 한 블록으로 처리:
///   1. Ubuntu 12.04/14.04 EOL 자동 감지 → sources.list 를 `old-releases.ubuntu.com` 으로.
///   2. apt-get update + `--force-yes` 로 GPG 만료 우회.
///   3. socat 설치. 실패 시 Python pyserial fallback.
///   4. `/dev/ttyUSB0` 권한 (dialout 그룹 추가 + sudo alias).
///   5. `f` alias 등록 (재로그인 없이 즉시 사용 가능).
///   6. 사용 안내 echo.
public enum RobotSetupCommand {

    /// 통합 1-블록 셋업. 사용자가 로봇 터미널에 붙여넣고 Enter 한 번이면 끝.
    /// 모든 EOL/권한 케이스를 자동 처리한다.
    public static let unifiedSetup: String = """
    # ── DarwinForge USB↔TCP bridge 통합 셋업 (한 번만 실행) ──
    # 모든 EOL/권한/alias 케이스를 자동 처리합니다.
    set +e
    echo "▶ 1/5 EOL 저장소 자동 보정"
    if grep -qE "(precise|trusty)" /etc/os-release 2>/dev/null || lsb_release -c 2>/dev/null | grep -qE "(precise|trusty)"; then
      sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%s) 2>/dev/null
      sudo sed -i 's|http://[a-z.]*archive\\.ubuntu\\.com|http://old-releases.ubuntu.com|g; s|http://security\\.ubuntu\\.com|http://old-releases.ubuntu.com|g; s|http://ftp\\.[a-z.]*/ubuntu|http://old-releases.ubuntu.com/ubuntu|g' /etc/apt/sources.list 2>/dev/null
      for f in /etc/apt/sources.list.d/*.list; do [ -f "$f" ] && sudo sed -i "s|^deb |# deb |g" "$f"; done
    fi
    sudo apt-get update -qq 2>/dev/null

    echo "▶ 2/5 socat 설치 시도"
    sudo apt-get install -y --force-yes socat 2>/dev/null || sudo apt-get install -y socat 2>/dev/null
    HAS_SOCAT=$(which socat)

    if [ -z "$HAS_SOCAT" ]; then
      echo "▶ socat 설치 실패 — Python fallback 사용"
      python -c "import serial" 2>/dev/null || sudo apt-get install -y --force-yes python-serial 2>/dev/null
      cat > ~/.df_bridge.py << 'PY'
    import socket,serial,threading,sys
    DEV=sys.argv[1] if len(sys.argv)>1 else '/dev/ttyUSB0'
    s=serial.Serial(DEV,1000000,timeout=0)
    srv=socket.socket();srv.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    srv.bind(('0.0.0.0',5530));srv.listen(1);print("listen 5530 via "+DEV)
    while True:
     c,_=srv.accept()
     def r():
      while True:
       d=s.read(4096)
       if d:c.send(d)
     threading.Thread(target=r).start()
     while True:
      d=c.recv(4096)
      if not d:break
      s.write(d)
     c.close()
    PY
      BRIDGE_CMD="sudo python ~/.df_bridge.py"
    else
      # nodelay: TCP nagle off → 패킷 즉시 송신 (fragmentation 감소 → 마법사 polling 안정).
      # stty 사전 설정: file:b1000000 의 baud 적용이 일부 ROBOTIS-OP2 이미지에서 무시되는
      # 케이스 방어. open: 옵션은 file:보다 더 명확한 소켓 형식.
      BRIDGE_CMD="sudo bash -c 'stty -F /dev/ttyUSB0 1000000 raw -echo -echoe -echok -echoctl -echoke -ixon -ixoff -isig -icanon 2>/dev/null; exec socat tcp-l:5530,reuseaddr,fork,nodelay open:/dev/ttyUSB0,nonblock=0'"
    fi

    echo "▶ 3/5 dialout 그룹 추가 (재로그인 후 sudo 불필요)"
    sudo usermod -aG dialout $USER 2>/dev/null

    echo "▶ 4/5 'f' alias 등록 (.bashrc)"
    sed -i "/alias f=/d" ~/.bashrc 2>/dev/null
    echo "alias f='$BRIDGE_CMD'" >> ~/.bashrc
    source ~/.bashrc

    echo "▶ 5/5 검증"
    if [ -e /dev/ttyUSB0 ]; then
      echo "  ✓ /dev/ttyUSB0 존재"
    else
      echo "  ✗ /dev/ttyUSB0 없음 — CM 보드 USB 케이블 확인"
    fi
    echo
    echo "✅ 셋업 완료. 이제 'f' 한 글자로 USB↔TCP bridge 시작."
    echo "   첫 실행 시 sudo 비밀번호를 한 번 묻고, 그 후 15분간 캐시됩니다."
    echo "   Mac DarwinForge 마법사 → '자동 연결' 클릭 → 끝."
    """

    /// 진단용 한 줄. 환경 정보 (커널 / RAM / Rust 유무 / USB 디바이스).
    public static let diagnose: String =
        "uname -m && free -m | head -2 && which python python3 socat gcc cargo 2>/dev/null && ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null"

    /// 매번 사용 — `f` 한 글자.
    public static let runBridge: String = "f"

    /// ROBOTIS official camera tutorial 실행.
    ///
    /// e-Manual 기준:
    ///   - `/darwin/Linux/project/tutorial/camera`
    ///   - `./camera_tutorial`
    ///   - `http://192.168.123.1:8080`
    ///   - `GET /?action=snapshot` 단일 JPEG, `GET /?action=stream` MJPEG stream.
    public static let cameraTutorialStart: String = #"""
    set +e
    MODE=$(cat /tmp/df-pilot-mode 2>/dev/null | tr -d '\r\n')
    if [ "$MODE" = "walklab" ] && (pgrep -x demo >/dev/null 2>&1 || pgrep -x demo-pilot >/dev/null 2>&1); then
      echo "WalkLab 조종 데모 유지 — camera_tutorial 만 재시작"
      sudo killall camera_tutorial vision_demo 2>/dev/null
    else
      sudo killall camera_tutorial demo vision_demo 2>/dev/null
    fi

    CAM_DIR=""
    for d in "$HOME/Framework/Linux/project/tutorial/camera" \
             "$HOME/darwin/Linux/project/tutorial/camera" \
             "/darwin/Linux/project/tutorial/camera" \
             "/robotis/Linux/project/tutorial/camera"; do
      if [ -d "$d" ]; then
        CAM_DIR="$d"
        break
      fi
    done

    if [ -z "$CAM_DIR" ]; then
      echo "camera tutorial directory not found"
      echo "checked: ~/Framework, ~/darwin, /darwin, /robotis"
      exit 1
    fi

    cd "$CAM_DIR" || exit 1
    if [ ! -x ./camera_tutorial ]; then
      echo "building camera_tutorial in $CAM_DIR"
      make
    fi

    echo "starting ROBOTIS camera_tutorial from $CAM_DIR"
    sudo ./camera_tutorial >/tmp/df-camera.log 2>&1 &
    sleep 1

    if command -v ss >/dev/null 2>&1; then
      LISTEN=$(ss -lnt 2>/dev/null | grep ':8080')
    else
      LISTEN=$(netstat -lnt 2>/dev/null | grep ':8080')
    fi

    if [ -n "$LISTEN" ]; then
      IP=$(hostname -I 2>/dev/null | awk '{print $1}')
      [ -z "$IP" ] && IP="192.168.123.1"
      echo "camera_tutorial running"
      echo "snapshot: http://$IP:8080/?action=snapshot"
      echo "stream:   http://$IP:8080/?action=stream"
    else
      echo "camera_tutorial started, but port 8080 is not visible yet"
      tail -40 /tmp/df-camera.log 2>/dev/null
    fi
    """#

    public static let cameraTutorialStatus: String = #"""
    set +e
    echo "process:"
    pgrep -af 'camera_tutorial|demo|vision_demo' || echo "not running"
    echo
    echo "port 8080:"
    if command -v ss >/dev/null 2>&1; then
      ss -lnt 2>/dev/null | grep ':8080' || echo "closed"
    else
      netstat -lnt 2>/dev/null | grep ':8080' || echo "closed"
    fi
    echo
    echo "camera devices:"
    ls -la /dev/video* 2>/dev/null || echo "no /dev/video*"
    """#

    public static let cameraTutorialStop: String =
        "sudo killall camera_tutorial vision_demo 2>/dev/null && echo stopped || echo camera tutorial not running"

    // MARK: - ROBOTIS demo 제어 (Sprint 18 — Pilot 모드 통합)
    //
    // 핵심 제약 (코드에 반영해야 사용자가 혼동 안 함):
    //   - ROBOTIS `demo` 또는 단위 `walk_demo` / `action_editor` 는 모두 **/dev/ttyUSB0** 를
    //     점유한다. forge-bridge (socat 5530) 도 같은 디바이스 점유.
    //   - 따라서 **demo 와 forge-bridge 는 동시 실행 불가**. 모드 전환 시 한쪽을 죽여야 함.
    //   - 카메라 데모 (8080 process) 는 USB bus 와 무관 → 다른 모드와 동시 실행 OK.
    //
    // 명령 패턴:
    //   *Start  → forge-bridge 종료 → target binary 시작 → 1초 후 verify
    //   *Stop   → target binary 종료 → forge-bridge 재시작 (Mac 측 모터 송출 복구)
    //   *Status → 프로세스 / USB bus / forge-bridge 상태

    /// 모든 demo 종료 + forge-bridge 복구 — "수동" 모드로 돌아갈 때 호출.
    public static let demoStop: String = #"""
    set +e
    echo "▶ 모든 ROBOTIS 데모 종료"
    sudo killall demo demo-pilot walk_demo walk_tuner action_editor ball_follower vision_demo 2>/dev/null
    rm -f /tmp/df-pilot-mode /tmp/df-pilot-progress 2>/dev/null
    sleep 0.5

    echo "▶ forge-bridge 복구 (Mac 측 모터 송출용)"
    if [ -x /etc/init.d/forge-bridge ]; then
      sudo /etc/init.d/forge-bridge start 2>/dev/null
      sleep 0.5
      sudo /etc/init.d/forge-bridge status 2>/dev/null
    else
      # 마스터 셋업 안 됐으면 socat 직접 시도
      if command -v socat >/dev/null 2>&1; then
        sudo bash -c 'stty -F /dev/ttyUSB0 1000000 raw -echo 2>/dev/null
                      nohup socat tcp-l:5530,reuseaddr,fork,nodelay open:/dev/ttyUSB0,nonblock=0 >/dev/null 2>&1 &'
        sleep 0.3
        if ss -lnt 2>/dev/null | grep -q ":5530"; then
          echo "forge-bridge: running (raw socat, 영구 등록 X)"
        else
          echo "forge-bridge: failed — 마스터 셋업이 필요해요"
        fi
      else
        echo "forge-bridge: 미설치 — 마스터 셋업이 필요해요"
      fi
    fi

    echo
    echo "✅ 수동 모드 — Mac 앱에서 직접 모터 제어 가능"
    """#

    /// 볼 트래킹 시작 — ROBOTIS demo 를 SOCCER 모드로 띄움.
    ///
    /// **Phase B 변경 (Sprint 18)**:
    ///   1. forge-bridge 종료 (USB bus 점유 해제)
    ///   2. `demo-pilot` (우리 patched binary) 우선 탐색 → 없으면 원본 `demo` fallback
    ///   3. `/tmp/df-pilot-mode` 에 "soccer" 작성 (patched binary 가 시작 시 read)
    ///   4. nohup 으로 binary 시작 → 1초 후 프로세스 검증
    ///
    /// **각 경로의 차이**:
    ///   - `demo-pilot` (patched): 시작 즉시 SOCCER 모드 자동 진입 + START 자동.
    ///                              사용자 한 번 클릭 = 진짜 자동 동작.
    ///   - `demo`     (원본):       READY 모드로 시작. 사용자가 로봇 후면 **MODE 버튼** 1회
    ///                              + **START 버튼** 1회 눌러야 SOCCER demo 시작.
    public static let ballTrackerStart: String = #"""
    set +e
    echo "▶ forge-bridge 종료 (USB bus 해제)"
    sudo killall socat 2>/dev/null
    sleep 0.3

    echo "▶ ROBOTIS demo binary 탐색 (patched 우선)"
    BIN=""
    PATCHED=0
    # 1. demo-pilot (Phase B patched) 우선.
    for d in "$HOME/Framework/Linux/project/demo/demo-pilot" \
             "$HOME/darwin/Linux/project/demo/demo-pilot" \
             "/darwin/Linux/project/demo/demo-pilot" \
             "/robotis/Linux/project/demo/demo-pilot"; do
      if [ -x "$d" ]; then BIN="$d"; PATCHED=1; break; fi
    done
    # 2. 원본 demo fallback.
    if [ -z "$BIN" ]; then
      for d in "$HOME/Framework/Linux/project/demo/demo" \
               "$HOME/darwin/Linux/project/demo/demo" \
               "/darwin/Linux/project/demo/demo" \
               "/robotis/Linux/project/demo/demo"; do
        if [ -x "$d" ]; then BIN="$d"; break; fi
      done
    fi
    if [ -z "$BIN" ]; then
      echo "demo / demo-pilot binary not found"
      echo "checked: ~/Framework, ~/darwin, /darwin, /robotis"
      echo "→ Framework 미설치 — ROBOTIS 공식 패키지 빌드 필요"
      exit 1
    fi

    # 진행 단계 파일 초기화 — Mac UI 가 stale 데이터 안 보도록.
    echo "start-demo" > /tmp/df-pilot-progress

    if [ "$PATCHED" = "1" ]; then
      echo "   patched binary 사용: $BIN"
      echo "soccer" > /tmp/df-pilot-mode
    else
      echo "   원본 demo 사용 (patched binary 미설치): $BIN"
      echo "   → 사용자가 로봇 후면 MODE 버튼 + START 버튼 눌러야 SOCCER demo 시작"
      rm -f /tmp/df-pilot-mode    # 잔여 파일이 의도치 않은 모드 진입을 일으키지 않도록.
    fi

    echo "▶ 이전 데모 종료 + 카메라/장치 해제 대기"
    sudo killall demo demo-pilot walk_demo action_editor 2>/dev/null
    # **fix (2026-06-02)**: 이전 demo 가 카메라(/dev/video0)를 쥔 채라 0.3s 로는 해제 전에
    # 새 demo 가 떠 "VIDIOC_S_FMT busy" 로 크래시했다. 프로세스 종료 + 카메라 해제까지 대기.
    for i in $(seq 1 20); do pgrep -x demo >/dev/null 2>&1 || pgrep -x demo-pilot >/dev/null 2>&1 || break; sleep 0.2; done
    sleep 1.5

    echo "▶ demo 시작 → $BIN"
    cd "$(dirname "$BIN")" || exit 1
    # nohup 이 sudo 를 감싸야 비대화형 SSH 에서 동작 (sudo nohup 은 nohup 이 NOPASSWD 화이트리스트에
    # 없어 비밀번호 프롬프트 → 실패). demo 바이너리는 NOPASSWD 등록됨.
    nohup sudo -n "$BIN" >/tmp/df-demo.log 2>&1 &
    sleep 1

    PROC=$(pgrep -x "$(basename "$BIN")" 2>/dev/null)
    if [ -n "$PROC" ]; then
      echo "✅ demo 실행 중 (pid $PROC)"
      if [ "$PATCHED" = "1" ]; then
        echo "   자동 SOCCER 진입 — gyro calibration 까지 약 3-5초 대기"
      else
        echo "   다음 단계: 로봇 후면 MODE 버튼 → START 버튼 (각 1회)"
      fi
      echo "   카메라: 8080 그대로 LIVE (별도 process)"
      tail -10 /tmp/df-demo.log 2>/dev/null
    else
      echo "✗ demo 시작 실패"
      tail -30 /tmp/df-demo.log 2>/dev/null
      exit 1
    fi
    """#

    /// 볼 트래킹 종료 = demoStop 의 alias. UI 명령 의도 명확화를 위해 별도 const.
    public static let ballTrackerStop: String = demoStop

    // MARK: - v1.11.5 (2026-05-18) — WalkLab ROBOTIS Onboard mode

    /// **WalkLab Onboard mode 시작 명령** — robot 측 demo-pilot 실행 + WalkLab brokerage 모드.
    ///
    /// 흐름:
    ///   1. 기존 demo / forge-bridge 종료
    ///   2. `demo-pilot` (patched binary) 탐색 — 없으면 fallback `demo`
    ///   3. `/tmp/df-pilot-mode` 에 `"walklab"` 작성 (robot-side patch 가 read)
    ///   4. `/tmp/df-walklab-cmd` 빈 파일 생성 (Mac 측 x/y/a brokering write 경로)
    ///   5. `nohup` 으로 binary 시작
    ///
    /// **robot-side patch 필요** (이번 PR 범위 밖):
    /// - `df-pilot-mode == "walklab"` 분기 추가
    /// - `/tmp/df-walklab-cmd` 5Hz polling → `Walking::GetInstance()->X/Y/A_MOVE_AMPLITUDE` set
    /// - polling 식: 최신 성공 버전은 `cmd_id enabled x y a period foot hip balance head ball_track`
    ///   14-token 형식까지 parse 하고, `/tmp/df-walklab-ack` 에 cmd_id 를 echo.
    /// - 미patch/구patch 시: 시작 거부. `df-walklab-cmd` 문자열만 있는 2026-06-01 구버전은
    ///   ACK/head 는 동작해도 다리 보행 초기화가 빠질 수 있어 성공 버전으로 보지 않는다.
    public static let walkLabRobotisStart: String = #"""
    set +e
    camera_port_open() {
      if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -q ':8080'
      else
        netstat -lnt 2>/dev/null | grep -q ':8080'
      fi
    }
    stop_camera_stream() {
      echo "DF_READY_CAMERA_STOP=begin"
      sudo killall camera_tutorial vision_demo 2>/dev/null || killall camera_tutorial vision_demo 2>/dev/null || true
      for i in $(seq 1 20); do
        pgrep -x camera_tutorial >/dev/null 2>&1 || pgrep -x vision_demo >/dev/null 2>&1 || break
        sleep 0.1
      done
      if pgrep -x camera_tutorial >/dev/null 2>&1 || pgrep -x vision_demo >/dev/null 2>&1; then
        echo "DF_READY_CAMERA_STOP=warn_still_running"
        pgrep -af 'camera_tutorial|vision_demo' 2>/dev/null
      else
        echo "DF_READY_CAMERA_STOP=ok"
      fi
    }
    check_camera_stream() {
      # **C1 (2026-06-12)** — walklab demo 가 8080 MJPEG 를 **직접 스트리밍**한다
      # (브로커리지 카메라 펌프, firmware-patches C1). demo 가 /dev/video0 을 쥔 동안
      # camera_tutorial 은 뜰 수 없으므로 더는 시도하지 않는다. 또한 포트 LISTEN 만으로는
      # 프레임이 보장되지 않으므로(과거 "열림·영상 없음" 오진의 원인) 스냅샷 1장을 실제로
      # 받아 검증한다. 로봇엔 curl 이 없을 수 있어 wget 우선.
      if ! camera_port_open; then
        echo "DF_READY_CAMERA=port_closed"
        echo "   8080 미오픈 — demo 의 mjpg httpd 가 안 떠 있습니다 (카메라 초기화 실패?)"
        return 0
      fi
      rm -f /tmp/df-cam-health.jpg 2>/dev/null
      if command -v wget >/dev/null 2>&1; then
        wget -q -T 4 -O /tmp/df-cam-health.jpg "http://127.0.0.1:8080/?action=snapshot" 2>/dev/null
      elif command -v curl >/dev/null 2>&1; then
        curl -m 4 -fsS -o /tmp/df-cam-health.jpg "http://127.0.0.1:8080/?action=snapshot" 2>/dev/null
      else
        echo "DF_READY_CAMERA=no_probe_tool"
        echo "   wget/curl 이 없어 스냅샷 검증 불가 — 포트는 열려 있음"
        return 0
      fi
      if [ -s /tmp/df-cam-health.jpg ]; then
        echo "DF_READY_CAMERA=running"
        echo "   walklab demo 가 8080 에서 직접 스트리밍 중 (snapshot OK)"
      else
        echo "DF_READY_CAMERA=no_frames"
        echo "   8080 은 열렸지만 프레임이 안 나옵니다 — C1 카메라 패치 이전 demo 입니다."
        echo "   로봇 demo 폴더에서 install-onboard.sh 재빌드가 필요합니다 (조종은 가능)."
      fi
      return 0
    }
    # === DarwinForge SSH parity (2026-06-01) — 시작 시 항상 re-arm ===
    # §B REMOVER: 새 start 는 잔여 e-stop flag 를 제거해 다시 보행 가능 상태로.
    rm -f /tmp/df-walklab-estop 2>/dev/null
    echo "▶ forge-bridge 종료 (USB bus 해제)"
    sudo killall socat 2>/dev/null
    sleep 0.3
    echo "▶ 카메라 스트림 임시 종료 (WalkLab 초기화 충돌 방지)"
    stop_camera_stream

    echo "▶ ROBOTIS demo binary 탐색 (switch-fix WalkLab patched 우선)"
    BIN=""
    PATCHED=0
    OLD_PATCH=""
    # **C1 (2026-06-12)**: switch-fix marker 만 있고 C1(카메라 스트림 펌프) marker 가 없는
    # 구버전 binary 는 최후 폴백 — 조종은 되지만 영상이 안 나오므로 C1 binary 를 우선한다.
    FALLBACK_BIN=""
    # 1) 별도 demo-pilot 바이너리 우선, 단 성공 버전 marker 가 있어야 한다.
    for d in "$HOME/Framework/Linux/project/demo/demo-pilot" \
             "$HOME/darwin/Linux/project/demo/demo-pilot" \
             "/darwin/Linux/project/demo/demo-pilot" \
             "/robotis/Linux/project/demo/demo-pilot"; do
      if [ -x "$d" ]; then
        if grep -qa "ROBOTIS onboard brokerage, switch fix" "$d" 2>/dev/null; then
          if grep -qa "camera stream pump" "$d" 2>/dev/null; then BIN="$d"; PATCHED=1; break; fi
          [ -z "$FALLBACK_BIN" ] && FALLBACK_BIN="$d"
        elif grep -qa "df-walklab-cmd" "$d" 2>/dev/null; then OLD_PATCH="$d"; fi
      fi
    done
    # 2) 없으면 demo (이 로봇은 demo 자체에 성공 버전을 in-place patch 했을 수 있음).
    if [ -z "$BIN" ]; then
      for d in "$HOME/Framework/Linux/project/demo/demo" \
               "$HOME/darwin/Linux/project/demo/demo" \
               "/darwin/Linux/project/demo/demo" \
               "/robotis/Linux/project/demo/demo"; do
        if [ -x "$d" ]; then
          if grep -qa "ROBOTIS onboard brokerage, switch fix" "$d" 2>/dev/null; then
            if grep -qa "camera stream pump" "$d" 2>/dev/null; then BIN="$d"; PATCHED=1; break; fi
            [ -z "$FALLBACK_BIN" ] && FALLBACK_BIN="$d"
          elif [ -z "$OLD_PATCH" ] && grep -qa "df-walklab-cmd" "$d" 2>/dev/null; then OLD_PATCH="$d"; fi
        fi
      done
    fi
    # C1 binary 가 없으면 switch-fix 구버전으로 폴백 (조종 가능, 카메라만 미지원 — 진실 보고).
    if [ -z "$BIN" ] && [ -n "$FALLBACK_BIN" ]; then
      BIN="$FALLBACK_BIN"
      PATCHED=1
      echo "DF_READY_CAMERA_HINT=binary_pre_c1"
      echo "   ⚠ C1 카메라 패치 이전 binary 사용 — 영상이 필요하면 install-onboard.sh 재빌드"
    fi
    if [ -z "$BIN" ]; then
      if [ -n "$OLD_PATCH" ]; then
        echo "DF_READY_START=old_walklab_patch"
        echo "old_demo_binary=$OLD_PATCH"
        echo "구버전 WalkLab patch 감지 — switch fix 성공 버전으로 demo 재빌드가 필요합니다."
        exit 4
      fi
      echo "DF_READY_START=missing_walklab_patch"
      echo "switch fix WalkLab demo / demo-pilot binary not found"
      rm -f /tmp/df-pilot-mode ~/.config/darwinforge/pilot-mode 2>/dev/null
      exit 4
    fi
    echo "   switch-fix patched binary 사용: $BIN"
    mkdir -p ~/.config/darwinforge 2>/dev/null
    echo walklab > ~/.config/darwinforge/pilot-mode 2>/dev/null
    echo "walklab" > /tmp/df-pilot-mode
    : > /tmp/df-walklab-cmd
    chmod 0666 /tmp/df-walklab-cmd 2>/dev/null
    echo "▶ /tmp/df-pilot-mode = walklab"

    echo "▶ 이전 데모 종료 + 카메라/장치 해제 대기"
    sudo killall demo demo-pilot walk_demo action_editor 2>/dev/null
    # **fix (2026-06-02)**: 이전 demo 가 카메라(/dev/video0)를 쥔 채라 0.3s 로는 해제 전에
    # 새 demo 가 떠 "VIDIOC_S_FMT busy" 로 크래시했다. 프로세스 종료 + 카메라 해제까지 대기.
    for i in $(seq 1 20); do pgrep -x demo >/dev/null 2>&1 || pgrep -x demo-pilot >/dev/null 2>&1 || break; sleep 0.2; done
    if pgrep -x demo >/dev/null 2>&1 || pgrep -x demo-pilot >/dev/null 2>&1; then
      echo "DF_READY_START=old_process_still_running"
      echo "기존 demo/demo-pilot 이 종료되지 않았습니다. sudo 권한/NOPASSWD 또는 프로세스 상태를 확인하세요."
      pgrep -af 'demo|demo-pilot' 2>/dev/null
      exit 5
    fi
    sleep 1.5

    echo "▶ demo 시작 → $BIN"
    cd "$(dirname "$BIN")" || exit 1
    # nohup 이 sudo 를 감싸야 비대화형 SSH 에서 동작 (sudo nohup 은 nohup 이 NOPASSWD 화이트리스트에
    # 없어 비밀번호 프롬프트 → 실패). demo 바이너리는 NOPASSWD 등록됨.
    nohup sudo -n "$BIN" >/tmp/df-demo.log 2>&1 &
    sleep 1

    PROC=$(pgrep -x "$(basename "$BIN")" 2>/dev/null)
    if [ -z "$PROC" ]; then
      echo "✗ demo 시작 실패"
      tail -30 /tmp/df-demo.log 2>/dev/null
      exit 1
    fi
    echo "✅ demo 실행 중 (pid $PROC)"

    echo "▶ WalkLab active 단계 확인"
    STAGE=""
    for i in $(seq 1 60); do
      STAGE=$(head -1 /tmp/df-pilot-progress 2>/dev/null | tr -d '\r\n')
      [ "$STAGE" = "walklab-active" ] && break
      sleep 0.2
    done
    if [ "$STAGE" != "walklab-active" ]; then
      echo "DF_READY_START=progress_timeout"
      echo "walklab-active 단계에 도달하지 못했습니다. stage=${STAGE:-none}"
      tail -40 /tmp/df-demo.log 2>/dev/null
      exit 5
    fi

    echo "▶ 최신 14-token 명령/ACK 계약 확인"
    CMD_ID="dfstart_$(date +%s)"
    rm -f /tmp/df-walklab-ack 2>/dev/null
    printf '%s\n' "$CMD_ID 0 0.00 0.00 0.00 600 40 13.00 1.00 0 2 0.00 0.00 0" > /tmp/df-walklab-cmd.tmp &&
      mv /tmp/df-walklab-cmd.tmp /tmp/df-walklab-cmd
    ACK=""
    for i in $(seq 1 40); do
      if grep -qF "$CMD_ID" /tmp/df-walklab-ack 2>/dev/null; then
        ACK=$(cat /tmp/df-walklab-ack 2>/dev/null)
        break
      fi
      sleep 0.05
    done
    if [ -z "$ACK" ]; then
      echo "DF_READY_START=ack_timeout"
      echo "최신 WalkLab brokerage ACK를 받지 못했습니다. 구버전 demo 이거나 brokerage loop 미동작입니다."
      tail -40 /tmp/df-demo.log 2>/dev/null
      exit 5
    fi

    echo "DF_READY_START=brokerage_ready"
    echo "   WalkLab switch-fix brokerage 활성 — 14-token 명령/ACK 검증 완료"
    echo "   ack: $ACK"
    tail -10 /tmp/df-demo.log 2>/dev/null
    echo "▶ 카메라 스트림 확인 (C1 — walklab demo 가 8080 직접 스트리밍)"
    check_camera_stream
    """#

    /// **WalkLab Onboard mode 종료 명령** — demo-pilot 정지 + 명령 파일 정리 +
    /// forge-bridge 복구 (Mac 측 모터 송출 경로 복원).
    ///
    /// **v1.11.7 (2026-05-18, GPT HIGH-3 fix)**: 종전엔 killall + rm 만 하고 끝나서
    /// Mac 측 직접 setPosition 송출 경로가 복구 안 되던 버그. demoStop 패턴 그대로
    /// forge-bridge 복구 추가.
    public static let walkLabRobotisStop: String = #"""
    set +e
    echo "▶ WalkLab onboard 모드 종료"
    sudo killall demo demo-pilot 2>/dev/null
    rm -f /tmp/df-pilot-mode /tmp/df-walklab-cmd 2>/dev/null
    sleep 0.5

    echo "▶ forge-bridge 복구 (Mac 측 모터 송출용)"
    if [ -x /etc/init.d/forge-bridge ]; then
      sudo /etc/init.d/forge-bridge start 2>/dev/null
      sleep 0.5
      sudo /etc/init.d/forge-bridge status 2>/dev/null
    else
      if command -v socat >/dev/null 2>&1; then
        sudo bash -c 'stty -F /dev/ttyUSB0 1000000 raw -echo 2>/dev/null
                      nohup socat tcp-l:5530,reuseaddr,fork,nodelay open:/dev/ttyUSB0,nonblock=0 >/dev/null 2>&1 &'
        sleep 0.3
        if ss -lnt 2>/dev/null | grep -q ":5530"; then
          echo "forge-bridge: running (raw socat, 영구 등록 X)"
        else
          echo "forge-bridge: failed — 마스터 셋업이 필요해요"
        fi
      else
        echo "forge-bridge: socat 미설치 — 수동 셋업 필요"
      fi
    fi
    echo "✅ WalkLab onboard 종료 + Mac 직접 송출 경로 복구"
    """#

    /// **x/y/a brokering 명령 송출** — Mac → robot `/tmp/df-walklab-cmd` atomic write.
    ///
    /// shell-quote 안전 (template — caller 가 line 변수 escaping 책임).
    ///
    /// **v1.11.7 (2026-05-18, GPT MEDIUM-1 fix)** — atomic write:
    /// 종전 `printf > /tmp/df-walklab-cmd` 직접 덮어쓰기 → robot C++ polling 이
    /// write 중간에 read 하면 빈 파일/부분 line 가능. tmp file 에 write 후 mv 로
    /// atomic 교체. POSIX rename(2) 는 같은 filesystem 안에서 atomic 보장.
    ///
    /// 예시 usage (Swift side):
    /// ```swift
    /// let line = WalkingEngineCommand(enabled: true, xMm: 28, ...).serializedLine
    /// let cmd = RobotSetupCommand.walkLabRobotisSendCommand(line: line)
    /// try await ssh.execute(cmd)
    /// ```
    public static func walkLabRobotisSendCommand(line: String, cmdId: String? = nil) -> String {
        // line 은 `enabled x_mm y_mm a_deg period_ms foot_mm hip_pitch_deg` — 숫자만.
        // 안전성: WalkingEngineCommand.serializedLine 이 %d %.2f format 만 출력 →
        // shell metacharacters 위험 없음. 추가 guard 로 single-quote 사용.
        // **v1.11.16.1 (2026-05-19) — ACK 검증**: 명령 write 후 daemon 의 polling
        // 주기 (200ms) + 안전 margin (50ms) = 250ms sleep 후 ACK 파일 cat.
        // **v1.11.16.2 (2026-05-19) — Codex CRITICAL 1+MED fix**: cmd_id nonce 추가
        // 로 stale ACK 검출. deadline polling (1.5s) — sleep 0.25 보다 robust.
        // - cmd_id 가 line prefix 로 prepend: "{cmd_id} {line}"
        // - firmware 가 sscanf 첫 token 으로 cmd_id parse → ACK 에 echo
        // - Mac 의 Bridge 가 result 의 cmd_id 매치 → stale ACK reject
        //
        // 응답 형식:
        //   "OK {ts_ms} {cmd_id} {line}"  — daemon 처리 성공 (firmware ≥ v1.11.16.2)
        //   "OK {ts_ms} {line}"            — firmware ≥ v1.11.16.1 (cmd_id 없음, backward)
        //   "NO_ACK"                       — daemon 없음 또는 firmware 미패치
        let id = cmdId ?? generateCmdId()
        let fullLine = "\(id) \(line)"
        // **codex HIGH fix (2026-06-02)**: ACK 를 **cmd_id 일치까지** 폴링한다. 종전엔 `[ -s ack ]`
        // (파일 비어있지 않음)만 보고 즉시 cat → 직전 명령의 stale ACK 를 반환(로봇 poll 100ms vs
        // shell 50ms race). 펌웨어는 새 명령 처리 시에만 ACK 를 cmd_id 와 함께 기록하므로,
        //   1) 명령 전 ACK clear (stale 제거),
        //   2) 이번 cmd_id 가 ACK 에 나타날 때까지 폴링(grep)
        // 으로 항상 *이번 명령*의 fresh ACK 를 받는다. 구형 firmware(cmd_id 미echo)는 loop 후
        // clear 이후 생긴 비어있지 않은 ACK 로 폴백. (로봇 busybox `seq` 미보장 → 명시 리스트.)
        let pollLoop = "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do sleep 0.05; if grep -qF '\(id)' /tmp/df-walklab-ack 2>/dev/null; then cat /tmp/df-walklab-ack; exit 0; fi; done; if [ -s /tmp/df-walklab-ack ]; then cat /tmp/df-walklab-ack; exit 0; fi; echo NO_ACK"
        return "rm -f /tmp/df-walklab-ack 2>/dev/null; printf '%s\\n' '\(fullLine)' > /tmp/df-walklab-cmd.tmp && mv /tmp/df-walklab-cmd.tmp /tmp/df-walklab-cmd && (\(pollLoop))"
    }

    /// **텔레메트리 UDP 업링크 타깃 지정 (2026-06-03)** — Mac → robot `/tmp/df-walklab-uplink`
    /// atomic write. 로봇 브로커리지가 이 파일을 읽어(`RefreshUplinkTarget`) 텔레메트리
    /// `TEL …` 라인을 해당 IP:port 로 UDP push 한다(`OnboardTelemetryUDPReceiver` 가 수신).
    ///
    /// `ip` 는 Mac 의 로컬 IPv4(`NetworkProbe.localIPv4Addresses()` 에서 SSH host 와 동일
    /// /24 선택) — 숫자뿐이라 shell-safe. 그래도 방어적으로 single-quote.
    /// `walkLabRobotisSendCommand` 와 동일한 tmp+mv 원자 패턴(로봇이 부분 read 하지 않게).
    public static func walkLabWriteUplink(ip: String, port: UInt16) -> String {
        return "printf '%s %d\\n' '\(ip)' \(port) > /tmp/df-walklab-uplink.tmp && mv /tmp/df-walklab-uplink.tmp /tmp/df-walklab-uplink"
    }

    /// **v1.11.16.2 (2026-05-19)**: cmd_id 생성 — UUID prefix 8글자 + millisecond timestamp.
    /// shell-safe ([a-zA-Z0-9_-]) 만 사용. 길이 < 32.
    public static func generateCmdId() -> String {
        let uuid = UUID().uuidString.prefix(8)  // 8 hex chars
        let ts = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000  // 6 digits
        return "c\(ts)_\(uuid)"
    }

    /// **O1 핸드셰이크 프로비저닝 (2026-06-12)** — Mac → robot `/tmp/df-walklab-channel`
    /// atomic write. 로봇 브로커리지가 Run 시작 시 읽어(LoadHandshake) UDP transport 스레드를
    /// 기동한다. 형식: `"{token} {estop_port} {cmd_port}\n"`. 토큰은 UDP E-STOP/명령
    /// 데이터그램 인증값(`OnboardEstopDatagram`/`OnboardCommandDatagram` 과 동일) — spoofing
    /// 시에도 피해 = '불필요 정지' = fail-safe. 토큰은 영숫자만(shell-safe).
    public static func walkLabWriteChannelHandshake(
        token: String,
        estopPort: UInt16 = DFConnectionConstants.estopUDPPort,
        cmdPort: UInt16 = DFConnectionConstants.commandUDPPort
    ) -> String {
        return "printf '%s %d %d\\n' '\(token)' \(estopPort) \(cmdPort) > /tmp/df-walklab-channel.tmp && mv /tmp/df-walklab-channel.tmp /tmp/df-walklab-channel"
    }

    /// **O1** — 로봇 측 핸드셰이크 제거(세션 종료 — UDP transport 비활성화, 파일 폴 복귀).
    public static let walkLabClearChannelHandshake: String =
        "rm -f /tmp/df-walklab-channel 2>/dev/null; true"

    /// **O1** — UDP 채널 인증 토큰 생성. 영숫자만(shell-safe), 길이 16. 세션마다 새로.
    public static func generateChannelToken() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var token = ""
        for _ in 0..<16 {
            token.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return token
    }

    /// 현재 demo 활성 상태 — 사용자에게 어떤 모드인지 알려줌.
    ///
    /// **출력 contract** (Mac 앱이 파싱):
    /// - 첫 줄에 `DF_STATUS=demo` 또는 `DF_STATUS=bridge` 또는 `DF_STATUS=idle`
    /// - 그 뒤 사람이 읽을 수 있는 상세
    /// Mac 측 `PilotDemoStatusParser` 가 첫 줄 marker 만 보고 분기.
    public static let ballTrackerStatus: String = #"""
    set +e
    # 1줄짜리 머신 파싱용 marker — Mac 앱이 첫 줄만 봐도 모드 판단 가능.
    DEMO_RUNNING=0
    BRIDGE_RUNNING=0
    DEMO_BINARY=""
    if pgrep -x demo-pilot >/dev/null 2>&1; then
      DEMO_RUNNING=1; DEMO_BINARY="demo-pilot"
    elif pgrep -x demo >/dev/null 2>&1; then
      DEMO_RUNNING=1; DEMO_BINARY="demo"
    fi
    if ss -lnt 2>/dev/null | grep -q ":5530\s"; then BRIDGE_RUNNING=1
    elif netstat -lnt 2>/dev/null | grep -q ":5530\s"; then BRIDGE_RUNNING=1; fi

    if [ "$DEMO_RUNNING" = "1" ]; then
      echo "DF_STATUS=demo"
    elif [ "$BRIDGE_RUNNING" = "1" ]; then
      echo "DF_STATUS=bridge"
    else
      echo "DF_STATUS=idle"
    fi

    echo "---"
    echo "ROBOTIS demo:"
    if [ "$DEMO_RUNNING" = "1" ]; then
      echo "  ✅ running ($DEMO_BINARY, pid $(pgrep -x $DEMO_BINARY))"
      tail -3 /tmp/df-demo.log 2>/dev/null | sed 's/^/  log: /'
    else
      echo "  ❌ not running"
    fi

    echo
    echo "forge-bridge (5530):"
    if [ "$BRIDGE_RUNNING" = "1" ]; then
      echo "  ✅ listening — Mac 앱이 모터 제어 가능"
    else
      echo "  ❌ not listening — demo 가 USB bus 점유 중이거나 forge-bridge 미설치"
    fi

    echo
    echo "USB bus 점유자:"
    sudo fuser -v /dev/ttyUSB0 2>&1 | head -3 || echo "  (점유자 없음)"
    """#

    /// 걷기 데모 시작 — walk_tuner. ROBOTIS 의 walk_tuner 는 좌/우/전/후 키로 보행.
    ///
    /// **참고**: ROBOTIS-OP2 의 단독 walk_demo binary 는 없고, demo 통합 또는 walk_tuner 가 표준.
    /// 사용자가 "걷기 시작" 누르면 walk_tuner 가 더 적절 (튜닝 + 보행 둘 다).
    public static let walkDemoStart: String = #"""
    set +e
    echo "▶ forge-bridge 종료 (USB bus 해제)"
    sudo killall socat 2>/dev/null
    sleep 0.3

    echo "▶ walk_tuner binary 탐색"
    BIN=""
    for d in "$HOME/Framework/Linux/project/walk_tuner/walk_tuner" \
             "$HOME/darwin/Linux/project/walk_tuner/walk_tuner" \
             "/darwin/Linux/project/walk_tuner/walk_tuner" \
             "/robotis/Linux/project/walk_tuner/walk_tuner"; do
      if [ -x "$d" ]; then BIN="$d"; break; fi
    done
    if [ -z "$BIN" ]; then
      echo "walk_tuner not found — demo 로 대체 시도"
      for d in "$HOME/Framework/Linux/project/demo/demo" \
               "$HOME/darwin/Linux/project/demo/demo" \
               "/darwin/Linux/project/demo/demo"; do
        if [ -x "$d" ]; then BIN="$d"; break; fi
      done
    fi
    if [ -z "$BIN" ]; then
      echo "walk_tuner 와 demo 모두 없음 — ROBOTIS 공식 패키지 빌드 필요"
      exit 1
    fi

    echo "▶ 이전 데모 종료"
    sudo killall demo walk_tuner walk_demo action_editor 2>/dev/null
    sleep 0.3

    echo "▶ 시작 → $BIN"
    cd "$(dirname "$BIN")" || exit 1
    sudo nohup ./$(basename "$BIN") >/tmp/df-walk.log 2>&1 &
    sleep 1

    if pgrep -f "$(basename "$BIN")" >/dev/null; then
      echo "✅ walk demo 실행 중 (pid $(pgrep -f "$(basename "$BIN")"))"
      echo "   조작은 VNC/SSH 콘솔의 walk_tuner UI 로"
      tail -10 /tmp/df-walk.log 2>/dev/null
    else
      echo "✗ walk demo 시작 실패"
      tail -30 /tmp/df-walk.log 2>/dev/null
      exit 1
    fi
    """#

    public static let walkDemoStop: String = demoStop

    public static let walkDemoStatus: String = ballTrackerStatus

    /// Action editor 시작 — motion_4096.bin 페이지를 키보드로 직접 재생.
    /// motion play 의 단일 pose preview 가 부족할 때 사용자가 진짜 chain 재생을 원할 때.
    public static let actionDemoStart: String = #"""
    set +e
    echo "▶ forge-bridge 종료 (USB bus 해제)"
    sudo killall socat 2>/dev/null
    sleep 0.3

    BIN=""
    for d in "$HOME/Framework/Linux/project/action_editor/action_editor" \
             "$HOME/darwin/Linux/project/action_editor/action_editor" \
             "/darwin/Linux/project/action_editor/action_editor"; do
      if [ -x "$d" ]; then BIN="$d"; break; fi
    done
    if [ -z "$BIN" ]; then
      echo "action_editor not found"
      exit 1
    fi

    sudo killall demo action_editor walk_tuner 2>/dev/null
    sleep 0.3
    cd "$(dirname "$BIN")" || exit 1
    sudo nohup ./action_editor >/tmp/df-action.log 2>&1 &
    sleep 1
    if pgrep -x action_editor >/dev/null; then
      echo "✅ action_editor 실행 중 (pid $(pgrep -x action_editor))"
      echo "   콘솔에서 motion_4096.bin 페이지 번호로 재생"
    else
      echo "✗ action_editor 시작 실패"
      tail -30 /tmp/df-action.log 2>/dev/null
      exit 1
    fi
    """#

    public static let actionDemoStop: String = demoStop

    // MARK: - Phase B: demo 소스 패치 + 자동 모드 진입 (Sprint 18)
    //
    // 동기: ROBOTIS 공식 demo 는 `StatusCheck::m_cur_mode = READY` 로 시작하고,
    // 모드/시작은 CM-740 후면 MODE/START 버튼으로만 전환됨. Mac UI 에서
    // "공 자동 추적" 클릭만으로 진짜 SOCCER 모드 진입을 시키려면 demo 소스
    // 시작부에 한 블록을 삽입한 binary (`demo-pilot`) 가 필요.
    //
    // 메커니즘:
    //   1. Mac 앱이 `/tmp/df-pilot-mode` 에 모드 문자열 작성 ("soccer"/"motion"/"vision").
    //   2. `demo-pilot` 가 시작 시 그 파일을 read → m_cur_mode + m_is_started=1 자동 set.
    //   3. demo 내부 main loop 가 normal soccer/motion/vision 핸들러 진입.
    //   4. 사용자가 후면 MODE 버튼 누르면 표준 ROBOTIS 흐름으로 모드 전환 — 우리 패치
    //      는 START 까지만 자동, 그 후 버튼은 원본 그대로 작동.
    //
    // 한 번 빌드 후 영구 — `demoBuildPatched` 는 처음 1회만, 그 후엔 `ballTrackerStart`
    // 가 `demo-pilot` 우선 탐색하여 즉시 사용.

    /// patched main.cpp 에 삽입할 injection 블록. main.cpp 의 `MotionManager::GetInstance()
    /// ->LoadINISettings(ini);` 다음 줄에 sed 로 끼워넣음. StatusCheck.cpp 의 BTN_MODE +
    /// BTN_START 핸들러 (97-160 라인) 를 그대로 재현 — Reinitialize / SetEnable / walk-ready
    /// motion (page 9) / gyro calibration / mp3 안내 모두 포함.
    private static let demoInjectBlock: String = #"""

    // === DarwinForge Pilot v1.5 — Phase B/D auto-mode injection ===
    // 출처: docs/handoff/2026-05-13 + StatusCheck.cpp:75-160 (ROBOTIS 공식 BTN 핸들러 재현).
    // 파일 `/tmp/df-pilot-mode` 에 모드 문자열이 있으면 demo 시작 시 자동 모드 진입.
    // 각 단계 종료 시 `/tmp/df-pilot-progress` 에 stage id 작성 → Mac UI sync.
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

            // 진행 상태 파일 helper — Mac UI 의 step driver 가 polling.
            #define DF_PROGRESS(stage) do { \
                FILE* dfP = fopen("/tmp/df-pilot-progress", "w"); \
                if (dfP) { fprintf(dfP, "%s\n", (stage)); fclose(dfP); } \
                fprintf(stderr, "[df-pilot] progress=%s\n", (stage)); \
            } while(0)

            int dfTarget = -1;
            const char* dfMp3Mode = NULL;
            const char* dfMp3Start = NULL;
            unsigned char dfLed = 0;
            if (strcmp(dfBuf, "soccer") == 0) {
                dfTarget = SOCCER;
                dfMp3Mode  = "../../../Data/mp3/Autonomous soccer mode.mp3";
                dfMp3Start = "../../../Data/mp3/Start soccer demonstration.mp3";
                dfLed = 0x01;
            } else if (strcmp(dfBuf, "motion") == 0) {
                dfTarget = MOTION;
                dfMp3Mode  = "../../../Data/mp3/Interactive motion mode.mp3";
                dfMp3Start = "../../../Data/mp3/Start motion demonstration.mp3";
                dfLed = 0x02;
            } else if (strcmp(dfBuf, "vision") == 0) {
                dfTarget = VISION;
                dfMp3Mode  = "../../../Data/mp3/Vision processing mode.mp3";
                dfMp3Start = "../../../Data/mp3/Start vision processing demonstration.mp3";
                dfLed = 0x04;
            } else if (strcmp(dfBuf, "walklab") == 0) {
                // === WalkLab ROBOTIS onboard brokerage (DarwinForge 2026-05-31) ===
                // Mac DarwinForge 의 `.robotisOnboard` 엔진 경로. 공식 Walking::GetInstance()
                // (8ms/125Hz CPG + 루프 내 자이로 밸런스 — ball-tracker 와 동일 메커니즘)을
                // 로봇에서 직접 구동하고, Mac 은 `/tmp/df-walklab-cmd` 로 X/Y/A 만 보내는
                // 얇은 원격이 된다. 준비 시퀀스는 SOCCER 분기와 동일(모션 enable / walk-ready
                // page 9 / 자이로 캘리브레이션) — 그 뒤 브로커리지 무한 루프가 SOCCER 메인
                // 루프를 대체한다. 이 분기는 `WalkLabBrokerage.h` 가 build 시 main.cpp 에
                // include 되어 있어야 한다(demoBuildPatched 가 주입).
                fprintf(stderr, "[df-pilot] auto-mode: walklab (ROBOTIS onboard brokerage, switch fix)\n");
                DF_PROGRESS("walklab-init");
                cm730.WriteByte(CM730::P_LED_PANNEL, 0x05, NULL);
                LinuxActionScript::PlayMP3((char*)"../../../Data/mp3/Autonomous soccer mode.mp3");
                usleep(500*1000);
                MotionManager::GetInstance()->Reinitialize();
                MotionManager::GetInstance()->SetEnable(true);
                Action::GetInstance()->m_Joint.SetEnableBody(true, true);
                DF_PROGRESS("walk-ready");
                Action::GetInstance()->Start(9);   // walk-ready 자세 (page 9)
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
                // 공식 gait 엔진 준비 — 주입점이 원본 Walking::Initialize() 앞일 수 있어
                // 명시 호출(idempotent). 이후 브로커리지가 Start()/X·Y·A 제어.
                Walking::GetInstance()->Initialize();
                StatusCheck::m_is_started = 1;
                DF_PROGRESS("walklab-active");
                unlink("/tmp/df-pilot-mode");
                fprintf(stderr, "[df-pilot] entering WalkLabBrokerage.Run()\n");
                // C1 (2026-06-12) — DF_RUN_ARGS_PLACEHOLDER 는 demoBuildPatched 가 main.cpp
                // 의 mjpg_streamer 변수 유무를 보고 sed 로 치환: 있으면 (&cm730, streamer)
                // → walklab 중 8080 카메라 펌프 활성, 없으면 (&cm730) 폴백(컴파일 보장).
                Robotis::WalkLabBrokerage().Run(DF_RUN_ARGS_PLACEHOLDER);   // 무한 루프 — SIGTERM 까지. SOCCER 루프 우회.
                return 0;                            // 도달 불가(Run 무한). 방어적.
            }

            if (dfTarget != -1) {
                fprintf(stderr, "[df-pilot] auto-mode: %s\n", dfBuf);
                DF_PROGRESS("auto-soccer-mode");
                StatusCheck::m_cur_mode = dfTarget;
                cm730.WriteByte(CM730::P_LED_PANNEL, dfLed, NULL);
                if (dfMp3Mode) LinuxActionScript::PlayMP3((char*)dfMp3Mode);
                usleep(500*1000);

                MotionManager::GetInstance()->Reinitialize();
                MotionManager::GetInstance()->SetEnable(true);
                Action::GetInstance()->m_Joint.SetEnableBody(true, true);

                if (dfMp3Start) LinuxActionScript::PlayMP3((char*)dfMp3Start);

                if (dfTarget == SOCCER) {
                    DF_PROGRESS("walk-ready");
                    Action::GetInstance()->Start(9);
                    while(Action::GetInstance()->IsRunning() == true) usleep(8000);
                    Head::GetInstance()->m_Joint.SetEnableHeadOnly(true, true);
                    Walking::GetInstance()->m_Joint.SetEnableBodyWithoutHead(true, true);

                    DF_PROGRESS("gyro-calibration");
                    MotionManager::GetInstance()->ResetGyroCalibration();
                    int dfWait = 0;
                    while (dfWait < 30) {
                        int s = MotionManager::GetInstance()->GetCalibrationStatus();
                        if (s == 1) {
                            LinuxActionScript::PlayMP3((char*)"../../../Data/mp3/Sensor calibration complete.mp3");
                            break;
                        }
                        if (s == -1) MotionManager::GetInstance()->ResetGyroCalibration();
                        usleep(100*1000); dfWait++;
                    }
                } else {
                    DF_PROGRESS("walk-ready");
                    Action::GetInstance()->Start(1);
                    while(Action::GetInstance()->IsRunning() == true) usleep(8000);
                }

                StatusCheck::m_is_started = 1;
                fprintf(stderr, "[df-pilot] m_is_started=1 (auto)\n");
                DF_PROGRESS("tracking-active");

                // 한 번 사용한 파일은 삭제 — 다음 재시작 시 의도치 않은 자동 진입 방지.
                unlink("/tmp/df-pilot-mode");
            }
            #undef DF_PROGRESS
        }
    }
    // === end DarwinForge injection ===

    """#

    /// 진행 단계 polling — RemotePilotView 의 step driver 가 1Hz 로 호출.
    /// `/tmp/df-pilot-progress` 의 마지막 stage id 1줄을 표준 marker 로 출력.
    public static let demoProgressRead: String = #"""
    set +e
    if [ -f /tmp/df-pilot-progress ]; then
      STAGE=$(head -1 /tmp/df-pilot-progress 2>/dev/null | tr -d '\r\n')
      echo "DF_STAGE=${STAGE:-unknown}"
    else
      echo "DF_STAGE=none"
    fi
    """#

    /// patch + make + binary 보존을 한 번에 처리하는 helper.
    ///
    /// 동작:
    ///   1. demo 소스 디렉토리 자동 탐색.
    ///   2. 이미 `demo-pilot` 가 있고 main.cpp 가 최신이면 skip (idempotent).
    ///   3. main.cpp 백업 → `MotionManager::GetInstance()->LoadINISettings(ini);` 다음 줄에
    ///      injection 블록 삽입.
    ///   4. `make` → demo binary 생성 → `demo-pilot` 으로 이름 변경.
    ///   5. main.cpp 원본 복구.
    ///   6. `demo-pilot` 실행 권한 확인 + 절대경로 출력.
    public static var demoBuildPatched: String {
        // injection 블록을 robot 측 임시 파일 (/tmp/df_inject.cpp) 에 here-doc 으로 작성.
        // 그 후 sed 의 `r` 명령으로 anchor 다음 줄에 삽입.
        // raw string + variable interpolation 안전성을 위해 EOF_DF_INJECT 마커 사용.
        return #"""
        set +e
        echo "▶ demo 소스 위치 탐색"
        SRC=""
        for d in "$HOME/Framework/Linux/project/demo" \
                 "$HOME/darwin/Linux/project/demo" \
                 "/darwin/Linux/project/demo" \
                 "/robotis/Linux/project/demo"; do
          if [ -f "$d/main.cpp" ] && [ -f "$d/Makefile" ]; then SRC="$d"; break; fi
        done
        if [ -z "$SRC" ]; then
          echo "demo source not found"
          echo "checked: ~/Framework, ~/darwin, /darwin, /robotis"
          exit 1
        fi
        echo "   $SRC"

        # 0) WalkLab brokerage 소스 배치 (onboard walk 분기 컴파일에 필수, 2026-05-31).
        #    injection 블록의 walklab 분기가 Robotis::WalkLabBrokerage 를 참조하므로
        #    이 파일들 + include + OBJECTS 항목이 없으면 빌드 실패한다.
        #    INTEGRATION.md 의 scp 위치(~/walklab-brokerage/) 또는 SRC 에 이미 있으면 사용.
        #    **P7 (2026-06-12)**: WalkLabTransport(O1 — 종전 누락 정정) + GamepadPilot(H1)
        #    동반 배치 — 6파일 전부 있어야 빌드 가능(구버전 ~/walklab-brokerage 는 명확히 거부).
        WLB_SRC=""
        for d in "$HOME/walklab-brokerage" "$SRC"; do
          if [ -f "$d/WalkLabBrokerage.cpp" ] && [ -f "$d/WalkLabBrokerage.h" ]; then WLB_SRC="$d"; break; fi
        done
        if [ -z "$WLB_SRC" ]; then
          echo "✗ WalkLabBrokerage 소스 없음 — onboard walk 빌드 불가."
          echo "   Mac 에서 먼저: scp -r firmware-patches/walklab-brokerage/ darwin@<robot-ip>:~/walklab-brokerage/"
          exit 1
        fi
        for f in WalkLabBrokerage.cpp WalkLabBrokerage.h \
                 WalkLabTransport.cpp WalkLabTransport.h \
                 GamepadPilot.cpp GamepadPilot.h; do
          if [ ! -f "$WLB_SRC/$f" ]; then
            echo "✗ $WLB_SRC/$f 없음 — ~/walklab-brokerage 가 구버전입니다."
            echo "   Mac 에서 재복사: scp -r firmware-patches/walklab-brokerage/ darwin@<robot-ip>:~/walklab-brokerage/"
            exit 1
          fi
          cp -f "$WLB_SRC/$f" "$SRC/$f"
        done
        echo "   WalkLab brokerage 소스 배치(6파일): $WLB_SRC → $SRC"

        # 1) injection 블록 작성.
        cat > /tmp/df_inject.cpp << 'EOF_DF_INJECT'
        \#(demoInjectBlock)
        EOF_DF_INJECT

        # 1b) **C1 (2026-06-12)** — 카메라 스트림: main.cpp 의 mjpg_streamer 지역변수
        #     (streamer)를 brokerage 에 전달해 walklab 중에도 8080 MJPEG 펌프가 돈다.
        #     streamer 변수가 없는 demo 변종은 종전 시그니처로 폴백 — 컴파일 항상 보장.
        if grep -q 'mjpg_streamer\*[[:space:]]*streamer' "$SRC/main.cpp"; then
          sed -i 's/Run(DF_RUN_ARGS_PLACEHOLDER)/Run(\&cm730, streamer)/' /tmp/df_inject.cpp
          echo "   C1: Run(&cm730, streamer) — 카메라 스트림 펌프 활성 주입"
        else
          sed -i 's/Run(DF_RUN_ARGS_PLACEHOLDER)/Run(\&cm730)/' /tmp/df_inject.cpp
          echo "   ⚠ C1: main.cpp 에 mjpg_streamer 변수 없음 — 스트림 없이 폴백"
        fi

        # 2) main.cpp 변경 안 됐으면 — 이미 빌드된 demo-pilot 이 신선한지 확인.
        if [ -x "$SRC/demo-pilot" ] && [ "$SRC/demo-pilot" -nt /tmp/df_inject.cpp ]; then
          echo "✅ demo-pilot 가 이미 빌드돼 있고 최신입니다."
          ls -la "$SRC/demo-pilot"
          exit 0
        fi

        # 3) 백업 + 패치.
        cd "$SRC" || exit 1
        cp -p main.cpp main.cpp.df-orig
        cp -p Makefile Makefile.df-orig
        # anchor: "MotionManager::GetInstance()->LoadINISettings(ini);" 다음 줄에 injection.
        sed -i.df-bak '/MotionManager::GetInstance()->LoadINISettings(ini);/r /tmp/df_inject.cpp' main.cpp

        if ! grep -q "DarwinForge Pilot v1.5" main.cpp; then
          echo "✗ 패치 적용 실패 — anchor 라인 못 찾음"
          cp main.cpp.df-orig main.cpp 2>/dev/null
          exit 1
        fi

        # walklab 분기 컴파일 의존성: include + OBJECTS (idempotent).
        grep -q 'WalkLabBrokerage.h' main.cpp || \
          sed -i '/#include "StatusCheck.h"/a #include "WalkLabBrokerage.h"' main.cpp
        if ! grep -q 'WalkLabBrokerage.h' main.cpp; then
          echo "✗ include 주입 실패 — StatusCheck.h anchor 못 찾음"
          cp main.cpp.df-orig main.cpp; exit 1
        fi
        # GNU Make 암묵 규칙(%.o:%.cpp, CXXFLAGS 에 INCLUDE_DIRS)이 컴파일 — OBJECTS 등록만.
        # P7: WalkLabTransport.o(O1 — 종전 누락 정정) + GamepadPilot.o(H1) 동반 등록(멱등).
        grep -q 'WalkLabBrokerage.o' Makefile || \
          sed -i 's/^OBJECTS = \(.*\)$/OBJECTS = \1 WalkLabBrokerage.o/' Makefile
        grep -q 'WalkLabTransport.o' Makefile || \
          sed -i 's/^OBJECTS = \(.*\)$/OBJECTS = \1 WalkLabTransport.o/' Makefile
        grep -q 'GamepadPilot.o' Makefile || \
          sed -i 's/^OBJECTS = \(.*\)$/OBJECTS = \1 GamepadPilot.o/' Makefile

        # 4) make + binary 이름 보존.
        echo "▶ make"
        make clean >/dev/null 2>&1
        if ! make 2>&1 | tail -5; then
          echo "✗ 빌드 실패 — 원본 복구"
          cp main.cpp.df-orig main.cpp
          exit 1
        fi

        if [ -x demo ]; then
          mv demo demo-pilot
          chmod 755 demo-pilot
          echo "✅ demo-pilot 빌드 완료 → $SRC/demo-pilot"
        else
          echo "✗ demo binary 생성되지 않음"
          cp main.cpp.df-orig main.cpp
          exit 1
        fi

        # 5) main.cpp + Makefile 원본 복구 — 추후 사용자가 원본 demo 도 다시 빌드 가능.
        #    (demo-pilot 바이너리는 이미 링크 완료 — 복구해도 영향 없음.)
        cp main.cpp.df-orig main.cpp
        [ -f Makefile.df-orig ] && cp Makefile.df-orig Makefile && rm -f Makefile.df-orig
        rm -f main.cpp.df-bak /tmp/df_inject.cpp
        echo "▶ 원본 main.cpp / Makefile 복구 완료"
        echo
        echo "이제 Mac DarwinForge → 원격 조종 → '공 자동 추적' 한 번 클릭으로 SOCCER 자동 진입."
        """#
    }

    /// patched binary 제거 — 원상 복구.
    public static let demoRemovePatched: String = #"""
    set +e
    REMOVED=0
    for d in "$HOME/Framework/Linux/project/demo" \
             "$HOME/darwin/Linux/project/demo" \
             "/darwin/Linux/project/demo" \
             "/robotis/Linux/project/demo"; do
      if [ -f "$d/demo-pilot" ]; then
        sudo killall demo-pilot 2>/dev/null
        rm -f "$d/demo-pilot"
        rm -f "$d/main.cpp.df-orig" "$d/main.cpp.df-bak"
        echo "✅ removed $d/demo-pilot"
        REMOVED=1
      fi
    done
    rm -f /tmp/df-pilot-mode /tmp/df_inject.cpp
    if [ "$REMOVED" = "0" ]; then
      echo "ℹ️  설치된 demo-pilot 없음"
    fi
    """#

    /// patched binary 가 설치돼 있는지 확인.
    // MARK: - HSV Vision config sync (Sprint 18 Phase E, Codex 잔여 3 v1.5 minimal viable)

    /// robot 측 config.ini 의 vision color 섹션 read.
    ///
    /// 탐색 위치 (정직성 — ROBOTIS 표준 layout):
    ///   - ~/Framework/Data/config.ini   (Framework default)
    ///   - ~/darwin/Data/config.ini
    ///   - /darwin/Data/config.ini
    ///   - ~/Framework/Linux/project/demo/config.ini   (demo 전용)
    ///
    /// 출력 contract — 한 줄씩 머신 파싱 가능:
    ///   `DF_HSV_<TAG>=hue=<h>,tolerance=<t>,min_saturation=<s>,min_value=<v>,min_percent=<mp>,max_percent=<xp>`
    /// 값은 ROBOTIS ini 의 raw 형식 그대로 — sat/val 은 0-100 정수.
    public static let readVisionConfig: String = #"""
    set +e
    INI=""
    for path in "$HOME/Framework/Data/config.ini" \
                "$HOME/darwin/Data/config.ini" \
                "/darwin/Data/config.ini" \
                "$HOME/Framework/Linux/project/demo/config.ini" \
                "$HOME/Framework/Linux/project/tutorial/color_filtering/config.ini" \
                "$HOME/Framework/Linux/project/tutorial/head_tracking/config.ini"; do
      if [ -f "$path" ]; then INI="$path"; break; fi
    done
    if [ -z "$INI" ]; then
      echo "DF_HSV_ERROR=ini not found"
      echo "checked: ~/Framework/Data, ~/darwin/Data, /darwin/Data, demo/, tutorial/color_filtering/, tutorial/head_tracking/"
      exit 1
    fi
    echo "DF_HSV_INI=$INI"

    # awk helper — 한 섹션의 한 키 read.
    read_key() {
      local sec="$1" key="$2"
      awk -v sec="[$sec]" -v key="$key" '
        $0 == sec { in_sec=1; next }
        /^\[/ { in_sec=0 }
        in_sec && $0 ~ ("^" key " *=") {
          gsub(".*= *", "")
          gsub(" .*", "")
          print
          exit
        }
      ' "$INI" 2>/dev/null
    }

    # ROBOTIS ColorFinder.h:106-111 의 6개 키 전부 read.
    # [ORANGE] 가 없을 수도 — color_filtering 의 [Find Color] 가 default ball.
    for TAG in ORANGE RED YELLOW BLUE; do
      H=$(read_key "$TAG" hue)
      T=$(read_key "$TAG" hue_tolerance)
      S=$(read_key "$TAG" min_saturation)
      V=$(read_key "$TAG" min_value)
      MP=$(read_key "$TAG" min_percent)
      XP=$(read_key "$TAG" max_percent)
      # ORANGE 가 비어 있고 TAG==ORANGE 면 [Find Color] 시도.
      if [ "$TAG" = "ORANGE" ] && [ -z "$H" ]; then
        H=$(read_key "Find Color" hue)
        T=$(read_key "Find Color" hue_tolerance)
        S=$(read_key "Find Color" min_saturation)
        V=$(read_key "Find Color" min_value)
        MP=$(read_key "Find Color" min_percent)
        XP=$(read_key "Find Color" max_percent)
      fi
      [ -z "$H" ] && H="?"
      [ -z "$T" ] && T="?"
      [ -z "$S" ] && S="?"
      [ -z "$V" ] && V="?"
      [ -z "$MP" ] && MP="?"
      [ -z "$XP" ] && XP="?"
      echo "DF_HSV_${TAG}=hue=$H,tolerance=$T,min_saturation=$S,min_value=$V,min_percent=$MP,max_percent=$XP"
    done
    """#

    /// robot 측 config.ini 의 vision color 섹션 write.
    ///
    /// **사용법** (Phase F1, 2026-05-14): Mac UI 가 `DF_ARGS` 환경변수로
    /// `7×4=28` 토큰 전달 — `TAG hue tol sat val min_pct max_pct` × 4색.
    /// 예: `DF_ARGS="ORANGE 355 15 60 15 0.10 50.00 RED 0 15 45 0 0.30 50.00 ..."`.
    ///
    /// **ROBOTIS ini 호환**: sat/val 은 0-100 정수, min/max_pct 는 float (ColorFinder.h:106-111).
    public static let writeVisionConfig: String = #"""
    set +e
    INI=""
    for path in "$HOME/Framework/Data/config.ini" \
                "$HOME/darwin/Data/config.ini" \
                "/darwin/Data/config.ini" \
                "$HOME/Framework/Linux/project/demo/config.ini"; do
      if [ -f "$path" ]; then INI="$path"; break; fi
    done
    if [ -z "$INI" ]; then
      echo "DF_HSV_ERROR=ini not found"
      exit 1
    fi

    cp "$INI" "$INI.df-bak.$(date +%s)"
    echo "▶ backup: $INI.df-bak"

    if [ -z "$DF_ARGS" ]; then
      echo "DF_HSV_ERROR=no DF_ARGS env"
      exit 1
    fi

    # DF_ARGS 의 7-토큰 (tag h t s v mp xp) 그룹 처리 — Phase F1 ROBOTIS 6키 완전 동기화.
    set -- $DF_ARGS
    while [ $# -ge 7 ]; do
      TAG="$1"; H="$2"; T="$3"; S="$4"; V="$5"; MP="$6"; XP="$7"
      shift 7
      awk -v tag="[$TAG]" -v h="$H" -v t="$T" -v s="$S" -v v="$V" -v mp="$MP" -v xp="$XP" '
        $0 == tag { in_sec=1; print; next }
        /^\[/ { in_sec=0 }
        in_sec && /^hue *=/ { print "hue = " h; next }
        in_sec && /^hue_tolerance *=/ { print "hue_tolerance = " t; next }
        in_sec && /^min_saturation *=/ { print "min_saturation = " s; next }
        in_sec && /^min_value *=/ { print "min_value = " v; next }
        in_sec && /^min_percent *=/ { print "min_percent = " mp; next }
        in_sec && /^max_percent *=/ { print "max_percent = " xp; next }
        { print }
      ' "$INI" > "$INI.tmp" && mv "$INI.tmp" "$INI"
      echo "DF_HSV_WROTE=$TAG"
    done

    echo "✅ vision config 저장 완료 — ROBOTIS demo 다시 시작해야 반영됨."
    """#

    public static let demoPatchedStatus: String = #"""
    set +e
    FOUND=""
    for d in "$HOME/Framework/Linux/project/demo" \
             "$HOME/darwin/Linux/project/demo" \
             "/darwin/Linux/project/demo" \
             "/robotis/Linux/project/demo"; do
      if [ -x "$d/demo-pilot" ]; then FOUND="$d/demo-pilot"; break; fi
    done
    if [ -n "$FOUND" ]; then
      echo "DF_PATCH=installed"
      echo "path: $FOUND"
      ls -la "$FOUND"
    else
      echo "DF_PATCH=missing"
      echo "→ '패치 demo 빌드' 명령으로 1회 설치"
    fi
    """#

    /// 🎯 마스터 셋업 — 로봇 VNC 터미널에서 한 번만 붙여넣으면 4가지 영구 등록.
    ///
    /// 처리:
    ///   1. openssh-server 설치 + 부팅 자동 시작 → 포트 22 영구 활성
    ///   2. socat 설치 + forge-bridge init.d 등록 → TCP 5530 영구 활성
    ///   3. df-inbox watcher init.d 등록 → SMB watcher 영구 활성
    ///   4. dialout 그룹 + 모든 권한 정리
    ///
    /// 결과: 로봇 재부팅 후 어떤 수동 작업도 필요 없음. DarwinForge 자동 연결 즉시 동작.
    public static let masterSetup: String = #"""
    # ── DarwinForge 마스터 셋업 (한 번 실행) ──────────────────
    # SSH + forge-bridge(5530) + df-inbox 모두 영구 등록.
    set +e
    # sudo 비밀번호 한 번 캐시 — 이후 모든 sudo 가 prompt 없이 진행.
    echo "▶ sudo 비밀번호 한 번 입력 (이후 자동 진행)"
    sudo -v
    # 백그라운드로 sudo 캐시 유지.
    while true; do sudo -n true; sleep 50; kill -0 $$ 2>/dev/null || exit; done 2>/dev/null &
    SUDOKEEP=$!
    trap "kill $SUDOKEEP 2>/dev/null" EXIT

    echo "▶ 1/6 EOL 저장소 자동 보정 (Ubuntu 12.04/14.04)"
    if grep -qE "(precise|trusty)" /etc/os-release 2>/dev/null || \
       lsb_release -c 2>/dev/null | grep -qE "(precise|trusty)"; then
      sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%s) 2>/dev/null
      sudo sed -i 's|http://[a-z.]*archive\.ubuntu\.com|http://old-releases.ubuntu.com|g;
                    s|http://security\.ubuntu\.com|http://old-releases.ubuntu.com|g;
                    s|http://ftp\.[a-z.]*/ubuntu|http://old-releases.ubuntu.com/ubuntu|g' \
                    /etc/apt/sources.list 2>/dev/null
    fi
    sudo apt-get update -qq 2>/dev/null

    echo "▶ 2/6 필수 패키지 설치 (socat + openssh-server)"
    sudo apt-get install -y --force-yes socat openssh-server 2>/dev/null
    sudo usermod -aG dialout $USER 2>/dev/null

    echo "▶ 3/6 SSH 영구 활성"
    sudo service ssh start 2>/dev/null
    sudo update-rc.d ssh defaults 2>/dev/null

    echo "▶ 4/6 forge-bridge (TCP 5530) 영구 활성"
    sudo bash -c 'cat > /etc/init.d/forge-bridge << "EOF"
    #!/bin/sh
    ### BEGIN INIT INFO
    # Provides:          forge-bridge
    # Required-Start:    $network $local_fs
    # Default-Start:     2 3 4 5
    # Default-Stop:      0 1 6
    # Short-Description: DarwinForge USB-TCP bridge
    ### END INIT INFO
    case "$1" in
      start)
        stty -F /dev/ttyUSB0 1000000 raw -echo 2>/dev/null
        /usr/bin/socat tcp-l:5530,reuseaddr,fork,nodelay open:/dev/ttyUSB0,nonblock=0 &
        echo $! > /var/run/forge-bridge.pid
        ;;
      stop)   [ -f /var/run/forge-bridge.pid ] && kill $(cat /var/run/forge-bridge.pid) 2>/dev/null ;;
      status)
        if pgrep -f "socat.*5530" >/dev/null; then echo "running"; else echo "stopped"; fi ;;
    esac
    EOF'
    sudo chmod +x /etc/init.d/forge-bridge
    sudo update-rc.d forge-bridge defaults 2>/dev/null
    sudo killall -q socat 2>/dev/null
    sudo /etc/init.d/forge-bridge start

    echo "▶ 5/6 df-inbox watcher (SMB 원격 명령 채널) 영구 활성"
    mkdir -p $HOME/.df_inbox $HOME/.df_outbox
    chmod 777 $HOME/.df_inbox $HOME/.df_outbox
    sudo bash -c 'cat > /etc/init.d/df-inbox << "EOF"
    #!/bin/sh
    ### BEGIN INIT INFO
    # Provides:          df-inbox
    # Required-Start:    $local_fs $remote_fs
    # Default-Start:     2 3 4 5
    # Default-Stop:      0 1 6
    ### END INIT INFO
    USER_HOME=/home/robotis
    INBOX="$USER_HOME/.df_inbox"
    OUTBOX="$USER_HOME/.df_outbox"
    PIDFILE=/var/run/df-inbox.pid
    case "$1" in
      start)
        mkdir -p "$INBOX" "$OUTBOX"
        chmod 777 "$INBOX" "$OUTBOX"
        chown robotis:robotis "$INBOX" "$OUTBOX" 2>/dev/null
        (
          while true; do
            for f in "$INBOX"/*.sh; do
              [ -f "$f" ] || continue
              name=$(basename "$f" .sh)
              out=$(su - robotis -c "bash $f" 2>&1)
              rc=$?
              printf "%s\n--- exit %d ---\n" "$out" "$rc" > "$OUTBOX/$name.out"
              chown robotis:robotis "$OUTBOX/$name.out" 2>/dev/null
              mv "$f" "$f.done"
            done
            sleep 2
          done
        ) &
        echo $! > "$PIDFILE"
        ;;
      stop)   [ -f "$PIDFILE" ] && kill $(cat "$PIDFILE") 2>/dev/null ;;
      status)
        if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
          echo "running"
        else echo "stopped"; fi ;;
    esac
    EOF'
    sudo chmod +x /etc/init.d/df-inbox
    sudo update-rc.d df-inbox defaults 2>/dev/null
    sudo /etc/init.d/df-inbox start

    echo "▶ 6/6 검증"
    sleep 1
    printf "  SSH (22):          "; pgrep -f sshd >/dev/null && echo "✅ running" || echo "❌"
    printf "  forge-bridge (5530): "; sudo /etc/init.d/forge-bridge status 2>/dev/null
    printf "  df-inbox:          "; sudo /etc/init.d/df-inbox status 2>/dev/null
    printf "  /dev/ttyUSB0:      "; [ -e /dev/ttyUSB0 ] && echo "✅ 존재" || echo "❌"
    echo
    echo "🎉 마스터 셋업 완료. Mac DarwinForge로 돌아가서 다음 단계 진행."
    """#

    /// **사이클 131 (audit #22, P0 safety)**: masterSetup rollback 스크립트.
    /// masterSetup 중 일부 단계 실패 시 또는 사용자가 시스템 원상복구 필요 시 실행.
    ///
    /// 종전 masterSetup 은 `set +e` 로 에러 무시 — 단계 3 (SSH) 성공 후 단계 5 (df-inbox)
    /// 실패 시 partial state (SSH 활성 + bridge 미설정 + df-inbox 부분 활성) 잔존.
    /// 본 스크립트는 모든 4가지 영구 등록 항목을 명시 해제 + 검증.
    ///
    /// **안전 정책**: rollback 도 `set +e` — 부분 실패해도 진행 (이미 stop 한 서비스 등).
    /// 사용자가 명시 실행해야 함 (자동 trigger X) — masterSetup 의 verification 화면에
    /// "rollback 필요 시 복사" 버튼 노출 권장.
    public static let masterSetupRollback: String = #"""
    # ── DarwinForge 마스터 셋업 rollback (수동 실행) ──
    # masterSetup 으로 등록된 4가지 영구 항목을 모두 해제.
    set +e
    echo "▶ 1/4 forge-bridge 서비스 정지 + 부팅 자동시작 해제"
    sudo /etc/init.d/forge-bridge stop 2>/dev/null
    sudo update-rc.d -f forge-bridge remove 2>/dev/null
    sudo rm -f /etc/init.d/forge-bridge /var/run/forge-bridge.pid

    echo "▶ 2/4 df-inbox watcher 정지 + 부팅 자동시작 해제"
    sudo /etc/init.d/df-inbox stop 2>/dev/null
    sudo update-rc.d -f df-inbox remove 2>/dev/null
    sudo rm -f /etc/init.d/df-inbox

    echo "▶ 3/4 inbox/outbox 디렉토리 보존 (사용자 데이터 — 수동 삭제 권장)"
    echo "   필요 시: rm -rf \$HOME/.df_inbox \$HOME/.df_outbox"

    echo "▶ 4/4 SSH/dialout 보존 — 다른 용도로 쓰일 수 있어 자동 해제 안 함"
    echo "   완전 원상복구 필요 시:"
    echo "     sudo service ssh stop"
    echo "     sudo update-rc.d -f ssh remove"
    echo "     sudo gpasswd -d \$USER dialout"

    echo
    echo "🔄 rollback 완료. forge-bridge / df-inbox 서비스 해제됨."
    echo "   재설치 필요 시 masterSetup 다시 실행."
    """#

    // MARK: - Remote command channel (SMB-based)

    /// 로봇 측 inbox watcher 셋업 — SMB로 떨어트린 .sh 파일을 자동 실행 + 결과 outbox에.
    ///
    /// 동작:
    ///   - `$HOME/.df_inbox` 에 새 `.sh` 파일이 생기면 2초 내 감지 → 실행 → 결과 `.out` 으로.
    ///   - `$HOME/.df_outbox/<name>.out` 에 stdout+stderr + exit code 저장.
    ///   - 실행 끝난 .sh 는 `.done` 접미사로 옮겨져 재실행 방지.
    ///   - 의존성 없음 (bash + sleep + mv 만 사용).
    ///   - 부팅 시 자동 시작 (init.d 등록).
    public static let remoteShellSetup: String = #"""
    # ── DarwinForge Remote Shell — SMB 기반 명령 채널 ──
    # Mac DarwinForge에서 작성한 .sh 를 자동 실행하고 결과를 돌려줍니다.
    set +e
    INBOX=$HOME/.df_inbox
    OUTBOX=$HOME/.df_outbox
    mkdir -p "$INBOX" "$OUTBOX"
    chmod 777 "$INBOX" "$OUTBOX"

    # 1) 사용자 home 이 SMB로 접근 가능한지 확인 — Samba [homes] share 활성화 권장.
    if ! grep -q "^\[homes\]" /etc/samba/smb.conf 2>/dev/null; then
      echo "  ⚠️  Samba [homes] share 비활성 — SMB로 home 접근 안 될 수 있어요."
      echo "     필요 시: sudo sed -i 's/^# *\[homes\]/[homes]/' /etc/samba/smb.conf"
      echo "     그리고: sudo service smbd restart"
    fi

    # 2) inbox watcher daemon — bash polling (의존성 없음).
    sudo bash -c 'cat > /etc/init.d/df-inbox << "EOF"
    #!/bin/sh
    ### BEGIN INIT INFO
    # Provides:          df-inbox
    # Required-Start:    $local_fs $remote_fs
    # Required-Stop:     $local_fs $remote_fs
    # Default-Start:     2 3 4 5
    # Default-Stop:      0 1 6
    # Short-Description: DarwinForge remote command inbox watcher
    ### END INIT INFO

    USER_HOME=/home/robotis
    INBOX="$USER_HOME/.df_inbox"
    OUTBOX="$USER_HOME/.df_outbox"
    PIDFILE=/var/run/df-inbox.pid

    case "$1" in
      start)
        mkdir -p "$INBOX" "$OUTBOX"
        chmod 777 "$INBOX" "$OUTBOX"
        chown robotis:robotis "$INBOX" "$OUTBOX" 2>/dev/null
        (
          while true; do
            for f in "$INBOX"/*.sh; do
              [ -f "$f" ] || continue
              name=$(basename "$f" .sh)
              out=$(su - robotis -c "bash $f" 2>&1)
              rc=$?
              printf "%s\n--- exit %d ---\n" "$out" "$rc" > "$OUTBOX/$name.out"
              chown robotis:robotis "$OUTBOX/$name.out" 2>/dev/null
              mv "$f" "$f.done"
            done
            sleep 2
          done
        ) &
        echo $! > "$PIDFILE"
        echo "df-inbox started (pid $(cat $PIDFILE))"
        ;;
      stop)
        [ -f "$PIDFILE" ] && kill $(cat "$PIDFILE") 2>/dev/null
        rm -f "$PIDFILE"
        ;;
      status)
        if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
          echo "running (pid $(cat $PIDFILE))"
        else
          echo "stopped"
        fi
        ;;
      *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
    esac
    EOF'
    sudo chmod +x /etc/init.d/df-inbox
    sudo update-rc.d df-inbox defaults 2>/dev/null
    sudo killall -q -f "df-inbox" 2>/dev/null
    sudo /etc/init.d/df-inbox start

    # 3) 검증
    sleep 1
    sudo /etc/init.d/df-inbox status
    echo
    echo "✅ Remote shell 셋업 완료. Mac DarwinForge → '원격 명령' 패널에서 사용."
    echo "   Inbox:  $INBOX"
    echo "   Outbox: $OUTBOX"
    """#

    // MARK: - SSH ↔ LAN parity (2026-06-01) — E-STOP · telemetry · mode persist/verify
    //
    // onboard(SSH) 경로가 wired-LAN(5530 bridge) 경로와 동일 기능을 갖게 하는 robot-side
    // helper 묶음. 모두 docs/ssh-parity-contract.md §B / §D.4 에 PINNED 된 문자열·동작.
    //
    // robot 은 service/killall/demo/reboot 에 대해 NOPASSWD sudo 를 가진다 (마스터 셋업 가정).

    /// **SSH E-STOP** — `/tmp/df-walklab-estop` flag 생성 + `demo`/`demo-pilot` SIGTERM.
    ///
    /// 의미: 파일의 *존재* = STOP (명령 큐 아님). robot 의 `Run()` poll loop 가 매 200ms
    /// 이 flag 를 확인 → `Walking::Stop()` + body torque OFF. `killall -TERM` 은 belt-and-
    /// suspenders 병렬 보험 (SIGTERM 핸들러가 gait 즉시 정지).
    /// **codex CRITICAL fix (2026-06-02)**: 종전엔 `touch` 실패(권한/RO-FS)에도 무조건
    /// `echo ESTOP_OK` 라 Mac 이 거짓으로 "정지됨"으로 신뢰했다. flag 가 *실제로 존재*할 때만
    /// `ESTOP_OK`, 아니면 `ESTOP_FAIL` 을 echo → Mac 이 전달 실패를 감지해 경고/물리개입 안내.
    public static let walkLabRobotisEstop: String =
        "touch /tmp/df-walklab-estop 2>/dev/null; sudo killall -TERM demo demo-pilot 2>/dev/null; [ -f /tmp/df-walklab-estop ] && echo ESTOP_OK || echo ESTOP_FAIL"

    /// **텔레메트리 1줄 read** — robot 이 5Hz 로 쓰는 `/tmp/df-walklab-telemetry` 의 최신 줄
    /// (또는 빈 문자열). `OnboardTelemetryPoller` 가 주기적으로 이 명령을 SSH 로 보내고
    /// 결과를 `OnboardTelemetry.parse` 로 파싱한다. (contract §A.3 / §D.4 — 문자열 PINNED)
    public static let walkLabReadTelemetry: String =
        "cat /tmp/df-walklab-telemetry 2>/dev/null"

    /// **E-stop flag 제거 (re-arm)** — 사용자가 명시적 복구/재무장 시 또는 onboard 재시작 시.
    /// `walkLabRobotisStart` 가 이미 시작 시 `rm -f` 를 수행하므로 이건 명시적 복구 버튼용.
    /// (contract §B REMOVER / §D.4 — 문자열 PINNED)
    /// **실기 F1 (2026-06-12)**: rm 실패(타 소유자 flag — sticky /tmp)에도 무조건 CLEARED 를
    /// echo 해 Mac 이 재무장 성공으로 오인했다. flag 가 *실제로 사라졌을 때만* CLEARED.
    public static let walkLabClearEstop: String =
        "rm -f /tmp/df-walklab-estop 2>/dev/null; [ ! -f /tmp/df-walklab-estop ] && echo CLEARED || echo CLEAR_FAIL"

    /// **bus 선점 (실기 F6, 2026-06-12)** — LAN(5530) 연결 직전 로봇측 버스 사용자 정리.
    ///
    /// 근거: CM730 시리얼은 단일 소유인데 demo(walklab 포함)가 8ms 벌크리드로 bus 를 읽는
    /// 동안 Mac `boardSnapshot` 의 응답 바이트를 가로채 LAN 연결이 "연결 중"에서 사실상
    /// 무한 대기했다(실기 재현). 마법사의 5530 TCP 프로브는 socat accept 만 봐서 초록 —
    /// 버스 경합은 보이지 않는다. **DarwinForge 연결 시도가 최상위 소유자**: demo 류 전부
    /// 정지 → forge-bridge(socat) 보장 → 그 다음에야 Bus open. (killall/service NOPASSWD
    /// sudo 가정 — 마스터 셋업. SSH 미가용 환경은 호출측에서 best-effort 스킵.)
    /// 출력 마커: `DF_BUS_PREEMPT=ok|busy_process_alive|bridge_down` → `parseBusPreempt`.
    public static let busPreemptTakeover: String = #"""
    set +e
    echo "▶ DarwinForge bus 선점 — 로봇측 버스 사용자 정지"
    sudo -n killall demo demo-pilot walk_demo walk_tuner action_editor ball_follower vision_demo camera_tutorial 2>/dev/null
    for i in $(seq 1 20); do
      pgrep -x demo >/dev/null 2>&1 || pgrep -x demo-pilot >/dev/null 2>&1 || break
      sleep 0.2
    done
    if pgrep -x demo >/dev/null 2>&1 || pgrep -x demo-pilot >/dev/null 2>&1; then
      echo "DF_BUS_PREEMPT=busy_process_alive"
      exit 5
    fi
    if ! pgrep -f "socat.*5530" >/dev/null 2>&1; then
      sudo -n service forge-bridge start >/dev/null 2>&1
      sleep 0.5
    fi
    if pgrep -f "socat.*5530" >/dev/null 2>&1; then
      echo "DF_BUS_PREEMPT=ok"
    else
      echo "DF_BUS_PREEMPT=bridge_down"
      exit 6
    fi
    """#

    /// `busPreemptTakeover` 출력 해석 결과.
    public enum BusPreemptResult: String, Sendable {
        case ok
        case busyProcessAlive = "busy_process_alive"
        case bridgeDown = "bridge_down"
        case unknown
    }

    /// `busPreemptTakeover` stdout 의 마지막 `DF_BUS_PREEMPT=` 마커를 해석 (순수 함수).
    public static func parseBusPreempt(_ output: String) -> BusPreemptResult {
        for line in output.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("DF_BUS_PREEMPT=") else { continue }
            let value = String(trimmed.dropFirst("DF_BUS_PREEMPT=".count))
            return BusPreemptResult(rawValue: value) ?? .unknown
        }
        return .unknown
    }

    /// **walklab 모드 영구 표식 기록** — 재부팅 후에도 connect-time verify 가 모드를 알도록.
    /// PINNED marker file: `~/.config/darwinforge/pilot-mode`, 내용 `walklab`.
    /// (contract §D.4 — 문자열 PINNED)
    public static let walkLabPersistMode: String =
        "mkdir -p ~/.config/darwinforge 2>/dev/null; echo walklab > ~/.config/darwinforge/pilot-mode; echo PERSIST_OK"

    /// **재부팅을 가로질러 walklab 모드 자동 복원** — rc.local 에 1줄 hook 을 idempotent 설치.
    ///
    /// 흐름:
    ///   1. `walkLabPersistMode` 와 동일하게 표식 파일 기록 (현재 세션 즉시 반영).
    ///   2. `/etc/rc.local` 의 `exit 0` 앞에 `df-walklab-restore` 마커가 달린 1줄 삽입 —
    ///      부팅 시 표식 파일이 `walklab` 이면 `demo-pilot` 을 nohup 으로 재시작.
    ///   3. 이미 마커가 있으면 skip (idempotent — 중복 삽입 방지).
    ///
    /// goal #5 (모드 영구 보존 + connect-time 복원) 의 robot-side 절반. Mac 측은 connect
    /// 시 `walkLabVerifyMode` 결과가 `missing` 이면 `walkLabRobotisStart` 를 다시 호출.
    /// service/killall/demo NOPASSWD sudo 가정.
    public static let walkLabPersistModeAcrossReboot: String = #"""
    set +e
    # 1) 현재 세션 표식.
    mkdir -p ~/.config/darwinforge 2>/dev/null
    echo walklab > ~/.config/darwinforge/pilot-mode
    USER_HOME="$HOME"

    # 2) rc.local 보장 (없으면 생성 + 실행권한).
    if [ ! -f /etc/rc.local ]; then
      sudo bash -c 'printf "#!/bin/sh -e\nexit 0\n" > /etc/rc.local'
      sudo chmod +x /etc/rc.local
    fi

    # 3) hook idempotent 삽입 — 마커가 이미 있으면 skip.
    if sudo grep -q "df-walklab-restore" /etc/rc.local 2>/dev/null; then
      echo "REBOOT_PERSIST_OK (already installed)"
    else
      # demo-pilot 후보 경로 탐색 결과를 부팅 시 평가하도록 한 줄 hook 작성.
      HOOK='[ "$(cat '"$USER_HOME"'/.config/darwinforge/pilot-mode 2>/dev/null)" = walklab ] && for d in '"$USER_HOME"'/Framework/Linux/project/demo/demo-pilot '"$USER_HOME"'/darwin/Linux/project/demo/demo-pilot /darwin/Linux/project/demo/demo-pilot /robotis/Linux/project/demo/demo-pilot; do [ -x "$d" ] && { rm -f /tmp/df-walklab-estop; echo walklab > '"$USER_HOME"'/.config/darwinforge/pilot-mode; cd "$(dirname "$d")"; nohup "$d" >/tmp/df-demo.log 2>&1 & break; }; done  # df-walklab-restore'
      # exit 0 앞에 삽입 (없으면 파일 끝에 append).
      if sudo grep -q "^exit 0" /etc/rc.local 2>/dev/null; then
        TMP=$(mktemp 2>/dev/null || echo /tmp/df-rc.tmp)
        sudo awk -v hook="$HOOK" '/^exit 0/ && !done { print hook; done=1 } { print }' /etc/rc.local > "$TMP" 2>/dev/null && sudo cp "$TMP" /etc/rc.local && rm -f "$TMP"
      else
        echo "$HOOK" | sudo tee -a /etc/rc.local >/dev/null
      fi
      echo "REBOOT_PERSIST_OK (installed)"
    fi
    """#

    /// **connect-time 모드 검증** — onboard 브로커리지가 살아있는지 + 어떤 모드인지 보고.
    ///
    /// 출력 contract (첫 줄 marker, Mac 파싱):
    ///   `DF_WALKLAB=active`   — demo/demo-pilot 실행 중 AND walklab 표식/명령 파일 존재
    ///   `DF_WALKLAB=idle`     — 프로세스는 살아있으나 walklab 모드 아님 (e.g. SOCCER)
    ///   `DF_WALKLAB=missing`  — demo 바이너리 미실행 → Mac 이 walkLabRobotisStart 재호출
    /// (contract §D.4 — 출력 marker PINNED)
    public static let walkLabVerifyMode: String = #"""
    set +e
    if pgrep -x demo-pilot >/dev/null 2>&1 || pgrep -x demo >/dev/null 2>&1; then
      # **fix (2026-06-02)**: walklab 브로커리지가 *실제로 동작* 중인지를 **telemetry 신선도**
      # 로 판정한다. 종전엔 영구 marker(~/.config/darwinforge/pilot-mode)나 /tmp/df-walklab-cmd
      # 존재만 봤는데, 둘 다 재부팅(soccer 자동시작) 후에도 잔존해 false-active 를 유발 →
      # 앱이 재시작을 건너뛰고 "연결 중" 고착. walklab 데몬만 telemetry 를 ~5Hz 로 쓰므로
      # 최근 3초 내 갱신됐으면 active, 아니면 idle(soccer 등).
      NOW=$(date +%s 2>/dev/null || echo 0)
      MT=$(stat -c %Y /tmp/df-walklab-telemetry 2>/dev/null || echo 0)
      if [ -f /tmp/df-walklab-telemetry ] && [ "$((NOW - MT))" -le 3 ]; then
        echo "DF_WALKLAB=active"
      else
        echo "DF_WALKLAB=idle"
      fi
    else
      echo "DF_WALKLAB=missing"
    fi
    """#

    /// **WiFi IP 자동 탐지 (2026-06-02)** — 로봇 wlan0 의 IPv4 를 읽어 "WIFI_IP=x.x.x.x" 출력.
    /// 무선 연결 호스트 자동 채움용 (유선 경유 SSH 로 조회). 없으면 "WIFI_IP=".
    public static let readWifiIP: String = #"""
    IP=$(ip -o -4 addr show wlan0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    # 구형 ifconfig 폴백: 출력이 "inet addr:192.168.x.x" 형태라 addr: 접두 제거 (리뷰 codex M2).
    if [ -z "$IP" ]; then IP=$(/sbin/ifconfig wlan0 2>/dev/null | awk '/inet /{print $2}' | sed 's/addr://' | head -1); fi
    echo "WIFI_IP=$IP"
    """#

    /// **LAN(5530) 자동 연결 (2026-06-01)** — "알아서 포트 열어서 연결".
    /// demo(온보드, ttyUSB0 점유)를 종료해 포트를 양보하고, socat 5530 bridge 를 백그라운드로
    /// 시작한 뒤 :5530 listen 을 최대 4초 대기한다. `BRIDGE_OK` 또는 `BRIDGE_FAIL` 출력.
    ///
    /// - sudo: `killall` 만 사용(NOPASSWD 등록됨). socat/stty 는 robotis 가 `dialout` 그룹
    ///   이라 **sudo 불필요** (ttyUSB0 crw-rw---- root:dialout).
    /// - ⚠️ demo 종료 시 SIGTERM 핸들러가 body torque off → 로봇이 풀린다(거치/파지 필요).
    public static let startLanBridge: String = #"""
    set +e
    # 1) 온보드 demo 종료 — ttyUSB0 점유 해제 (LAN bus 와 상호 배타).
    sudo killall -TERM demo demo-pilot 2>/dev/null
    for i in $(seq 1 15); do pgrep -x demo >/dev/null 2>&1 || break; sleep 0.2; done
    rm -f /tmp/df-pilot-mode 2>/dev/null   # LAN 모드 — walklab 표식 제거
    # 2) 이미 listen 중이면 즉시 성공.
    if (netstat -tln 2>/dev/null || ss -tln 2>/dev/null) | grep -q ':5530 '; then echo BRIDGE_OK; exit 0; fi
    # 3) socat bridge 백그라운드 시작 (dialout → sudo 불필요).
    nohup bash -c 'stty -F /dev/ttyUSB0 1000000 raw -echo -echoe -echok -echoctl -echoke -ixon -ixoff -isig -icanon 2>/dev/null; exec socat tcp-l:5530,reuseaddr,fork,nodelay open:/dev/ttyUSB0,nonblock=0' >/tmp/df-bridge.log 2>&1 &
    # 4) :5530 listen 대기 (최대 ~4s).
    for i in $(seq 1 20); do
      if (netstat -tln 2>/dev/null || ss -tln 2>/dev/null) | grep -q ':5530 '; then echo BRIDGE_OK; exit 0; fi
      sleep 0.2
    done
    echo BRIDGE_FAIL
    tail -5 /tmp/df-bridge.log 2>/dev/null
    """#
}
