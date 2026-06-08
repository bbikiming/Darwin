import XCTest
@testable import DarwinForgeUI

/// `SwitchRobotLinkCommands` 의 셸 명령 빌더 검증.
///
/// 핵심: 공개키는 신뢰할 수 없는(로봇 외부에서 온) 문자열이므로, 로봇에 보내는
/// authorized_keys 등록 명령에서 반드시 single-quote escaping 되어 셸 인젝션이
/// 불가능해야 한다. 또한 중복 등록 방지/권한 설정/성공 마커가 보존돼야 한다.
final class SwitchRobotLinkCommandsTests: XCTestCase {

    // MARK: - shellSingleQuote

    func testShellSingleQuoteWrapsPlainString() {
        XCTAssertEqual(SwitchRobotLinkCommands.shellSingleQuote("abc"), "'abc'")
    }

    func testShellSingleQuoteEscapesEmbeddedQuote() {
        // a'b → 'a'\''b'  (close, escaped quote, reopen)
        XCTAssertEqual(SwitchRobotLinkCommands.shellSingleQuote("a'b"), "'a'\\''b'")
    }

    func testShellSingleQuoteNeutralizesInjection() {
        // 악의적 입력이 명령 분리/치환으로 새지 않는지 — POSIX `'\''` 패턴으로만 quote 분리.
        let evil = "key'; rm -rf ~; echo '"
        let quoted = SwitchRobotLinkCommands.shellSingleQuote(evil)
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        // 정밀 계약: 각 raw `'` → `'\''` (닫고/escaped quote/다시 열기). 그 외 break 없음.
        XCTAssertEqual(quoted, "'key'\\''; rm -rf ~; echo '\\'''")
        // 핵심 안전성: 입력의 모든 single-quote 는 반드시 `'\''` 묶음 안에서만 등장.
        // 즉, 원문에 있던 `'` 개수(3) × 4글자(`'\''`) 가 그대로 보존.
        let escapedUnits = quoted.components(separatedBy: "'\\''").count - 1
        XCTAssertEqual(escapedUnits, 2, "raw single-quote 2개가 모두 escaped 형태로 변환돼야 함")
    }

    // MARK: - installAuthorizedKeyOnRobot

    func testInstallKeyContainsSafetyInvariants() {
        let cmd = SwitchRobotLinkCommands.installAuthorizedKeyOnRobot(
            pubkey: "ssh-rsa AAAAB3Nza1234567890abcdef switch")
        XCTAssertTrue(cmd.contains("chmod 700 ~/.ssh"), "`.ssh` 700 권한 필요")
        XCTAssertTrue(cmd.contains("chmod 600 ~/.ssh/authorized_keys"), "authorized_keys 600 권한 필요")
        XCTAssertTrue(cmd.contains("grep -qxF"), "중복 등록 방지 필요")
        XCTAssertTrue(cmd.contains(SwitchRobotLinkCommands.keyInstalledMarker), "성공 마커 echo 필요")
    }

    func testInstallKeyTrimsAndQuotesPubkey() {
        let cmd = SwitchRobotLinkCommands.installAuthorizedKeyOnRobot(
            pubkey: "  ssh-ed25519 AAAAC3NzaC1lZDI1 darwin-switch  \n")
        // trim 후 single-quote 로 감싸인 키가 등장.
        XCTAssertTrue(cmd.contains("'ssh-ed25519 AAAAC3NzaC1lZDI1 darwin-switch'"))
        XCTAssertFalse(cmd.contains("\n  "), "앞뒤 공백/개행은 trim")
    }

    func testInstallKeyEscapesMaliciousPubkey() {
        let cmd = SwitchRobotLinkCommands.installAuthorizedKeyOnRobot(
            pubkey: "ssh-rsa AAAA'; rm -rf / #")
        // 악성 공개키의 single-quote 는 반드시 `'\''` 로 escape — 원문 그대로의 raw `'`
        // 뒤에 명령이 붙는 형태(닫힌 quote + 명령)는 등장하지 않아야 한다.
        XCTAssertTrue(cmd.contains("'ssh-rsa AAAA'\\''; rm -rf / #'"),
                      "악성 공개키가 single-quote escaping 된 채로 등장해야 함")
    }

    // MARK: - looksLikePublicKey

    func testLooksLikePublicKeyAcceptsValid() {
        XCTAssertTrue(SwitchRobotLinkCommands.looksLikePublicKey(
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQ switch"))
        XCTAssertTrue(SwitchRobotLinkCommands.looksLikePublicKey(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI darwin"))
    }

    func testLooksLikePublicKeyRejectsGarbage() {
        XCTAssertFalse(SwitchRobotLinkCommands.looksLikePublicKey(""))
        XCTAssertFalse(SwitchRobotLinkCommands.looksLikePublicKey("No such file or directory"))
        XCTAssertFalse(SwitchRobotLinkCommands.looksLikePublicKey("ssh-rsa short"))
        // prefix 만 있고 본문 없음.
        XCTAssertFalse(SwitchRobotLinkCommands.looksLikePublicKey("ssh-rsa"))
    }

    // MARK: - terminal fallback

    func testTerminalCommandForSwitchQuotesRemote() {
        let cmd = SwitchRobotLinkCommands.terminalCommandForSwitch(
            switchUser: "yuseok", switchHost: "192.168.0.25",
            remoteCommand: "darwin-switch-robot-ready keygen")
        XCTAssertEqual(cmd, "ssh yuseok@192.168.0.25 'darwin-switch-robot-ready keygen'")
    }

    // MARK: - 네트워크 도달성 파서

    func testParseRobotIPv4sFromHostnameAndIpAddr() {
        // `hostname -I` (공백) + `ip -o addr` (CIDR) 혼합 출력.
        let output = """
        192.168.123.1 192.168.0.100
        127.0.0.1/8
        192.168.0.100/24
        169.254.5.5/16
        """
        let ips = SwitchRobotLinkCommands.parseRobotIPv4s(output)
        XCTAssertEqual(ips, ["192.168.123.1", "192.168.0.100"], "loopback/link-local 제외 + 중복 제거 + 순서 보존")
    }

    func testParseRobotIPv4sIgnoresGarbage() {
        XCTAssertTrue(SwitchRobotLinkCommands.parseRobotIPv4s("no ip here\nblah").isEmpty)
        XCTAssertTrue(SwitchRobotLinkCommands.parseRobotIPv4s("999.1.1.1 256.0.0.1").isEmpty)
    }

    func testParseReachableHost() {
        let ok = "reach=192.168.123.1:22 closed\nreach=192.168.0.100:22 open\nDF_REACHABLE=192.168.0.100\nDF_REACHABLE_ALL=192.168.0.100"
        XCTAssertEqual(SwitchRobotLinkCommands.parseReachableHost(ok), "192.168.0.100")
        XCTAssertNil(SwitchRobotLinkCommands.parseReachableHost("reach=a:22 closed\nDF_REACHABLE=none"))
        XCTAssertNil(SwitchRobotLinkCommands.parseReachableHost("nothing useful"))
    }

    func testWithRobotHostAppendsOverrideSafely() {
        let base = "darwin-switch-robot-ready probe"
        XCTAssertEqual(SwitchRobotLinkCommands.withRobotHost(base, "192.168.0.100"),
                       "darwin-switch-robot-ready probe --robot-host '192.168.0.100'")
        // 빈/nil 이면 base 그대로.
        XCTAssertEqual(SwitchRobotLinkCommands.withRobotHost(base, nil), base)
        XCTAssertEqual(SwitchRobotLinkCommands.withRobotHost(base, "  "), base)
    }

    func testReachabilityFromSwitchBuildsCsv() {
        let cmd = SwitchRobotLinkCommands.reachabilityFromSwitch(
            candidates: ["192.168.123.1", " 192.168.0.100 ", ""])
        XCTAssertEqual(cmd, "darwin-switch-robot-ready reachability --candidates '192.168.123.1,192.168.0.100'")
    }

    func testIsIPv4() {
        XCTAssertTrue(SwitchRobotLinkCommands.isIPv4("192.168.0.1"))
        XCTAssertTrue(SwitchRobotLinkCommands.isIPv4("0.0.0.0"))
        XCTAssertFalse(SwitchRobotLinkCommands.isIPv4("192.168.0"))
        XCTAssertFalse(SwitchRobotLinkCommands.isIPv4("256.0.0.1"))
        XCTAssertFalse(SwitchRobotLinkCommands.isIPv4("a.b.c.d"))
    }

    // MARK: - 실사용 검증 파서 (api/state, walklab cmd, stabilize)

    func testParseApiStateExtractsNestedCommand() {
        let json = """
        {"mode":"ssh","target":"robotis@192.168.0.33","ssh_connected":true,
         "input_status":"/dev/input/event8","armed":true,"deadman":true,"moving":true,
         "command":{"stride_mm":24.95,"side_mm":0.0,"turn_deg":-10.94}}
        """
        guard let s = SwitchRobotLinkCommands.parseApiState(json) else {
            return XCTFail("parse 실패")
        }
        XCTAssertEqual(s.mode, "ssh")
        XCTAssertEqual(s.target, "robotis@192.168.0.33")
        XCTAssertEqual(s.sshConnected, true)
        XCTAssertEqual(s.inputStatus, "/dev/input/event8")
        XCTAssertEqual(s.armed, true)
        XCTAssertEqual(s.moving, true)
        XCTAssertEqual(s.stride ?? 0, 24.95, accuracy: 0.001)
        XCTAssertEqual(s.turn ?? 0, -10.94, accuracy: 0.001)
    }

    func testParseApiStateRejectsGarbage() {
        XCTAssertNil(SwitchRobotLinkCommands.parseApiState("not json"))
        XCTAssertNil(SwitchRobotLinkCommands.parseApiState(""))
    }

    func testParseWalkLabCmd() {
        let out = "2026-06-07 16:00:00 84\n---DF_CMD---\nc641d853 1 24.95 0 -10.94 600 40 13 1.0 0 2 0.00 0.00 0\n"
        guard let c = SwitchRobotLinkCommands.parseWalkLabCmd(out) else {
            return XCTFail("parse 실패")
        }
        XCTAssertEqual(c.cmdId, "c641d853")
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.stride, 24.95, accuracy: 0.001)
        XCTAssertEqual(c.turn, -10.94, accuracy: 0.001)
        XCTAssertEqual(c.period, 600, accuracy: 0.001)
        XCTAssertEqual(c.foot, 40, accuracy: 0.001)
        XCTAssertNotNil(c.timestamp)
    }

    func testParseWalkLabCmdRejectsShortLine() {
        XCTAssertNil(SwitchRobotLinkCommands.parseWalkLabCmd("---DF_CMD---\nfoo bar"))
    }

    func testParsePilotLivenessDemoDownIsNotConsuming() {
        // 실측 시나리오: demo 죽음, 스위치는 cmd 계속 씀, ack 는 stale.
        let now = 1_780_829_360
        let out = """
        demo=none
        now=\(now)
        cmd_mtime=\(now - 1)
        ack_mtime=\(now - 8713)
        pilot_mode=walklab
        """
        guard let l = SwitchRobotLinkCommands.parsePilotLiveness(out) else { return XCTFail("parse 실패") }
        XCTAssertFalse(l.demoRunning)
        XCTAssertFalse(l.actuallyConsuming, "demo 없으면 절대 '소비 중' 아님")
        XCTAssertEqual(l.ackAgeSec, 8713)
        XCTAssertEqual(l.cmdAgeSec, 1)
        XCTAssertEqual(l.pilotMode, "walklab")
    }

    func testParsePilotLivenessRunningAndFreshIsConsuming() {
        let now = 2_000_000
        let out = "demo=demo\nnow=\(now)\ncmd_mtime=\(now - 1)\nack_mtime=\(now - 2)\npilot_mode=walklab"
        guard let l = SwitchRobotLinkCommands.parsePilotLiveness(out) else { return XCTFail("parse 실패") }
        XCTAssertTrue(l.demoRunning)
        XCTAssertTrue(l.actuallyConsuming, "demo 생존 + ack 신선(≤3s) → 소비 중")
    }

    func testParsePilotLivenessRunningButStaleAckNotConsuming() {
        let now = 2_000_000
        let out = "demo=demo-pilot\nnow=\(now)\ncmd_mtime=\(now)\nack_mtime=\(now - 60)\npilot_mode=walklab"
        guard let l = SwitchRobotLinkCommands.parsePilotLiveness(out) else { return XCTFail("parse 실패") }
        XCTAssertTrue(l.demoRunning)
        XCTAssertFalse(l.actuallyConsuming, "demo 살아도 ack stale 이면 소비 안 함")
    }

    func testParsePilotLivenessNoAckFile() {
        let now = 2_000_000
        let out = "demo=demo\nnow=\(now)\ncmd_mtime=\(now)\nack_mtime=0\npilot_mode=walklab"
        guard let l = SwitchRobotLinkCommands.parsePilotLiveness(out) else { return XCTFail("parse 실패") }
        XCTAssertNil(l.ackAgeSec)
        XCTAssertFalse(l.actuallyConsuming)
    }

    func testStabilizeCommandWithAndWithoutHost() {
        XCTAssertEqual(SwitchRobotLinkCommands.stabilize(robotHost: "192.168.0.33"),
                       "darwin-switch-robot-ready stabilize --robot-host '192.168.0.33'")
        XCTAssertEqual(SwitchRobotLinkCommands.stabilize(robotHost: nil),
                       "darwin-switch-robot-ready stabilize")
    }

    // MARK: - 상수 계약 (CLI subcommand 와 일치)

    func testRobotReadySubcommandStrings() {
        XCTAssertEqual(SwitchRobotLinkCommands.ensureSwitchKey, "darwin-switch-robot-ready keygen")
        XCTAssertEqual(SwitchRobotLinkCommands.probeRobotFromSwitch, "darwin-switch-robot-ready probe")
        XCTAssertEqual(SwitchRobotLinkCommands.robotWalkLabStatus, "darwin-switch-robot-ready status")
        XCTAssertEqual(SwitchRobotLinkCommands.startWalkLabFromSwitch, "darwin-switch-robot-ready start-walklab")
        XCTAssertEqual(SwitchRobotLinkCommands.enableSwitchAgentSSH, "darwin-switch-robot-ready enable-agent-ssh")
    }

    // MARK: - 카메라 + 조종 데모 원클릭 (2026-06-08)

    func testEnableSwitchCameraTunnelCommandShape() {
        let cmd = SwitchRobotLinkCommands.enableSwitchCameraTunnel
        // 핵심: sudo -n (비대화형), enable --now (즉시 기동), 결과 마커.
        XCTAssertTrue(cmd.contains("sudo -n systemctl enable --now darwin-switch-camera-tunnel.service"),
                      "비대화형 sudo + enable --now 으로 서비스 한 줄에 기동해야 함")
        XCTAssertTrue(cmd.contains("DF_TUNNEL_STATE="),
                      "결과 마커가 있어야 caller 가 거짓 성공을 가려낼 수 있음")
        XCTAssertTrue(cmd.contains("is-active darwin-switch-camera-tunnel.service"),
                      "is-active 로 실제 활성 여부 확인 필요")
    }

    func testParseCameraTunnelActiveTrue() {
        let out = "Created symlink ...\nDF_TUNNEL_STATE=active\n"
        XCTAssertTrue(SwitchRobotLinkCommands.parseCameraTunnelActive(out))
    }

    func testParseCameraTunnelActiveFalseWhenInactive() {
        let out = "Failed to enable: Access denied\nDF_TUNNEL_STATE=inactive\n"
        XCTAssertFalse(SwitchRobotLinkCommands.parseCameraTunnelActive(out))
    }

    func testParseCameraTunnelActiveFalseWhenMarkerMissing() {
        // 마커가 없으면 "거짓 양성 금지" — 항상 false.
        XCTAssertFalse(SwitchRobotLinkCommands.parseCameraTunnelActive("any random output"))
        XCTAssertFalse(SwitchRobotLinkCommands.parseCameraTunnelActive(""))
    }

    func testParseDemoSuiteRobotOutcomeFullyOk() {
        let out = """
        DF_READY_CAMERA_STOP=ok
        demo_binary=/robotis/Linux/project/demo/demo
        pid=12345
        DF_READY_START=walklab_running
        DF_READY_CAMERA=running
        """
        let parsed = SwitchRobotLinkCommands.parseDemoSuiteRobotOutcome(out)
        XCTAssertTrue(parsed.walkLabStarted)
        XCTAssertTrue(parsed.cameraStarted)
        XCTAssertEqual(parsed.startTag, "walklab_running")
        XCTAssertEqual(parsed.cameraTag, "running")
    }

    func testParseDemoSuiteRobotOutcomeCameraAlreadyRunningIsOK() {
        // 이미 카메라가 떠 있던 케이스도 진행 — 사용자가 재실행해도 OK.
        let out = "DF_READY_START=walklab_running\nDF_READY_CAMERA=already_running"
        let parsed = SwitchRobotLinkCommands.parseDemoSuiteRobotOutcome(out)
        XCTAssertTrue(parsed.walkLabStarted)
        XCTAssertTrue(parsed.cameraStarted)
    }

    func testParseDemoSuiteRobotOutcomeMissingPatch() {
        // 패치 누락은 hard fail — caller 가 빌드 안내를 보여야 함.
        let out = "DF_READY_START=missing_walklab_patch\nswitch fix WalkLab demo / demo-pilot binary not found"
        let parsed = SwitchRobotLinkCommands.parseDemoSuiteRobotOutcome(out)
        XCTAssertFalse(parsed.walkLabStarted)
        XCTAssertEqual(parsed.startTag, "missing_walklab_patch")
        XCTAssertEqual(parsed.cameraTag, "", "camera 마커는 없을 수 있음")
    }

    func testParseDemoSuiteRobotOutcomeWalkLabOKCameraMissing() {
        // 부분 실패 시나리오: demo 는 떴는데 camera_tutorial 디렉터리가 없는 로봇.
        let out = """
        DF_READY_START=walklab_running
        DF_READY_CAMERA=missing
        camera tutorial directory not found
        """
        let parsed = SwitchRobotLinkCommands.parseDemoSuiteRobotOutcome(out)
        XCTAssertTrue(parsed.walkLabStarted, "demo 가 떴으면 조종은 가능 — walkLabStarted=true")
        XCTAssertFalse(parsed.cameraStarted, "camera missing 은 false")
        XCTAssertEqual(parsed.cameraTag, "missing", "원시 태그가 진단용으로 보존")
    }

    func testParseApiStateExtractsCameraRuntime() {
        let json = """
        {
          "mode": "ssh",
          "ssh_connected": true,
          "armed": true,
          "command": {"stride_mm": 12.0, "turn_deg": -3.5},
          "camera_runtime": {
            "enabled": true,
            "status": "port_open",
            "host": "127.0.0.1",
            "port": 18080,
            "local_port_open": true,
            "url": "http://127.0.0.1:18080/?action=snapshot"
          }
        }
        """
        guard let st = SwitchRobotLinkCommands.parseApiState(json) else {
            return XCTFail("api state 파싱 실패")
        }
        guard let cam = st.cameraRuntime else { return XCTFail("camera_runtime 필드 누락") }
        XCTAssertTrue(cam.enabled)
        XCTAssertTrue(cam.localPortOpen)
        XCTAssertEqual(cam.status, "port_open")
        XCTAssertEqual(cam.port, 18080)
        XCTAssertTrue(cam.isLive, "enabled + localPortOpen 둘 다면 isLive=true")
    }

    func testParseApiStateCameraRuntimeMissingIsNil() {
        // 구버전 agent /api/state (camera_runtime 없음) — nil 로 안전 처리.
        let json = """
        {"mode": "ssh", "ssh_connected": false, "command": {}}
        """
        guard let st = SwitchRobotLinkCommands.parseApiState(json) else {
            return XCTFail("api state 파싱 실패")
        }
        XCTAssertNil(st.cameraRuntime, "필드 없으면 nil — 거짓 양성 금지")
    }

    func testParseApiStateCameraRuntimePortClosedIsNotLive() {
        let json = """
        {"camera_runtime": {"enabled": true, "status": "port_closed", "local_port_open": false, "port": 18080}}
        """
        guard let cam = SwitchRobotLinkCommands.parseApiState(json)?.cameraRuntime else {
            return XCTFail("camera_runtime 누락")
        }
        XCTAssertFalse(cam.localPortOpen)
        XCTAssertFalse(cam.isLive, "port 닫혀 있으면 isLive=false")
        XCTAssertEqual(cam.status, "port_closed")
    }
}
