import XCTest
@testable import DarwinForgeUI

/// `SSHShell.scpArguments` 빌더 검증 (R2 — 에이전트 tarball 전송).
///
/// scp 는 ssh 와 동일 연결 옵션을 공유하되, source(로컬)·destination(`user@host:remote`)
/// 이 **마지막 2개 요소**여야 한다(scp 인자 순서). 이 테스트가 그 구성을 고정한다.
final class SSHShellScpArgumentsTests: XCTestCase {

    func testSourceThenDestinationAreLastTwoArgs() {
        let args = SSHShell.scpArguments(
            localPath: "/tmp/darwin-switch-agent-0.1.0.tar.gz",
            remotePath: "/tmp/darwin-switch-agent-0.1.0.tar.gz",
            host: "192.168.0.25", user: "yuseok",
            connectTimeoutSeconds: 8,
            options: SSHShell.SSHOptions(identityFile: nil, legacyServerCompat: false))

        XCTAssertEqual(args[args.count - 2], "/tmp/darwin-switch-agent-0.1.0.tar.gz",
                       "끝에서 두 번째는 로컬 소스")
        XCTAssertEqual(args.last, "yuseok@192.168.0.25:/tmp/darwin-switch-agent-0.1.0.tar.gz",
                       "마지막은 user@host:remote 목적지")
    }

    func testBatchModeAndConnectTimeoutPresent() {
        let args = SSHShell.scpArguments(
            localPath: "/a", remotePath: "/b", host: "h", user: "u",
            connectTimeoutSeconds: 8,
            options: SSHShell.SSHOptions(identityFile: nil))
        assertOptionPaired(args, "BatchMode=yes")
        assertOptionPaired(args, "StrictHostKeyChecking=accept-new")
        assertOptionPaired(args, "ConnectTimeout=8")
    }

    func testIdentityFilePairedWithIdentitiesOnly() {
        let key = "/Users/x/.ssh/id_rsa_darwin"
        let args = SSHShell.scpArguments(
            localPath: "/a", remotePath: "/b", host: "h", user: "u",
            connectTimeoutSeconds: 5,
            options: SSHShell.SSHOptions(identityFile: key, identitiesOnly: true))
        guard let i = args.firstIndex(of: "-i") else { return XCTFail("`-i` 누락") }
        XCTAssertEqual(args[i + 1], key, "`-i` 다음이 키 경로")
        assertOptionPaired(args, "IdentitiesOnly=yes")
    }

    func testIdentitiesOnlyOmittedWhenFalse() {
        let args = SSHShell.scpArguments(
            localPath: "/a", remotePath: "/b", host: "h", user: "u",
            connectTimeoutSeconds: 5,
            options: SSHShell.SSHOptions(identityFile: "/k", identitiesOnly: false))
        XCTAssertTrue(args.contains("/k"))
        XCTAssertFalse(args.contains("IdentitiesOnly=yes"),
                       "identitiesOnly=false 면 IdentitiesOnly 옵션 없음 (Switch fallback 키 허용)")
    }

    func testLegacyCompatToggle() {
        let on = SSHShell.scpArguments(
            localPath: "/a", remotePath: "/b", host: "h", user: "u",
            connectTimeoutSeconds: 5,
            options: SSHShell.SSHOptions(identityFile: nil, legacyServerCompat: true))
        assertOptionPaired(on, "PubkeyAcceptedAlgorithms=+ssh-rsa")

        let off = SSHShell.scpArguments(
            localPath: "/a", remotePath: "/b", host: "h", user: "u",
            connectTimeoutSeconds: 5,
            options: SSHShell.SSHOptions(identityFile: nil, legacyServerCompat: false))
        XCTAssertFalse(off.contains("PubkeyAcceptedAlgorithms=+ssh-rsa"))
    }

    /// `value` 가 args 에 있고 바로 앞 요소가 `-o` 인지 검증.
    private func assertOptionPaired(_ args: [String], _ value: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let idx = args.firstIndex(of: value) else {
            return XCTFail("옵션 값 누락: \(value)", file: file, line: line)
        }
        XCTAssertGreaterThan(idx, 0, "옵션 값이 맨 앞 — `-o` 누락", file: file, line: line)
        XCTAssertEqual(args[idx - 1], "-o", "`\(value)` 앞에 `-o` 가 와야 함", file: file, line: line)
    }
}
