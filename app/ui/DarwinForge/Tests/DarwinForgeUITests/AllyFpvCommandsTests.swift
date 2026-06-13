import XCTest
@testable import DarwinForgeUI

/// `AllyFpvCommands` 순수 명령 빌더 / 파서 검증.
///
/// 핵심: ROG Ally(Windows PowerShell) 로 보내는 명령에서 경로·키·IP 등 외부 값이
/// 반드시 PowerShell single-quote(`'` → `''`) 로 이스케이프되어 주입이 불가능해야
/// 하고, ally-cli 호출형/네트워크 경로 매핑/출력 파싱이 계약대로여야 한다.
final class AllyFpvCommandsTests: XCTestCase {

    // MARK: - psQuote (PowerShell 안전 인용)

    func testPsQuoteWrapsPlainString() {
        XCTAssertEqual(AllyFpvCommands.psQuote("C:/dev/Darwin"), "'C:/dev/Darwin'")
    }

    func testPsQuoteEscapesEmbeddedQuoteWithDoubledSingleQuote() {
        // PowerShell 리터럴: a'b → 'a''b'
        XCTAssertEqual(AllyFpvCommands.psQuote("a'b"), "'a''b'")
    }

    func testPsQuoteNeutralizesInjection() {
        let evil = "x'; Remove-Item -Recurse $HOME; '"
        let quoted = AllyFpvCommands.psQuote(evil)
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        // 모든 단일 따옴표가 쌍을 이룬다(외곽 2 + 내부 이중화 2n = 짝수) → 리터럴이
        // 조기 종료될 수 없으므로 주입 페이로드가 코드로 새지 못한다.
        XCTAssertEqual(quoted.filter { $0 == "'" }.count % 2, 0)
        // 디코딩(외곽 제거 + '' → ')하면 원본이 손실 없이 복원된다(올바른 PowerShell 리터럴).
        let inner = String(quoted.dropFirst().dropLast())
        XCTAssertEqual(inner.replacingOccurrences(of: "''", with: "'"), evil)
    }

    // MARK: - allyProjectDir

    func testAllyProjectDirJoinsSubpath() {
        XCTAssertEqual(AllyFpvCommands.allyProjectDir(repo: "C:/dev/Darwin"),
                       "C:/dev/Darwin/app/ally")
    }

    func testAllyProjectDirNormalizesTrailingSlash() {
        XCTAssertEqual(AllyFpvCommands.allyProjectDir(repo: "C:/dev/Darwin/"),
                       "C:/dev/Darwin/app/ally")
    }

    // MARK: - NetPath

    func testNetPathRobotHostMapping() {
        XCTAssertEqual(AllyFpvCommands.NetPath.wired.robotHost, "192.168.123.1")
        XCTAssertEqual(AllyFpvCommands.NetPath.wireless.robotHost, "192.168.0.33")
    }

    func testNetPathCliFlag() {
        XCTAssertEqual(AllyFpvCommands.NetPath.wired.cliFlag, "wired")
        XCTAssertEqual(AllyFpvCommands.NetPath.wireless.cliFlag, "wireless")
    }

    // MARK: - 점검 명령

    func testReachableIsHostname() {
        XCTAssertEqual(AllyFpvCommands.reachable(), "hostname")
    }

    func testW0SmokeRunsCargoTestInProjectDir() {
        let cmd = AllyFpvCommands.w0Smoke(repo: "C:/dev/Darwin")
        XCTAssertEqual(cmd, "cd 'C:/dev/Darwin/app/ally'; cargo test")
    }

    func testCliProbeWiredExact() {
        let cmd = AllyFpvCommands.cliProbe(prefer: .wired, repo: "C:/dev/Darwin")
        XCTAssertEqual(cmd,
            "cd 'C:/dev/Darwin/app/ally'; cargo run -p ally-cli -- probe --prefer wired")
    }

    func testCliProbeWirelessFlag() {
        let cmd = AllyFpvCommands.cliProbe(prefer: .wireless)
        XCTAssertTrue(cmd.hasSuffix("--prefer wireless"))
    }

    func testCliConnectQuotesIdentityAndClampsSeconds() {
        let cmd = AllyFpvCommands.cliConnect(identity: "C:/Users/me/.ssh/id_rsa_darwin",
                                             prefer: .wired, seconds: 0, repo: "C:/dev/Darwin")
        XCTAssertTrue(cmd.contains("cargo run -p ally-cli -- connect"))
        XCTAssertTrue(cmd.contains("--identity 'C:/Users/me/.ssh/id_rsa_darwin'"))
        XCTAssertTrue(cmd.contains("--prefer wired"))
        // seconds 0 → 최소 1 로 클램프(0초 연결은 무의미).
        XCTAssertTrue(cmd.contains("--seconds 1"))
    }

    // MARK: - darwin-fpv (W2)

    func testFpvReadyProbeChecksBinaryAndEmitsMarkers() {
        let cmd = AllyFpvCommands.fpvReadyProbe(repo: "C:/dev/Darwin")
        XCTAssertTrue(cmd.contains("Test-Path"))
        XCTAssertTrue(cmd.contains("darwin-fpv.exe"))
        XCTAssertTrue(cmd.contains("'READY'"))
        XCTAssertTrue(cmd.contains("'MISSING'"))
    }

    func testFpvLaunchUsesStartProcess() {
        let cmd = AllyFpvCommands.fpvLaunch(repo: "C:/dev/Darwin")
        XCTAssertTrue(cmd.hasPrefix("Start-Process "))
        XCTAssertTrue(cmd.contains("darwin-fpv.exe"))
    }

    // MARK: - 파서

    func testParseCargoTestSingleLine() {
        let out = "test result: ok. 21 passed; 0 failed; 0 ignored; 0 measured"
        let r = AllyFpvCommands.parseCargoTest(out)
        XCTAssertEqual(r, AllyFpvCommands.CargoTestResult(passed: 21, failed: 0))
        XCTAssertTrue(r?.ok ?? false)
    }

    func testParseCargoTestSumsMultipleSuites() {
        let out = """
        running 14 tests
        test result: ok. 14 passed; 0 failed; 0 ignored
        running 7 tests
        test result: ok. 7 passed; 0 failed; 0 ignored
        """
        let r = AllyFpvCommands.parseCargoTest(out)
        XCTAssertEqual(r, AllyFpvCommands.CargoTestResult(passed: 21, failed: 0))
    }

    func testParseCargoTestDetectsFailure() {
        let out = "test result: FAILED. 18 passed; 3 failed; 0 ignored"
        let r = AllyFpvCommands.parseCargoTest(out)
        XCTAssertEqual(r?.passed, 18)
        XCTAssertEqual(r?.failed, 3)
        XCTAssertFalse(r?.ok ?? true)
    }

    func testParseCargoTestNoMatchReturnsNil() {
        XCTAssertNil(AllyFpvCommands.parseCargoTest("Compiling ally-cli v0.1.0\n"))
    }

    func testParseProbeUsesExitCode() {
        XCTAssertTrue(AllyFpvCommands.parseProbe("path: wired", exitCode: 0).ok)
        XCTAssertFalse(AllyFpvCommands.parseProbe("no route", exitCode: 1).ok)
    }

    func testParseFpvReady() {
        XCTAssertTrue(AllyFpvCommands.parseFpvReady("READY"))
        XCTAssertTrue(AllyFpvCommands.parseFpvReady("noise\nREADY\n"))
        XCTAssertFalse(AllyFpvCommands.parseFpvReady("MISSING"))
        XCTAssertFalse(AllyFpvCommands.parseFpvReady(""))
    }
}
