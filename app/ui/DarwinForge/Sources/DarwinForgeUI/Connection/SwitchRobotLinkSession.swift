import Foundation

/// **Switch → Darwin 연결 세팅 마법사** 의 단계별 실행 상태 머신 (2026-06-07).
///
/// # 비유
///
/// 공항 환승 카운터. Mac(이미 입국한 사람)이 Switch(환승객)의 여권 사본(공개키)을
/// 받아 로봇(목적지) 입국 명단(`authorized_keys`)에 대신 등록해 준 뒤, Switch 가
/// 스스로 게이트를 통과(probe)하는지 확인하고 탑승(WalkLab)까지 안내한다.
///
/// 설계:
///   - **Switch 측** 명령은 `SSHShell.run`(Mac→Switch) — Switch 는 최신 Ubuntu 라
///     legacy 옵션/전용 키 없이(robot 키를 offer 하면 인증 실패) 기본 키 탐색 사용.
///   - **로봇 측** 키 등록은 Mac 의 *검증된* 경로를 closure(`robotRun`)로 주입 —
///     새 SSH 옵션을 만들지 않고 기존 `RemoteShell` 성공 경로를 재사용한다.
///   - 모든 단계는 출력 마커로 성공을 *확정*(거짓 성공 금지). probe/status 통과
///     전까지 다음 단계를 자동 진행하지 않는다.
@MainActor
public final class SwitchRobotLinkSession: ObservableObject {

    /// 마법사 단계 — 순서가 곧 의존성.
    public enum StepID: String, CaseIterable, Identifiable, Sendable {
        case switchReachable    // ① Switch 도달 (Mac→Switch)
        case discoverRoute      // ② 네트워크: Switch 가 닿는 로봇 IP 탐색
        case ensureKey          // ③ Switch 로봇용 키 확인/생성
        case readPubKey         // ④ Switch 공개키 읽기
        case installOnRobot     // ⑤ 로봇 authorized_keys 등록 (키 인증)
        case probe              // ⑥ Switch→Robot SSH probe
        case status             // ⑦ WalkLab patch 확인
        case startWalkLab       // ⑧ WalkLab 시작 (안전 확인 후)
        case enableAgent        // ⑨ Switch agent SSH 모드 전환 (닿는 IP 영구 기록)
        case finalVerify        // ⑩ 최종 확인

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .switchReachable: return "Switch 연결 확인"
            case .discoverRoute:   return "로봇 네트워크 경로 탐색"
            case .ensureKey:       return "Switch 키 확인 / 생성"
            case .readPubKey:      return "Switch 공개키 읽기"
            case .installOnRobot:  return "로봇에 공개키 등록 (키 인증)"
            case .probe:           return "Switch → 로봇 SSH 확인"
            case .status:          return "WalkLab 패치 확인"
            case .startWalkLab:    return "WalkLab 시작"
            case .enableAgent:     return "Switch agent SSH 모드 (IP 영구 저장)"
            case .finalVerify:     return "최종 상태 확인"
            }
        }

        public var detail: String {
            switch self {
            case .switchReachable: return "Mac 에서 Switch 에 SSH 로 닿는지 확인"
            case .discoverRoute:   return "[네트워크] 로봇 IP 들 중 Switch 가 실제로 라우팅되는 IP 찾기 — 이게 진짜 연결의 핵심"
            case .ensureKey:       return "Switch 내부 로봇용 RSA 키 생성(없을 때만)"
            case .readPubKey:      return "Switch 공개키를 Mac 으로 가져오기"
            case .installOnRobot:  return "[키] Mac 의 검증된 로봇 채널로 authorized_keys 에 등록"
            case .probe:           return "Switch 가 닿는 IP 로 로봇에 키 인증되는지 확인"
            case .status:          return "로봇 demo 바이너리에 WalkLab 패치가 있는지 확인"
            case .startWalkLab:    return "로봇 모터/보행 엔진 초기화 — 로봇을 잡고 실행"
            case .enableAgent:     return "Switch 조종석을 mode=ssh 로 전환 + 닿는 로봇 IP 를 config 에 영구 기록"
            case .finalVerify:     return "config mode=ssh + agent active 확인"
            }
        }

        public var icon: String {
            switch self {
            case .switchReachable: return "wifi"
            case .discoverRoute:   return "point.3.connected.trianglepath.dotted"
            case .ensureKey:       return "key.fill"
            case .readPubKey:      return "doc.on.doc"
            case .installOnRobot:  return "lock.shield.fill"
            case .probe:           return "checkmark.shield"
            case .status:          return "puzzlepiece.extension.fill"
            case .startWalkLab:    return "figure.walk"
            case .enableAgent:     return "gearshape.2.fill"
            case .finalVerify:     return "checkmark.seal.fill"
            }
        }

        /// 위험 단계(로봇이 실제로 움직일 수 있음) — 안전 확인 게이트 필요.
        public var isDangerous: Bool { self == .startWalkLab }
    }

    public enum Phase: String, Equatable, Sendable {
        case idle, running, success, failed
    }

    /// 한 단계의 결과 — UI 가 아이콘/세부/폴백을 구동.
    public struct Outcome: Equatable, Sendable {
        public var phase: Phase = .idle
        /// 사람이 읽는 한 줄 요약.
        public var message: String = ""
        /// 원시 stdout/stderr 합본(접기/펼치기).
        public var detail: String = ""
        /// 실패 시 사용자가 Mac 터미널에 붙여넣을 수 있는 대안 명령.
        public var fallbackCommand: String? = nil
    }

    // MARK: - Inputs (사용자 편집)

    /// Switch 의 IP/host. 확인된 기본값 — 절대 강제하지 않고 사용자가 바꿀 수 있음.
    @Published public var switchHost: String
    @Published public var switchUser: String
    /// start-walklab 안전 확인(로봇을 잡고 있음 / 주변 안전).
    @Published public var safetyConfirmed: Bool = false

    // MARK: - Outputs (읽기 전용)

    @Published public private(set) var outcomes: [StepID: Outcome] = [:]
    @Published public private(set) var runningStep: StepID?
    /// Switch 공개키 — readPubKey 성공 시 채워짐. installOnRobot 의 입력.
    @Published public private(set) var switchPublicKey: String?
    /// Switch config 가 보는 로봇 SSH target(plan 출력 파싱). Mac 의 host 와 비교용.
    @Published public private(set) var switchConfiguredRobotTarget: String?
    /// **Switch 가 실제로 라우팅되는 로봇 IP** — discoverRoute 가 채움. probe/status/
    /// start/enable 이 이 IP 로 `--robot-host` override. enableAgent 가 config 에 영구 기록.
    @Published public private(set) var reachableRobotHost: String?
    /// 로봇이 보고한 IPv4 후보 전체(표시용).
    @Published public private(set) var robotCandidateIPs: [String] = []
    /// 최종 확인 결과.
    @Published public private(set) var finalConfigMode: String?
    @Published public private(set) var finalAgentActive: Bool?

    /// Mac 이 현재 연결 중인 로봇 host(표시용). Switch 가 접근할 host 와 다를 수 있음.
    public let macRobotHost: String
    public let macRobotUser: String

    /// 안정화 설정 적용 결과(별도 액션 — 10단계 흐름 밖).
    @Published public private(set) var stabilizeOutcome = Outcome()
    @Published public private(set) var isStabilizing = false

    /// **원클릭 카메라+조종 데모** 의 단계별 진척 (2026-06-08).
    /// 기존 10단계는 디버그/고급용으로 그대로 두고, 이 흐름은 *현장에서 한 번에 다 켜는* 길.
    public enum DemoSuiteStage: String, Equatable, Sendable, CaseIterable, Identifiable {
        case preflight       // ① 전제 확인 (Mac↔로봇 SSH·안전·Switch 도달·라우팅 IP)
        case startRobotDemo  // ② 로봇 demo+camera_tutorial 부팅 (start-walklab 한 줄)
        case enableAgent     // ③ Switch agent SSH 모드 + 닿는 IP 영구 기록
        case cameraTunnel    // ④ Switch 카메라 SSH 터널 enable + start
        case verify          // ⑤ /api/state.ssh_connected + camera_runtime.local_port_open + 로봇 demo 생존
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .preflight:      return "전제 확인"
            case .startRobotDemo: return "로봇 demo+카메라 부팅"
            case .enableAgent:    return "Switch agent SSH 모드"
            case .cameraTunnel:   return "Switch 카메라 터널 기동"
            case .verify:         return "최종 검증"
            }
        }
    }

    /// 원클릭 데모 한 회의 결과(스테이지별 phase + 한 줄 메시지 + 합본 디테일).
    public struct DemoSuiteOutcome: Equatable, Sendable {
        public var stages: [DemoSuiteStage: Phase] = [:]
        public var stageMessages: [DemoSuiteStage: String] = [:]
        public var currentStage: DemoSuiteStage?
        public var summary: String = ""
        public var detail: String = ""
        public var fallbackCommand: String? = nil
        /// 전체 종료 여부와 무관한 "최후 단계 통과" — verify 까지 success 인지.
        public var allGreen: Bool {
            DemoSuiteStage.allCases.allSatisfy { stages[$0] == .success }
        }
        public func phase(_ s: DemoSuiteStage) -> Phase { stages[s] ?? .idle }
        public func message(_ s: DemoSuiteStage) -> String { stageMessages[s] ?? "" }
    }

    @Published public private(set) var demoSuiteOutcome = DemoSuiteOutcome()
    @Published public private(set) var isRunningDemoSuite = false

    /// **사용자가 한 번에 띄우고 싶은 조종 모드** (2026-06-08). 3가지 의도를 1열 타일로
    /// 노출 → 각각 다른 스테이지 조합을 실행. `cameraAndControl` 이 기존 5스테이지(권장),
    /// `quickPilot` 은 카메라 터널만 빼서 빠르게, `diagnostics` 는 모터를 켜지 않고 점검만.
    public enum LaunchMode: String, Equatable, Sendable, CaseIterable, Identifiable {
        case quickPilot         // 조종만 (모터 ON, 카메라 X)
        case cameraAndControl   // 카메라 + 조종 (권장 — 모터 ON, 카메라 O)
        case diagnostics        // 진단 (안전 — 모터 X)
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .quickPilot:       return "빠른 조종"
            case .cameraAndControl: return "카메라 + 조종"
            case .diagnostics:      return "연결 진단"
            }
        }
        public var subtitle: String {
            switch self {
            case .quickPilot:       return "걷기/회전만, 빠른 시작 — 카메라 없이"
            case .cameraAndControl: return "1인칭 영상으로 조종 (권장)"
            case .diagnostics:      return "로봇 안 움직이고 패치/네트워크/연결만 확인"
            }
        }
        public var icon: String {
            switch self {
            case .quickPilot:       return "figure.walk"
            case .cameraAndControl: return "play.tv.fill"
            case .diagnostics:      return "stethoscope"
            }
        }
        /// **모터가 켜지는가?** 켜지면 safetyConfirmed 게이트 강제.
        public var movesRobot: Bool {
            self == .quickPilot || self == .cameraAndControl
        }
        /// 이 모드가 실행할 스테이지 목록 — UI 가 progress strip 을 모드별로 다르게 그림.
        public var stages: [DemoSuiteStage] {
            switch self {
            case .quickPilot:       return [.preflight, .startRobotDemo, .enableAgent, .verify]
            case .cameraAndControl: return DemoSuiteStage.allCases  // 5 stages 전부
            case .diagnostics:      return [.preflight, .verify]
            }
        }
    }

    /// 마지막으로 선택/실행한 모드 — UI 가 강조 표시.
    @Published public private(set) var lastLaunchMode: LaunchMode?
    /// Switch 조종석 `/api/state` 실시간 상태(ssh_connected/armed/deadman/moving/stride/turn).
    @Published public private(set) var apiState: SwitchRobotLinkCommands.ApiState?
    @Published public private(set) var isRefreshingState = false
    /// 로봇 `/tmp/df-walklab-cmd` 실사용 검증(조이콘 입력 반영 여부).
    @Published public private(set) var walkLabCmd: SwitchRobotLinkCommands.WalkLabCmd?
    /// **로봇 측 실제 생존** — demo 프로세스 + ack 신선도. 거짓 양성 방지의 단일 진실.
    @Published public private(set) var pilotLiveness: SwitchRobotLinkCommands.PilotLiveness?

    /// 로봇 측 명령 실행 — Mac 의 검증된 채널 주입(반환 nil = 실행 불가).
    private let robotRun: (String) async -> (ok: Bool, output: String)?

    public init(switchHost: String = "192.168.0.25",
                switchUser: String = "yuseok",
                macRobotHost: String,
                macRobotUser: String = "robotis",
                robotRun: @escaping (String) async -> (ok: Bool, output: String)?) {
        self.switchHost = switchHost
        self.switchUser = switchUser
        self.macRobotHost = macRobotHost
        self.macRobotUser = macRobotUser
        self.robotRun = robotRun
    }

    public func outcome(_ step: StepID) -> Outcome { outcomes[step] ?? Outcome() }

    private var isBusy: Bool { runningStep != nil }

    // MARK: - Switch SSH 실행기 (Mac → Switch)

    /// Switch 는 최신 Ubuntu. **2026-06-07 실측 회귀 수정**: 공용 `id_rsa_darwin` 키가
    /// Switch 에도 authorized 인데, 비표준 파일명이라 ssh 가 자동으로 offer 하지 않아
    /// BatchMode 가 실패했다. 그 키를 `-i` 로 offer 하되 `identitiesOnly:false` 로 두어
    /// 사용자의 다른 기본/agent 키도 fallback 으로 시도한다. legacy 옵션은 불필요.
    private func switchOptions() -> SSHShell.SSHOptions {
        let rsaPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_rsa_darwin")
        let identity = FileManager.default.fileExists(atPath: rsaPath) ? rsaPath : nil
        return SSHShell.SSHOptions(identityFile: identity,
                                   legacyServerCompat: false,
                                   multiplex: false,
                                   identitiesOnly: false)
    }

    private struct SwitchResult {
        var ok: Bool
        var stdout: String
        var stderr: String
        var authFailed: Bool
    }

    private func runSwitch(_ command: String, timeout: TimeInterval = 15) async -> SwitchResult {
        do {
            let r = try await SSHShell.run(command: command,
                                           host: switchHost.trimmingCharacters(in: .whitespaces),
                                           user: switchUser.trimmingCharacters(in: .whitespaces),
                                           timeoutSeconds: timeout,
                                           options: switchOptions())
            return SwitchResult(ok: r.ok, stdout: r.stdout, stderr: r.stderr, authFailed: false)
        } catch SSHShell.SSHError.keyAuthRequired {
            return SwitchResult(ok: false, stdout: "",
                                stderr: "Mac → Switch SSH 키 인증이 안 됐어요(비밀번호 필요).",
                                authFailed: true)
        } catch SSHShell.SSHError.timeout {
            return SwitchResult(ok: false, stdout: "",
                                stderr: "시간 초과 — Switch IP/네트워크를 확인하세요.", authFailed: false)
        } catch {
            return SwitchResult(ok: false, stdout: "", stderr: error.localizedDescription, authFailed: false)
        }
    }

    private func combined(_ r: SwitchResult) -> String {
        var s = r.stdout
        if !r.stderr.isEmpty { s += (s.isEmpty ? "" : "\n") + "--- stderr ---\n" + r.stderr }
        return s
    }

    private func setRunning(_ step: StepID) {
        runningStep = step
        var o = outcome(step)
        o.phase = .running
        o.message = "실행 중…"
        outcomes[step] = o
    }

    private func finish(_ step: StepID, _ outcome: Outcome) {
        outcomes[step] = outcome
        if runningStep == step { runningStep = nil }
    }

    /// 터미널 fallback 명령 — Switch 단계 실패(특히 auth) 시 사용자 복사용.
    private func switchFallback(_ remoteCommand: String) -> String {
        SwitchRobotLinkCommands.terminalCommandForSwitch(
            switchUser: switchUser.trimmingCharacters(in: .whitespaces),
            switchHost: switchHost.trimmingCharacters(in: .whitespaces),
            remoteCommand: remoteCommand)
    }

    // MARK: - 개별 단계

    @discardableResult
    public func runSwitchReachable() async -> Bool {
        guard !isBusy else { return false }
        setRunning(.switchReachable)
        let r = await runSwitch(SwitchRobotLinkCommands.switchEcho, timeout: 8)
        var o = Outcome()
        o.detail = combined(r)
        if r.ok && r.stdout.contains("ok") {
            o.phase = .success
            o.message = "Switch(\(switchUser)@\(switchHost)) 연결 OK"
        } else {
            o.phase = .failed
            o.message = r.authFailed
                ? "Switch SSH 키 인증 필요 — 아래 명령을 터미널에서 1회 실행(비밀번호 입력)"
                : "Switch 에 닿지 못했어요 — IP/전원/네트워크 확인"
            o.fallbackCommand = r.authFailed
                ? "ssh-copy-id \(switchUser)@\(switchHost)"
                : switchFallback(SwitchRobotLinkCommands.switchEcho)
        }
        finish(.switchReachable, o)
        return o.phase == .success
    }

    /// **네트워크 다리** — 로봇의 IPv4 후보를 Mac(검증된 채널)으로 수집한 뒤, Switch 에서
    /// 어떤 IP 로 실제 라우팅되는지 테스트해 `reachableRobotHost` 를 확정한다.
    /// 이게 비어 있으면 키를 등록해도 Switch 가 로봇에 못 닿는다(가장 흔한 실패).
    @discardableResult
    public func runDiscoverRoute() async -> Bool {
        guard !isBusy else { return false }
        setRunning(.discoverRoute)
        var o = Outcome()

        // 1) 로봇이 가진 IP 들을 Mac 의 검증된 채널로 수집.
        var candidates: [String] = []
        if let result = await robotRun(SwitchRobotLinkCommands.robotListOwnIPv4) {
            o.detail += "[robot ip]\n" + result.output + "\n"
            if result.ok {
                candidates = SwitchRobotLinkCommands.parseRobotIPv4s(result.output)
            }
        } else {
            o.detail += "[robot ip] 로봇 채널 미연결 — Mac config host 만 후보로 사용\n"
        }
        // Mac 이 보는 host 도 후보에 포함(중복 제거).
        let macHost = macRobotHost.trimmingCharacters(in: .whitespaces)
        if SwitchRobotLinkCommands.isIPv4(macHost), !candidates.contains(macHost) {
            candidates.insert(macHost, at: 0)
        }
        robotCandidateIPs = candidates

        guard !candidates.isEmpty else {
            o.phase = .failed
            o.message = "로봇 IP 후보를 못 구했어요 — 먼저 DarwinForge 가 로봇에 연결됐는지 확인"
            finish(.discoverRoute, o)
            return false
        }

        // 2) Switch 에서 후보들의 도달성 테스트.
        let reachCmd = SwitchRobotLinkCommands.reachabilityFromSwitch(candidates: candidates)
        let r = await runSwitch(reachCmd, timeout: max(10, Double(candidates.count) * 3))
        o.detail += "[switch reachability]\n" + combined(r)
        if let host = SwitchRobotLinkCommands.parseReachableHost(r.stdout) {
            reachableRobotHost = host
            o.phase = .success
            o.message = "Switch 가 닿는 로봇 IP: \(host) (후보 \(candidates.count)개 중)"
        } else {
            reachableRobotHost = nil
            o.phase = .failed
            o.message = "Switch 가 어떤 로봇 IP 에도 못 닿아요 — Switch 와 로봇을 같은 네트워크(같은 WiFi)에 두세요"
            o.fallbackCommand = switchFallback(reachCmd)
        }
        finish(.discoverRoute, o)
        return o.phase == .success
    }

    /// probe/status/start/enable 이 사용할 실제 로봇 host — 탐색된 IP 우선,
    /// 없으면 nil(= robot-ready 가 Switch config 기본값 사용).
    private var effectiveRobotHostArg: String? { reachableRobotHost }

    @discardableResult
    public func runEnsureKey() async -> Bool {
        guard !isBusy else { return false }
        setRunning(.ensureKey)
        let r = await runSwitch(SwitchRobotLinkCommands.ensureSwitchKey, timeout: 20)
        var o = Outcome()
        o.detail = combined(r)
        if r.ok {
            o.phase = .success
            o.message = "Switch 로봇용 키 준비됨"
        } else {
            o.phase = .failed
            o.message = "키 생성 실패 — 아래 명령을 직접 실행해 보세요"
            o.fallbackCommand = switchFallback(SwitchRobotLinkCommands.ensureSwitchKey)
        }
        finish(.ensureKey, o)
        return o.phase == .success
    }

    @discardableResult
    public func runReadPublicKey() async -> Bool {
        guard !isBusy else { return false }
        setRunning(.readPubKey)
        let r = await runSwitch(SwitchRobotLinkCommands.readSwitchPublicKey, timeout: 10)
        var o = Outcome()
        o.detail = combined(r)
        let key = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.ok && SwitchRobotLinkCommands.looksLikePublicKey(key) {
            switchPublicKey = key
            o.phase = .success
            o.message = "공개키 읽음: …\(String(key.suffix(24)))"
        } else {
            switchPublicKey = nil
            o.phase = .failed
            o.message = "공개키를 읽지 못했어요 — 먼저 ‘키 생성’ 단계를 실행하세요"
            o.fallbackCommand = switchFallback(SwitchRobotLinkCommands.readSwitchPublicKey)
        }
        finish(.readPubKey, o)
        return o.phase == .success
    }

    /// **핵심 단계** — Mac 의 검증된 로봇 채널로 authorized_keys 등록.
    @discardableResult
    public func runInstallOnRobot() async -> Bool {
        guard !isBusy else { return false }
        guard let key = switchPublicKey, SwitchRobotLinkCommands.looksLikePublicKey(key) else {
            var o = Outcome()
            o.phase = .failed
            o.message = "먼저 ‘Switch 공개키 읽기’ 단계를 완료하세요"
            finish(.installOnRobot, o)
            return false
        }
        setRunning(.installOnRobot)
        let cmd = SwitchRobotLinkCommands.installAuthorizedKeyOnRobot(pubkey: key)
        var o = Outcome()
        if let result = await robotRun(cmd) {
            o.detail = result.output
            if result.ok && result.output.contains(SwitchRobotLinkCommands.keyInstalledMarker) {
                o.phase = .success
                o.message = "로봇 authorized_keys 에 등록 완료 (다음 단계에서 probe 로 확정)"
            } else {
                o.phase = .failed
                o.message = "로봇 키 등록 명령이 성공 마커를 반환하지 않았어요"
            }
        } else {
            o.phase = .failed
            o.message = "로봇 채널이 연결돼 있지 않아요 — 먼저 DarwinForge 가 로봇에 연결됐는지 확인"
        }
        finish(.installOnRobot, o)
        return o.phase == .success
    }

    @discardableResult
    public func runProbe() async -> Bool {
        guard !isBusy else { return false }
        setRunning(.probe)
        let cmd = SwitchRobotLinkCommands.withRobotHost(
            SwitchRobotLinkCommands.probeRobotFromSwitch, effectiveRobotHostArg)
        let r = await runSwitch(cmd, timeout: 15)
        var o = Outcome()
        o.detail = combined(r)
        if r.ok && r.stdout.contains(SwitchRobotLinkCommands.probeOkMarker) {
            o.phase = .success
            o.message = "Switch → 로봇 SSH 인증 OK"
        } else {
            o.phase = .failed
            o.message = "Switch 가 로봇에 붙지 못했어요 — 로봇 IP 경로/키 등록을 확인"
            o.fallbackCommand = switchFallback(cmd)
        }
        finish(.probe, o)
        return o.phase == .success
    }

    @discardableResult
    public func runStatus() async -> Bool {
        guard !isBusy else { return false }
        setRunning(.status)
        let cmd = SwitchRobotLinkCommands.withRobotHost(
            SwitchRobotLinkCommands.robotWalkLabStatus, effectiveRobotHostArg)
        let r = await runSwitch(cmd, timeout: 15)
        var o = Outcome()
        o.detail = combined(r)
        if r.ok && r.stdout.contains(SwitchRobotLinkCommands.walkLabPatchOkMarker) {
            o.phase = .success
            o.message = "로봇 WalkLab 패치 확인됨"
        } else {
            o.phase = .failed
            o.message = "로봇에 WalkLab 패치가 없어요 — demo 패치 빌드가 필요할 수 있어요"
            o.fallbackCommand = switchFallback(cmd)
        }
        finish(.status, o)
        return o.phase == .success
    }

    /// 안전 확인(`safetyConfirmed`) 후에만 실행 — 로봇이 실제로 움직인다.
    @discardableResult
    public func runStartWalkLab() async -> Bool {
        guard !isBusy else { return false }
        guard safetyConfirmed else {
            var o = Outcome()
            o.phase = .failed
            o.message = "안전 확인이 필요해요 — ‘로봇을 잡고 있음’ 체크 후 실행"
            finish(.startWalkLab, o)
            return false
        }
        setRunning(.startWalkLab)
        let cmd = SwitchRobotLinkCommands.withRobotHost(
            SwitchRobotLinkCommands.startWalkLabFromSwitch, effectiveRobotHostArg)
        let r = await runSwitch(cmd, timeout: 30)
        var o = Outcome()
        o.detail = combined(r)
        if r.ok && r.stdout.contains(SwitchRobotLinkCommands.walkLabStartOkMarker) {
            o.phase = .success
            o.message = "로봇 WalkLab 시작됨"
        } else {
            o.phase = .failed
            o.message = "WalkLab 시작 실패 — 출력에서 원인을 확인하세요"
            o.fallbackCommand = switchFallback(cmd)
        }
        finish(.startWalkLab, o)
        return o.phase == .success
    }

    @discardableResult
    public func runEnableAgent() async -> Bool {
        guard !isBusy else { return false }
        setRunning(.enableAgent)
        // 닿는 IP 를 함께 넘겨 Switch config 에 영구 기록(네트워크 다리 영속화).
        let cmd = SwitchRobotLinkCommands.withRobotHost(
            SwitchRobotLinkCommands.enableSwitchAgentSSH, effectiveRobotHostArg)
        let r = await runSwitch(cmd, timeout: 20)
        var o = Outcome()
        o.detail = combined(r)
        if r.ok && r.stdout.contains("mode=ssh") {
            o.phase = .success
            let hostNote = reachableRobotHost.map { " (로봇 IP=\($0) 저장)" } ?? ""
            o.message = "Switch agent 를 SSH 모드로 전환했어요\(hostNote)"
        } else {
            o.phase = .failed
            o.message = "agent 모드 전환 실패 — sudo 권한/서비스 상태를 확인"
            o.fallbackCommand = switchFallback(cmd)
        }
        finish(.enableAgent, o)
        return o.phase == .success
    }

    @discardableResult
    public func runFinalVerify() async -> Bool {
        guard !isBusy else { return false }
        setRunning(.finalVerify)
        let r = await runSwitch(SwitchRobotLinkCommands.finalVerify, timeout: 12)
        var o = Outcome()
        o.detail = combined(r)
        let modeSSH = r.stdout.contains("\"mode\": \"ssh\"") || r.stdout.contains("\"mode\":\"ssh\"")
        let active = r.stdout.contains("active")
        finalConfigMode = modeSSH ? "ssh" : (r.stdout.contains("dry_run") ? "dry_run" : nil)
        finalAgentActive = active
        if r.ok && modeSSH && active {
            o.phase = .success
            o.message = "완료 — config mode=ssh, agent active"
        } else {
            o.phase = .failed
            o.message = "아직 완료되지 않았어요 — mode=\(finalConfigMode ?? "?"), agent=\(active ? "active" : "inactive")"
            o.fallbackCommand = switchFallback(SwitchRobotLinkCommands.finalVerify)
        }
        finish(.finalVerify, o)
        return o.phase == .success
    }

    // MARK: - 원클릭 조종 모드 시작 (2026-06-08)

    /// **「원클릭 조종 모드 시작」** — 사용자가 의도하는 모드(빠른 조종 / 카메라+조종 /
    /// 진단)에 맞춰 *정확히 필요한 단계만* 실행한다.
    ///
    /// # 비유
    /// 손님이 메뉴를 고르면(모드 선택), 주방이 그 메뉴에 필요한 재료만 꺼낸다 — 카메라
    /// 안 쓰는 손님에게 카메라 터널을 켜지 않고, 진단만 원하는 손님에게는 모터를
    /// 켜지 않는다. 모든 손님이 같은 풀코스를 받지 않는다.
    ///
    /// 디자인:
    ///   - 기존 10단계는 그대로 — 이 함수는 그 단계들을 묶어 *현장 한 번* 흐름으로 노출.
    ///   - 각 스테이지는 정직한 마커 파싱으로 통과(거짓 성공 금지).
    ///   - 부분 실패도 진척으로 표시 — 예: demo 는 떴지만 camera_tutorial 미발견 시
    ///     `cameraTag=missing` 을 메시지에 노출하고 다음 단계는 계속.
    ///   - 한 단계라도 hard-fail(필수 통과 못 함) 시 즉시 중단 + 명확한 다음 행동.
    ///   - `diagnostics` 는 모터를 켜지 않으므로 안전 토글 게이트가 풀린다.
    @discardableResult
    public func runLaunch(_ mode: LaunchMode) async -> Bool {
        guard !isBusy, !isRunningDemoSuite else { return false }
        lastLaunchMode = mode
        isRunningDemoSuite = true
        defer { isRunningDemoSuite = false }
        var out = DemoSuiteOutcome()
        let activeStages = Set(mode.stages)

        func enter(_ s: DemoSuiteStage) {
            out.currentStage = s
            out.stages[s] = .running
            out.stageMessages[s] = "실행 중…"
            demoSuiteOutcome = out
        }
        func mark(_ s: DemoSuiteStage, _ p: Phase, _ msg: String) {
            out.stages[s] = p
            out.stageMessages[s] = msg
            demoSuiteOutcome = out
        }
        func appendDetail(_ tag: String, _ body: String) {
            if !body.isEmpty {
                out.detail += "[\(tag)]\n\(body)\n"
                demoSuiteOutcome = out
            }
        }
        func finishHard(_ s: DemoSuiteStage, _ msg: String,
                        fallback: String? = nil) -> Bool {
            mark(s, .failed, msg)
            out.summary = "중단됨: \(s.title) — \(msg)"
            out.fallbackCommand = fallback
            out.currentStage = nil
            demoSuiteOutcome = out
            return false
        }

        // ─── ① PREFLIGHT ─────────────────────────────────────────────
        enter(.preflight)
        var preflightProblems: [String] = []

        // 안전 확인 — 모터를 켜는 모드에서만 강제. 진단 모드는 모터 OFF 라 면제.
        if mode.movesRobot && !safetyConfirmed {
            preflightProblems.append("‘로봇을 잡고 있음’ 안전 확인 필요")
        }
        // Mac↔로봇 채널 — install_key/검증에 필수.
        if await robotRun("echo ok") == nil {
            preflightProblems.append("Mac 의 로봇 SSH 채널 미연결 — 먼저 로봇에 연결")
        }
        // Switch 도달 — 아직 안 했으면 조용히 한 번 시도(상태가 success 가 아니면).
        if outcome(.switchReachable).phase != .success {
            let r = await runSwitch(SwitchRobotLinkCommands.switchEcho, timeout: 8)
            appendDetail("switch reach", combined(r))
            if !(r.ok && r.stdout.contains("ok")) {
                preflightProblems.append("Switch SSH 미연결 — ‘Switch 연결 확인’ 단계 먼저 통과 필요")
            }
        }
        // 라우팅 IP — 없으면 한 번 자동 탐색(시간 비용 ~3s).
        if reachableRobotHost == nil && preflightProblems.isEmpty {
            isRunningDemoSuite = false  // discoverRoute 가 isBusy 검사
            _ = await runDiscoverRoute()
            isRunningDemoSuite = true
            appendDetail("auto discover route", outcome(.discoverRoute).detail)
        }
        if reachableRobotHost == nil {
            preflightProblems.append("Switch 가 닿는 로봇 IP 미확정 — ‘로봇 네트워크 경로 탐색’ 필요")
        }

        if !preflightProblems.isEmpty {
            return finishHard(.preflight, preflightProblems.joined(separator: " · "))
        }
        let safetyNote = mode.movesRobot ? " · 안전" : " · 모터 OFF 모드"
        mark(.preflight, .success, "전제 OK — Mac↔로봇 SSH, Switch, 라우팅 IP\(safetyNote)")

        // ─── ② 로봇 demo + camera_tutorial 부팅 ──────────────────────
        // 진단 모드는 모터를 켜지 않으므로 이 단계 건너뜀.
        guard activeStages.contains(.startRobotDemo) else {
            return await runDiagnosticsVerify(&out)
        }
        enter(.startRobotDemo)
        let startCmd = SwitchRobotLinkCommands.withRobotHost(
            SwitchRobotLinkCommands.startWalkLabFromSwitch, effectiveRobotHostArg)
        // start-walklab 은 demo kill→재기동(~3s)+camera_tutorial 부팅까지 묶여 있어
        // 무선 왕복까지 합치면 20~30s 가 정상. timeout 은 robot_ready 측 45s 와 정렬.
        let startR = await runSwitch(startCmd, timeout: 45)
        appendDetail("start-walklab", combined(startR))
        let robotOutcome = SwitchRobotLinkCommands.parseDemoSuiteRobotOutcome(startR.stdout)
        if !robotOutcome.walkLabStarted {
            // walklab 자체가 안 뜨면 카메라가 떠도 의미 없음 — hard fail.
            let why: String = {
                switch robotOutcome.startTag {
                case "missing_walklab_patch":
                    return "로봇 demo 에 WalkLab 패치가 없어요 — install-onboard.sh 로 빌드 필요"
                case "old_walklab_patch":
                    return "로봇 demo 가 구버전 WalkLab 패치 — switch fix 버전으로 재빌드 필요"
                case "start_failed":
                    return "demo 기동 실패 — /tmp/df-demo.log 확인 필요"
                default:
                    return startR.stdout.contains(SwitchRobotLinkCommands.walkLabStartOkMarker)
                        ? "demo 는 떴지만 success 마커 없음 — 로봇 상태 점검 필요"
                        : "demo 가 기동되지 않았어요 (start-walklab 마커 없음)"
                }
            }()
            return finishHard(.startRobotDemo, why,
                              fallback: switchFallback(startCmd))
        }
        // 부분 성공 메시지 — camera 까지 한 줄에 진실하게.
        // C1 (2026-06-12): walklab demo 가 8080 을 직접 스트리밍 — camera_tutorial 미사용.
        // cameraTag 는 start-walklab 의 스냅샷 헬스체크 결과(running/no_frames/port_closed…).
        let camLine: String = {
            if robotOutcome.cameraStarted {
                return "demo 가동 + 카메라 스트림 \(robotOutcome.cameraTag) (demo 직접 송출)"
            }
            if robotOutcome.cameraTag.isEmpty {
                return "demo 가동 — 카메라 상태 응답 없음(구버전 start 스크립트 가능)"
            }
            if robotOutcome.cameraTag == "no_frames" {
                return "demo 가동 — 8080 열림·프레임 없음: C1 카메라 패치 이전 demo (install-onboard.sh 재빌드 필요, 조종은 가능)"
            }
            return "demo 가동 — 카메라=\(robotOutcome.cameraTag) (영상이 안 떠도 SSH 조종은 가능)"
        }()
        mark(.startRobotDemo, robotOutcome.cameraStarted ? .success : .success, camLine)
        // 위는 의도적으로 camera 실패도 success 로 — 다음 스테이지를 막지 않는다.
        // 사용자 메시지에 cameraTag 가 진실하게 노출되므로 진단은 가능.

        // ─── ③ Switch agent SSH 모드 ─────────────────────────────────
        enter(.enableAgent)
        let enableCmd = SwitchRobotLinkCommands.withRobotHost(
            SwitchRobotLinkCommands.enableSwitchAgentSSH, effectiveRobotHostArg)
        let enableR = await runSwitch(enableCmd, timeout: 25)
        appendDetail("enable-agent-ssh", combined(enableR))
        if !(enableR.ok && enableR.stdout.contains("mode=ssh")) {
            return finishHard(.enableAgent,
                              "Switch agent SSH 전환 실패 — sudoers/서비스 권한 확인",
                              fallback: switchFallback(enableCmd))
        }
        let hostNote = reachableRobotHost.map { " · 로봇 IP \($0) 저장" } ?? ""
        mark(.enableAgent, .success, "Switch agent mode=ssh 전환됨\(hostNote)")

        // ─── ④ Switch 카메라 SSH 터널 (mode 가 카메라를 원할 때만) ───
        if activeStages.contains(.cameraTunnel) {
            enter(.cameraTunnel)
            let tunnelR = await runSwitch(SwitchRobotLinkCommands.enableSwitchCameraTunnel, timeout: 15)
            appendDetail("camera tunnel", combined(tunnelR))
            let tunnelActive = SwitchRobotLinkCommands.parseCameraTunnelActive(tunnelR.stdout)
            if tunnelActive {
                mark(.cameraTunnel, .success, "Switch 카메라 터널 active — :18080 LISTEN 대기")
            } else {
                // soft-fail — agent SSH 가 됐으니 조종은 가능. 카메라만 별도 안내.
                mark(.cameraTunnel, .failed,
                     "터널 enable 결과 active 아님 — sudoers/유닛 설치 확인 (조종 자체는 가능)")
                out.fallbackCommand = switchFallback(SwitchRobotLinkCommands.enableSwitchCameraTunnel)
            }
        }

        // ─── ⑤ 검증 ──────────────────────────────────────────────────
        enter(.verify)
        await refreshApiState()
        await refreshPilotLiveness()
        let st = apiState
        let live = pilotLiveness
        let sshOK = st?.sshConnected == true
        let demoOK = live?.demoRunning == true
        let cameraExpected = activeStages.contains(.cameraTunnel)
        let camOK = st?.cameraRuntime?.localPortOpen == true

        var verifyMsg: [String] = []
        verifyMsg.append(sshOK ? "✓ Switch ssh_connected" : "✗ ssh_connected=false")
        verifyMsg.append(demoOK ? "✓ 로봇 demo 살아있음" : "✗ 로봇 demo 미실행")
        if cameraExpected {
            verifyMsg.append(camOK ? "✓ 카메라 터널 :18080 LISTEN" : "✗ 터널 포트 미활성")
        }

        if sshOK && demoOK {
            // 핵심 통과 — 카메라가 요구된 모드만 추가로 평가.
            let verifyOK = !cameraExpected || camOK
            mark(.verify, verifyOK ? .success : .failed, verifyMsg.joined(separator: " · "))
            switch mode {
            case .cameraAndControl:
                out.summary = camOK
                    ? "카메라+조종 OK — Switch 에서 영상 + 조종 모두 가능"
                    : "조종은 가능 — 카메라 터널만 미활성 (Switch :18080 확인 필요)"
            case .quickPilot:
                out.summary = "빠른 조종 OK — 카메라 없이 조이콘으로 즉시 조종 가능"
            case .diagnostics:
                out.summary = ""  // 진단 모드는 별도 verify 경로 사용
            }
        } else {
            mark(.verify, .failed, verifyMsg.joined(separator: " · "))
            out.summary = sshOK
                ? "Switch SSH 는 연결됐지만 로봇 demo 가 안 떠 있어요 — 다시 시도 또는 로봇 콘솔 확인"
                : "Switch 가 아직 로봇에 SSH 로 붙지 않았어요 — agent 재시작 확인"
        }
        out.currentStage = nil
        demoSuiteOutcome = out
        return mode.stages.allSatisfy { out.stages[$0] == .success }
    }

    /// 진단 모드 전용 verify — 모터를 안 켰으므로 demo 생존을 요구하지 않고, 단지
    /// 패치 존재 + Switch SSH 상태(`/api/state`) + Switch→로봇 SSH probe 까지 확인한다.
    private func runDiagnosticsVerify(_ out: inout DemoSuiteOutcome) async -> Bool {
        out.currentStage = .verify
        out.stages[.verify] = .running
        out.stageMessages[.verify] = "패치/연결 확인 중…"
        demoSuiteOutcome = out

        // 1) Switch → 로봇 SSH probe
        let probeCmd = SwitchRobotLinkCommands.withRobotHost(
            SwitchRobotLinkCommands.probeRobotFromSwitch, effectiveRobotHostArg)
        let probeR = await runSwitch(probeCmd, timeout: 15)
        let probeOK = probeR.ok && probeR.stdout.contains(SwitchRobotLinkCommands.probeOkMarker)
        out.detail += "[probe]\n\(combined(probeR))\n"

        // 2) WalkLab 패치 존재 확인
        let statusCmd = SwitchRobotLinkCommands.withRobotHost(
            SwitchRobotLinkCommands.robotWalkLabStatus, effectiveRobotHostArg)
        let statusR = await runSwitch(statusCmd, timeout: 15)
        let patchOK = statusR.ok && statusR.stdout.contains(SwitchRobotLinkCommands.walkLabPatchOkMarker)
        out.detail += "[status]\n\(combined(statusR))\n"

        // 3) /api/state 새로고침 (참고용)
        await refreshApiState()

        let parts = [
            probeOK ? "✓ Switch→로봇 SSH OK" : "✗ Switch→로봇 SSH 실패",
            patchOK ? "✓ WalkLab 패치 있음" : "✗ WalkLab 패치 없음",
        ]
        if probeOK && patchOK {
            out.stages[.verify] = .success
            out.stageMessages[.verify] = parts.joined(separator: " · ")
            out.summary = "진단 통과 — 언제든 ‘빠른 조종’ 또는 ‘카메라+조종’ 모드로 진입 가능"
        } else {
            out.stages[.verify] = .failed
            out.stageMessages[.verify] = parts.joined(separator: " · ")
            out.summary = "진단 실패 — 다음 행동: " + (
                !probeOK ? "Switch→로봇 SSH 키 등록(9단계 wizard ⑤)"
                          : "로봇에 WalkLab 패치 빌드(install-onboard.sh)"
            )
            if !probeOK {
                out.fallbackCommand = switchFallback(probeCmd)
            } else {
                out.fallbackCommand = switchFallback(statusCmd)
            }
        }
        out.currentStage = nil
        demoSuiteOutcome = out
        return out.stages[.verify] == .success
    }

    /// 하위 호환 — 기존 호출 경로 보존(테스트/외부 트리거 무파장 변경).
    @discardableResult
    public func runDemoSuite() async -> Bool {
        await runLaunch(.cameraAndControl)
    }

    // MARK: - 안정화 / 실사용 검증 (10단계 흐름 밖의 보조 액션)

    /// **안정화 설정 적용** — SSH 전송 빈도↓ + 보행 속도 가변 완만화 + identity 절대경로 +
    /// 닿는 로봇 IP 영구 저장. Switch Wi-Fi 연결 끊김 완화(스펙 §6).
    @discardableResult
    public func runStabilize() async -> Bool {
        guard !isBusy, !isStabilizing else { return false }
        isStabilizing = true
        defer { isStabilizing = false }
        var o = Outcome()
        o.phase = .running
        o.message = "적용 중…"
        stabilizeOutcome = o
        let cmd = SwitchRobotLinkCommands.stabilize(robotHost: effectiveRobotHostArg)
        let r = await runSwitch(cmd, timeout: 25)
        o.detail = combined(r)
        if r.ok && r.stdout.contains("stabilized") {
            o.phase = .success
            o.message = "안정화 설정 적용 완료 — SSH 전송 빈도↓·보행 속도 변화 완만"
        } else {
            o.phase = .failed
            o.message = "안정화 적용 실패 — sudo 권한/서비스 상태 확인"
            o.fallbackCommand = switchFallback(cmd)
        }
        stabilizeOutcome = o
        return o.phase == .success
    }

    /// Switch 조종석 `/api/state` 새로고침 — mode/target/ssh_connected/armed/deadman/
    /// moving/stride/turn 을 UI 가 사용자 문장으로 표시.
    public func refreshApiState() async {
        guard !isRefreshingState else { return }
        isRefreshingState = true
        defer { isRefreshingState = false }
        let r = await runSwitch(SwitchRobotLinkCommands.apiState, timeout: 8)
        if r.ok, let parsed = SwitchRobotLinkCommands.parseApiState(r.stdout) {
            apiState = parsed
        }
    }

    /// 로봇 `/tmp/df-walklab-cmd` 새로고침 — Mac 의 검증된 채널로 읽어 조이콘 입력이
    /// 실제 명령 파일에 반영되는지(stride/turn 변화) 확인.
    public func refreshWalkLabCmd() async {
        guard let result = await robotRun(SwitchRobotLinkCommands.readWalkLabCmdOnRobot) else { return }
        if result.ok, let parsed = SwitchRobotLinkCommands.parseWalkLabCmd(result.output) {
            walkLabCmd = parsed
        }
    }

    /// **로봇 측 실제 생존 새로고침** — demo 프로세스 + ack 신선도. `/api/state` 의
    /// 스위치 측 낙관(armed/moving)을 로봇 측 사실로 교차검증해 거짓 양성을 막는다.
    public func refreshPilotLiveness() async {
        guard let result = await robotRun(SwitchRobotLinkCommands.robotPilotLivenessProbe) else {
            pilotLiveness = nil
            return
        }
        if result.ok, let parsed = SwitchRobotLinkCommands.parsePilotLiveness(result.output) {
            pilotLiveness = parsed
        }
    }

    /// Switch config 가 보는 로봇 target 을 plan 출력에서 파싱(표시용 — 비교 경고).
    public func refreshSwitchConfiguredTarget() async {
        let r = await runSwitch(SwitchRobotLinkCommands.plan, timeout: 10)
        guard r.ok else { return }
        for raw in r.stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Robot SSH target:") {
                switchConfiguredRobotTarget = line
                    .replacingOccurrences(of: "Robot SSH target:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return
            }
        }
    }

    /// Switch config 가 보는 로봇 IP(plan 파싱)와 탐색으로 닿은 IP 가 다른지(정보용).
    /// 다르면 enableAgent 단계가 닿는 IP 로 config 를 고쳐 쓴다 — 정상 동작이므로 경고가 아닌 안내.
    public var robotHostMismatchWarning: String? {
        guard let target = switchConfiguredRobotTarget, !target.isEmpty else { return nil }
        // target 형태: "robotis@192.168.123.1:22"
        let host = target.split(separator: "@").last.map { String($0.split(separator: ":").first ?? "") } ?? ""
        guard !host.isEmpty else { return nil }
        if let reachable = reachableRobotHost {
            guard reachable != host else { return nil }
            return "Switch config 의 로봇 IP(\(host))는 Switch 에서 닿지 않아요. 닿는 IP(\(reachable))로 ‘Switch agent SSH 모드’ 단계에서 config 를 자동 교정합니다."
        }
        guard host != macRobotHost else { return nil }
        return "Mac 이 보는 로봇 IP(\(macRobotHost))와 Switch config 의 로봇 IP(\(host))가 달라요. ‘로봇 네트워크 경로 탐색’ 단계로 Switch 가 닿는 IP 를 먼저 찾으세요."
    }

    /// 연결 확인 → 경로 탐색 → 키 등록 → patch 확인까지 순차 자동 실행. 위험 단계
    /// (start-walklab)는 제외 — 안전 확인 후 사용자가 명시적으로 실행한다. 한 단계라도
    /// 실패하면 중단(다음 행동은 해당 단계 메시지에).
    public func runThroughStatus() async {
        guard await runSwitchReachable() else { return }
        await refreshSwitchConfiguredTarget()
        guard await runDiscoverRoute() else { return }
        guard await runEnsureKey() else { return }
        guard await runReadPublicKey() else { return }
        guard await runInstallOnRobot() else { return }
        guard await runProbe() else { return }
        _ = await runStatus()
    }
}
