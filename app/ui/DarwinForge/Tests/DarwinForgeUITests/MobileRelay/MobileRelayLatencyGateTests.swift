import XCTest
@testable import DarwinForgeUI

/// V291-8 — Walk/Motion latency gate 단위 테스트.
///
/// # 비유: 택배 유통기한
/// 리모컨 신호가 너무 늦게 도착하면 이미 상황이 달라진 셈 —
/// 화면 보면서 누른 버튼이 1초 뒤 반응하면 의도와 다른 동작이 일어난다.
/// 150ms(walk) / 200ms(motion) 임계치를 넘은 오래된 명령은 즉시 폐기한다.
///
/// 테스트 전략: `clock` 클로저 주입으로 시간을 완전히 제어한다.
/// sentAt = 고정 시각, clock() = sentAt + 측정하려는 latency.
final class MobileRelayLatencyGateTests: XCTestCase {

    // MARK: - Walk: 100ms → pass

    func testWalk_100ms_passes() async throws {
        let base = Date(timeIntervalSince1970: 1_748_000_000)
        let code = "lat001"
        let (server, channel) = makeServer(clockOffset: 0.100, base: base, pairingCode: code)

        await server.handleClientConnected(channel, handshake: helloFrame(code: code, sentAt: base))
        await server.handleClientFrame(
            walkFrame(id: "cmd_w100", sentAt: base),
            from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_w100" && $0.type == "command.rejected" }
        XCTAssertTrue(rejected.isEmpty, "100ms latency 는 통과해야 한다 (gate=150ms)")
    }

    // MARK: - Walk: 150ms → reject "latencyGate"

    func testWalk_150ms_rejectsLatencyGate() async throws {
        let base = Date(timeIntervalSince1970: 1_748_000_000)
        let code = "lat002"
        let (server, channel) = makeServer(clockOffset: 0.150, base: base, pairingCode: code)

        await server.handleClientConnected(channel, handshake: helloFrame(code: code, sentAt: base))
        await server.handleClientFrame(
            walkFrame(id: "cmd_w150", sentAt: base),
            from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_w150" && $0.type == "command.rejected" }
        XCTAssertFalse(rejected.isEmpty, "150ms latency 는 command.rejected 여야 한다")
        // reason 검증
        if let frame = channel.frames.first(where: {
            decodeHead($0)?.id == "cmd_w150" && decodeHead($0)?.type == "command.rejected"
        }) {
            let env = try? RelayCodec.decoder.decode(RelayEnvelope<RejectedPayload>.self, from: frame)
            XCTAssertEqual(env?.payload.reason, "latencyGate")
        }
    }

    // MARK: - Walk: 200ms → reject "latencyGate"

    func testWalk_200ms_rejectsLatencyGate() async throws {
        let base = Date(timeIntervalSince1970: 1_748_000_000)
        let code = "lat003"
        let (server, channel) = makeServer(clockOffset: 0.200, base: base, pairingCode: code)

        await server.handleClientConnected(channel, handshake: helloFrame(code: code, sentAt: base))
        await server.handleClientFrame(
            walkFrame(id: "cmd_w200", sentAt: base),
            from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_w200" && $0.type == "command.rejected" }
        XCTAssertFalse(rejected.isEmpty, "200ms latency 도 command.rejected 여야 한다")
    }

    // MARK: - Walk: 음수 latency (clock skew) → pass

    func testWalk_negativeLatency_passes() async throws {
        // clock() = sentAt - 0.5s (Mac 시계가 iPhone 보다 느린 상황)
        let base = Date(timeIntervalSince1970: 1_748_000_000)
        let code = "lat004"
        let (server, channel) = makeServer(clockOffset: -0.500, base: base, pairingCode: code)

        await server.handleClientConnected(channel, handshake: helloFrame(code: code, sentAt: base))
        await server.handleClientFrame(
            walkFrame(id: "cmd_wneg", sentAt: base),
            from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_wneg" && $0.type == "command.rejected" }
        XCTAssertTrue(rejected.isEmpty, "음수 latency 는 clock skew — 관대 정책으로 통과해야 한다")
    }

    // MARK: - E-stop: 1초 후에도 통과 (latency gate 미적용)

    func testEstop_1second_passes() async throws {
        let base = Date(timeIntervalSince1970: 1_748_000_000)
        let code = "lat005"
        let port = LatencyGateTestPort()
        // clock offset = +1.0s (walk gate 150ms 훨씬 초과)
        let (server, channel) = makeServer(port: port, clockOffset: 1.000, base: base, pairingCode: code)

        await server.handleClientConnected(channel, handshake: helloFrame(code: code, sentAt: base))
        let estopData = buildFrame(type: "pilot.estop", id: "cmd_estop",
                                   sentAt: base, payload: ["reason": "test"])
        await server.handleClientFrame(estopData, from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        // E-stop 은 command.rejected 가 아닌 command.ack 또는 command.failed 여야 한다.
        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_estop" && $0.type == "command.rejected" }
        XCTAssertTrue(rejected.isEmpty, "E-stop 은 latency gate 미적용 — 1초 후에도 통과해야 한다")
    }

    // MARK: - Motion: 199ms → pass (gate=200ms)

    func testMotion_199ms_passes() async throws {
        let base = Date(timeIntervalSince1970: 1_748_000_000)
        let code = "lat006"
        let (server, channel) = makeServer(clockOffset: 0.199, base: base, pairingCode: code)

        await server.handleClientConnected(channel, handshake: helloFrame(code: code, sentAt: base))
        let arm = buildFrame(type: "pilot.arm", id: "cmd_arm_lat",
                             sentAt: base, payload: ["cradleConfirmed": true, "operator": "T"])
        await server.handleClientFrame(arm, from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        let motion = buildFrame(type: "pilot.motion", id: "cmd_m199",
                                sentAt: base,
                                payload: ["slot": 1, "label": "walkReady", "confirmRisk": false])
        await server.handleClientFrame(motion, from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_m199" && $0.type == "command.rejected" }
        XCTAssertTrue(rejected.isEmpty, "199ms latency 는 motion gate (200ms) 를 통과해야 한다")
    }

    // MARK: - Motion: 200ms → reject "latencyGate"

    func testMotion_200ms_rejectsLatencyGate() async throws {
        let base = Date(timeIntervalSince1970: 1_748_000_000)
        let code = "lat007"
        let (server, channel) = makeServer(clockOffset: 0.200, base: base, pairingCode: code)

        await server.handleClientConnected(channel, handshake: helloFrame(code: code, sentAt: base))
        let arm = buildFrame(type: "pilot.arm", id: "cmd_arm_lat2",
                             sentAt: base, payload: ["cradleConfirmed": true, "operator": "T"])
        await server.handleClientFrame(arm, from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        let motion = buildFrame(type: "pilot.motion", id: "cmd_m200",
                                sentAt: base,
                                payload: ["slot": 1, "label": "walkReady", "confirmRisk": false])
        await server.handleClientFrame(motion, from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_m200" && $0.type == "command.rejected" }
        XCTAssertFalse(rejected.isEmpty, "200ms latency 는 motion gate 에서 거절돼야 한다")
        if let frame = channel.frames.first(where: {
            decodeHead($0)?.id == "cmd_m200" && decodeHead($0)?.type == "command.rejected"
        }) {
            let env = try? RelayCodec.decoder.decode(RelayEnvelope<RejectedPayload>.self, from: frame)
            XCTAssertEqual(env?.payload.reason, "latencyGate")
        }
    }

    // MARK: - Helpers

    /// `clockOffset` 초 후 시각을 반환하는 고정 clock 을 주입한 서버를 생성한다.
    /// `base` 는 envelope sentAt 으로 사용될 기준 시각.
    /// `pairingCode` 는 helloFrame 과 반드시 일치시켜야 한다.
    private func makeServer(
        port: RobotSafetyPort = LatencyGateTestPort(),
        clockOffset: TimeInterval,
        base: Date,
        pairingCode: String
    ) -> (MobileRelayServer, LatencyGateChannel) {
        let pairing = MobileRelayPairing(initialCode: pairingCode)
        // clock() 는 항상 base + offset 을 반환 (세션 연결 후에도 고정).
        let server = MobileRelayServer(
            pairing: pairing,
            port: port,
            clock: { base.addingTimeInterval(clockOffset) }
        )
        return (server, LatencyGateChannel())
    }

    private func helloFrame(code: String, sentAt: Date) -> Data {
        buildFrame(type: "session.hello", id: "cmd_hello_\(code)",
                   sentAt: sentAt,
                   payload: ["app": "ios", "appVersion": "0.1.0",
                             "protocolVersion": 1, "deviceName": "LatencyTestPhone",
                             "deviceId": "LT001", "pairingCode": code])
    }

    private func walkFrame(id: String, sentAt: Date) -> Data {
        buildFrame(type: "pilot.walk", id: id, sentAt: sentAt,
                   payload: ["preset": "slowForward", "enabled": true,
                             "xMm": 20.0, "yMm": 0.0, "aDeg": 0.0,
                             "periodMs": 700, "footMm": 35.0, "hipPitchDeg": 13.0])
    }

    private func buildFrame(type: String, id: String, sentAt: Date, payload: [String: Any]) -> Data {
        let iso = ISO8601DateFormatter.relayFractional.string(from: sentAt)
        let envelope: [String: Any] = [
            "v": 1, "id": id, "type": type,
            "sentAt": iso,
            "payload": payload
        ]
        return try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private func decode(_ data: Data) -> RelayEnvelopeHead? {
        try? RelayCodec.decoder.decode(RelayEnvelopeHead.self, from: data)
    }

    private func decodeHead(_ data: Data) -> RelayEnvelopeHead? {
        try? RelayCodec.decoder.decode(RelayEnvelopeHead.self, from: data)
    }
}

// MARK: - LatencyGateTestPort

/// Latency gate 테스트 전용 안전 포트.
/// arm/walk/motion/estop 모두 즉시 성공 반환 (latency gate 분기만 검증).
final class LatencyGateTestPort: RobotSafetyPort, @unchecked Sendable {

    func snapshot() async -> TelemetryStatePayload {
        TelemetryStatePayload(
            mac: .connected, robot: .connected, endpoint: nil,
            armed: true, dxlPower: true,
            batteryV: 12.0, maxTempC: 40,
            latencyMs: 5, lastAckAgeMs: nil,
            safety: .ready, uiState: .armedReady)
    }

    func arm(cradleConfirmed: Bool,
             operator: String,
             progress: @Sendable @escaping (String, Double) async -> Void) async throws -> Int {
        await progress("armed", 1.0)
        return 5
    }

    func disarm(reason: String) async throws -> Int { 5 }
    func emergencyStop(reason: String) async throws -> Int { 5 }
    func runMotion(slot: Int, label: String, confirmRisk: Bool) async throws -> Int { 5 }
    func sendWalk(payload: WalkPayload) async throws -> (latencyMs: Int, robotAckId: String?) { (5, nil) }
    func sendStop(reason: String) async throws -> Int { 5 }
}

// MARK: - LatencyGateChannel

final class LatencyGateChannel: RelayClientChannel, @unchecked Sendable {
    let clientId: String = UUID().uuidString
    private let lock = NSLock()
    private var _frames: [Data] = []
    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return _frames }

    func deliver(_ frame: Data) async throws {
        lock.lock(); _frames.append(frame); lock.unlock()
    }

    func disconnect(reason: String) async { _ = reason }
}
