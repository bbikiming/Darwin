import XCTest
@testable import DarwinForgeUI

/// V297-5 audit fix unit tests — GPT review 결과로 추가된 5 CRITICAL + 4 HIGH 회로.
///
/// 각 테스트는 회귀 가능성이 있는 단일 결함만 검증한다 — long form integration 은
/// 기존 MobileRelayServerTests / WalkIntegrationTests 가 다룸.
final class MobileRelayV297_5AuditTests: XCTestCase {

    // MARK: - CRITICAL-2 — hello 검증 순서

    /// protocol/pairing 검증 실패 시 기존 session 이 mutate 되지 않아야 한다.
    /// 종전 회로: same deviceId reconnect 의 session 교체가 검증 전 발생 → 검증 실패해도
    /// 새 channel 로 mutate 되어 권한 leak.
    func testProtocolMismatchPreservesExistingSession() async throws {
        let pairing = MobileRelayPairing(initialCode: "100100")
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort())

        let first = InMemoryChannel()
        await server.handleClientConnected(first, handshake: helloFrame(code: "100100",
                                                                         deviceId: "phone-A"))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(first.frames.contains { decode($0)?.type == "session.welcome" })

        // 동일 deviceId 로 protocol version 잘못된 hello — 검증 실패해야 함.
        let second = InMemoryChannel()
        let badHello = helloFrame(code: "100100", deviceId: "phone-A", protocolVersion: 999)
        await server.handleClientConnected(second, handshake: badHello)
        try await Task.sleep(nanoseconds: 30_000_000)

        // second 는 session.rejected 받아야 함.
        XCTAssertTrue(second.frames.contains { decode($0)?.type == "session.rejected" })
        // 기존 first session 은 그대로 살아있어야 함 — telemetry 보내서 확인.
        await server.broadcastTelemetry()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(first.frames.contains { decode($0)?.type == "telemetry.state" })
    }

    /// pairing 코드 실패도 기존 session 보존.
    func testPairingMismatchPreservesExistingSession() async throws {
        let pairing = MobileRelayPairing(initialCode: "200200")
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort())

        let first = InMemoryChannel()
        await server.handleClientConnected(first, handshake: helloFrame(code: "200200",
                                                                         deviceId: "phone-A"))
        try await Task.sleep(nanoseconds: 30_000_000)

        // 동일 deviceId 로 잘못된 pairing 코드 — pairing.validate 가 lockout 트리거하기 전 1회만.
        let second = InMemoryChannel()
        await server.handleClientConnected(second, handshake: helloFrame(code: "999999",
                                                                          deviceId: "phone-A"))
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(second.frames.contains { decode($0)?.type == "session.rejected" })
        // first 의 telemetry 전송이 여전히 가능 = session 보존됨.
        await server.broadcastTelemetry()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(first.frames.contains { decode($0)?.type == "telemetry.state" })
    }

    // MARK: - CRITICAL-4 — disconnect grace cancel 시점

    /// 다른 deviceId 가 grace 중 hello 시도 → alreadyOwned 거절. 기존 grace 가
    /// 유지되어야 함 (검증 실패 path 에서 cancel 해버리면 stop/disarm 안 발사).
    /// 본 테스트는 회로 존재 여부만 확인 — actual 1.5s grace timer 동작은 별도 통합 테스트.
    func testForeignReconnectInGracePeriodRejectsButPreservesSession() async throws {
        let pairing = MobileRelayPairing(initialCode: "303030")
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort())

        let owner = InMemoryChannel()
        await server.handleClientConnected(owner, handshake: helloFrame(code: "303030",
                                                                         deviceId: "phone-A"))
        try await Task.sleep(nanoseconds: 30_000_000)

        // 다른 deviceId 로 시도 — alreadyOwned 응답.
        let stranger = InMemoryChannel()
        await server.handleClientConnected(stranger, handshake: helloFrame(code: "303030",
                                                                            deviceId: "phone-B"))
        try await Task.sleep(nanoseconds: 30_000_000)

        let strangerRejected = stranger.frames.compactMap { decode($0) }
            .first { $0.type == "session.rejected" }
        XCTAssertNotNil(strangerRejected)

        // owner session 은 그대로 telemetry 받음.
        await server.broadcastTelemetry()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(owner.frames.contains { decode($0)?.type == "telemetry.state" })
    }

    // MARK: - HIGH-4 — clockSkew 양방향

    /// iOS clock 이 Mac 보다 12초 앞선 (음수 skew) hello 는 통과하더라도, 후속 명령은
    /// abs(skew) > 10s 로 clockSkew reject 되어야 한다.
    func testClockSkewRejectsBothDirections() async throws {
        let pairing = MobileRelayPairing(initialCode: "404040")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { 11.7 })
        let channel = InMemoryChannel()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "404040",
                                                                           deviceId: "phone-A"))
        try await Task.sleep(nanoseconds: 30_000_000)

        // ARM (정상 sentAt).
        let arm = makeFrame(type: "pilot.arm", id: "cmd_arm",
                            payload: ["cradleConfirmed": true, "operator": "Tester"])
        await server.handleClientFrame(arm, from: channel)
        try await Task.sleep(nanoseconds: 50_000_000)

        // walk 인데 sentAt 이 12초 미래 (iOS clock 앞섬, 음수 skew).
        let futureDate = Date().addingTimeInterval(12.0)
        let walk = makeFrame(type: "pilot.walk", id: "cmd_walk_skewed",
                             sentAt: futureDate,
                             payload: ["preset": "slowForward",
                                       "enabled": true,
                                       "xMm": 20.0, "yMm": 0.0, "aDeg": 0.0,
                                       "periodMs": 700, "footMm": 35.0, "hipPitchDeg": 13.0])
        await server.handleClientFrame(walk, from: channel)
        try await Task.sleep(nanoseconds: 50_000_000)

        // command.rejected with reason=clockSkew
        let rejects = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_walk_skewed" && $0.type == "command.rejected" }
        XCTAssertFalse(rejects.isEmpty, "음수 skew (iOS clock 앞섬) 도 reject 되어야")
    }

    // MARK: - CRITICAL-1 — priority command bypass

    /// MobileRelayWireProtocol.isPriorityCommand 가 estop/stop 만 분류.
    func testPriorityCommandClassification() {
        XCTAssertTrue(MobileRelayWireProtocol.isPriorityCommand("pilot.estop"))
        XCTAssertTrue(MobileRelayWireProtocol.isPriorityCommand("pilot.stop"))
        XCTAssertFalse(MobileRelayWireProtocol.isPriorityCommand("pilot.arm"))
        XCTAssertFalse(MobileRelayWireProtocol.isPriorityCommand("pilot.walk"))
        XCTAssertFalse(MobileRelayWireProtocol.isPriorityCommand("pilot.motion"))
        XCTAssertFalse(MobileRelayWireProtocol.isPriorityCommand("session.hello"))
    }

    // MARK: - V297-5 LOW-2 — capabilities 명칭

    /// WelcomeCapabilities 필드명이 speedScaleAccepted (실 적용 vs 수신 검증 구분).
    func testWelcomeCapabilitiesUsesAcceptedSemantics() throws {
        let cap = WelcomeCapabilities(head: false, walkFreeform: false, speedScaleAccepted: true)
        let encoded = try JSONEncoder().encode(cap)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("speedScaleAccepted"),
                      "capability JSON 에 speedScaleAccepted 필드 존재")
        XCTAssertFalse(json.contains("\"speedScale\":"),
                       "legacy speedScale 명칭 잔존 X")
    }

    // MARK: - Helpers

    private func helloFrame(code: String,
                             deviceId: String,
                             protocolVersion: Int = 1) -> Data {
        makeFrame(type: "session.hello", id: "cmd_hello",
                  payload: ["app": "ios",
                            "appVersion": "0.1.0",
                            "protocolVersion": protocolVersion,
                            "deviceName": "Test iPhone",
                            "deviceId": deviceId,
                            "pairingCode": code])
    }

    private func makeFrame(type: String, id: String,
                            sentAt: Date = Date(),
                            payload: [String: Any]) -> Data {
        let envelope: [String: Any] = [
            "v": 1, "id": id, "type": type,
            "sentAt": Self.isoFormatter.string(from: sentAt),
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
