import XCTest
@testable import MobilePilotKit

final class PilotCommandEncodingTests: XCTestCase {

    func testHelloRoundTrip() throws {
        let env = RelayEnvelope(id: "cmd_000001",
                                type: CommandType.sessionHello.rawValue,
                                sentAt: Date(timeIntervalSince1970: 1748169600),
                                payload: HelloPayload(appVersion: "0.1.0",
                                                      deviceName: "Pilot iPhone",
                                                      deviceId: "BEEF",
                                                      pairingCode: "482913"))
        let data = try RelayCodec.encode(env)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"pairingCode\":\"482913\""))
        let decoded = try RelayCodec.decode(data, as: HelloPayload.self)
        XCTAssertEqual(decoded.payload.pairingCode, "482913")
        XCTAssertEqual(decoded.type, CommandType.sessionHello.rawValue)
        XCTAssertEqual(decoded.v, 1)
    }

    func testWalkPresetEncoding() throws {
        let env = RelayEnvelope(id: "cmd_000099",
                                type: CommandType.pilotWalk.rawValue,
                                sentAt: Date(),
                                payload: WalkPayload(preset: .slowForward,
                                                     params: WalkPreset.slowForward.defaultParams))
        let data = try RelayCodec.encode(env)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertTrue(s.contains("\"preset\":\"slowForward\""))
        XCTAssertTrue(s.contains("\"xMm\":20"))
        XCTAssertTrue(s.contains("\"periodMs\":700"))
    }

    func testFreeformJoystickMapsForwardToStrideAndRightToSide() throws {
        let builder = CommandBuilder(ids: MonotonicCommandIDGenerator(prefix: "test"),
                                     clock: DeterministicClock())
        let env = builder.walkFreeform(.init(x: 0.5, y: -0.8, turn: 0.25,
                                             speedScale: 1.5))

        XCTAssertEqual(env.payload.preset, .freeform)
        XCTAssertEqual(env.payload.xMm, 20, accuracy: 0.001,
                       "joystick up/down must map to stride xMm")
        XCTAssertEqual(env.payload.yMm, 8, accuracy: 0.001,
                       "joystick left/right must map to lateral yMm")
        XCTAssertEqual(env.payload.aDeg, 3, accuracy: 0.001)
        XCTAssertEqual(env.payload.speedScale, 1.5, accuracy: 0.001,
                       "speedScale is sent separately for Mac-side safety clamp")
    }

    func testInboundTelemetryDecodes() throws {
        let json = """
        {"v":1,"id":"evt_000001","type":"telemetry.state","sentAt":"2026-05-25T12:00:00.000Z","payload":{"mac":"connected","robot":"connected","endpoint":"tcp://1.2.3.4:5530","armed":true,"dxlPower":true,"batteryV":11.7,"maxTempC":42,"latencyMs":34,"lastAckAgeMs":90,"safety":"ready","uiState":"armedReady"}}
        """
        let data = json.data(using: .utf8)!
        let inbound = try InboundDecoder.decode(data)
        switch inbound {
        case .telemetryState(let env):
            XCTAssertEqual(env.payload.armed, true)
            XCTAssertEqual(env.payload.batteryV, 11.7)
        default:
            XCTFail("expected telemetry.state, got \(inbound)")
        }
    }

    func testWalkPresetDefaults() {
        XCTAssertEqual(WalkPreset.slowForward.defaultParams.xMm, 20)
        XCTAssertEqual(WalkPreset.turnLeft.defaultParams.aDeg, 8)
        XCTAssertEqual(WalkPreset.turnRight.defaultParams.aDeg, -8)
        XCTAssertFalse(WalkPreset.stop.defaultParams.enabled)
    }

    func testMotionCatalogMVPSubset() {
        XCTAssertTrue(SafeMotionCatalog.mvpEnabledLabels.contains("walkReady"))
        XCTAssertFalse(SafeMotionCatalog.mvpEnabledLabels.contains("kickRight"))
        XCTAssertEqual(SafeMotionCatalog.entry(forLabel: "walkReady")?.slot, 9)
    }
}
