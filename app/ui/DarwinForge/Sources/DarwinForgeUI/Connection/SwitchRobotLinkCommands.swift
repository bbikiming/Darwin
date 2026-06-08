import Foundation

/// **Switch → Darwin 연결 세팅** 의 셸 명령 단일 source-of-truth (2026-06-07).
///
/// # 배경 / 비유
///
/// Nintendo Switch(Switchroot Ubuntu) 조종석은 로봇에 직접 SSH 로 붙어야 하는데,
/// Switch 에서 `ssh-copy-id` 가 비밀번호 프롬프트에서 멈춘다(네트워크 경로 미확정 +
/// 비대화형 prompt). 반면 **Mac DarwinForge 는 이미 로봇 SSH 에 성공**한다 —
/// 마치 이미 문을 연 사람(Mac)이 다른 사람(Switch)의 열쇠(공개키)를 받아 대신
/// 문 안쪽 열쇠고리(`authorized_keys`)에 걸어주는 것. 그 "대신 걸어주기" 명령들을
/// 한 곳에 모아 셸 인젝션 위험 없이(공개키 single-quote escaping) 구성한다.
///
/// 순수 함수/상수만 — 단위 테스트(`SwitchRobotLinkCommandsTests`)로 고정한다.
/// 실제 실행은 `SwitchRobotLinkSession` 이 Switch 는 `SSHShell.run`, 로봇은 Mac 의
/// 검증된 `RemoteShell` 경로로 위임한다(새 SSH 옵션을 만들지 않는다).
public enum SwitchRobotLinkCommands {

    /// Switch 에 설치된 robot-ready CLI 경로(`/usr/local/bin/darwin-switch-robot-ready`).
    public static let robotReadyBin = "darwin-switch-robot-ready"

    /// Switch 내부 로봇 전용 키 경로 — robot-ready 의 기본값과 일치.
    public static let switchIdentity = "~/.ssh/id_rsa_darwin"
    public static let switchPublicKeyPath = "~/.ssh/id_rsa_darwin.pub"

    // MARK: - Switch-side 명령 (Mac → Switch SSH 로 실행)

    /// Switch 도달 확인 — `echo ok`.
    public static let switchEcho = "echo ok"

    /// Switch 내부 로봇용 RSA 키 생성(없을 때만 — robot-ready keygen 이 idempotent).
    public static let ensureSwitchKey = "\(robotReadyBin) keygen"

    /// Switch 공개키 읽기 — 한 줄 출력.
    public static let readSwitchPublicKey = "cat \(switchPublicKeyPath)"

    /// Switch→Robot SSH 인증 probe(`Robot SSH auth: OK` 확인).
    public static let probeRobotFromSwitch = "\(robotReadyBin) probe"

    /// Switch→Robot WalkLab patch 상태(`Robot WalkLab patch: OK` 확인).
    public static let robotWalkLabStatus = "\(robotReadyBin) status"

    /// Switch→Robot WalkLab 시작(로봇 모터/보행 엔진 초기화 — 안전 확인 후에만).
    public static let startWalkLabFromSwitch = "\(robotReadyBin) start-walklab"

    /// Switch agent 를 `mode=ssh` 로 전환 + 서비스 재시작.
    public static let enableSwitchAgentSSH = "\(robotReadyBin) enable-agent-ssh"

    /// Switch 의 계획 출력 — switch config 가 보는 로봇 SSH target 을 노출.
    public static let plan = "\(robotReadyBin) plan"

    /// Switch 카메라 SSH 터널 systemd 서비스를 enable + 즉시 기동 + 상태 확인.
    ///
    /// 2026-06-08 오늘 아침 실측: 로봇 측 `start-walklab` 은 demo 와 함께
    /// `camera_tutorial` 까지 자동으로 띄우므로(REMOTE_START_WALKLAB_SCRIPT 참조),
    /// **Switch 측에서 남은 일은 `darwin-switch-camera-tunnel.service` 를 enable + start
    /// 하는 한 줄뿐**이다. `sudo -n` 으로 NOPASSWD 전제(install.sh 가 sudoers 자동 적용).
    /// 끝에 `is-active` 로 결과를 echo — caller 가 출력 마커로 성공을 확정한다.
    public static let enableSwitchCameraTunnel =
        "sudo -n systemctl enable --now darwin-switch-camera-tunnel.service 2>&1; " +
        "echo DF_TUNNEL_STATE=$(systemctl is-active darwin-switch-camera-tunnel.service 2>/dev/null || echo unknown)"

    /// 카메라 터널 단독 성공 마커.
    public static let cameraTunnelActiveMarker = "DF_TUNNEL_STATE=active"

    /// 최종 확인 — switch config 의 mode 와 agent 활성 상태.
    public static let finalVerify =
        "grep -n '\"mode\"' /etc/darwin-switch-agent/config.json 2>/dev/null; systemctl is-active darwin-switch-agent 2>/dev/null"

    // MARK: - 성공 마커 (출력 파싱 — 거짓 성공 방지)

    /// 로봇 키 등록 성공 마커. 명령 끝에 echo 하여 exit code 외 내용으로도 확인.
    public static let keyInstalledMarker = "DF_SWITCH_KEY_INSTALLED"
    /// Switch probe 성공 시 robot-ready 가 출력하는 문자열.
    public static let probeOkMarker = "Robot SSH auth: OK"
    /// Switch status 성공 시 robot-ready 가 출력하는 문자열.
    public static let walkLabPatchOkMarker = "Robot WalkLab patch: OK"
    /// start-walklab 성공 시 robot-ready 가 출력하는 문자열.
    public static let walkLabStartOkMarker = "Robot WalkLab start: OK"

    // MARK: - 네트워크 도달성 (Switch → 로봇 경로 탐색)

    /// 로봇이 가진 모든 IPv4 주소를 묻는 명령 — Mac 의 검증된 로봇 채널로 실행.
    /// 로봇은 보통 유선 직결(192.168.123.1) + 무선(192.168.0.x) 두 인터페이스를 갖고,
    /// Switch(WiFi)는 *무선* IP 로만 닿을 수 있다. 후보 IP 를 모아 Switch 에서 도달성 테스트.
    public static let robotListOwnIPv4 =
        "{ hostname -I 2>/dev/null; ip -4 -o addr show 2>/dev/null | awk '{print $4}'; } | tr ' ' '\\n'"

    /// Switch 에서 후보 로봇 IP 들의 TCP 도달성을 테스트(robot-ready reachability).
    public static func reachabilityFromSwitch(candidates: [String]) -> String {
        let csv = candidates
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        return "\(robotReadyBin) reachability --candidates \(shellSingleQuote(csv))"
    }

    /// robot-ready 서브커맨드에 `--robot-host` override 를 덧붙인다(닿는 IP 강제).
    /// host 가 비면 base 그대로(= Switch config 기본값 사용).
    public static func withRobotHost(_ base: String, _ host: String?) -> String {
        guard let h = host?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return base }
        return "\(base) --robot-host \(shellSingleQuote(h))"
    }

    /// 로봇 IPv4 목록 출력에서 사용 가능한 후보를 추출(loopback/link-local 제외, 중복 제거).
    /// `hostname -I` 는 공백 구분, `ip -o addr` 는 `192.168.0.100/24` 형태 — 둘 다 처리.
    public static func parseRobotIPv4s(_ output: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let tokens = output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        for raw in tokens {
            let ip = String(raw.split(separator: "/").first ?? raw)
            guard isIPv4(ip) else { continue }
            guard !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") else { continue }
            if seen.insert(ip).inserted { result.append(ip) }
        }
        return result
    }

    /// reachability 출력에서 첫 도달 가능 IP 추출(`DF_REACHABLE=<ip>`; none 이면 nil).
    public static func parseReachableHost(_ output: String) -> String? {
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("DF_REACHABLE=") else { continue }
            let value = String(line.dropFirst("DF_REACHABLE=".count))
            return (value == "none" || value.isEmpty) ? nil : value
        }
        return nil
    }

    /// 단순 IPv4 형태 검증(0-255 4옥텟).
    public static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let n = Int(part) else { return false }
            return n >= 0 && n <= 255
        }
    }

    // MARK: - Robot-side 명령 (Mac 의 검증된 RemoteShell 로 실행)

    /// **핵심 단계** — Switch 공개키를 로봇 `~/.ssh/authorized_keys` 에 등록.
    ///
    /// 보장:
    ///   - `.ssh` 700 / `authorized_keys` 600 권한
    ///   - 중복 등록 방지(`grep -qxF`)
    ///   - 공개키는 single-quote escaping 으로 셸 인젝션 차단
    ///   - 끝에 성공 마커 echo (caller 가 내용으로 성공 확정)
    public static func installAuthorizedKeyOnRobot(pubkey: String) -> String {
        let key = shellSingleQuote(pubkey.trimmingCharacters(in: .whitespacesAndNewlines))
        return [
            "mkdir -p ~/.ssh",
            "chmod 700 ~/.ssh",
            "touch ~/.ssh/authorized_keys",
            "chmod 600 ~/.ssh/authorized_keys",
            "(grep -qxF \(key) ~/.ssh/authorized_keys || printf '%s\\n' \(key) >> ~/.ssh/authorized_keys)",
            "echo \(keyInstalledMarker)",
        ].joined(separator: " && ")
    }

    /// 로봇의 `/tmp/df-walklab-cmd` 읽기 — Mac 의 검증된 로봇 채널로 실행. 조이콘 입력이
    /// 실제 명령 파일에 반영되는지(stride/turn 변화) 실사용 검증용.
    public static let readWalkLabCmdOnRobot =
        "stat -c '%y %s' /tmp/df-walklab-cmd 2>/dev/null; echo '---DF_CMD---'; cat /tmp/df-walklab-cmd 2>/dev/null"

    /// **로봇 측 실제 생존 프로브** — Mac 의 검증된 로봇 채널로 실행. `/api/state` 의
    /// 스위치 측 flag(armed/moving)는 *명령을 보냈다*는 뜻일 뿐, 로봇이 *받아 실행한다*는
    /// 보장이 아니다(2026-06-07 실측: demo 가 죽어도 스위치는 idle 명령을 계속 씀). 그래서
    /// 로봇에서 직접 ① demo/demo-pilot 프로세스 생존, ② cmd 대비 ack 신선도를 본다.
    public static let robotPilotLivenessProbe = """
    if pgrep -x demo-pilot >/dev/null 2>&1; then echo demo=demo-pilot; \
    elif pgrep -x demo >/dev/null 2>&1; then echo demo=demo; else echo demo=none; fi
    echo now=$(date +%s)
    echo cmd_mtime=$(stat -c %Y /tmp/df-walklab-cmd 2>/dev/null || echo 0)
    echo ack_mtime=$(stat -c %Y /tmp/df-walklab-ack 2>/dev/null || echo 0)
    echo pilot_mode=$(cat /tmp/df-pilot-mode 2>/dev/null || echo none)
    """

    /// 로봇 측 조종 생존 상태 — 거짓 양성 방지의 단일 진실.
    public struct PilotLiveness: Equatable, Sendable {
        public var demoRunning: Bool
        public var demoName: String        // "demo" | "demo-pilot" | "none"
        public var ackAgeSec: Int?         // ack 가 마지막으로 갱신된 후 경과(초). nil=ack 없음
        public var cmdAgeSec: Int?         // cmd 가 마지막으로 쓰인 후 경과(초)
        public var pilotMode: String

        /// **정직한 판정**: demo 가 살아 있고 ack 가 신선(≤3s)해야 "실제 조종 반영".
        public var actuallyConsuming: Bool {
            demoRunning && (ackAgeSec.map { $0 <= 3 } ?? false)
        }
    }

    /// `robotPilotLivenessProbe` 출력 파싱.
    public static func parsePilotLiveness(_ output: String) -> PilotLiveness? {
        var kv: [String: String] = [:]
        for raw in output.split(whereSeparator: { $0 == "\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            kv[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let demo = kv["demo"], let nowS = kv["now"], let now = Int(nowS) else { return nil }
        func age(_ key: String) -> Int? {
            guard let v = kv[key], let t = Int(v), t > 0 else { return nil }
            return max(0, now - t)
        }
        return PilotLiveness(
            demoRunning: demo != "none",
            demoName: demo,
            ackAgeSec: age("ack_mtime"),
            cmdAgeSec: age("cmd_mtime"),
            pilotMode: kv["pilot_mode"] ?? "none")
    }

    // MARK: - 실사용 검증 / 안정화 (Switch-side)

    /// Switch 조종석 상태 API — Switch 에서 실행. mode/target/ssh_connected/armed 등.
    public static let apiState = "curl -fsS --max-time 4 http://127.0.0.1:8765/api/state"

    /// Switch 도구 점검 — robot-ready 설치 + agent 활성 + API 응답.
    public static let switchToolCheck =
        "command -v darwin-switch-robot-ready >/dev/null 2>&1 && echo cli=ok || echo cli=missing; " +
        "systemctl is-active darwin-switch-agent 2>/dev/null | sed 's/^/agent=/'; " +
        "curl -fsS --max-time 4 http://127.0.0.1:8765/api/state >/dev/null 2>&1 && echo api=ok || echo api=down"

    /// 안정화 설정 적용(+닿는 IP 영구 저장 + identity 절대경로). robotHost override 포함.
    public static func stabilize(robotHost: String?) -> String {
        withRobotHost("\(robotReadyBin) stabilize", robotHost)
    }

    /// 14-token WalkLab 명령 라인에서 사람이 읽을 값 파싱(거짓 성공 방지·실사용 검증).
    /// 형식: `cmd_id enabled stride side turn period foot hip bgain benable blevel pan tilt ball`.
    public struct WalkLabCmd: Equatable, Sendable {
        public var cmdId: String
        public var enabled: Bool
        public var stride: Double
        public var side: Double
        public var turn: Double
        public var period: Double
        public var foot: Double
        public var timestamp: String?
    }

    /// `readWalkLabCmdOnRobot` 출력(stat 줄 + `---DF_CMD---` + 명령 라인) 파싱.
    public static func parseWalkLabCmd(_ output: String) -> WalkLabCmd? {
        let parts = output.components(separatedBy: "---DF_CMD---")
        let timestamp = parts.first.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.flatMap { $0.isEmpty ? nil : $0 }
        guard let body = parts.count >= 2 ? parts[1] : parts.first else { return nil }
        guard let line = body.split(whereSeparator: { $0 == "\n" })
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let t = line.split(separator: " ").map(String.init)
        guard t.count >= 7 else { return nil }
        return WalkLabCmd(
            cmdId: t[0],
            enabled: t[1] == "1",
            stride: Double(t[2]) ?? 0,
            side: Double(t[3]) ?? 0,
            turn: Double(t[4]) ?? 0,
            period: Double(t[5]) ?? 0,
            foot: Double(t[6]) ?? 0,
            timestamp: timestamp)
    }

    /// Switch 조종석 `/api/state` JSON 의 핵심 필드(없으면 nil).
    public struct ApiState: Equatable, Sendable {
        public var mode: String?
        public var target: String?
        public var sshConnected: Bool?
        public var inputStatus: String?
        public var armed: Bool?
        public var deadman: Bool?
        public var moving: Bool?
        public var stride: Double?
        public var turn: Double?
        /// 2026-06-08 추가 — Switch 측 카메라 터널 런타임 상태(`camera_runtime` 필드).
        /// `control_bus.read_camera_runtime()` 가 채움. `port_open` 이면 :18080 LISTEN.
        public var cameraRuntime: CameraRuntime?
    }

    /// Switch 측 카메라 SSH 터널 런타임 — `/api/state.camera_runtime` 미러.
    /// 원클릭 데모 검증에서 "카메라까지 실제로 흐른다" 를 확정하는 단일 진실.
    public struct CameraRuntime: Equatable, Sendable {
        /// 사용자가 카메라 모드를 켰는지(`camera.enabled`).
        public var enabled: Bool
        /// `disabled` | `missing_url` | `port_closed` | `port_open` — control_bus 4상태.
        public var status: String
        /// 터널 로컬 포트(:18080)가 실제 LISTEN 중인지 — 진짜 스트림 가능 여부.
        public var localPortOpen: Bool
        public var port: Int?

        /// 사람이 읽는 정직한 판정.
        public var isLive: Bool { enabled && localPortOpen }
    }

    /// `start-walklab` 출력 마커를 한 번에 분해 — UI 가 "demo OK, 카메라는 아직" 같은
    /// 부분성공을 정확히 표현(원클릭 데모는 부분성공도 진척으로 본다).
    public struct DemoSuiteRobotOutcome: Equatable, Sendable {
        /// `DF_READY_START=walklab_running` 마커가 있으면 true.
        public var walkLabStarted: Bool
        /// `DF_READY_CAMERA=running|already_running` 이면 true. missing/build_failed → false.
        public var cameraStarted: Bool
        /// `DF_READY_CAMERA=<raw>` 의 원시값 — 진단 표시용.
        public var cameraTag: String
        /// `DF_READY_START` 마커의 원시값 (`walklab_running` | `missing_walklab_patch` | `start_failed` | `old_walklab_patch`).
        public var startTag: String
    }

    public static func parseDemoSuiteRobotOutcome(_ output: String) -> DemoSuiteRobotOutcome {
        var startTag = ""
        var cameraTag = ""
        for raw in output.split(whereSeparator: { $0 == "\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DF_READY_START=") {
                startTag = String(line.dropFirst("DF_READY_START=".count))
            } else if line.hasPrefix("DF_READY_CAMERA=") {
                cameraTag = String(line.dropFirst("DF_READY_CAMERA=".count))
            }
        }
        let walkOK = startTag == "walklab_running"
        let camOK = cameraTag == "running" || cameraTag == "already_running"
        return DemoSuiteRobotOutcome(
            walkLabStarted: walkOK,
            cameraStarted: camOK,
            cameraTag: cameraTag,
            startTag: startTag)
    }

    /// Switch 카메라 터널 명령 출력(`DF_TUNNEL_STATE=...`)에서 활성 여부 파싱.
    public static func parseCameraTunnelActive(_ output: String) -> Bool {
        for raw in output.split(whereSeparator: { $0 == "\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DF_TUNNEL_STATE=") {
                return String(line.dropFirst("DF_TUNNEL_STATE=".count)) == "active"
            }
        }
        return false
    }

    /// `/api/state` 출력 파싱 — top-level + nested `command.stride_mm/turn_deg`.
    public static func parseApiState(_ json: String) -> ApiState? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let command = obj["command"] as? [String: Any]
        func dbl(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            if let s = any as? String { return Double(s) }
            return nil
        }
        let cameraRaw = obj["camera_runtime"] as? [String: Any]
        let cameraRuntime: CameraRuntime? = cameraRaw.map { raw in
            CameraRuntime(
                enabled: (raw["enabled"] as? Bool) ?? false,
                status: (raw["status"] as? String) ?? "unknown",
                localPortOpen: (raw["local_port_open"] as? Bool) ?? false,
                port: (raw["port"] as? Int) ?? (raw["port"] as? Double).map(Int.init))
        }
        return ApiState(
            mode: obj["mode"] as? String,
            target: obj["target"] as? String,
            sshConnected: obj["ssh_connected"] as? Bool,
            inputStatus: obj["input_status"] as? String,
            armed: obj["armed"] as? Bool,
            deadman: obj["deadman"] as? Bool,
            moving: obj["moving"] as? Bool,
            stride: dbl(command?["stride_mm"]),
            turn: dbl(command?["turn_deg"]),
            cameraRuntime: cameraRuntime)
    }

    // MARK: - 터미널 fallback (BatchMode 즉시 실패 시 사용자 복사용)

    /// Switch 에 비밀번호로 붙어야 할 때 사용자가 Mac 터미널에 붙여넣을 명령.
    /// (Swift `Process` 로 password prompt 처리가 어려운 경우의 1차 대안.)
    public static func terminalCommandForSwitch(switchUser: String,
                                                switchHost: String,
                                                remoteCommand: String) -> String {
        let remote = shellSingleQuote(remoteCommand)
        return "ssh \(switchUser)@\(switchHost) \(remote)"
    }

    // MARK: - 유틸

    /// POSIX 셸 single-quote escaping — `'` 를 `'\''` 로 치환 후 양끝 quote.
    /// 공개키 comment 의 공백/특수문자까지 안전.
    public static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 읽어온 문자열이 SSH 공개키 형태인지 가벼운 검증(거짓 성공 방지).
    /// `ssh-rsa` / `ssh-ed25519` / `ecdsa-*` prefix + base64 본문.
    public static func looksLikePublicKey(_ s: String) -> Bool {
        let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        let prefixes = ["ssh-rsa ", "ssh-ed25519 ", "ecdsa-sha2-", "sk-ssh-", "ssh-dss "]
        guard prefixes.contains(where: { line.hasPrefix($0) }) else { return false }
        let parts = line.split(separator: " ")
        return parts.count >= 2 && parts[1].count > 16
    }
}
