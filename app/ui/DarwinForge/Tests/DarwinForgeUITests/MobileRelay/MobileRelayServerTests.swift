import XCTest
@testable import DarwinForgeUI

final class MobileRelayServerTests: XCTestCase {

    func testHelloAcceptedWithCorrectPairingCode() async throws {
        let pairing = MobileRelayPairing(initialCode: "123456")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(pairing: pairing, port: port)
        let channel = InMemoryChannel()

        await server.handleClientConnected(channel,
                                           handshake: helloFrame(code: "123456"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(channel.frames.contains { decode($0)?.type == "session.welcome" })
        XCTAssertFalse(channel.frames.contains { decode($0)?.type == "session.rejected" })
    }

    func testHelloRejectedWithWrongCode() async throws {
        let pairing = MobileRelayPairing(initialCode: "123456")
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort())
        let channel = InMemoryChannel()

        await server.handleClientConnected(channel,
                                           handshake: helloFrame(code: "999999"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(channel.frames.contains { decode($0)?.type == "session.rejected" })
    }

    func testSingleAuthorityRejectsSecondClient() async throws {
        let pairing = MobileRelayPairing(initialCode: "555000")
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort())
        let first = InMemoryChannel()
        let second = InMemoryChannel()

        await server.handleClientConnected(first, handshake: helloFrame(code: "555000"))
        await server.handleClientConnected(second, handshake: helloFrame(code: "555000"))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(first.frames.contains { decode($0)?.type == "session.welcome" })
        XCTAssertTrue(second.frames.contains { decode($0)?.type == "session.rejected" })
    }

    func testHeartbeatTimeoutEmitsWatchdogStop() async throws {
        let pairing = MobileRelayPairing(initialCode: "200000")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(
            configuration: .init(heartbeatIntervalMs: 20, watchdogTimeoutMs: 40),
            pairing: pairing, port: port)
        let channel = InMemoryChannel()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "200000"))
        // Simulate active command so watchdog actually fires the stop path.
        let heartbeat = makeFrame(type: "pilot.heartbeat",
                                  id: "cmd_hb",
                                  payload: ["uiState": "commandActive",
                                            "activeCommandId": "cmd_walk"])
        await server.handleClientFrame(heartbeat, from: channel)
        // wait > watchdog timeout
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(channel.frames.contains { decode($0)?.type == "watchdog.stop" })
    }

    func testEStopRoutesToSafetyPort() async throws {
        let pairing = MobileRelayPairing(initialCode: "303030")
        let port = InMemorySafetyPort()
        port.setRobotState(.connected)
        let server = MobileRelayServer(pairing: pairing, port: port)
        let channel = InMemoryChannel()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "303030"))
        let estop = makeFrame(type: "pilot.estop", id: "cmd_e",
                              payload: ["reason": "user"])
        await server.handleClientFrame(estop, from: channel)
        try await Task.sleep(nanoseconds: 100_000_000)

        // After E-stop the safety port should report estopped robot.
        let snapshot = await port.snapshot()
        XCTAssertEqual(snapshot.robot, .estopped)
        // And the channel should have received an ack for the command.
        let ackFrames = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_e" && $0.type == "command.ack" }
        XCTAssertFalse(ackFrames.isEmpty)
    }

    func testWalkPresetRoundTripsThroughPort() async throws {
        let pairing = MobileRelayPairing(initialCode: "111111")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { 11.7 })
        let channel = InMemoryChannel()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "111111"))
        // ARM
        let arm = makeFrame(type: "pilot.arm", id: "cmd_arm",
                            payload: ["cradleConfirmed": true, "operator": "Tester"])
        await server.handleClientFrame(arm, from: channel)
        try await Task.sleep(nanoseconds: 50_000_000)
        // Walk
        let walk = makeFrame(type: "pilot.walk", id: "cmd_walk",
                             payload: ["preset": "slowForward",
                                       "enabled": true,
                                       "xMm": 20.0, "yMm": 0.0, "aDeg": 0.0,
                                       "periodMs": 700, "footMm": 35.0, "hipPitchDeg": 13.0])
        await server.handleClientFrame(walk, from: channel)
        try await Task.sleep(nanoseconds: 50_000_000)

        let walkAcks = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_walk" && $0.type == "command.ack" }
        XCTAssertFalse(walkAcks.isEmpty)
    }

    // MARK: - Helpers

    private func helloFrame(code: String) -> Data {
        makeFrame(type: "session.hello", id: "cmd_hello",
                  payload: ["app": "ios",
                            "appVersion": "0.1.0",
                            "protocolVersion": 1,
                            "deviceName": "Tester iPhone",
                            "deviceId": "TEST",
                            "pairingCode": code])
    }

    private func makeFrame(type: String, id: String, payload: [String: Any]) -> Data {
        // sentAt 은 현재 시각으로 — server의 latency gate (walk: 150ms, motion: 200ms)
        // 와 clockSkew 가드(>10s)를 통과하려면 fixture 가 server clock 근처여야 한다.
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

    private func decode(_ data: Data) -> RelayEnvelopeHead? {
        try? RelayCodec.decoder.decode(RelayEnvelopeHead.self, from: data)
    }
}

final class InMemoryChannel: RelayClientChannel, @unchecked Sendable {
    let clientId: String = UUID().uuidString
    private let lock = NSLock()
    private var _frames: [Data] = []
    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return _frames }

    func deliver(_ frame: Data) async throws {
        lock.lock(); _frames.append(frame); lock.unlock()
    }

    func disconnect(reason: String) async {
        _ = reason
    }
}
