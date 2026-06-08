import XCTest
@testable import DarwinForgeUI

/// `SwitchAgentDeploySession` 오케스트레이션 검증 (R2).
///
/// 주입된 effect(mock)로 5단계 상태머신을 실 SSH 없이 검증한다:
///   - 단계 게이팅: 앞 단계 실패 시 뒤 단계 미호출.
///   - **보안**: sudo 비밀번호는 install 단계 stdin 으로만 전달, 어떤 명령/결과 detail
///     에도 남지 않는다.
///   - 정직성: 마커/active 가 없으면 성공으로 표시하지 않는다.
@MainActor
final class SwitchAgentDeploySessionTests: XCTestCase {

    /// 호출을 기록하는 mock effects (MainActor 격리).
    final class MockEffects {
        var tarball = SwitchAgentDeploySession.TarballResult(
            ok: true, localPath: "/tmp/darwin-switch-agent-0.1.0.tar.gz",
            version: "0.1.0", log: "packaged")
        var upload = SwitchAgentDeploySession.StageResult(ok: true, output: "")
        var unpack = SwitchAgentDeploySession.StageResult(ok: true, output: "DF_UNPACK_OK\n")
        var install = SwitchAgentDeploySession.StageResult(ok: true, output: "Installed.\nDF_INSTALL_OK\n")
        var verify = SwitchAgentDeploySession.StageResult(
            ok: true, output: "active\n---DF-VER---\n__version__ = \"0.1.0\"\n")

        private(set) var commands: [String] = []
        private(set) var stdins: [String?] = []
        private(set) var uploadArgs: [(String, String)] = []
        private(set) var providedTarball = false

        func effects() -> SwitchAgentDeploySession.Effects {
            SwitchAgentDeploySession.Effects(
                provideTarball: { [self] in providedTarball = true; return tarball },
                uploadFile: { [self] local, remote in
                    uploadArgs.append((local, remote)); return upload
                },
                runSwitch: { [self] command, stdin in
                    commands.append(command)
                    stdins.append(stdin)
                    if command.contains("tar -xzf") { return unpack }
                    if command.contains("install.sh") { return install }
                    if command.contains("is-active") { return verify }
                    return SwitchAgentDeploySession.StageResult(ok: false, output: "unrouted")
                })
        }
    }

    func testHappyPathReachesVerifySuccess() async {
        let mock = MockEffects()
        let session = SwitchAgentDeploySession(effects: mock.effects())

        let ok = await session.deploy(sudoPassword: "secret")

        XCTAssertTrue(ok, "전 단계 성공 → 배포 성공")
        for stage in SwitchAgentDeployCommand.Stage.allCases {
            XCTAssertEqual(session.outcome(stage).phase, .success, "\(stage) 성공")
        }
        XCTAssertEqual(session.deployedVersion, "0.1.0")
        XCTAssertFalse(session.isDeploying, "완료 후 isDeploying=false")
    }

    func testPackageFailureStopsBeforeUpload() async {
        let mock = MockEffects()
        mock.tarball = .init(ok: false, localPath: nil, version: nil, log: "package.sh 실패")
        let session = SwitchAgentDeploySession(effects: mock.effects())

        let ok = await session.deploy(sudoPassword: "secret")

        XCTAssertFalse(ok)
        XCTAssertEqual(session.outcome(.package).phase, .failed)
        XCTAssertTrue(mock.uploadArgs.isEmpty, "패키지 실패 시 업로드 미호출")
        XCTAssertTrue(mock.commands.isEmpty, "SSH 명령 미호출")
    }

    func testUploadFailureStopsBeforeUnpack() async {
        let mock = MockEffects()
        mock.upload = .init(ok: false, output: "scp: Permission denied")
        let session = SwitchAgentDeploySession(effects: mock.effects())

        let ok = await session.deploy(sudoPassword: "secret")

        XCTAssertFalse(ok)
        XCTAssertEqual(session.outcome(.upload).phase, .failed)
        XCTAssertTrue(mock.commands.isEmpty, "업로드 실패 시 원격 명령 미호출")
    }

    func testUnpackMarkerMissingFails() async {
        let mock = MockEffects()
        mock.unpack = .init(ok: true, output: "tar: corrupt\n")  // exit 0 이지만 마커 없음
        let session = SwitchAgentDeploySession(effects: mock.effects())

        let ok = await session.deploy(sudoPassword: "secret")

        XCTAssertFalse(ok, "마커 없으면 성공 아님(정직)")
        XCTAssertEqual(session.outcome(.unpack).phase, .failed)
        // install 명령은 호출되지 않아야.
        XCTAssertFalse(mock.commands.contains { $0.contains("install.sh") })
    }

    func testSudoAuthFailureReportedAndStops() async {
        let mock = MockEffects()
        mock.install = .init(ok: false, output: "[sudo] password for yuseok: \nSorry, try again.\n")
        let session = SwitchAgentDeploySession(effects: mock.effects())

        let ok = await session.deploy(sudoPassword: "wrong")

        XCTAssertFalse(ok)
        XCTAssertEqual(session.outcome(.install).phase, .failed)
        XCTAssertTrue(session.outcome(.install).message.contains("비밀번호"),
                      "sudo 비번 오류를 사용자에게 안내")
        XCTAssertFalse(mock.commands.contains { $0.contains("is-active") },
                       "설치 실패 시 검증 미호출")
    }

    func testVersionMismatchFails() async {
        let mock = MockEffects()
        mock.verify = .init(ok: true, output: "active\n---DF-VER---\n__version__ = \"9.9.9\"\n")
        let session = SwitchAgentDeploySession(effects: mock.effects())

        let ok = await session.deploy(sudoPassword: "secret")

        XCTAssertFalse(ok, "설치 버전 ≠ 패키지 버전 → 실패")
        XCTAssertEqual(session.outcome(.verify).phase, .failed)
    }

    func testInactiveServiceFails() async {
        let mock = MockEffects()
        mock.verify = .init(ok: true, output: "inactive\n")
        let session = SwitchAgentDeploySession(effects: mock.effects())

        let ok = await session.deploy(sudoPassword: "secret")

        XCTAssertFalse(ok)
        XCTAssertEqual(session.outcome(.verify).phase, .failed)
    }

    // MARK: - 보안: 비밀번호 격리

    func testPasswordPassedOnlyToInstallStdinAndNeverLeaks() async {
        let mock = MockEffects()
        let session = SwitchAgentDeploySession(effects: mock.effects())
        let password = "S3cr3t!pw"

        _ = await session.deploy(sudoPassword: password)

        // runSwitch 호출은 unpack, install, verify 3건.
        XCTAssertEqual(mock.commands.count, 3)
        for (cmd, stdin) in zip(mock.commands, mock.stdins) {
            if cmd.contains("install.sh") {
                XCTAssertEqual(stdin, password + "\n", "install 단계만 비번을 stdin 으로(개행 포함)")
            } else {
                XCTAssertNil(stdin, "install 외 단계는 stdin 없음")
            }
            // 어떤 명령행에도 비번 평문이 없어야 한다.
            XCTAssertFalse(cmd.contains(password), "명령행에 비번 평문 금지: \(cmd)")
        }
        // 업로드 인자에도 비번 없음.
        for (a, b) in mock.uploadArgs {
            XCTAssertFalse(a.contains(password)); XCTAssertFalse(b.contains(password))
        }
        // 어떤 단계의 UI 메시지/detail 에도 비번이 남지 않아야 한다.
        for stage in SwitchAgentDeployCommand.Stage.allCases {
            let o = session.outcome(stage)
            XCTAssertFalse(o.message.contains(password), "\(stage) message 비번 누출")
            XCTAssertFalse(o.detail.contains(password), "\(stage) detail 비번 누출")
        }
    }

    func testCommandsTargetCorrectVersionPaths() async {
        let mock = MockEffects()
        let session = SwitchAgentDeploySession(effects: mock.effects())
        _ = await session.deploy(sudoPassword: "secret")

        XCTAssertEqual(mock.uploadArgs.first?.1, "/tmp/darwin-switch-agent-0.1.0.tar.gz",
                       "업로드 목적지가 버전 경로")
        XCTAssertTrue(mock.commands.contains { $0.contains("/tmp/df-agent-deploy/darwin-switch-agent-0.1.0") },
                      "install 이 버전 디렉터리 사용")
    }
}
