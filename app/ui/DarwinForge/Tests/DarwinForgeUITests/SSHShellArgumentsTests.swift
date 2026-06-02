import XCTest
@testable import DarwinForgeUI

/// SSHShell 의 ssh subprocess 인자 빌더 검증.
///
/// 배경: 로봇(DARwIn-OP)은 OpenSSH 5.9 (구형) — 최신 macOS ssh 클라이언트는
/// SHA-1 `ssh-rsa` 서명을 기본 비활성화하므로, `+ssh-rsa` 알고리즘을 명시 허용하고
/// 전용 RSA 키를 써야 key 인증이 성공한다. 이 테스트는 그 인자 구성을 고정한다.
final class SSHShellArgumentsTests: XCTestCase {

    func testLegacyRSACompatIncludedWhenEnabled() {
        let args = SSHShell.sshArguments(
            host: "192.168.123.1", user: "robotis", command: "echo ok",
            connectTimeoutSeconds: 6,
            options: SSHShell.SSHOptions(identityFile: nil, legacyServerCompat: true))

        // 단순 presence 가 아니라 `-o` 가 값 바로 앞에 와야 함 (-o 누락 회귀 차단).
        assertOptionPaired(args, "PubkeyAcceptedAlgorithms=+ssh-rsa")
        assertOptionPaired(args, "HostKeyAlgorithms=+ssh-rsa")
    }

    /// `value` 가 args 에 있고, 그 바로 앞 요소가 `-o` 인지 검증.
    private func assertOptionPaired(_ args: [String], _ value: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard let idx = args.firstIndex(of: value) else {
            return XCTFail("옵션 값 누락: \(value)", file: file, line: line)
        }
        XCTAssertGreaterThan(idx, 0, "옵션 값이 맨 앞 — `-o` 누락", file: file, line: line)
        XCTAssertEqual(args[idx - 1], "-o",
                       "`\(value)` 앞에 `-o` 가 와야 함", file: file, line: line)
    }

    func testLegacyRSACompatOmittedWhenDisabled() {
        let args = SSHShell.sshArguments(
            host: "h", user: "u", command: "c",
            connectTimeoutSeconds: 5,
            options: SSHShell.SSHOptions(identityFile: nil, legacyServerCompat: false))

        XCTAssertFalse(args.contains("PubkeyAcceptedAlgorithms=+ssh-rsa"))
        XCTAssertFalse(args.contains("HostKeyAlgorithms=+ssh-rsa"))
    }

    func testIdentityFileUsesIdentitiesOnly() {
        let key = "/Users/x/.ssh/id_rsa_darwin"
        let args = SSHShell.sshArguments(
            host: "h", user: "u", command: "c",
            connectTimeoutSeconds: 5,
            options: SSHShell.SSHOptions(identityFile: key, legacyServerCompat: true))

        guard let i = args.firstIndex(of: "-i") else {
            return XCTFail("-i 옵션 없음")
        }
        XCTAssertEqual(args[args.index(after: i)], key, "지정한 RSA 키 경로 사용")
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"),
                      "지정 키만 쓰도록 IdentitiesOnly 필요 (다른 키 offer 방지)")
    }

    func testNoIdentityFileOmitsDashI() {
        let args = SSHShell.sshArguments(
            host: "h", user: "u", command: "c",
            connectTimeoutSeconds: 5,
            options: SSHShell.SSHOptions(identityFile: nil, legacyServerCompat: true))

        XCTAssertFalse(args.contains("-i"), "키 미지정 시 -i 생략(기본 키 사용)")
        XCTAssertFalse(args.contains("IdentitiesOnly=yes"))
    }

    func testBatchModeAndHostCommandOrdering() {
        let args = SSHShell.sshArguments(
            host: "192.168.123.1", user: "robotis", command: "echo ok",
            connectTimeoutSeconds: 6,
            options: SSHShell.SSHOptions(identityFile: nil, legacyServerCompat: true))

        // BatchMode = 비번 프롬프트 없이 key 전용.
        XCTAssertTrue(args.contains("BatchMode=yes"))
        // host@user 와 command 가 항상 마지막 2개(순서 보장).
        XCTAssertEqual(args.dropLast().last, "robotis@192.168.123.1")
        XCTAssertEqual(args.last, "echo ok")
    }

    func testConnectTimeoutPropagated() {
        let args = SSHShell.sshArguments(
            host: "h", user: "u", command: "c",
            connectTimeoutSeconds: 8,
            options: SSHShell.SSHOptions())
        XCTAssertTrue(args.contains("ConnectTimeout=8"))
    }

    // MARK: - ② ServerAlive (죽은 연결 빠른 감지) + ① ControlMaster (연결 재사용)

    /// ServerAlive 는 multiplex 여부와 무관하게 항상 포함 — WiFi stall 시 ~4s 내 abort.
    func testServerAliveAlwaysIncluded() {
        let args = SSHShell.sshArguments(
            host: "192.168.0.33", user: "robotis", command: "echo ok",
            connectTimeoutSeconds: 6,
            options: SSHShell.SSHOptions(identityFile: nil, multiplex: false))
        assertOptionPaired(args, "ServerAliveInterval=2")
        assertOptionPaired(args, "ServerAliveCountMax=2")
    }

    /// multiplex=true 면 ControlMaster 3종이 `-o` 페어로 포함.
    func testMultiplexAddsControlMaster() {
        let args = SSHShell.sshArguments(
            host: "192.168.0.33", user: "robotis", command: "echo ok",
            connectTimeoutSeconds: 6,
            options: SSHShell.SSHOptions(identityFile: "/Users/x/.ssh/id_rsa_darwin",
                                         multiplex: true))
        assertOptionPaired(args, "ControlMaster=auto")
        assertOptionPaired(args, "ControlPath=~/.ssh/df-cm-%C")
        assertOptionPaired(args, "ControlPersist=30")
        // host@user / command 는 여전히 마지막 2개(순서 보존).
        XCTAssertEqual(args.dropLast().last, "robotis@192.168.0.33")
        XCTAssertEqual(args.last, "echo ok")
    }

    /// multiplex=false 면 ControlMaster 미포함(소켓 디렉터리 부재 시 연결 실패 회피).
    func testMultiplexOmittedWhenDisabled() {
        let args = SSHShell.sshArguments(
            host: "h", user: "u", command: "c",
            connectTimeoutSeconds: 6,
            options: SSHShell.SSHOptions(identityFile: nil, multiplex: false))
        XCTAssertFalse(args.contains("ControlMaster=auto"))
        XCTAssertFalse(args.contains("ControlPath=~/.ssh/df-cm-%C"))
        XCTAssertFalse(args.contains("ControlPersist=30"))
    }
}
