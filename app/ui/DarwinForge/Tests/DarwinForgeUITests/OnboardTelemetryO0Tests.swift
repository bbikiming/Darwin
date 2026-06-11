import XCTest
@testable import DarwinForgeUI

/// **O0 — TEL 파서 ≥11 토큰 완화 + last_cmd_id/loop_ms 선택 토큰** (walklab-onboard-teleop-upgrade O0-2).
final class OnboardTelemetryO0Tests: XCTestCase {

    func testParse_legacy11Tokens_stillWorks_noExtraFields() {
        // 구버전 펌웨어(10 토큰=11 필드) — last_cmd_id/loop_ms 없음 → nil.
        let s = OnboardTelemetry.parse("TEL 1748736000123 511 530 498 512 489 760 122 1 0")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.tsMs, 1748736000123)
        XCTAssertTrue(s?.walking ?? false)
        XCTAssertNil(s?.lastCmdId)
        XCTAssertNil(s?.loopMs)
    }

    func testParse_withO0Tokens_capturesCmdIdAndLoopMs() {
        let s = OnboardTelemetry.parse("TEL 1748736000123 511 530 498 512 489 760 122 1 0 c123_ab12cd34 18")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.lastCmdId, "c123_ab12cd34")
        XCTAssertEqual(s?.loopMs, 18)
    }

    func testParse_noIdSentinel_normalizesToNil() {
        let s = OnboardTelemetry.parse("TEL 1 0 0 0 0 0 0 120 0 0 no_id 5")
        XCTAssertNotNil(s)
        XCTAssertNil(s?.lastCmdId)   // "no_id" → nil
        XCTAssertEqual(s?.loopMs, 5)
    }

    func testParse_moreThan13Tokens_ignoresExtra() {
        // 미래 토큰(예: TEL2 류)이 붙어도 첫 11 + 선택 2 만 소비, 나머지 무시(전방 호환).
        let s = OnboardTelemetry.parse("TEL 1 0 0 0 0 0 0 120 1 0 cidX 22 EXTRA1 EXTRA2")
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.lastCmdId, "cidX")
        XCTAssertEqual(s?.loopMs, 22)
    }

    func testParse_rejectsFewerThan11Tokens() {
        XCTAssertNil(OnboardTelemetry.parse("TEL 1 0 0 0 0 0 0 120 1"))   // 10 토큰
    }

    func testParse_badLoopMs_keepsLineValid_loopNil() {
        let s = OnboardTelemetry.parse("TEL 1 0 0 0 0 0 0 120 1 0 cidX notanint")
        XCTAssertNotNil(s)           // 라인은 유효(첫 11 토큰 정상)
        XCTAssertEqual(s?.lastCmdId, "cidX")
        XCTAssertNil(s?.loopMs)      // loop_ms 형식 불량 → 그 필드만 nil
    }

    func testParse_combinedOutputWithExitSuffix_findsTelLine() {
        // poller 의 combined 출력(TEL 라인 + exit suffix)에서 TEL 라인을 찾아 파싱.
        let combined = "TEL 1 0 0 0 0 0 0 120 1 0 cidY 12\n--- exit 0 ---"
        let s = OnboardTelemetry.parse(combined)
        XCTAssertEqual(s?.lastCmdId, "cidY")
        XCTAssertEqual(s?.loopMs, 12)
    }
}
