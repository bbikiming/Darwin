import XCTest
@testable import DarwinForgeUI

/// V291-8 + V297-4 — Walk/Motion latency gate 단위 테스트.
///
/// # 비유: 택배 유통기한
/// 리모컨 신호가 너무 늦게 도착하면 이미 상황이 달라진 셈 —
/// 화면 보면서 누른 버튼이 1초 뒤 반응하면 의도와 다른 동작이 일어난다.
/// 보행/모션 명령은 **서버측 측정 RTT** 임계 (walk 350ms, motion 450ms) 를 넘으면 폐기.
///
/// # V297-4 의도된 동작 변경
///
/// 종전: iOS clock 기반 (sentAt − clock()) latency 가 임계 (walk 150ms, motion 200ms)
/// 초과시 reject. → 시계 드리프트로 거짓 reject 위험.
///
/// 신규: **서버측 RTT 기반** (`lastRobotRttMs`, 마지막 robot ACK round-trip).
/// iOS clock 은 ±10초 초과시 clockSkew reject 만. 정상 범위 iOS-Mac latency 는
/// reject 트리거 안 함 (highLatency 정보성 warning 만).
///
/// 테스트 전략: `clock` 클로저로 iOS clock latency 시뮬, port.latencyMs 로 RTT 시뮬.
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

    // MARK: - Walk: iOS clock 150ms 만으로는 reject 안 됨 (V297-4)
    //
    // 종전: iOS clock 150ms ≥ walk gate → reject. V297-4 이후: 서버측 RTT 가 350ms 미만이면
    // iOS clock 150ms 는 정상 명령으로 통과. clockSkew 도 ±10s 미만 → 통과.

    func testWalk_iOSClock150ms_passes_serverRTTNotPrimed() async throws {
        let base = Date(timeIntervalSince1970: 1_748_000_000)
        let code = "lat002"
        let (server, channel) = makeServer(clockOffset: 0.150, base: base, pairingCode: code)

        await server.handleClientConnected(channel, handshake: helloFrame(code: code, sentAt: base))
        await server.handleClientFrame(
            walkFrame(id: "cmd_w150", sentAt: base),
            from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        // V297-4: iOS clock 150ms 만으로는 reject 트리거 X (서버측 RTT 가 nil → 게이트 관대 통과).
        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_w150" && $0.type == "command.rejected" }
        XCTAssertTrue(rejected.isEmpty,
                      "V297-4: iOS clock 150ms 는 reject 트리거 X — 서버측 RTT 기반 게이트")
    }

    // MARK: - Walk: iOS clock 200ms 도 reject 안 됨 (V297-4)

    func testWalk_iOSClock200ms_passes_serverRTTNotPrimed() async throws {
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
        XCTAssertTrue(rejected.isEmpty,
                      "V297-4: iOS clock 200ms 도 reject 트리거 X (서버측 RTT 기준)")
    }

    // MARK: - V297-4 — 서버측 RTT 350ms+ 시 reject

    /// 첫 walk 가 robot ACK latency 400ms 반환 → 서버측 RTT 캐시 = 400ms.
    /// 두 번째 walk 가 동일 캐시 보고 350ms 임계 초과 → reject.
    func testWalk_serverRTT400ms_rejectsLatencyGate() async throws {
        let base = Date(timeIntervalSince1970: 1_748_000_000)
        let code = "lat003b"
        let port = MutableLatencyGateTestPort(latencyMs: 400)
        let (server, channel) = makeServer(port: port,
                                           clockOffset: 0.020, base: base, pairingCode: code)

        await server.handleClientConnected(channel, handshake: helloFrame(code: code, sentAt: base))

        // 첫 walk — RTT 캐시 prime (이 호출 자체는 RTT nil 이라 게이트 통과 + 400ms cache).
        await server.handleClientFrame(
            walkFrame(id: "cmd_w_prime", sentAt: base), from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        // 두 번째 walk — 캐시된 400ms 가 walk gate 350ms 초과 → reject.
        await server.handleClientFrame(
            walkFrame(id: "cmd_w_after", sentAt: base), from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_w_after" && $0.type == "command.rejected" }
        XCTAssertFalse(rejected.isEmpty,
                       "서버측 RTT 400ms 캐시 → walk gate 350ms 초과 → reject")
        if let frame = channel.frames.first(where: {
            decodeHead($0)?.id == "cmd_w_after" && decodeHead($0)?.type == "command.rejected"
        }) {
            let env = try? RelayCodec.decoder.decode(RelayEnvelope<RejectedPayload>.self, from: frame)
            XCTAssertEqual(env?.payload.reason, "latencyGate")
        }
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

    // MARK: - Motion: iOS clock 200ms 만으로는 reject 안 됨 (V297-4)

    func testMotion_iOSClock200ms_passes_serverRTTNotPrimed() async throws {
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
        XCTAssertTrue(rejected.isEmpty,
                      "V297-4: iOS clock 200ms 는 motion reject 트리거 X (서버측 RTT 기준)")
    }

    // MARK: - V297-4 — clockSkew >10s 양방향 reject

    /// iOS clock 이 Mac 보다 12초 앞선 (음수 raw skew, abs > 10000) → clockSkew reject.
    func testWalk_iOSClock12sAhead_rejectsClockSkew() async throws {
        let base = Date(timeIntervalSince1970: 1_748_000_000)
        let code = "lat_skew"
        // clock() = base − 12s (iOS clock 이 12초 앞섬 = Mac clock 이 12초 뒤짐)
        let (server, channel) = makeServer(clockOffset: -12.0, base: base, pairingCode: code)
        await server.handleClientConnected(channel, handshake: helloFrame(code: code, sentAt: base))
        await server.handleClientFrame(walkFrame(id: "cmd_skew", sentAt: base), from: channel)
        try await Task.sleep(nanoseconds: 60_000_000)

        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_skew" && $0.type == "command.rejected" }
        XCTAssertFalse(rejected.isEmpty, "12초 음수 skew 는 clockSkew reject 되어야")
        if let frame = channel.frames.first(where: {
            decodeHead($0)?.id == "cmd_skew" && decodeHead($0)?.type == "command.rejected"
        }) {
            let env = try? RelayCodec.decoder.decode(RelayEnvelope<RejectedPayload>.self, from: frame)
            XCTAssertEqual(env?.payload.reason, "clockSkew")
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

// MARK: - MutableLatencyGateTestPort (V297-4 RTT prime 테스트용)

/// 서버측 RTT 캐시 prime 테스트용 — sendWalk 가 반환하는 latency 를 변경 가능.
final class MutableLatencyGateTestPort: RobotSafetyPort, @unchecked Sendable {
    private let lock = NSLock()
    private var _latencyMs: Int

    init(latencyMs: Int) {
        self._latencyMs = latencyMs
    }

    var latencyMs: Int {
        get { lock.lock(); defer { lock.unlock() }; return _latencyMs }
        set { lock.lock(); _latencyMs = newValue; lock.unlock() }
    }

    func snapshot() async -> TelemetryStatePayload {
        TelemetryStatePayload(
            mac: .connected, robot: .connected, endpoint: nil,
            armed: true, dxlPower: true,
            batteryV: 12.0, maxTempC: 40,
            latencyMs: latencyMs, lastAckAgeMs: nil,
            safety: .ready, uiState: .armedReady)
    }

    func arm(cradleConfirmed: Bool,
             operator: String,
             progress: @Sendable @escaping (String, Double) async -> Void) async throws -> Int {
        await progress("armed", 1.0)
        return latencyMs
    }

    func disarm(reason: String) async throws -> Int { latencyMs }
    func emergencyStop(reason: String) async throws -> Int { latencyMs }
    func runMotion(slot: Int, label: String, confirmRisk: Bool) async throws -> Int { latencyMs }
    func sendWalk(payload: WalkPayload) async throws -> (latencyMs: Int, robotAckId: String?) {
        (latencyMs, "mock-rtt-\(latencyMs)")
    }
    func sendStop(reason: String) async throws -> Int { latencyMs }
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
