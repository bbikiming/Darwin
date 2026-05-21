import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.20.0 (2026-05-21) 사이클 5 — Tello state parser 단위 test**.
final class TelloStateMessageTests: XCTestCase {

    func testParseFullValidMessage() {
        let raw = "pitch:0;roll:0;yaw:0;vgx:0;vgy:0;vgz:0;templ:60;temph:62;tof:10;h:0;bat:87;baro:-21.34;time:0;agx:-12.00;agy:8.00;agz:-996.00;"
        guard let msg = TelloStateMessageParser.parse(raw) else {
            XCTFail("parse failed"); return
        }
        XCTAssertEqual(msg.pitchDeg, 0)
        XCTAssertEqual(msg.rollDeg, 0)
        XCTAssertEqual(msg.batteryPct, 87)
        XCTAssertEqual(msg.tofCm, 10)
        XCTAssertEqual(msg.heightCm, 0)
        XCTAssertEqual(msg.agx, -12.0, accuracy: 1e-9)
        XCTAssertEqual(msg.agz, -996.0, accuracy: 1e-9)
    }

    func testParseRejectsWhenRequiredFieldMissing() {
        // bat 누락.
        let raw = "pitch:0;roll:0;yaw:0;vgx:0;templ:60"
        XCTAssertNil(TelloStateMessageParser.parse(raw),
                     "필수 필드 (bat) 누락 → nil")
    }

    func testBatteryLevelClassification() {
        let high = makeMsg(battery: 80)
        XCTAssertEqual(high.batteryLevel, .good)
        let mid = makeMsg(battery: 30)
        XCTAssertEqual(mid.batteryLevel, .medium)
        let low = makeMsg(battery: 10)
        XCTAssertEqual(low.batteryLevel, .low)
    }

    func testBatteryClamping() {
        // bat 150 (out of range) — clamp 100.
        let raw = "pitch:0;roll:0;yaw:0;bat:150;"
        let msg = TelloStateMessageParser.parse(raw)
        XCTAssertEqual(msg?.batteryPct, 100, "150 → 100 clamp")

        let rawNeg = "pitch:0;roll:0;yaw:0;bat:-5;"
        let msgNeg = TelloStateMessageParser.parse(rawNeg)
        XCTAssertEqual(msgNeg?.batteryPct, 0, "-5 → 0 clamp")
    }

    func testParseHandlesExtraWhitespace() {
        let raw = "pitch : 0 ; roll: 0 ; yaw:0 ; bat: 87 ;"
        let msg = TelloStateMessageParser.parse(raw)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.batteryPct, 87)
    }

    func testParseIgnoresUnknownKeys() {
        let raw = "pitch:0;roll:0;yaw:0;bat:50;unknown_key:abc;"
        let msg = TelloStateMessageParser.parse(raw)
        XCTAssertNotNil(msg, "알 수 없는 키 무시")
    }

    func testTofOptionalWhenMissing() {
        let raw = "pitch:0;roll:0;yaw:0;bat:50"  // tof 없음.
        let msg = TelloStateMessageParser.parse(raw)
        XCTAssertNil(msg?.tofCm)
    }

    private func makeMsg(battery: Int) -> TelloStateMessage {
        TelloStateMessage(
            pitchDeg: 0, rollDeg: 0, yawDeg: 0,
            vgx: 0, vgy: 0, vgz: 0,
            templ: 0, temph: 0, tofCm: nil,
            heightCm: 0, batteryPct: battery, baroPa: nil,
            agx: 0, agy: 0, agz: 0,
            receivedAt: Date()
        )
    }
}
