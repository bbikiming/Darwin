import Foundation

/// **스위치 에이전트 자동 배포 — 순수 명령/파싱 (R2)**.
///
/// Mac DarwinForge 가 한 번의 클릭으로 최신 `darwin-switch-agent` 를 Switch 에 배포한다:
///
///   1. **package** — 로컬 tarball 확보(빌드 임베드 또는 `package.sh`).
///   2. **upload**  — `scp` 로 Switch `/tmp` 로 전송.
///   3. **unpack**  — 원격 스테이지 디렉터리 정리 후 압축 해제.
///   4. **install** — `install.sh`(sudo) + `enable` + `restart` 를 한 sudo 세션에서.
///   5. **verify**  — `systemctl is-active` + 설치 버전 일치 확인.
///
/// `SwitchRobotLinkCommands` 와 같은 설계: 모든 원격 명령은 결정적 문자열이라 SSH 없이
/// 고정 검증 가능하고, 마커가 없으면 실패로 판정하는 **정직한 파싱**(거짓 양성 차단).
///
/// # 보안 (security.md)
///
/// sudo 비밀번호는 **명령행에 절대 들어가지 않는다**. `installCommand` 는 `sudo -S`
/// (stdin 읽기) + `-p ''`(프롬프트 억제) 만 구성하고, 실제 비번은 `SwitchAgentDeploySession`
/// 이 SSH stdin 으로만 흘려보낸다. 비번은 어떤 명령 문자열·로그·@Published 에도 남지 않는다.
public enum SwitchAgentDeployCommand {

    /// 배포 단계 — UI 진행률 + 게이팅 순서.
    public enum Stage: String, CaseIterable, Identifiable, Sendable {
        case package
        case upload
        case unpack
        case install
        case verify

        public var id: String { rawValue }

        /// 사람이 읽는 단계 제목.
        public var title: String {
            switch self {
            case .package: return "패키지 준비"
            case .upload:  return "Switch 전송"
            case .unpack:  return "원격 압축 해제"
            case .install: return "설치 + 재시작"
            case .verify:  return "동작 검증"
            }
        }
    }

    /// 원격 스테이지 디렉터리 — 배포마다 정리 후 재사용.
    public static let remoteStageDir = "/tmp/df-agent-deploy"

    /// 설치된 에이전트의 버전 소스 파일(검증 단계가 읽음).
    public static let installedVersionFile =
        "/opt/darwin-switch-agent/src/darwin_switch_agent/__init__.py"

    static let unpackMarker = "DF_UNPACK_OK"
    static let installMarker = "DF_INSTALL_OK"
    static let versionMarker = "---DF-VER---"

    // MARK: - 경로/이름 (결정적)

    public static func tarballName(version: String) -> String {
        "darwin-switch-agent-\(version).tar.gz"
    }

    public static func packageDirName(version: String) -> String {
        "darwin-switch-agent-\(version)"
    }

    public static func remoteTarballPath(version: String) -> String {
        "/tmp/\(tarballName(version: version))"
    }

    public static func remotePackageDir(version: String) -> String {
        "\(remoteStageDir)/\(packageDirName(version: version))"
    }

    /// 번들된 tarball 파일명에서 버전 추출 — "darwin-switch-agent-0.1.0.tar.gz" → "0.1.0".
    /// View 의 패키지 로케이터가 Resources 의 임베드 tarball 버전을 읽을 때 사용.
    public static func versionFromTarballName(_ filename: String) -> String? {
        let prefix = "darwin-switch-agent-"
        let suffix = ".tar.gz"
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        let version = String(filename.dropFirst(prefix.count).dropLast(suffix.count))
        return version.isEmpty ? nil : version
    }

    // MARK: - 원격 명령

    /// 원격 압축 해제 — 이전 배포 잔재 제거 후 새로 풀고 성공 마커 echo.
    public static func unpackCommand(version: String) -> String {
        let tarball = remoteTarballPath(version: version)
        return "rm -rf \(remoteStageDir) && mkdir -p \(remoteStageDir) "
            + "&& tar -xzf \(tarball) -C \(remoteStageDir) && echo \(unpackMarker)"
    }

    /// 설치 — **한 sudo 세션**(`sudo -S` stdin 비번)에서 install.sh + enable + restart.
    ///
    /// install.sh 는 `daemon-reload` 만 하고 서비스를 재시작하지 않으므로, 새 코드를
    /// 즉시 로드하려면 별도 `restart` 가 필요하다. `enable` 은 부팅 자동기동 보장.
    /// install.sh 가 0 이 아닌 종료를 내면 `&&` 체인이 끊겨 마커가 안 나온다 → 실패 판정.
    public static func installCommand(version: String) -> String {
        let dir = remotePackageDir(version: version)
        // sh -c 로 묶어 단일 sudo 세션 — 비번 1회 입력으로 install→enable→restart.
        let rootChain = "bash install.sh "
            + "&& systemctl enable darwin-switch-agent "
            + "&& systemctl restart darwin-switch-agent"
        return "cd \(dir) && sudo -S -p '' sh -c '\(rootChain)' && echo \(installMarker)"
    }

    /// 검증 — 서비스 active 여부 + 설치된 버전 라인(배포 버전 일치 확인용).
    /// `is-active` 는 sudo 불필요.
    public static func verifyCommand() -> String {
        "systemctl is-active darwin-switch-agent; echo \(versionMarker); "
            + "grep -m1 __version__ \(installedVersionFile) 2>/dev/null"
    }

    // MARK: - 파싱 (정직: 마커 없으면 실패)

    public static func unpackSucceeded(_ output: String) -> Bool {
        output.contains(unpackMarker)
    }

    public static func installSucceeded(_ output: String) -> Bool {
        output.contains(installMarker)
    }

    /// `systemctl is-active` 가 정확히 `active` 한 줄을 냈는지. `activating`/`inactive`/
    /// `failed` 는 부분일치로 오판하지 않도록 줄 단위 정확 비교.
    public static func parseAgentActive(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "active" }
    }

    /// `__version__ = "0.1.0"` 라인에서 따옴표 안 버전 추출.
    public static func parseDeployedVersion(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .first(where: { $0.contains("__version__") }) else { return nil }
        guard let open = line.firstIndex(of: "\"") else { return nil }
        let afterOpen = line.index(after: open)
        guard let close = line[afterOpen...].firstIndex(of: "\"") else { return nil }
        let value = String(line[afterOpen..<close]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// sudo 비번 오류 신호 — install 출력에서 감지해 사용자에게 "비번 재시도" 안내.
    public static func looksLikeSudoAuthFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("sorry, try again")
            || lower.contains("incorrect password")
            || lower.contains("a password is required")
            || lower.contains("a terminal is required")   // requiretty 환경
    }
}
