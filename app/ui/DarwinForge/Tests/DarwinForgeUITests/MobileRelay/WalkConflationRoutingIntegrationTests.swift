import XCTest
@testable import DarwinForgeUI

/// B2 — **production-path** proof for the STOP-ordered-ahead / never-dropped safety
/// property (SDD bounce HIGH).
///
/// Unlike `WalkConflationSlotTests` (which exercises the value type in isolation
/// with a 4-offers-1-drain sequence the real path never produces), this drives the
/// ACTUAL routing: `handleClientFrame` → `handleWalk` → `port.sendWalk`, one frame
/// at a time, exactly as the live transport delivers them. It asserts that an
/// interleaved STOP reaches `sendWalk` ORDERED AHEAD of the later walk and is never
/// dropped.
///
/// No ms value is asserted — the latency NUMBERS are robot-deferred.
final class WalkConflationRoutingIntegrationTests: XCTestCase {

    // MARK: - test_stopInterleavedBetweenWalkFrames_reachesSendWalkOrderedAhead (MANDATORY, real path)

    func test_stopInterleavedBetweenWalkFrames_reachesSendWalkOrderedAhead() async throws {
        let port = RecordingWalkPort()
        let (server, channel) = try await makeArmedServer(port: port)

        // Real routing: four SEPARATE frames, each fully awaited (as the live
        // transport's serialized taskChain delivers them): [walk, walk, STOP, walk].
        await server.handleClientFrame(
            walkFrame(id: "w1", preset: "freeform", enabled: true, xMm: 11), from: channel)
        await server.handleClientFrame(
            walkFrame(id: "w2", preset: "freeform", enabled: true, xMm: 12), from: channel)
        await server.handleClientFrame(
            walkFrame(id: "s1", preset: "stop", enabled: false, xMm: 0), from: channel)
        await server.handleClientFrame(
            walkFrame(id: "w3", preset: "freeform", enabled: true, xMm: 13), from: channel)
        try await Task.sleep(nanoseconds: 120_000_000)

        let order = port.sendWalkOrder()

        // STOP reached sendWalk — never dropped.
        let stopIndex = order.firstIndex { $0.preset == .stop }
        XCTAssertNotNil(stopIndex,
                        "interleaved STOP must reach port.sendWalk through the real path")

        // The later walk (xMm == 13) also reached sendWalk.
        let laterWalkIndex = order.firstIndex { $0.preset == .freeform && $0.xMm == 13 }
        XCTAssertNotNil(laterWalkIndex, "the later walk must reach sendWalk")

        // CORE SAFETY PROPERTY: STOP is ordered AHEAD of the later walk — never behind.
        XCTAssertLessThan(stopIndex!, laterWalkIndex!,
                          "STOP must reach sendWalk ordered ahead of the later walk")

        // STOP delivered exactly once (not duplicated, not coalesced away).
        let stopCount = order.filter { $0.preset == .stop }.count
        XCTAssertEqual(stopCount, 1, "STOP must be delivered exactly once")

        // The STOP command itself was ACKed back to the client (delivered, not lost).
        let stopAcks = channel.frames.compactMap { try? RelayCodec.decoder.decode(
            RelayEnvelopeHead.self, from: $0) }
            .filter { $0.id == "s1" && $0.type == "command.ack" }
        XCTAssertFalse(stopAcks.isEmpty, "STOP frame must receive a command.ack")
    }

    // MARK: - Helpers

    private func makeArmedServer(
        port: RecordingWalkPort
    ) async throws -> (MobileRelayServer, InMemoryWalkChannel) {
        let pairing = MobileRelayPairing(initialCode: "walk02")
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { 11.7 })
        let channel = InMemoryWalkChannel()
        await server.handleClientConnected(channel, handshake: helloFrame(code: "walk02"))
        let arm = makeFrame(type: "pilot.arm", id: "cmd_arm_setup",
                            payload: ["cradleConfirmed": true, "operator": "Test"])
        await server.handleClientFrame(arm, from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)
        return (server, channel)
    }

    private func walkFrame(id: String, preset: String, enabled: Bool,
                           xMm: Double) -> Data {
        makeFrame(type: "pilot.walk", id: id,
                  payload: ["preset": preset, "enabled": enabled,
                            "xMm": xMm, "yMm": 0.0, "aDeg": 0.0,
                            "periodMs": 700, "footMm": 35.0, "hipPitchDeg": 13.0])
    }

    private func helloFrame(code: String) -> Data {
        makeFrame(type: "session.hello", id: "cmd_hello",
                  payload: ["app": "ios", "appVersion": "0.1.0",
                            "protocolVersion": 1, "deviceName": "TestPhone",
                            "deviceId": "T002", "pairingCode": code])
    }

    private func makeFrame(type: String, id: String, payload: [String: Any]) -> Data {
        let envelope: [String: Any] = [
            "v": 1, "id": id, "type": type,
            "sentAt": Self.isoFormatter.string(from: Date()),
            "payload": payload
        ]
        return try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - RecordingWalkPort

/// `RobotSafetyPort` that records the ORDERED sequence of `sendWalk` payloads so
/// the integration test can assert STOP-ordered-ahead through the real relay path.
final class RecordingWalkPort: RobotSafetyPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _sendWalkOrder: [WalkPayload] = []

    func sendWalkOrder() -> [WalkPayload] {
        lock.lock(); defer { lock.unlock() }; return _sendWalkOrder
    }

    func snapshot() async -> TelemetryStatePayload {
        TelemetryStatePayload(
            mac: .connected, robot: .connected, endpoint: nil,
            armed: true, dxlPower: true, batteryV: 11.7, maxTempC: 41,
            latencyMs: 10, lastAckAgeMs: nil, safety: .ready, uiState: .armedReady)
    }

    func arm(cradleConfirmed: Bool, operator: String,
             progress: @Sendable @escaping (String, Double) async -> Void) async throws -> Int {
        guard cradleConfirmed else { throw RelayServerError.rejected("cradleRequired") }
        await progress("armed", 1.0)
        return 10
    }

    func disarm(reason: String) async throws -> Int { 5 }
    func emergencyStop(reason: String) async throws -> Int { 5 }
    func runMotion(slot: Int, label: String, confirmRisk: Bool) async throws -> Int { 10 }

    func sendWalk(payload: WalkPayload) async throws -> (latencyMs: Int, robotAckId: String?) {
        lock.lock(); _sendWalkOrder.append(payload); lock.unlock()
        return (10, "mock-\(payload.preset.rawValue)")
    }

    func sendStop(reason: String) async throws -> Int { 5 }
}
