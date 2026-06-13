import Foundation
import SwiftUI

/// **ROG Ally FPV 데모 — 로직/상태 계층**
///
/// Mac→ROG Ally(Windows OpenSSH) 점검을 `SSHShell` 로 수행하고, 단일 세션 가드
/// (Mac 로봇 연결 해제)를 소유한다. 명령 문자열은 전부 `AllyFpvCommands`(순수)에서
/// 가져오므로 이 클래스는 *실행·상태*만 담당한다. 표시는 `AllyFpvLauncherView`.
///
/// 단일 세션 규칙(05 §6): ROG Ally 가 로봇을 조종하는 동안 Mac DarwinForge 는 로봇
/// 연결을 끊어야 한다 — `disconnectRobotForAlly()` 가 기존 `ConnectionStore.disconnect()`
/// 를 재사용.
@MainActor
public final class AllyFpvLauncherSession: ObservableObject {

    // MARK: - 점검 항목

    public enum CheckId: String, CaseIterable, Identifiable, Sendable {
        case reachable     // Ally 도달성 (hostname)
        case w0Smoke       // 와이어 계약 패리티 (cargo test)
        case cliProbe      // ally-cli 경로 탐지 (TCP :22)
        case fpvReady      // darwin-fpv(W2) 빌드 산출물 존재
        case cliConnect    // ally-cli 풀 연결 게이트(headless)

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .reachable:  return "ROG Ally 연결 확인"
            case .w0Smoke:    return "와이어 계약 패리티 (W0)"
            case .cliProbe:   return "로봇 경로 탐지 (ally-cli probe)"
            case .fpvReady:   return "FPV 앱 준비 상태 (darwin-fpv)"
            case .cliConnect: return "연결 게이트 실연 (ally-cli connect)"
            }
        }
        /// cargo build 를 포함해 오래 걸리는 명령(긴 타임아웃 필요).
        var isLongRunning: Bool { self == .w0Smoke || self == .cliProbe || self == .cliConnect }
    }

    public enum Phase: Equatable, Sendable { case idle, running, success, failed }

    public struct CheckOutcome: Equatable, Sendable {
        public var phase: Phase = .idle
        public var message: String = ""
        public var detail: String = ""
    }

    // MARK: - 사용자 입력 (편집 가능)

    @Published public var allyHost: String = ""
    @Published public var allyUser: String = ""
    /// Mac→Ally SSH 키 경로(옵션). 비면 시스템 키/ssh-agent 사용.
    @Published public var allyIdentity: String = ""
    /// ally-cli 가 로봇에 SSH 할 때 쓰는 **Ally 로컬** 키 경로.
    @Published public var robotIdentityOnAlly: String = AllyFpvCommands.defaultRobotIdentityOnAlly
    @Published public var allyRepoPath: String = AllyFpvCommands.defaultAllyRepoPath
    @Published public var prefer: AllyFpvCommands.NetPath = .wired

    // MARK: - 결과 상태

    @Published public private(set) var outcomes: [CheckId: CheckOutcome] = [:]
    @Published public private(set) var runningCheck: CheckId?
    @Published public private(set) var fpvReady: Bool = false
    @Published public private(set) var launchOutcome = CheckOutcome()

    // MARK: - 단일 세션 가드

    @Published public private(set) var robotConnected: Bool
    @Published public private(set) var didDisconnectRobot = false

    private weak var store: ConnectionStore?

    public init(store: ConnectionStore?) {
        self.store = store
        self.robotConnected = Self.isRobotConnected(store)
    }

    static func isRobotConnected(_ store: ConnectionStore?) -> Bool {
        guard let store else { return false }
        if case .connected = store.status { return true }
        return false
    }

    public func refreshRobotConnection() {
        robotConnected = Self.isRobotConnected(store)
    }

    /// Mac 의 로봇 연결을 끊어 ROG Ally 에 단독 소유권을 넘긴다(단일 세션 규칙).
    public func disconnectRobotForAlly() {
        store?.disconnect()
        didDisconnectRobot = true
        refreshRobotConnection()
    }

    // MARK: - 명령 매핑

    func command(for id: CheckId) -> String {
        switch id {
        case .reachable:  return AllyFpvCommands.reachable()
        case .w0Smoke:    return AllyFpvCommands.w0Smoke(repo: allyRepoPath)
        case .cliProbe:   return AllyFpvCommands.cliProbe(prefer: prefer, repo: allyRepoPath)
        case .fpvReady:   return AllyFpvCommands.fpvReadyProbe(repo: allyRepoPath)
        case .cliConnect: return AllyFpvCommands.cliConnect(identity: robotIdentityOnAlly,
                                                            prefer: prefer, repo: allyRepoPath)
        }
    }

    public var inputsReady: Bool {
        !allyHost.trimmingCharacters(in: .whitespaces).isEmpty
            && !allyUser.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - 실행

    public func runCheck(_ id: CheckId) async {
        guard runningCheck == nil else { return }
        guard let (host, user) = validatedTarget(failing: id) else { return }
        runningCheck = id
        set(id, .running, "실행 중…")
        do {
            let res = try await runSSH(command(for: id), host: host, user: user, long: id.isLongRunning)
            apply(id, res)
        } catch {
            set(id, .failed, "SSH 실행 실패", detail: "\(error)")
        }
        runningCheck = nil
    }

    /// darwin-fpv 실행(W2 준비 시). View 가 단일 세션 가드 통과 후에만 호출.
    public func launchFpv() async {
        guard let (host, user) = validatedTarget(failing: nil) else {
            launchOutcome = CheckOutcome(phase: .failed, message: "ROG Ally IP/계정을 먼저 입력하세요.")
            return
        }
        launchOutcome = CheckOutcome(phase: .running, message: "ROG Ally 에서 FPV 앱 실행 중…")
        do {
            let res = try await runSSH(AllyFpvCommands.fpvLaunch(repo: allyRepoPath),
                                       host: host, user: user, long: false)
            launchOutcome = res.ok
                ? CheckOutcome(phase: .success, message: "ROG Ally 화면에서 FPV 데모가 실행됐어요.", detail: res.combined)
                : CheckOutcome(phase: .failed, message: "실행 실패 — FPV 앱 경로를 확인하세요.", detail: res.combined)
        } catch {
            launchOutcome = CheckOutcome(phase: .failed, message: "SSH 실행 실패", detail: "\(error)")
        }
    }

    public func outcome(_ id: CheckId) -> CheckOutcome { outcomes[id] ?? CheckOutcome() }

    // MARK: - 내부

    private func validatedTarget(failing id: CheckId?) -> (host: String, user: String)? {
        let host = allyHost.trimmingCharacters(in: .whitespaces)
        let user = allyUser.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !user.isEmpty else {
            if let id { set(id, .failed, "ROG Ally 의 IP 와 계정을 먼저 입력하세요.") }
            return nil
        }
        return (host, user)
    }

    private func runSSH(_ cmd: String, host: String, user: String, long: Bool) async throws -> SSHShell.Result {
        let identity = allyIdentity.trimmingCharacters(in: .whitespaces)
        let opts = SSHShell.SSHOptions(
            identityFile: identity.isEmpty ? nil : identity,
            legacyServerCompat: false,                 // Windows OpenSSH = 최신 (legacy 옵션 불요)
            multiplex: false,
            identitiesOnly: !identity.isEmpty)
        return try await SSHShell.run(command: cmd, host: host, user: user,
                                      timeoutSeconds: long ? 240 : 25, options: opts)
    }

    private func apply(_ id: CheckId, _ res: SSHShell.Result) {
        switch id {
        case .reachable:
            res.ok ? set(id, .success, "도달 OK — \(res.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
                   : set(id, .failed, "도달 실패", detail: res.combined)
        case .w0Smoke:
            if let t = AllyFpvCommands.parseCargoTest(res.combined) {
                set(id, t.ok ? .success : .failed,
                    "테스트 \(t.passed) passed / \(t.failed) failed", detail: res.combined)
            } else {
                set(id, res.ok ? .success : .failed, "결과 파싱 불가", detail: res.combined)
            }
        case .cliProbe:
            let p = AllyFpvCommands.parseProbe(res.combined, exitCode: res.exitCode)
            set(id, p.ok ? .success : .failed,
                p.ok ? "경로 도달 OK (\(prefer.label))" : "경로 도달 실패", detail: p.detail)
        case .cliConnect:
            set(id, res.ok ? .success : .failed,
                res.ok ? "연결 게이트 통과 — 조종 채널이 섭니다" : "연결 게이트 실패", detail: res.combined)
        case .fpvReady:
            let ready = AllyFpvCommands.parseFpvReady(res.combined)
            fpvReady = ready
            set(id, ready ? .success : .failed,
                ready ? "darwin-fpv 준비됨 — 실행할 수 있어요" : "darwin-fpv 미빌드 (W2 선행 필요)",
                detail: res.combined)
        }
    }

    /// 불변 교체 — outcomes 딕셔너리를 새 값으로 대체(mutation 회피).
    private func set(_ id: CheckId, _ phase: Phase, _ message: String, detail: String = "") {
        var next = outcomes
        next[id] = CheckOutcome(phase: phase, message: message, detail: detail)
        outcomes = next
    }
}
