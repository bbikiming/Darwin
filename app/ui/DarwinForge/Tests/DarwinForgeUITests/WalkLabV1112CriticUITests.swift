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
    /// **v1.11.14**: Bundle.module ("fake-claude.sh") 우선, source 트리 fallback.
    /// Package.swift 가 fixtures/fake-claude.sh 를 resource 로 copy.
    private var fakeCliPath: String {
        // 1. Bundle.module resource (SwiftPM copy 후) — 실행 권한 있어야 함.
        if let url = Bundle.module.url(forResource: "fake-claude", withExtension: "sh") {
            let path = url.path
            // copy 된 파일은 executable bit 없을 수 있음 — chmod +x 시도.
            if !FileManager.default.isExecutableFile(atPath: path) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                        ofItemAtPath: path)
            }
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // 2. Source 트리 절대 경로 fallback (개발자 로컬).
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

    /// **v1.11.14 (2026-05-19) — 진단 문서 #6 fix**: 실 fail fixture 검증.
    /// 종전 (v1.11.12) 은 default fixture 만 호출하는 no-op 였음.
    /// wrapper script 를 /tmp 에 두고 그 안에서 fake-claude.sh --fixture=fail 호출.
    /// 결과 — dataQuality.verdict=fail + nextExperiment=null + recommendation=recollect 검증.
    func testFakeCliFailFixture() async throws {
        guard FileManager.default.isExecutableFile(atPath: fakeCliPath) else {
            throw XCTSkip("fake-claude.sh 실행 권한 없음 — skip")
        }
        let wrapper = "/tmp/fake-claude-fail-wrapper.sh"
        let content = "#!/bin/bash\n\"\(fakeCliPath)\" --fixture=fail\n"
        try? content.write(toFile: wrapper, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                ofItemAtPath: wrapper)
        guard FileManager.default.isExecutableFile(atPath: wrapper) else {
            throw XCTSkip("wrapper 실행 권한 setup 실패")
        }
        defer { try? FileManager.default.removeItem(atPath: wrapper) }

        let analyst = WalkSessionClaudeAnalyst(cliPath: wrapper, timeoutSeconds: 10)
        let response = try await analyst.analyzeAsCritic(prompt: "test")
        XCTAssertEqual(response.dataQuality.verdict, .fail,
                       "fail fixture 는 quality.verdict=fail 기대")
        XCTAssertNil(response.nextExperiment,
                     "fail fixture 는 nextExperiment=null 기대")
        XCTAssertEqual(response.recommendation?.action, .recollect,
                       "fail → recollect 권고 기대")
        XCTAssertTrue(response.validate().passed,
                      "fail + nextExperiment=null 은 self-consistent (validation 통과)")
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
