import XCTest
@testable import DarwinForgeUI

/// V297-9 CRITICAL-2 MEDIUM-2: Handshake guard for priority bypass.
///
/// # 검증 invariant
///
/// I-HS-1: handshakeAccepted=false (acceptHello 완료 전) 동안 priority frame 도
///         chain 으로 강제 → bypass 안 함.
///
/// I-HS-2: handshakeAccepted=true 후에는 priority frame 만 bypass.
///
/// # 종전 회로
///
/// firstAppFrameDelivered = true 가 onConnect await 전 set → priority bypass 가
/// hello 처리 완료 전 actor 진입 → session.channel mismatch → alreadyOwned 거절 →
/// estop frame 유실.
final class MobileRelayHandshakeGuardTests: XCTestCase {

    /// I-HS-1: handshake 전 priority frame (estop) 도 peekPriorityType 가 nil 반환.
    func testHandshakeNotAcceptedYet_priorityReturnsNil() {
        let estopFrame = makeFrame(type: "pilot.estop", id: "cmd_e",
                                   payload: ["reason": "user"])
        let result = WSChannel.peekPriorityType(estopFrame, firstFrameDelivered: false)
        XCTAssertNil(result,
                     "AC I-HS-1: handshake 전 estop frame 은 priority bypass 안 함 → chain 으로")
    }

    /// I-HS-2: handshake 후 priority frame 은 type 반환.
    func testHandshakeAccepted_priorityReturnsType() {
        let estopFrame = makeFrame(type: "pilot.estop", id: "cmd_e",
                                   payload: ["reason": "user"])
        let result = WSChannel.peekPriorityType(estopFrame, firstFrameDelivered: true)
        XCTAssertEqual(result, "pilot.estop",
                       "AC I-HS-2: handshake 후 estop priority 분류")
    }

    /// stop 도 priority.
    func testStopIsPriorityAfterHandshake() {
        let stopFrame = makeFrame(type: "pilot.stop", id: "cmd_s",
                                  payload: ["reason": "user"])
        let result = WSChannel.peekPriorityType(stopFrame, firstFrameDelivered: true)
        XCTAssertEqual(result, "pilot.stop")
    }

    /// 일반 명령은 priority 아님.
    func testWalkNotPriority() {
        let walkFrame = makeFrame(type: "pilot.walk", id: "cmd_w",
                                  payload: ["preset": "slowForward", "enabled": true,
                                            "xMm": 0.0, "yMm": 0.0, "aDeg": 0.0,
                                            "periodMs": 700, "footMm": 35.0,
                                            "hipPitchDeg": 13.0])
        let result = WSChannel.peekPriorityType(walkFrame, firstFrameDelivered: true)
        XCTAssertNil(result, "AC: 일반 walk 는 priority 아님 — chain 처리")
    }

    /// 잘못된 JSON 은 nil — chain 으로 fallback (방어 정책).
    func testGarbageFrameFallsThroughToChain() {
        let garbage = Data("not json".utf8)
        let result = WSChannel.peekPriorityType(garbage, firstFrameDelivered: true)
        XCTAssertNil(result, "AC: 잘못된 JSON 은 chain 으로 fallback")
    }

    // MARK: - Helper

    private func makeFrame(type: String, id: String, payload: [String: Any]) -> Data {
        let iso = ISO8601DateFormatter.hsFractional.string(from: Date())
        let envelope: [String: Any] = [
            "v": 1, "id": id, "type": type, "sentAt": iso, "payload": payload
        ]
        return try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }
}

private extension ISO8601DateFormatter {
    static let hsFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
