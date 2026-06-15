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
        // V297-4: identity 기준이 channel.clientId 에서 hello.payload.deviceId 로 변경.
        // single-authority 검증은 **다른 deviceId** 두 폰이 같은 페어링 코드로 접속할 때
        // 두 번째가 alreadyOwned 거절되는지가 핵심. 동일 deviceId 는 reconnect 시나리오.
        let pairing = MobileRelayPairing(initialCode: "555000")
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort())
        let first = InMemoryChannel()
        let second = InMemoryChannel()

        await server.handleClientConnected(first,
                                            handshake: helloFrame(code: "555000",
                                                                  deviceId: "phone-A"))
        await server.handleClientConnected(second,
                                            handshake: helloFrame(code: "555000",
                                                                  deviceId: "phone-B"))
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

    /// **볼 트래킹 (2026-06-02)** — pilot.ballTrack 이 port.setBallTracking 으로 라우팅 +
    /// enabled 값 전달 + command.ack 회신.
    func testBallTrackRoutesToSafetyPort() async throws {
        let pairing = MobileRelayPairing(initialCode: "121212")
        let port = InMemorySafetyPort()
        port.setRobotState(.connected)
        let server = MobileRelayServer(pairing: pairing, port: port)
        let channel = InMemoryChannel()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "121212"))
        let on = makeFrame(type: "pilot.ballTrack", id: "cmd_bt_on",
                           payload: ["enabled": true])
        await server.handleClientFrame(on, from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(port.ballTrackingCalls, [true],
                       "pilot.ballTrack(enabled:true) → port.setBallTracking(true)")
        let acks = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_bt_on" && $0.type == "command.ack" }
        XCTAssertFalse(acks.isEmpty, "ballTrack 명령에 command.ack 회신")

        // OFF 토글도 전달.
        let off = makeFrame(type: "pilot.ballTrack", id: "cmd_bt_off",
                            payload: ["enabled": false])
        await server.handleClientFrame(off, from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(port.ballTrackingCalls, [true, false],
                       "OFF 토글도 port 로 전달")
    }

    /// 서버 welcome capabilities 가 ballTracking=true 광고 (iOS 가 버튼 노출 판단).
    func testWelcomeAdvertisesBallTrackingCapability() async throws {
        let pairing = MobileRelayPairing(initialCode: "131313")
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort())
        let channel = InMemoryChannel()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "131313"))
        try await Task.sleep(nanoseconds: 50_000_000)

        let welcome = channel.frames.compactMap { decode($0) }
            .first { $0.type == "session.welcome" }
        XCTAssertNotNil(welcome, "welcome 수신")
    }

    // MARK: - Helpers

    private func helloFrame(code: String, deviceId: String = "TEST") -> Data {
        makeFrame(type: "session.hello", id: "cmd_hello",
                  payload: ["app": "ios",
                            "appVersion": "0.1.0",
                            "protocolVersion": 1,
                            "deviceName": "Tester iPhone",
                            "deviceId": deviceId,
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
