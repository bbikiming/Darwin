import Foundation

/// **번들된 에이전트 패키지 로케이터 + 실제 배포 effect 빌더 (R2 글루)**.
///
/// `scripts/build-app.sh` / `run-app.sh` 가 `package.sh` 산출물
/// `darwin-switch-agent-<ver>.tar.gz` 를 `DarwinForge.app/Contents/Resources/` 에
/// 임베드한다. 배포의 package 단계는 그 tarball 을 찾아 버전과 함께 돌려준다.
///
/// 순수 파싱(`versionFromTarballName`)은 `SwitchAgentDeployCommand` 에서 단위 검증되고,
/// 여기는 파일시스템/SSH 글루라 단위 테스트 대상이 아니다(주입 effect 로 세션이 검증됨).
public enum SwitchAgentDeployBundle {

    /// Resources 에서 임베드된 에이전트 tarball 탐색.
    public static func locateTarball() -> SwitchAgentDeploySession.TarballResult {
        let fm = FileManager.default
        var searchDirs: [URL] = []
        if let main = Bundle.main.resourceURL { searchDirs.append(main) }
        if let module = Bundle.module.resourceURL { searchDirs.append(module) }

        for dir in searchDirs {
            guard let urls = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            if let tar = urls.first(where: {
                let n = $0.lastPathComponent
                return n.hasPrefix("darwin-switch-agent-") && n.hasSuffix(".tar.gz")
            }), let version = SwitchAgentDeployCommand.versionFromTarballName(tar.lastPathComponent) {
                return .init(ok: true, localPath: tar.path, version: version,
                             log: "번들 패키지: \(tar.lastPathComponent)")
            }
        }
        return .init(ok: false, localPath: nil, version: nil,
                     log: "앱에 에이전트 패키지가 없습니다 — scripts/build-app.sh 로 재빌드하면 임베드됩니다.")
    }

    /// Switch SSH 옵션 — 공용 `id_rsa_darwin` 키를 offer 하되 사용자 기본 키도 fallback
    /// (비표준 파일명이라 자동 offer 안 됨). 최신 Ubuntu 라 legacy compat 불요.
    /// `SwitchRobotLinkSession.switchOptions()` 와 동일 정책.
    public static func switchSSHOptions() -> SSHShell.SSHOptions {
        let rsaPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/id_rsa_darwin")
        let identity = FileManager.default.fileExists(atPath: rsaPath) ? rsaPath : nil
        return SSHShell.SSHOptions(identityFile: identity,
                                   legacyServerCompat: false,
                                   multiplex: false,
                                   identitiesOnly: false)
    }

    /// 실제 배포 effect — `package.sh` 산출 tarball(번들) + `scp` + `ssh`.
    ///
    /// - Parameter switchTarget: 호출 시점의 (host, user) 를 돌려주는 클로저
    ///   (사용자가 편집 가능한 `SwitchRobotLinkSession.switchHost/User` 를 라이브로 읽음).
    @MainActor
    public static func liveEffects(
        switchTarget: @escaping @MainActor () -> (host: String, user: String)
    ) -> SwitchAgentDeploySession.Effects {
        SwitchAgentDeploySession.Effects(
            provideTarball: {
                // 파일시스템 접근은 백그라운드로 — UI 블로킹 회피.
                await Task.detached(priority: .userInitiated) {
                    locateTarball()
                }.value
            },
            uploadFile: { local, remote in
                let target = switchTarget()
                do {
                    let r = try await SSHShell.copyFile(
                        localPath: local, remotePath: remote,
                        host: target.host, user: target.user,
                        timeoutSeconds: 120, options: switchSSHOptions())
                    return .init(ok: r.ok, output: r.combined)
                } catch {
                    return .init(ok: false, output: deployErrorText(error))
                }
            },
            runSwitch: { command, stdin in
                let target = switchTarget()
                do {
                    let r = try await SSHShell.run(
                        command: command, host: target.host, user: target.user,
                        timeoutSeconds: 180, options: switchSSHOptions(), stdin: stdin)
                    return .init(ok: r.ok, output: r.combined)
                } catch {
                    return .init(ok: false, output: deployErrorText(error))
                }
            })
    }

    private static func deployErrorText(_ error: Error) -> String {
        if case SSHShell.SSHError.keyAuthRequired = error {
            return "Mac → Switch SSH 키 인증 실패(비밀번호 필요) — id_rsa_darwin 등록 확인"
        }
        if case SSHShell.SSHError.timeout = error {
            return "시간 초과 — Switch IP/네트워크 확인"
        }
        return error.localizedDescription
    }
}
