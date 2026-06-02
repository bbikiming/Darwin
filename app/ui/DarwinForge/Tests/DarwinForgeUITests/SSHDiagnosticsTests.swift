import XCTest
@testable import DarwinForgeUI

/// SSHDiagnostics (2026-06-02) — SSH 제어 명령 진단 분류 순수 함수 검증.
///
/// # 비유
/// 택배 송장 검수 — 품목 분류(category), 내용물 요약(preview, 민감정보 가림),
/// 반송 사유 코드(error_case)가 각각 정확히 찍히는지 확인한다.
final class SSHDiagnosticsTests: XCTestCase {

    // MARK: - classify(_:) 실패 원인

    func testClassifyMapsSSHErrorCases() {
        XCTAssertEqual(SSHDiagnostics.classify(SSHShell.SSHError.timeout), .timeout)
        XCTAssertEqual(SSHDiagnostics.classify(SSHShell.SSHError.keyAuthRequired), .keyAuthRequired)
        XCTAssertEqual(SSHDiagnostics.classify(SSHShell.SSHError.spawnFailed("boom")), .spawnFailed)
    }

    func testClassifyUnknownErrorIsGeneric() {
        struct Other: Error {}
        XCTAssertEqual(SSHDiagnostics.classify(Other()), .generic)
        XCTAssertEqual(SSHDiagnostics.classify(URLError(.notConnectedToInternet)), .generic)
    }

    func testErrorCodeRawValuesAreStableSnakeCase() {
        XCTAssertEqual(SSHDiagnostics.ErrorCode.timeout.rawValue, "timeout")
        XCTAssertEqual(SSHDiagnostics.ErrorCode.keyAuthRequired.rawValue, "key_auth_required")
        XCTAssertEqual(SSHDiagnostics.ErrorCode.spawnFailed.rawValue, "spawn_failed")
        XCTAssertEqual(SSHDiagnostics.ErrorCode.generic.rawValue, "generic")
        // 모든 코드가 distinct.
        let raws = Set(SSHDiagnostics.ErrorCode.allCases.map { $0.rawValue })
        XCTAssertEqual(raws.count, SSHDiagnostics.ErrorCode.allCases.count)
    }

    // MARK: - category(of:) — 실제 send() 명령 문자열 기반

    func testCategoryTelemetryPoll() {
        XCTAssertEqual(SSHDiagnostics.category(of: "cat /tmp/df-walklab-telemetry 2>/dev/null"),
                       .telemetry)
    }

    func testCategoryWalkCommand() {
        // walkLabRobotisSendCommand 가 만드는 실제 형태.
        let walk = "rm -f /tmp/df-walklab-ack 2>/dev/null; printf '%s\\n' 'abc123 1 28 0 0 600 3' > /tmp/df-walklab-cmd.tmp && mv /tmp/df-walklab-cmd.tmp /tmp/df-walklab-cmd"
        XCTAssertEqual(SSHDiagnostics.category(of: walk), .walk)
    }

    func testCategoryStopBeatsWalk() {
        // estop 명령이 walklab 토큰을 포함해도 stop 으로 분류(우선순위).
        XCTAssertEqual(SSHDiagnostics.category(of: "touch /tmp/df-walklab-estop"), .stop)
        XCTAssertEqual(SSHDiagnostics.category(of: "echo emergency_stop"), .stop)
    }

    func testCategoryDemoAndVisionAndBridge() {
        XCTAssertEqual(SSHDiagnostics.category(of: "echo \"soccer\" > /tmp/df-pilot-mode"), .demo)
        XCTAssertEqual(SSHDiagnostics.category(of: "sudo ./camera_tutorial >/tmp/df-camera.log"), .vision)
        XCTAssertEqual(SSHDiagnostics.category(of: "sudo bash -c 'exec socat tcp-l:5530 open:/dev/ttyUSB0'"), .bridge)
    }

    func testCategorySetupAndService() {
        XCTAssertEqual(SSHDiagnostics.category(of: "ssh-keygen -t rsa -b 2048"), .setup)
        XCTAssertEqual(SSHDiagnostics.category(of: "sudo service ssh start"), .service)
    }

    func testCategoryFallsBackToOther() {
        XCTAssertEqual(SSHDiagnostics.category(of: "true"), .other)
        XCTAssertEqual(SSHDiagnostics.category(of: ""), .other)
    }

    // MARK: - redactedPreview(_:)

    func testPreviewCollapsesWhitespaceAndNewlines() {
        let cmd = "echo   one\n  two\t  three"
        XCTAssertEqual(SSHDiagnostics.redactedPreview(cmd), "echo one two three")
    }

    func testPreviewMasksPasswordValues() {
        let p1 = SSHDiagnostics.redactedPreview("connect password=hunter2 now")
        XCTAssertFalse(p1.contains("hunter2"), "비밀번호 노출: \(p1)")
        XCTAssertTrue(p1.contains("***"))

        let p2 = SSHDiagnostics.redactedPreview("sshpass -p s3cr3t ssh robotis@10.0.0.5")
        XCTAssertFalse(p2.contains("s3cr3t"), "sshpass 비밀번호 노출: \(p2)")

        let p3 = SSHDiagnostics.redactedPreview("export API_KEY=abcdef123456")
        XCTAssertFalse(p3.contains("abcdef123456"), "API 키 노출: \(p3)")
    }

    func testPreviewTruncatesToMaxLen() {
        let long = String(repeating: "x", count: 500)
        let preview = SSHDiagnostics.redactedPreview(long, maxLen: 160)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertLessThanOrEqual(preview.count, 161)  // 160 + ellipsis
    }

    func testPreviewKeepsControlValuesVisible() {
        // walk 명령의 x/y/a 수치는 진단에 필요 — 가려지면 안 됨.
        let walk = "printf '%s\\n' 'id1 1 28 0 0 600 3' > /tmp/df-walklab-cmd"
        let preview = SSHDiagnostics.redactedPreview(walk)
        XCTAssertTrue(preview.contains("28"), "제어 수치가 보존돼야 함: \(preview)")
    }

    // MARK: - payload 빌더

    func testSentDataHasExpectedFields() {
        let d = SSHDiagnostics.sentData(command: "cat /tmp/df-walklab-telemetry", channel: "ssh")
        XCTAssertEqual(d["channel"]?.value as? String, "ssh")
        XCTAssertEqual(d["category"]?.value as? String, "telemetry")
        XCTAssertEqual(d["cmd_len"]?.value as? Int, "cat /tmp/df-walklab-telemetry".count)
        XCTAssertNotNil(d["cmd_hash"]?.value as? String)
        XCTAssertNotNil(d["preview"]?.value as? String)
    }

    func testRespondedDataRecordsExitCodeAndOk() {
        let ok = SSHDiagnostics.respondedData(command: "echo ok", channel: "ssh",
                                              exitCode: 0, elapsedMs: 42, resultLen: 3)
        XCTAssertEqual(ok["exit_code"]?.value as? Int, 0)
        XCTAssertEqual(ok["ok"]?.value as? Bool, true)
        XCTAssertEqual(ok["elapsed_ms"]?.value as? Int, 42)

        // 비-0 exit = 로봇이 명령 거부 → ok=false (종전엔 성공으로 오인되던 케이스).
        let bad = SSHDiagnostics.respondedData(command: "false", channel: "ssh",
                                               exitCode: 1, elapsedMs: 10, resultLen: 0)
        XCTAssertEqual(bad["exit_code"]?.value as? Int, 1)
        XCTAssertEqual(bad["ok"]?.value as? Bool, false)
    }

    func testErrorDataClassifiesAndIncludesElapsed() {
        let d = SSHDiagnostics.errorData(command: "cat /tmp/df-walklab-telemetry",
                                         channel: "ssh",
                                         error: SSHShell.SSHError.timeout,
                                         elapsedMs: 4000,
                                         multiplex: true)
        XCTAssertEqual(d["error_case"]?.value as? String, "timeout")
        XCTAssertEqual(d["category"]?.value as? String, "telemetry")
        XCTAssertEqual(d["elapsed_ms"]?.value as? Int, 4000)  // 종전 누락 필드.
        XCTAssertEqual(d["multiplex"]?.value as? Bool, true)
    }
}
