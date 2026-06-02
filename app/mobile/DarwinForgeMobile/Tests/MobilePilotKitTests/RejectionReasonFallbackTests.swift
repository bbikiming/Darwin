import XCTest
@testable import MobilePilotKit

/// V297-5 HIGH-1: iOS RejectionReason strict enum 이 Mac 의 새 reason 코드 decode 실패
/// → WebSocket 연결 종료 회로를 차단하는 fallback decoder 검증.
final class RejectionReasonFallbackTests: XCTestCase {

    // MARK: - 알려진 새 case decode

    func testLowBatteryDecodes() throws {
        let r = try decode(reason: "lowBattery")
        XCTAssertEqual(r, .lowBattery)
    }

    func testClockSkewDecodes() throws {
        XCTAssertEqual(try decode(reason: "clockSkew"), .clockSkew)
    }

    func testHighRiskNotAllowedDecodes() throws {
        XCTAssertEqual(try decode(reason: "highRiskNotAllowed"), .highRiskNotAllowed)
    }

    func testDxlPowerOffDecodes() throws {
        XCTAssertEqual(try decode(reason: "dxlPowerOff"), .dxlPowerOff)
    }

    func testHeadUnsupportedInMVPDecodes() throws {
        XCTAssertEqual(try decode(reason: "headUnsupportedInMVP"), .headUnsupportedInMVP)
    }

    func testPreflightFailedDecodes() throws {
        XCTAssertEqual(try decode(reason: "preflightFailed"), .preflightFailed)
    }

    // MARK: - 미래 reason — unknown fallback

    func testFutureReasonFallsBackToUnknown() throws {
        let r = try decode(reason: "futureReasonThatMacMightAdd")
        XCTAssertEqual(r, .unknown,
                       "모르는 reason 은 .unknown 으로 fallback — 연결 종료 X")
    }

    func testEmptyStringFallsBackToUnknown() throws {
        XCTAssertEqual(try decode(reason: ""), .unknown)
    }

    // MARK: - Full RejectedPayload decode

    func testRejectedPayloadWithUnknownReasonDecodes() throws {
        let json = """
        { "reason": "someBrandNewReason", "message": "테스트 메시지" }
        """
        let data = json.data(using: .utf8)!
        let payload = try JSONDecoder().decode(RejectedPayload.self, from: data)
        XCTAssertEqual(payload.reason, .unknown)
        XCTAssertEqual(payload.message, "테스트 메시지")
    }

    // MARK: - FailureReason 도 fallback

    func testFailureReasonFallback() throws {
        let json = """
        { "reason": "newFailureModeFromFuture", "message": null, "lastErrorAtMs": null }
        """
        let data = json.data(using: .utf8)!
        let payload = try JSONDecoder().decode(FailedPayload.self, from: data)
        XCTAssertEqual(payload.reason, .unknown)
    }

    func testStopFailedFailureReason() throws {
        let json = """
        { "reason": "stopFailed", "message": null, "lastErrorAtMs": null }
        """
        let data = json.data(using: .utf8)!
        let payload = try JSONDecoder().decode(FailedPayload.self, from: data)
        XCTAssertEqual(payload.reason, .stopFailed)
    }

    // MARK: - V297-5 LOW-2 — capabilities 명칭

    func testWelcomeCapabilitiesNewName() throws {
        let json = """
        { "head": false, "walkFreeform": false, "speedScaleAccepted": true }
        """
        let data = json.data(using: .utf8)!
        let caps = try JSONDecoder().decode(WelcomeCapabilities.self, from: data)
        XCTAssertFalse(caps.head)
        XCTAssertFalse(caps.walkFreeform)
        XCTAssertTrue(caps.speedScaleAccepted)
    }

    /// V297-5 MEDIUM-4: capabilities nil 정책 — WelcomePayload 가 capabilities 없이도 decode.
    func testWelcomePayloadWithoutCapabilitiesDecodes() throws {
        let json = """
        {
            "macName": "Legacy Mac",
            "macVersion": "0.9.0",
            "relayProtocolVersion": 1,
            "sessionId": "ses_legacy",
            "heartbeatIntervalMs": 100,
            "watchdogTimeoutMs": 500
        }
        """
        let data = json.data(using: .utf8)!
        let welcome = try JSONDecoder().decode(WelcomePayload.self, from: data)
        XCTAssertNil(welcome.capabilities, "legacy Mac 의 capabilities-free welcome 도 decode")
    }

    // MARK: - Helpers

    private func decode(reason: String) throws -> RejectionReason {
        let data = "\"\(reason)\"".data(using: .utf8)!
        return try JSONDecoder().decode(RejectionReason.self, from: data)
    }
}
