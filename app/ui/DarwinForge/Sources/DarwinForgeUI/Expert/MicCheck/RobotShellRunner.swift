import Foundation

/// 로봇 측 셸 명령 실행 결과 — `SSHShell.Result` 와 독립된 값 타입.
///
/// 오케스트레이터(`MicCheckStore`)가 SSHShell 구체 타입에 직접 묶이지 않도록 경계를 둔다.
/// 테스트는 이 값 타입을 직접 구성해 mock 실행기를 만든다.
public struct RobotShellOutput: Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let elapsedMs: Int

    public init(stdout: String, stderr: String, exitCode: Int32, elapsedMs: Int) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.elapsedMs = elapsedMs
    }

    public var ok: Bool { exitCode == 0 }

    /// stdout + stderr 를 합친 사람이 읽는 텍스트(진단 표시용).
    public var combined: String {
        stderr.isEmpty ? stdout : "\(stdout)\n--- stderr ---\n\(stderr)"
    }
}

/// 로봇 측 셸 명령 실행기 추상화.
///
/// 프로덕션은 `SSHRobotShellRunner`(SSHShell 래핑), 테스트는 canned 출력 mock 을 주입한다.
public protocol RobotShellRunning {
    func run(_ command: String) async throws -> RobotShellOutput
}

/// SSHShell 기반 프로덕션 실행기 — host/user 를 보관하고 `SSHShell.run` 으로 위임.
///
/// `RemoteShell` 환경 객체의 `host`/`username` 으로 구성한다(원격 명령 화면과 동일 채널).
public struct SSHRobotShellRunner: RobotShellRunning {
    public let host: String
    public let user: String
    public let timeoutSeconds: TimeInterval

    /// - timeoutSeconds: 녹음 명령은 최대 15초 실행되므로 기본 30초로 충분한 여유.
    public init(host: String, user: String, timeoutSeconds: TimeInterval = 30) {
        self.host = host
        self.user = user
        self.timeoutSeconds = timeoutSeconds
    }

    public func run(_ command: String) async throws -> RobotShellOutput {
        let result = try await SSHShell.run(
            command: command, host: host, user: user, timeoutSeconds: timeoutSeconds
        )
        return RobotShellOutput(
            stdout: result.stdout, stderr: result.stderr,
            exitCode: result.exitCode, elapsedMs: result.elapsedMs
        )
    }
}
