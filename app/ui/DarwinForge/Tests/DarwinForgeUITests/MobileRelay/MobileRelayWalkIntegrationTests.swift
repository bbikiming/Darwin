import XCTest
@testable import DarwinForgeUI

/// V291-4 — WalkPreset 매핑 + sendWalk 실 구현 통합 테스트.
///
/// # 비유: 회로 기판 검수
/// 리모컨-TV 회로를 연결한 후, 채널 변경 신호가 실제로 전달되는지 측정기로 확인하는 단계.
/// InMemoryWalkPort 가 WalkLabSession 역할을 수행하고, 각 preset 매핑과 안전 로직을 검증한다.
final class MobileRelayWalkIntegrationTests: XCTestCase {

    // MARK: - WalkPresetMapper 매핑 5 케이스

    func testPresetMapper_slowForward_mapsToSlowWalk() {
        XCTAssertEqual(WalkPresetMapper.map(.slowForward), .slowWalk)
    }

    func testPresetMapper_turnLeft_mapsToTurnLeft() {
        XCTAssertEqual(WalkPresetMapper.map(.turnLeft), .turnLeft)
    }

    func testPresetMapper_turnRight_mapsToTurnRight() {
        XCTAssertEqual(WalkPresetMapper.map(.turnRight), .turnRight)
    }

    func testPresetMapper_stop_mapsToIdle() {
        XCTAssertEqual(WalkPresetMapper.map(.stop), .idle)
    }

    func testPresetMapper_freeform_fallsBackToIdle() {
        // freeform 은 whitelist 에서 차단되지만 mapper 는 idle fallback.
        XCTAssertEqual(WalkPresetMapper.map(.freeform), .idle)
    }

    // MARK: - freeform joystick path

    func testFreeformPreset_isAcceptedByWalkPort() async throws {
        let port = MockWalkSafetyPort(dxlPower: true, walkSessionAvailable: true)
        let (server, channel) = try await makeArmedServer(port: port)

        let walk = makeWalkFrame(id: "cmd_fw", preset: "freeform",
                                 xMm: 18, yMm: 6, aDeg: 3, speedScale: 1.25)
        await server.handleClientFrame(walk, from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        let acks = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_fw" && $0.type == "command.ack" }
        XCTAssertFalse(acks.isEmpty, "freeform 정상 시 command.ack 를 받아야 한다")
        XCTAssertEqual(port.lastWalkPayload?.preset, .freeform)
        XCTAssertEqual(port.lastWalkPayload?.speedScale, 1.25)
    }

    func testFreeformMapper_appliesSpeedScaleAndClamp() {
        let payload = WalkPayload(preset: .freeform, enabled: true,
                                  xMm: 40, yMm: 40, aDeg: 40,
                                  periodMs: 700, footMm: 35,
                                  hipPitchDeg: 13, speedScale: 1.5)
        let tuning = MobileFreeformWalkMapper.tuning(from: payload,
                                                     speedScale: payload.speedScale ?? 1.0)
        // 2026-06-08 빠른보행 baseline: stride clamp 38→50, side 22→26 (Switch agent 정합).
        XCTAssertEqual(tuning.strideMm, 50, accuracy: 0.001)
        XCTAssertEqual(tuning.sideMm, 26, accuracy: 0.001)
        // turn clamp 18 → 12 보수화 (다리 충돌 방지, 모든 조종 경로 공통).
        XCTAssertEqual(tuning.turnDeg, 12, accuracy: 0.001)
    }

    // MARK: - dxlPower OFF 시 reject

    func testDxlPowerOff_rejectsWalkCommand() async throws {
        let port = MockWalkSafetyPort(dxlPower: false, walkSessionAvailable: true)
        let (server, channel) = try await makeArmedServer(port: port)

        let walk = makeWalkFrame(id: "cmd_dxl", preset: "slowForward")
        await server.handleClientFrame(walk, from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_dxl" && $0.type == "command.rejected" }
        XCTAssertFalse(rejected.isEmpty, "dxlPower OFF 시 command.rejected 를 받아야 한다")
    }

    // MARK: - 정상 경로: commandAck + walkActive=true

    func testNormalWalk_slowForward_returnsCommandAck() async throws {
        let port = MockWalkSafetyPort(dxlPower: true, walkSessionAvailable: true)
        let (server, channel) = try await makeArmedServer(port: port)

        let walk = makeWalkFrame(id: "cmd_ok", preset: "slowForward")
        await server.handleClientFrame(walk, from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        let acks = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_ok" && $0.type == "command.ack" }
        XCTAssertFalse(acks.isEmpty, "slowForward 정상 시 command.ack 를 받아야 한다")
        XCTAssertTrue(port.walkStarted, "WalkLabSession.start 가 호출돼야 한다")
    }

    // MARK: - stop preset → 정지 전달

    func testStopPreset_triggersSessionStop() async throws {
        let port = MockWalkSafetyPort(dxlPower: true, walkSessionAvailable: true,
                                      walkActive: true)
        let (server, channel) = try await makeArmedServer(port: port)

        let walk = makeWalkFrame(id: "cmd_stop", preset: "stop")
        await server.handleClientFrame(walk, from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        let acks = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_stop" && $0.type == "command.ack" }
        XCTAssertFalse(acks.isEmpty, "stop preset 도 command.ack 를 받아야 한다")
        XCTAssertTrue(port.walkStopped, "stop preset 이면 session.stop() 이 호출돼야 한다")
    }

    // MARK: - walkSession nil → reject

    func testWalkSessionUnavailable_rejectsCommand() async throws {
        let port = MockWalkSafetyPort(dxlPower: true, walkSessionAvailable: false)
        let (server, channel) = try await makeArmedServer(port: port)

        let walk = makeWalkFrame(id: "cmd_nosession", preset: "slowForward")
        await server.handleClientFrame(walk, from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)

        let rejected = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_nosession" && $0.type == "command.rejected" }
        XCTAssertFalse(rejected.isEmpty, "walkSession nil 시 command.rejected 를 받아야 한다")
    }

    // MARK: - Helpers

    private func makeArmedServer(
        port: MockWalkSafetyPort
    ) async throws -> (MobileRelayServer, InMemoryWalkChannel) {
        let pairing = MobileRelayPairing(initialCode: "walk01")
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { 11.7 })
        let channel = InMemoryWalkChannel()
        await server.handleClientConnected(channel, handshake: helloFrame(code: "walk01"))
        // ARM so commands are accepted.
        let arm = makeFrame(type: "pilot.arm", id: "cmd_arm_setup",
                            payload: ["cradleConfirmed": true, "operator": "Test"])
        await server.handleClientFrame(arm, from: channel)
        try await Task.sleep(nanoseconds: 80_000_000)
        return (server, channel)
    }

    private func makeWalkFrame(id: String, preset: String,
                               xMm: Double = 20.0,
                               yMm: Double = 0.0,
                               aDeg: Double = 0.0,
                               speedScale: Double? = nil) -> Data {
        var payload: [String: Any] = ["preset": preset, "enabled": true,
                                      "xMm": xMm, "yMm": yMm, "aDeg": aDeg,
                                      "periodMs": 700, "footMm": 35.0,
                                      "hipPitchDeg": 13.0]
        if let speedScale {
            payload["speedScale"] = speedScale
        }
        return makeFrame(type: "pilot.walk", id: id,
                         payload: payload)
    }

    private func helloFrame(code: String) -> Data {
        makeFrame(type: "session.hello", id: "cmd_hello",
                  payload: ["app": "ios", "appVersion": "0.1.0",
                            "protocolVersion": 1, "deviceName": "TestPhone",
                            "deviceId": "T001", "pairingCode": code])
    }

    private func makeFrame(type: String, id: String, payload: [String: Any]) -> Data {
        // sentAt 은 현재 시각 — server latency gate (walk: 150ms) 와 clockSkew(>10s)
        // 가드를 통과하기 위해 fixture 가 server clock 근처여야 한다.
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

// MARK: - Mock WalkSafetyPort

/// `RobotSafetyPort` 구현체 — WalkLabSession 연동 검증용.
/// dxlPower / walkSession 유무 / 정상 vs 거절 시나리오를 파라미터로 제어한다.
final class MockWalkSafetyPort: RobotSafetyPort, @unchecked Sendable {

    private let lock = NSLock()
    private var _dxlPower: Bool
    private var _walkSessionAvailable: Bool
    private var _walkActive: Bool
    private var _walkStarted = false
    private var _walkStopped = false
    private var _lastWalkPayload: WalkPayload?

    var walkStarted: Bool { lock.lock(); defer { lock.unlock() }; return _walkStarted }
    var walkStopped: Bool { lock.lock(); defer { lock.unlock() }; return _walkStopped }
    var lastWalkPayload: WalkPayload? { lock.lock(); defer { lock.unlock() }; return _lastWalkPayload }

    init(dxlPower: Bool, walkSessionAvailable: Bool, walkActive: Bool = false) {
        _dxlPower = dxlPower
        _walkSessionAvailable = walkSessionAvailable
        _walkActive = walkActive
    }

    func snapshot() async -> TelemetryStatePayload {
        lock.lock(); defer { lock.unlock() }
        return TelemetryStatePayload(
            mac: .connected, robot: .connected, endpoint: nil,
            armed: true, dxlPower: _dxlPower,
            batteryV: 11.7, maxTempC: 41,
            latencyMs: 10, lastAckAgeMs: nil,
            safety: .ready, uiState: .armedReady)
    }

    func arm(cradleConfirmed: Bool,
             operator: String,
             progress: @Sendable @escaping (String, Double) async -> Void) async throws -> Int {
        guard cradleConfirmed else { throw RelayServerError.rejected("cradleRequired") }
        await progress("armed", 1.0)
        return 10
    }

    func disarm(reason: String) async throws -> Int { return 5 }
    func emergencyStop(reason: String) async throws -> Int { return 5 }
    func runMotion(slot: Int, label: String, confirmRisk: Bool) async throws -> Int { return 10 }

    func sendWalk(payload: WalkPayload) async throws -> (latencyMs: Int, robotAckId: String?) {
        lock.lock()
        let dxlPower = _dxlPower
        let sessionAvailable = _walkSessionAvailable
        let walkActive = _walkActive
        lock.unlock()

        // 안전 whitelist 확인.
        let safelist: Set<WalkPreset> = [.slowForward, .turnLeft, .turnRight, .stop, .freeform]
        guard safelist.contains(payload.preset) else {
            throw RelayServerError.rejected("highRiskNotAllowed")
        }
        guard dxlPower else {
            throw RelayServerError.rejected("dxlPowerOff")
        }
        guard sessionAvailable else {
            throw RelayServerError.rejected("walkSessionUnavailable")
        }
        if payload.preset == .stop {
            if walkActive {
                lock.lock(); _walkStopped = true; lock.unlock()
            }
            return (5, nil)
        }
        lock.lock()
        _walkStarted = true
        _lastWalkPayload = payload
        lock.unlock()
        return (10, "mock-\(payload.preset.rawValue)")
    }

    func sendStop(reason: String) async throws -> Int {
        lock.lock(); _walkStopped = true; lock.unlock()
        return 5
    }
}

// MARK: - InMemoryWalkChannel (dedicated to avoid name clash)

final class InMemoryWalkChannel: RelayClientChannel, @unchecked Sendable {
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
