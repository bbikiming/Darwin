import XCTest
@testable import DarwinForgeUI

/// `cockpit.telemetry` 와이어 계약 검증 — iOS `RobotAttitudePayload` 와 JSON 키가
/// 정확히 일치해야 모바일 인공 수평선/복구 배너가 동작한다.
final class RobotAttitudePayloadTests: XCTestCase {

    func testEncodedKeysMatchIOSContract() throws {
        let payload = RobotAttitudePayload(
            rollDeg: -3.5,
            pitchDeg: 12.0,
            balanceState: "correcting",
            autoRecoveryPhase: "gettingUp",
            fallDirection: "forward")

        let data = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dict = try XCTUnwrap(obj)

        XCTAssertEqual(Set(dict.keys),
                       ["rollDeg", "pitchDeg", "balanceState",
                        "autoRecoveryPhase", "fallDirection"])

        XCTAssertEqual(dict["rollDeg"] as? Double, -3.5)
        XCTAssertEqual(dict["pitchDeg"] as? Double, 12.0)
        XCTAssertEqual(dict["balanceState"] as? String, "correcting")
        XCTAssertEqual(dict["autoRecoveryPhase"] as? String, "gettingUp")
        XCTAssertEqual(dict["fallDirection"] as? String, "forward")
    }

    func testRoundTripPreservesValues() throws {
        let payload = RobotAttitudePayload(rollDeg: 1.0, pitchDeg: -2.0)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(RobotAttitudePayload.self, from: data)
        XCTAssertEqual(decoded, payload)
    }
}
