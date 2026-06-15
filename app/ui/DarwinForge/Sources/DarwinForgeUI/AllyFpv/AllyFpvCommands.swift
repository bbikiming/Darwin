import Foundation

/// **ROG Ally FPV 데모 — 순수 명령 계층**
///
/// Mac DarwinForge 가 ROG Ally(Windows 11)를 *가이드·점검·트리거* 하기 위한 명령
/// 문자열을 만드는 순수 함수 모음. 부수효과 없음 — 문자열 생성 / PowerShell 안전
/// 인용 / 출력 파싱만 담당한다. 실제 SSH 실행은 `AllyFpvLauncherSession` 이
/// `SSHShell` 로 수행한다(경계 분리 = 테스트 용이성).
///
/// 단일 세션 규칙: ROG Ally 가 로봇을 조종하는 동안 Mac 은 로봇 연결을 끊는다
/// (`app/ally/docs/05_ALLY_DEV_SETUP.md §6`). 따라서 여기의 명령은 **로봇이 아니라
/// ROG Ally(Windows)** 를 향한다 — 기본 셸이 PowerShell 이므로 PowerShell 문법.
public enum AllyFpvCommands {

    // MARK: - 단일 출처 상수 (app/ally/crates/ally-link/src/lib.rs 와 일치)

    /// 유선 USB-C LAN 직결 로봇 IP — 무선보다 ~166× 빠름(W1 유선 게이트).
    public static let robotWiredHost = "192.168.123.1"
    /// 무선(공유기 AP) 로봇 IP.
    public static let robotWirelessHost = "192.168.0.33"
    /// ROG Ally 위 리포 클론 기본 경로(05 §3.2 `git clone … C:\dev\Darwin`).
    public static let defaultAllyRepoPath = "C:/dev/Darwin"
    /// 리포 내 Ally 프로젝트 하위 경로.
    public static let allyProjectSubpath = "app/ally"
    /// ally-cli 가 로봇에 SSH 할 때 쓰는 Ally 로컬 키 기본 경로(로봇 OpenSSH 5.9 = RSA only).
    ///
    /// `~` 사용(C1 수정): PowerShell single-quote 안에서 `$HOME` 은 확장되지 않아 ally-cli 에
    /// 리터럴 `$HOME/…` 이 도달했었다. `~/…` 로 두면 ally-cli 의 `expand_home` 이 USERPROFILE
    /// 로 풀고, 미확장이어도 ssh 자체가 `~` 를 해석한다(이중 안전).
    public static let defaultRobotIdentityOnAlly = "~/.ssh/id_rsa_darwin"
    /// darwin-fpv(W2) Tauri 빌드 산출물 추정 경로(워크스페이스 target).
    static let fpvBinaryRelPath = "target/release/darwin-fpv.exe"

    // MARK: - 네트워크 경로

    public enum NetPath: String, CaseIterable, Sendable, Identifiable {
        case wired, wireless
        public var id: String { rawValue }
        public var robotHost: String {
            self == .wired ? AllyFpvCommands.robotWiredHost : AllyFpvCommands.robotWirelessHost
        }
        /// ally-cli `--prefer` 플래그 값.
        public var cliFlag: String { rawValue }
        public var label: String { self == .wired ? "유선 (USB-C LAN)" : "무선" }
    }

    // MARK: - PowerShell 안전 인용

    /// PowerShell 작은따옴표 리터럴 — 내부 `'` 는 `''` 로 이스케이프(주입 방지).
    /// 경로/IP/키 경로 등 모든 외부 값은 이 함수를 통과시킨다(시스템 경계 검증).
    public static func psQuote(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// 리포 경로 + Ally 프로젝트 하위 경로 결합(슬래시 정규화).
    static func allyProjectDir(repo: String) -> String {
        let base = repo.hasSuffix("/") ? String(repo.dropLast()) : repo
        return "\(base)/\(allyProjectSubpath)"
    }

    // MARK: - 점검 명령 (Mac → ROG Ally, PowerShell)

    /// Ally 도달성 — `hostname`(가장 가벼운 왕복).
    public static func reachable() -> String { "hostname" }

    /// 리포 진행 확인 — 최근 커밋 5줄.
    public static func gitHead(repo: String = defaultAllyRepoPath) -> String {
        "cd \(psQuote(repo)); git log --oneline -5"
    }

    /// W0 스모크 — 와이어 계약 패리티(기대: 21 passed).
    public static func w0Smoke(repo: String = defaultAllyRepoPath) -> String {
        "cd \(psQuote(allyProjectDir(repo: repo))); cargo test"
    }

    /// ally-cli 연결 경로 탐지 — TCP :22 도달성(로봇 미연결로도 안전).
    public static func cliProbe(prefer: NetPath, repo: String = defaultAllyRepoPath) -> String {
        "cd \(psQuote(allyProjectDir(repo: repo))); cargo run -p ally-cli -- probe --prefer \(prefer.cliFlag)"
    }

    /// ally-cli 풀 연결 게이트(headless) — 핸드셰이크→20Hz→메트릭. FPV 화면은 없지만
    /// "로봇과 실제로 조종 채널이 선다"를 증명(darwin-fpv W2 준비 전의 실연 경로).
    /// ⚠️ 로봇을 깨우므로 단일 세션 가드(Mac 로봇 연결 해제) 후 실행.
    public static func cliConnect(identity: String = defaultRobotIdentityOnAlly,
                                  prefer: NetPath,
                                  seconds: Int = 5,
                                  repo: String = defaultAllyRepoPath) -> String {
        let secs = max(1, seconds)
        return "cd \(psQuote(allyProjectDir(repo: repo))); "
            + "cargo run -p ally-cli -- connect --identity \(psQuote(identity)) "
            + "--prefer \(prefer.cliFlag) --seconds \(secs)"
    }

    /// darwin-fpv(W2) 빌드 산출물 존재 확인 — 있으면 `READY`, 없으면 `MISSING`.
    public static func fpvReadyProbe(repo: String = defaultAllyRepoPath) -> String {
        let bin = "\(allyProjectDir(repo: repo))/\(fpvBinaryRelPath)"
        return "if (Test-Path \(psQuote(bin))) { 'READY' } else { 'MISSING' }"
    }

    /// darwin-fpv(W2) 실행 — GUI 라 비차단 Start-Process 로 띄운다.
    public static func fpvLaunch(repo: String = defaultAllyRepoPath) -> String {
        let bin = "\(allyProjectDir(repo: repo))/\(fpvBinaryRelPath)"
        return "Start-Process \(psQuote(bin))"
    }

    // MARK: - 출력 파서

    public struct CargoTestResult: Equatable, Sendable {
        public let passed: Int
        public let failed: Int
        public var ok: Bool { failed == 0 && passed > 0 }
    }

    /// `test result: ok. 21 passed; 0 failed; …` 형태에서 passed/failed 추출.
    /// 여러 줄이면 합산(unit + parity 등 복수 스위트).
    public static func parseCargoTest(_ output: String) -> CargoTestResult? {
        var passedTotal = 0
        var failedTotal = 0
        var matched = false
        // CRLF 안전: `\r\n` 은 단일 grapheme 이라 split(separator:"\n") 이 Windows 출력을 못
        // 나눈다(멀티스위트 합산이 어긋남). `.newlines` CharacterSet 으로 분리한다.
        for line in output.components(separatedBy: .newlines) {
            guard line.contains("test result:") else { continue }
            matched = true
            passedTotal += firstInt(before: "passed", in: line) ?? 0
            failedTotal += firstInt(before: "failed", in: line) ?? 0
        }
        return matched ? CargoTestResult(passed: passedTotal, failed: failedTotal) : nil
    }

    public struct ProbeResult: Equatable, Sendable {
        public let ok: Bool
        public let detail: String
    }

    /// ally-cli probe 결과 — exit 0 이면 경로 도달 성공.
    public static func parseProbe(_ output: String, exitCode: Int32) -> ProbeResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProbeResult(ok: exitCode == 0, detail: trimmed)
    }

    /// fpvReadyProbe 출력 → 준비 여부(`READY` 만 true).
    ///
    /// `components(separatedBy: .newlines)` 사용(H3 수정): ROG Ally PowerShell 출력은 CRLF다.
    /// Swift 에서 `"\r\n"` 은 **단일 grapheme cluster** 라 `split(separator: "\n")` 은 CRLF 줄을
    /// 아예 못 나눠 `"…READY"` 가 한 토큰에 묻혀 비교 실패했다(영구 false). `.newlines`
    /// CharacterSet 은 `\r`·`\n` 스칼라 각각을 구분자로 처리해 CRLF/LF/CR 모두 올바르게 분리한다.
    public static func parseFpvReady(_ output: String) -> Bool {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("READY")
    }

    // MARK: - 내부 헬퍼

    /// 토큰(예: "passed") 바로 앞의 정수를 찾는다 — "21 passed" → 21.
    private static func firstInt(before token: String, in line: String) -> Int? {
        let words = line
            .replacingOccurrences(of: ";", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard let idx = words.firstIndex(of: token), idx > 0 else { return nil }
        return Int(words[idx - 1])
    }
}
