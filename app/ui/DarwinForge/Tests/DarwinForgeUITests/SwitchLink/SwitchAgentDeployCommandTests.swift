import XCTest
@testable import DarwinForgeUI

/// `SwitchAgentDeployCommand` 순수 명령/파싱 검증 (R2 — 앱 내 스위치 에이전트 자동배포).
///
/// 배포는 package(tarball) → scp → 원격 압축해제 → install.sh(sudo) + 재시작 → 검증의
/// 5단계. 모든 원격 명령은 결정적 문자열이라 SSH 없이 고정 검증한다. 보안 핵심:
/// **sudo 비밀번호는 명령행에 절대 들어가지 않고** `sudo -S`(stdin) 로만 전달된다.
final class SwitchAgentDeployCommandTests: XCTestCase {

    // MARK: - 경로/이름 (결정적)

    func testTarballAndPackageNaming() {
        XCTAssertEqual(SwitchAgentDeployCommand.tarballName(version: "0.1.0"),
                       "darwin-switch-agent-0.1.0.tar.gz")
        XCTAssertEqual(SwitchAgentDeployCommand.packageDirName(version: "0.1.0"),
                       "darwin-switch-agent-0.1.0")
        XCTAssertEqual(SwitchAgentDeployCommand.remoteTarballPath(version: "0.1.0"),
                       "/tmp/darwin-switch-agent-0.1.0.tar.gz")
        XCTAssertEqual(SwitchAgentDeployCommand.remotePackageDir(version: "0.1.0"),
                       "/tmp/df-agent-deploy/darwin-switch-agent-0.1.0")
    }

    // MARK: - 원격 명령 구성

    func testUnpackCommandCleansStageDirAndExtracts() {
        let cmd = SwitchAgentDeployCommand.unpackCommand(version: "0.1.0")
        // 이전 배포 잔재 제거 후 새로 풀기 (idempotent).
        XCTAssertTrue(cmd.contains("rm -rf /tmp/df-agent-deploy"), "스테이지 디렉터리 정리")
        XCTAssertTrue(cmd.contains("mkdir -p /tmp/df-agent-deploy"))
        XCTAssertTrue(cmd.contains("tar -xzf /tmp/darwin-switch-agent-0.1.0.tar.gz -C /tmp/df-agent-deploy"))
        XCTAssertTrue(cmd.contains("DF_UNPACK_OK"), "성공 마커 echo")
    }

    func testInstallCommandUsesSudoStdinAndNeverEmbedsPassword() {
        let cmd = SwitchAgentDeployCommand.installCommand(version: "0.1.0")
        // 패키지 디렉터리로 이동 후 설치.
        XCTAssertTrue(cmd.contains("cd /tmp/df-agent-deploy/darwin-switch-agent-0.1.0"))
        // **보안**: sudo -S 로 stdin 비번 — 프롬프트 억제(-p '') 로 stderr 오염 방지.
        XCTAssertTrue(cmd.contains("sudo -S"), "비번은 stdin 으로만(-S)")
        XCTAssertTrue(cmd.contains("-p ''"), "sudo 프롬프트 억제")
        // install.sh + 부팅 enable + 새 코드 로드용 restart 가 한 sudo 세션 안.
        XCTAssertTrue(cmd.contains("bash install.sh"))
        XCTAssertTrue(cmd.contains("systemctl enable darwin-switch-agent"))
        XCTAssertTrue(cmd.contains("systemctl restart darwin-switch-agent"))
        XCTAssertTrue(cmd.contains("DF_INSTALL_OK"), "성공 마커 echo")
        // 명령 빌더는 비번을 인자로 받지 않으므로 어떤 비번 문자열도 포함될 수 없다.
        XCTAssertFalse(cmd.lowercased().contains("password"))
    }

    func testVerifyCommandChecksActiveAndReadsVersion() {
        let cmd = SwitchAgentDeployCommand.verifyCommand()
        XCTAssertTrue(cmd.contains("systemctl is-active darwin-switch-agent"))
        // 설치 버전 확인 — 배포 버전 일치 검증용.
        XCTAssertTrue(cmd.contains("__version__"))
        XCTAssertTrue(cmd.contains("/opt/darwin-switch-agent/src/darwin_switch_agent/__init__.py"))
    }

    // MARK: - 파싱 (정직성: 마커 없으면 실패)

    func testUnpackSucceededRequiresMarker() {
        XCTAssertTrue(SwitchAgentDeployCommand.unpackSucceeded("foo\nDF_UNPACK_OK\n"))
        XCTAssertFalse(SwitchAgentDeployCommand.unpackSucceeded("tar: error\n"))
        XCTAssertFalse(SwitchAgentDeployCommand.unpackSucceeded(""))
    }

    func testInstallSucceededRequiresMarker() {
        XCTAssertTrue(SwitchAgentDeployCommand.installSucceeded("Installed Darwin Switch Agent.\nDF_INSTALL_OK\n"))
        // install.sh 실패 시 && 체인이 끊겨 마커가 안 나온다 → 실패로 판정.
        XCTAssertFalse(SwitchAgentDeployCommand.installSucceeded("install.sh must be run with sudo\n"))
        XCTAssertFalse(SwitchAgentDeployCommand.installSucceeded(""))
    }

    func testParseAgentActiveOnlyForActiveState() {
        XCTAssertTrue(SwitchAgentDeployCommand.parseAgentActive("active\n---DF-VER---\n__version__ = \"0.1.0\"\n"))
        // "activating"/"inactive"/"failed" 는 active 아님 (부분일치 오판 차단).
        XCTAssertFalse(SwitchAgentDeployCommand.parseAgentActive("activating\n"))
        XCTAssertFalse(SwitchAgentDeployCommand.parseAgentActive("inactive\n"))
        XCTAssertFalse(SwitchAgentDeployCommand.parseAgentActive("failed\n"))
        XCTAssertFalse(SwitchAgentDeployCommand.parseAgentActive(""))
    }

    func testParseDeployedVersionExtractsQuotedValue() {
        let out = "active\n---DF-VER---\n__version__ = \"0.1.0\"\n"
        XCTAssertEqual(SwitchAgentDeployCommand.parseDeployedVersion(out), "0.1.0")
        // 버전 줄 없으면 nil.
        XCTAssertNil(SwitchAgentDeployCommand.parseDeployedVersion("active\n"))
    }

    func testLooksLikeSudoAuthFailure() {
        XCTAssertTrue(SwitchAgentDeployCommand.looksLikeSudoAuthFailure("[sudo] password: Sorry, try again.\n"))
        XCTAssertTrue(SwitchAgentDeployCommand.looksLikeSudoAuthFailure("sudo: a password is required\n"))
        XCTAssertFalse(SwitchAgentDeployCommand.looksLikeSudoAuthFailure("Installed Darwin Switch Agent.\nDF_INSTALL_OK\n"))
    }

    // MARK: - 단계 메타

    func testStagesAreOrdered() {
        XCTAssertEqual(SwitchAgentDeployCommand.Stage.allCases,
                       [.package, .upload, .unpack, .install, .verify])
    }

    func testVersionFromTarballName() {
        XCTAssertEqual(SwitchAgentDeployCommand.versionFromTarballName("darwin-switch-agent-0.1.0.tar.gz"), "0.1.0")
        XCTAssertEqual(SwitchAgentDeployCommand.versionFromTarballName("darwin-switch-agent-1.2.3-rc1.tar.gz"), "1.2.3-rc1")
        XCTAssertNil(SwitchAgentDeployCommand.versionFromTarballName("darwin-switch-agent-.tar.gz"))
        XCTAssertNil(SwitchAgentDeployCommand.versionFromTarballName("other.tar.gz"))
        XCTAssertNil(SwitchAgentDeployCommand.versionFromTarballName("darwin-switch-agent-0.1.0.zip"))
    }
}
