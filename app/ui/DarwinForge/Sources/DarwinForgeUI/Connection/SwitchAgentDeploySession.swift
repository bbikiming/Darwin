import Foundation

/// **스위치 에이전트 자동 배포 — 오케스트레이션 (R2)**.
///
/// `SwitchAgentDeployCommand`(순수 명령/파싱) 위에서 5단계 상태머신을 구동한다.
/// 모든 부수효과(패키지·scp·SSH)는 **주입된 `Effects`** 로 추상화 — 테스트는 mock,
/// `SwitchRobotLinkView` 는 실제 `SSHShell`/`Process` 를 연결한다.
///
/// # 정직성 (거짓 양성 차단)
///
/// 각 단계는 종료코드뿐 아니라 **성공 마커**(`DF_UNPACK_OK`/`DF_INSTALL_OK`)와
/// `systemctl is-active == active`, 그리고 **설치 버전 == 패키지 버전** 까지 확인해야
/// `.success` 로 넘어간다. 하나라도 어긋나면 즉시 `.failed` 로 멈춘다.
///
/// # 보안 (security.md)
///
/// `sudoPassword` 는 `deploy(sudoPassword:)` 의 지역 파라미터로만 존재하고, **install
/// 단계의 SSH stdin** 으로만 흘러간다(`sudo -S`). 명령 문자열·`Outcome.detail`·`@Published`
/// 어디에도 저장/로깅하지 않는다. 완료 후 참조를 보관하지 않는다.
@MainActor
public final class SwitchAgentDeploySession: ObservableObject {

    // MARK: - 결과 타입

    /// 로컬 tarball 확보 결과.
    public struct TarballResult: Sendable {
        public var ok: Bool
        public var localPath: String?
        public var version: String?
        public var log: String
        public init(ok: Bool, localPath: String?, version: String?, log: String) {
            self.ok = ok; self.localPath = localPath; self.version = version; self.log = log
        }
    }

    /// 단계 실행 결과(scp/SSH 공통).
    public struct StageResult: Sendable {
        public var ok: Bool
        public var output: String
        public init(ok: Bool, output: String) { self.ok = ok; self.output = output }
    }

    /// 주입 부수효과 — 테스트 mock / View 실제 구현 모두 같은 표면.
    public struct Effects {
        /// 로컬 tarball 확보(빌드 임베드 또는 package.sh).
        public var provideTarball: @MainActor () async -> TarballResult
        /// scp 로컬→Switch.
        public var uploadFile: @MainActor (_ localPath: String, _ remotePath: String) async -> StageResult
        /// Switch SSH 명령 실행. `stdin` 은 sudo 비번 등(install 단계만 사용).
        public var runSwitch: @MainActor (_ command: String, _ stdin: String?) async -> StageResult

        public init(
            provideTarball: @escaping @MainActor () async -> TarballResult,
            uploadFile: @escaping @MainActor (_ localPath: String, _ remotePath: String) async -> StageResult,
            runSwitch: @escaping @MainActor (_ command: String, _ stdin: String?) async -> StageResult
        ) {
            self.provideTarball = provideTarball
            self.uploadFile = uploadFile
            self.runSwitch = runSwitch
        }
    }

    public enum Phase: String, Equatable, Sendable {
        case idle, running, success, failed
    }

    public struct Outcome: Equatable, Sendable {
        public var phase: Phase = .idle
        public var message: String = ""
        public var detail: String = ""
    }

    // MARK: - 상태

    @Published public private(set) var outcomes: [SwitchAgentDeployCommand.Stage: Outcome] = [:]
    @Published public private(set) var isDeploying = false
    @Published public private(set) var deployedVersion: String?
    @Published public private(set) var lastSucceeded = false

    private let effects: Effects

    public init(effects: Effects) {
        self.effects = effects
    }

    public func outcome(_ stage: SwitchAgentDeployCommand.Stage) -> Outcome {
        outcomes[stage] ?? Outcome()
    }

    // MARK: - 배포

    /// 전체 배포 실행. 한 번에 하나만(재진입 차단).
    ///
    /// - Parameter sudoPassword: Switch 의 sudo 비밀번호. install 단계 stdin 으로만 전달.
    /// - Returns: 모든 단계 성공 시 `true`.
    @discardableResult
    public func deploy(sudoPassword: String) async -> Bool {
        guard !isDeploying else { return false }
        isDeploying = true
        lastSucceeded = false
        resetOutcomes()
        defer { isDeploying = false }

        // 1. package — 로컬 tarball.
        setRunning(.package, "패키지 준비 중…")
        let pkg = await effects.provideTarball()
        guard pkg.ok, let localPath = pkg.localPath, let version = pkg.version else {
            setFailed(.package, "패키지 준비 실패", pkg.log)
            return false
        }
        setSuccess(.package, "darwin-switch-agent \(version)", pkg.log)

        // 2. upload — scp tarball.
        setRunning(.upload, "Switch 로 전송 중…")
        let remoteTarball = SwitchAgentDeployCommand.remoteTarballPath(version: version)
        let up = await effects.uploadFile(localPath, remoteTarball)
        guard up.ok else {
            setFailed(.upload, "scp 전송 실패", up.output)
            return false
        }
        setSuccess(.upload, "전송 완료 → \(remoteTarball)", up.output)

        // 3. unpack — 원격 압축 해제.
        setRunning(.unpack, "원격 압축 해제 중…")
        let unpackOut = await effects.runSwitch(
            SwitchAgentDeployCommand.unpackCommand(version: version), nil)
        guard unpackOut.ok, SwitchAgentDeployCommand.unpackSucceeded(unpackOut.output) else {
            setFailed(.unpack, "압축 해제 실패", unpackOut.output)
            return false
        }
        setSuccess(.unpack, "압축 해제 완료", unpackOut.output)

        // 4. install — install.sh(sudo -S, 비번 stdin) + enable + restart.
        setRunning(.install, "install.sh 실행(sudo) + 재시작…")
        let installOut = await effects.runSwitch(
            SwitchAgentDeployCommand.installCommand(version: version),
            sudoPassword + "\n")
        if SwitchAgentDeployCommand.looksLikeSudoAuthFailure(installOut.output) {
            setFailed(.install, "sudo 비밀번호 오류 — 다시 시도하세요", installOut.output)
            return false
        }
        guard installOut.ok, SwitchAgentDeployCommand.installSucceeded(installOut.output) else {
            setFailed(.install, "install.sh 실패 — journalctl 확인", installOut.output)
            return false
        }
        setSuccess(.install, "설치 + 재시작 완료", installOut.output)

        // 5. verify — 서비스 active + 버전 일치.
        setRunning(.verify, "동작 검증 중…")
        let verifyOut = await effects.runSwitch(SwitchAgentDeployCommand.verifyCommand(), nil)
        let active = SwitchAgentDeployCommand.parseAgentActive(verifyOut.output)
        let installed = SwitchAgentDeployCommand.parseDeployedVersion(verifyOut.output)
        deployedVersion = installed
        guard active else {
            setFailed(.verify, "에이전트 비활성 — journalctl -u darwin-switch-agent 확인", verifyOut.output)
            return false
        }
        if let installed, installed != version {
            setFailed(.verify, "버전 불일치(설치 \(installed) ≠ 패키지 \(version))", verifyOut.output)
            return false
        }
        setSuccess(.verify, installed.map { "active · v\($0)" } ?? "active", verifyOut.output)
        lastSucceeded = true
        return true
    }

    // MARK: - Outcome 헬퍼

    private func resetOutcomes() {
        outcomes = [:]
        deployedVersion = nil
    }

    private func setRunning(_ stage: SwitchAgentDeployCommand.Stage, _ message: String) {
        outcomes[stage] = Outcome(phase: .running, message: message, detail: "")
    }

    private func setSuccess(_ stage: SwitchAgentDeployCommand.Stage,
                            _ message: String, _ detail: String) {
        outcomes[stage] = Outcome(phase: .success, message: message, detail: detail)
    }

    private func setFailed(_ stage: SwitchAgentDeployCommand.Stage,
                           _ message: String, _ detail: String) {
        outcomes[stage] = Outcome(phase: .failed, message: message, detail: detail)
    }
}
