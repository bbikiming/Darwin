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
