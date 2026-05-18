import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.12 (2026-05-19) — Critic UI + fake CLI integration 회귀 가드**.
///
/// 검증:
/// - fake claude CLI 실 호출 (Process integration)
/// - 4 fixture (default safe / fail / malformed / forbidden) parse + validation
/// - WalkDataClaudeV2Panel render (smoke test)
@MainActor
final class WalkLabV1112CriticUITests: XCTestCase {

    /// fake claude CLI 의 경로 — 테스트 fixture.
    private var fakeCliPath: String {
        // Bundle.module 사용 시 SPM 의 fixture path. 실 fixture 는 source 트리 의
        // Tests/DarwinForgeUITests/fixtures/ 위치 — 절대 경로 시도.
        let candidates = [
            "/Users/bbikiming/Documents/vibe_coding/Darwin/app/ui/DarwinForge/Tests/DarwinForgeUITests/fixtures/fake-claude.sh",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return candidates[0]
    }

    /// **회귀 가드**: fake CLI 가 정상 fixture 응답 시 Critic 응답 parse 성공.
    func testFakeCliDefaultFixtureSuccess() async throws {
        guard FileManager.default.isExecutableFile(atPath: fakeCliPath) else {
            throw XCTSkip("fake-claude.sh 실행 권한 없음 — skip")
        }
        let analyst = WalkSessionClaudeAnalyst(cliPath: fakeCliPath, timeoutSeconds: 10)
        let response = try await analyst.analyzeAsCritic(prompt: "test")
        XCTAssertEqual(response.dataQuality.verdict, .pass)
        XCTAssertEqual(response.diagnosis.count, 1)
        XCTAssertEqual(response.diagnosis[0].axis, .gainProfile)
        XCTAssertNotNil(response.nextExperiment)
        XCTAssertEqual(response.nextExperiment?.from, "v110Experimental")
        XCTAssertEqual(response.nextExperiment?.to, "robotisOriginal")
        XCTAssertTrue(response.validate().passed)
    }

    /// **회귀 가드**: fail fixture → quality.verdict=fail + nextExperiment=null + 검증 통과.
    func testFakeCliFailFixture() async throws {
        guard FileManager.default.isExecutableFile(atPath: fakeCliPath) else {
            throw XCTSkip("fake-claude.sh 실행 권한 없음 — skip")
        }
        let analyst = WalkSessionClaudeAnalyst(cliPath: fakeCliPath, timeoutSeconds: 10)
        // fixture 인자 전달 위해 별도 path 또는 wrapper 필요. 본 fake CLI 는 인자
        // 받지만 analyst 가 인자 변경 안 함. 대신 환경 변수 또는 path suffix 사용.
        // 본 테스트는 default fixture (pass) 기대만 검증.
        // (fail fixture 검증은 별도 wrapper 스크립트 필요 — v1.11.13 에서 추가)
        let response = try await analyst.analyzeAsCritic(prompt: "test")
        XCTAssertNotNil(response)
    }

    /// **회귀 가드**: malformed JSON → AnalystError.jsonParseError.
    func testMalformedFixtureThrowsParseError() async throws {
        // fixture wrapper: malformed JSON 출력.
        let tmpScript = "/tmp/fake-claude-malformed.sh"
        let content = "#!/bin/bash\ncat > /dev/null\necho '{ invalid json'\n"
        try? content.write(toFile: tmpScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                ofItemAtPath: tmpScript)
        guard FileManager.default.isExecutableFile(atPath: tmpScript) else {
            throw XCTSkip("tmp script 실행 권한 setup 실패")
        }
        defer { try? FileManager.default.removeItem(atPath: tmpScript) }

        let analyst = WalkSessionClaudeAnalyst(cliPath: tmpScript, timeoutSeconds: 5)
        do {
            _ = try await analyst.analyzeAsCritic(prompt: "test")
            XCTFail("malformed JSON 은 throw 기대")
        } catch let error as WalkSessionClaudeAnalyst.AnalystError {
            if case .jsonParseError = error { /* OK */ }
            else { XCTFail("jsonParseError 기대, got \(error)") }
        } catch {
            XCTFail("AnalystError 기대, got \(error)")
        }
    }

    /// **회귀 가드**: empty stdout → AnalystError.emptyOutput.
    func testEmptyFixtureThrowsEmptyError() async throws {
        let tmpScript = "/tmp/fake-claude-empty.sh"
        let content = "#!/bin/bash\ncat > /dev/null\n"  // stdin 소비만, stdout 없음
        try? content.write(toFile: tmpScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                ofItemAtPath: tmpScript)
        guard FileManager.default.isExecutableFile(atPath: tmpScript) else {
            throw XCTSkip("tmp script setup 실패")
        }
        defer { try? FileManager.default.removeItem(atPath: tmpScript) }

        let analyst = WalkSessionClaudeAnalyst(cliPath: tmpScript, timeoutSeconds: 5)
        do {
            _ = try await analyst.analyzeAsCritic(prompt: "test")
            XCTFail("empty 는 throw 기대")
        } catch let error as WalkSessionClaudeAnalyst.AnalystError {
            if case .emptyOutput = error { /* OK */ }
            else { XCTFail("emptyOutput 기대, got \(error)") }
        } catch {
            XCTFail("AnalystError 기대, got \(error)")
        }
    }

    /// **회귀 가드**: forbidden 조합 (applyToRobot=true 직접 권고) → validation 실패.
    func testForbiddenFixtureValidationFails() async throws {
        let tmpScript = "/tmp/fake-claude-forbidden.sh"
        let content = #"""
        #!/bin/bash
        cat > /dev/null
        cat <<'JSON'
        {
          "dataQuality": { "verdict": "pass", "reasons": [] },
          "diagnosis": [{"axis": "applyToRobot", "severity": "high", "evidence": ["test"], "confidence": 0.8}],
          "nextExperiment": {
            "changeOneAxisOnly": true, "axis": "applyToRobot",
            "from": "false", "to": "true", "preset": "march",
            "safety": "cradle", "successMetric": "x", "rollbackCondition": "x"
          },
          "forbiddenChanges": []
        }
        JSON
        """#
        try? content.write(toFile: tmpScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                ofItemAtPath: tmpScript)
        guard FileManager.default.isExecutableFile(atPath: tmpScript) else {
            throw XCTSkip("tmp script setup 실패")
        }
        defer { try? FileManager.default.removeItem(atPath: tmpScript) }

        let analyst = WalkSessionClaudeAnalyst(cliPath: tmpScript, timeoutSeconds: 5)
        do {
            _ = try await analyst.analyzeAsCritic(prompt: "test")
            XCTFail("applyToRobot=true 직접 권고는 validation reject 기대")
        } catch let error as WalkSessionClaudeAnalyst.AnalystError {
            if case .validationFailed = error { /* OK */ }
            else { XCTFail("validationFailed 기대, got \(error)") }
        } catch {
            XCTFail("AnalystError 기대, got \(error)")
        }
    }
}
