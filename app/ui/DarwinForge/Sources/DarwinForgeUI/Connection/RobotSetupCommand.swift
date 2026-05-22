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
    sudo killall camera_tutorial demo vision_demo 2>/dev/null

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
        "sudo killall camera_tutorial demo vision_demo 2>/dev/null && echo stopped || echo camera demo not running"

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

    echo "▶ 이전 데모 종료"
    sudo killall demo demo-pilot walk_demo action_editor 2>/dev/null
    sleep 0.3

    echo "▶ demo 시작 → $BIN"
    cd "$(dirname "$BIN")" || exit 1
    sudo nohup "$BIN" >/tmp/df-demo.log 2>&1 &
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
    /// - polling 식: `sscanf(line, "%d %f %f %f %f %f", &en, &x, &y, &a, &p, &f)`
    /// - 미patch 시: `demo-pilot` 가 default SOCCER 모드로 시작 → ball tracker 동작
    public static let walkLabRobotisStart: String = #"""
    set +e
    echo "▶ forge-bridge 종료 (USB bus 해제)"
    sudo killall socat 2>/dev/null
    sleep 0.3

    echo "▶ ROBOTIS demo binary 탐색 (patched 우선)"
    BIN=""
    PATCHED=0
    for d in "$HOME/Framework/Linux/project/demo/demo-pilot" \
             "$HOME/darwin/Linux/project/demo/demo-pilot" \
             "/darwin/Linux/project/demo/demo-pilot" \
             "/robotis/Linux/project/demo/demo-pilot"; do
      if [ -x "$d" ]; then BIN="$d"; PATCHED=1; break; fi
    done
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
      exit 1
    fi

    if [ "$PATCHED" = "1" ]; then
      echo "   patched binary 사용: $BIN"
      echo "walklab" > /tmp/df-pilot-mode
      # 빈 명령 파일 생성 — Mac 측이 x/y/a brokering write.
      : > /tmp/df-walklab-cmd
      chmod 0666 /tmp/df-walklab-cmd 2>/dev/null
      echo "▶ /tmp/df-walklab-cmd 생성 — Mac 측 brokering 준비 완료"
      echo "▶ /tmp/df-pilot-mode = walklab"
    else
      echo "   ⚠️  원본 demo 사용 (patched binary 미설치): $BIN"
      echo "   → WalkLab brokerage 미지원 — SOCCER 기본 모드로 시작됩니다"
      echo "   robot-side patch 적용 후 재시도 권장"
      rm -f /tmp/df-pilot-mode 2>/dev/null
    fi

    echo "▶ 이전 데모 종료"
    sudo killall demo demo-pilot walk_demo action_editor 2>/dev/null
    sleep 0.3

    echo "▶ demo 시작 → $BIN"
    cd "$(dirname "$BIN")" || exit 1
    sudo nohup "$BIN" >/tmp/df-demo.log 2>&1 &
    sleep 1

    PROC=$(pgrep -x "$(basename "$BIN")" 2>/dev/null)
    if [ -n "$PROC" ]; then
      echo "✅ demo 실행 중 (pid $PROC)"
      if [ "$PATCHED" = "1" ]; then
        echo "   WalkLab brokerage 활성 — Mac 측에서 x/y/a 명령 송출"
      else
        echo "   ⚠️  patched binary 없음 — SOCCER 기본 모드 동작"
      fi
      tail -10 /tmp/df-demo.log 2>/dev/null
    else
      echo "✗ demo 시작 실패"
      tail -30 /tmp/df-demo.log 2>/dev/null
      exit 1
    fi
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
        // Bash polling loop: 최대 1.5s 대기 + 50ms 단위 check (안전 margin 충분).
        // 종전 sleep 0.25 는 daemon polling 200ms + 부하 시 부족.
        let pollLoop = "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do sleep 0.05; if [ -s /tmp/df-walklab-ack ]; then cat /tmp/df-walklab-ack; exit 0; fi; done; echo NO_ACK"
        return "printf '%s\\n' '\(fullLine)' > /tmp/df-walklab-cmd.tmp && mv /tmp/df-walklab-cmd.tmp /tmp/df-walklab-cmd && (\(pollLoop))"
    }

    /// **v1.11.16.2 (2026-05-19)**: cmd_id 생성 — UUID prefix 8글자 + millisecond timestamp.
    /// shell-safe ([a-zA-Z0-9_-]) 만 사용. 길이 < 32.
    public static func generateCmdId() -> String {
        let uuid = UUID().uuidString.prefix(8)  // 8 hex chars
        let ts = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000  // 6 digits
        return "c\(ts)_\(uuid)"
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

        # 1) injection 블록 작성.
        cat > /tmp/df_inject.cpp << 'EOF_DF_INJECT'
        \#(demoInjectBlock)
        EOF_DF_INJECT

        # 2) main.cpp 변경 안 됐으면 — 이미 빌드된 demo-pilot 이 신선한지 확인.
        if [ -x "$SRC/demo-pilot" ] && [ "$SRC/demo-pilot" -nt /tmp/df_inject.cpp ]; then
          echo "✅ demo-pilot 가 이미 빌드돼 있고 최신입니다."
          ls -la "$SRC/demo-pilot"
          exit 0
        fi

        # 3) 백업 + 패치.
        cd "$SRC" || exit 1
        cp -p main.cpp main.cpp.df-orig
        # anchor: "MotionManager::GetInstance()->LoadINISettings(ini);" 다음 줄에 injection.
        sed -i.df-bak '/MotionManager::GetInstance()->LoadINISettings(ini);/r /tmp/df_inject.cpp' main.cpp

        if ! grep -q "DarwinForge Pilot v1.5" main.cpp; then
          echo "✗ 패치 적용 실패 — anchor 라인 못 찾음"
          cp main.cpp.df-orig main.cpp 2>/dev/null
          exit 1
        fi

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

        # 5) main.cpp 원본 복구 — 추후 사용자가 원본 demo 도 다시 빌드 가능.
        cp main.cpp.df-orig main.cpp
        rm -f main.cpp.df-bak /tmp/df_inject.cpp
        echo "▶ 원본 main.cpp 복구 완료"
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
}
