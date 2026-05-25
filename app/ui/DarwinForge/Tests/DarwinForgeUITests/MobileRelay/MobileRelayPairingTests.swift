import XCTest
@testable import DarwinForgeUI

final class MobileRelayPairingTests: XCTestCase {

    func testCorrectCodeAccepted() {
        let pairing = MobileRelayPairing(initialCode: "424242")
        XCTAssertEqual(pairing.validate("424242"), .ok)
    }

    func testWrongCodeReportsRemainingAttempts() {
        let pairing = MobileRelayPairing(initialCode: "424242")
        XCTAssertEqual(pairing.validate("000000"), .mismatch(remainingAttempts: 2))
        XCTAssertEqual(pairing.validate("000000"), .mismatch(remainingAttempts: 1))
    }

    func testLockoutAfterThreeFailures() {
        let pairing = MobileRelayPairing(initialCode: "424242")
        _ = pairing.validate("000000")
        _ = pairing.validate("000000")
        let final = pairing.validate("000000")
        if case .locked = final {
            // ok
        } else {
            XCTFail("Expected locked, got \(final)")
        }
        // Code should have rotated; original is no longer valid.
        XCTAssertNotEqual(pairing.currentCode(), "424242")
    }

    func testRotateGeneratesNewCode() {
        let pairing = MobileRelayPairing(initialCode: "111111")
        let next = pairing.rotate()
        XCTAssertNotEqual(next, "111111")
        XCTAssertEqual(next.count, MobileRelayPairing.codeLength)
    }

    func testQRPayloadEncodes() throws {
        let payload = PairingQRPayload(host: "10.0.0.1", port: 17370, pairingCode: "555000")
        let encoded = try payload.encode()
        XCTAssertTrue(encoded.contains("\"pairingCode\":\"555000\""))
        XCTAssertTrue(encoded.contains("\"host\":\"10.0.0.1\""))
    }

    func testWebSocketAcceptToken() {
        // RFC 6455 example: client key "dGhlIHNhbXBsZSBub25jZQ==" → "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        let token = WebSocketHandshake.accept(for: "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertEqual(token, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}
