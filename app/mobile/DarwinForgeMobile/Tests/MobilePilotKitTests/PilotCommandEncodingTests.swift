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

    func testInboundCockpitTelemetryDecodes() throws {
        let json = """
        {"v":1,"id":"evt_000002","type":"cockpit.telemetry","sentAt":"2026-06-03T12:00:00.000Z","payload":{"rollDeg":-3.5,"pitchDeg":12.0,"balanceState":"correcting","autoRecoveryPhase":"gettingUp","fallDirection":"forward"}}
        """
        let data = json.data(using: .utf8)!
        let inbound = try InboundDecoder.decode(data)
        switch inbound {
        case .cockpitTelemetry(let env):
            XCTAssertEqual(env.payload.rollDeg, -3.5, accuracy: 0.001)
            XCTAssertEqual(env.payload.pitchDeg, 12.0, accuracy: 0.001)
            XCTAssertEqual(env.payload.balanceState, "correcting")
            XCTAssertEqual(env.payload.autoRecoveryPhase, "gettingUp")
            XCTAssertEqual(env.payload.fallDirection, "forward")
            XCTAssertTrue(env.payload.isRecovering)
        default:
            XCTFail("expected cockpit.telemetry, got \(inbound)")
        }
    }

    /// forward-compat: balance/recovery 필드가 없는 최소 페이로드도 디코드돼야 한다
    /// (Mac 이 IMU 만 보내는 단계).
    func testInboundCockpitTelemetryMinimalDecodes() throws {
        let json = """
        {"v":1,"id":"evt_000003","type":"cockpit.telemetry","sentAt":"2026-06-03T12:00:01.000Z","payload":{"rollDeg":0,"pitchDeg":0}}
        """
        let data = json.data(using: .utf8)!
        let inbound = try InboundDecoder.decode(data)
        switch inbound {
        case .cockpitTelemetry(let env):
            XCTAssertEqual(env.payload.rollDeg, 0, accuracy: 0.001)
            XCTAssertNil(env.payload.balanceState)
            XCTAssertNil(env.payload.autoRecoveryPhase)
            XCTAssertFalse(env.payload.isRecovering)
        default:
            XCTFail("expected cockpit.telemetry, got \(inbound)")
        }
    }

    func testInboundCockpitLinkDecodes() throws {
        let json = """
        {"v":1,"id":"evt_000004","type":"cockpit.link","sentAt":"2026-06-03T12:00:02.000Z","payload":{"robotLinkRttMs":480,"telemetryHz":4.5,"transport":"ssh-wireless","onboardStale":false}}
        """
        let data = json.data(using: .utf8)!
        let inbound = try InboundDecoder.decode(data)
        switch inbound {
        case .cockpitLink(let env):
            XCTAssertEqual(env.payload.robotLinkRttMs, 480)
            XCTAssertEqual(env.payload.telemetryHz, 4.5)
            XCTAssertEqual(env.payload.transport, "ssh-wireless")
            XCTAssertTrue(env.payload.isWireless)
            XCTAssertTrue(env.payload.isDegraded, "RTT 480ms > 350ms → degraded")
        default:
            XCTFail("expected cockpit.link, got \(inbound)")
        }
    }

    func testRobotLinkDegradedThresholds() {
        // 양호: 유선 UDP.
        let good = RobotLinkPayload(robotLinkRttMs: 5, telemetryHz: 9.9,
                                    transport: "udp", onboardStale: false)
        XCTAssertFalse(good.isDegraded)
        XCTAssertFalse(good.isWireless)

        // 저하: 저주파.
        let lowHz = RobotLinkPayload(robotLinkRttMs: 80, telemetryHz: 1.5)
        XCTAssertTrue(lowHz.isDegraded, "1.5Hz < 2Hz → degraded")

        // 저하: stale.
        let stale = RobotLinkPayload(onboardStale: true)
        XCTAssertTrue(stale.isDegraded)

        // 무선 추론: transport 없어도 RTT 큰 경우.
        let wirelessByRtt = RobotLinkPayload(robotLinkRttMs: 149)
        XCTAssertTrue(wirelessByRtt.isWireless, "RTT 149 > 100 → wireless 추론")
    }

    /// forward-compat: 빈 회선 페이로드(모든 필드 nil)도 디코드되고 안전.
    func testInboundCockpitLinkMinimalDecodes() throws {
        let json = """
        {"v":1,"id":"evt_000005","type":"cockpit.link","sentAt":"2026-06-03T12:00:03.000Z","payload":{}}
        """
        let data = json.data(using: .utf8)!
        let inbound = try InboundDecoder.decode(data)
        switch inbound {
        case .cockpitLink(let env):
            XCTAssertNil(env.payload.robotLinkRttMs)
            XCTAssertFalse(env.payload.isDegraded)
        default:
            XCTFail("expected cockpit.link, got \(inbound)")
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
