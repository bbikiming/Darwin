import XCTest
@testable import DarwinForgeUI

// MARK: - V291TelemetryIntegrationTests
//
// Mobile Pilot Relay → Harness TelemetryEvent 기록 검증.
// 각 emit site 가 올바른 kind 로 기록되는지 RecordingHarness 를 통해 단위 검증.

@MainActor
final class V291TelemetryIntegrationTests: XCTestCase {

    // MARK: - 1. TelemetryKind 8 신규 kind rawValue 검증

    func testMobilePilotKindRawValues() {
        XCTAssertEqual(TelemetryKind.mobilePilotPairingSuccess.rawValue,
                       "mobile_pilot.pairing_success")
        XCTAssertEqual(TelemetryKind.mobilePilotPairingRejected.rawValue,
                       "mobile_pilot.pairing_rejected")
        XCTAssertEqual(TelemetryKind.mobilePilotLockoutTriggered.rawValue,
                       "mobile_pilot.lockout_triggered")
        XCTAssertEqual(TelemetryKind.mobilePilotCodeRotated.rawValue,
                       "mobile_pilot.code_rotated")
        XCTAssertEqual(TelemetryKind.mobilePilotCommandAccepted.rawValue,
                       "mobile_pilot.command_accepted")
        XCTAssertEqual(TelemetryKind.mobilePilotCommandRejected.rawValue,
                       "mobile_pilot.command_rejected")
        XCTAssertEqual(TelemetryKind.mobilePilotDisconnected.rawValue,
                       "mobile_pilot.disconnected")
        XCTAssertEqual(TelemetryKind.mobilePilotWatchdogStop.rawValue,
                       "mobile_pilot.watchdog_stop")
    }

    func testMobilePilotKindNamespace() {
        XCTAssertEqual(TelemetryKind.mobilePilotPairingSuccess.namespace, "mobile_pilot")
        XCTAssertEqual(TelemetryKind.mobilePilotCommandAccepted.namespace, "mobile_pilot")
        XCTAssertEqual(TelemetryKind.mobilePilotWatchdogStop.namespace, "mobile_pilot")
    }

    // MARK: - 2. Pairing Success emit

    func testPairingSuccessEmitsTelemetry() async throws {
        let harness = RecordingHarness()
        let pairing = MobileRelayPairing(initialCode: "123456")
        let server = MobileRelayServer(pairing: pairing,
                                       port: InMemorySafetyPort(),
                                       harness: harness,
                                       batteryVoltage: { 11.7 })
        let channel = InMemoryChannelV291()

        await server.handleClientConnected(channel,
                                           handshake: helloFrame(code: "123456"))
        try await Task.sleep(nanoseconds: 50_000_000)

        let ev = harness.events.first { $0.kind == .mobilePilotPairingSuccess }
        XCTAssertNotNil(ev, "mobilePilotPairingSuccess 가 기록되어야 함")
        XCTAssertEqual(ev?.level, .info)
        XCTAssertEqual(ev?.actor, .user)
    }

    // MARK: - 3. Pairing Rejected (mismatch) emit

    func testPairingMismatchEmitsTelemetry() async throws {
        let harness = RecordingHarness()
        let pairing = MobileRelayPairing(initialCode: "999999")
        let server = MobileRelayServer(pairing: pairing,
                                       port: InMemorySafetyPort(),
                                       harness: harness,
                                       batteryVoltage: { 11.7 })
        let channel = InMemoryChannelV291()

        await server.handleClientConnected(channel,
                                           handshake: helloFrame(code: "000000"))
        try await Task.sleep(nanoseconds: 50_000_000)

        let ev = harness.events.first { $0.kind == .mobilePilotPairingRejected }
        XCTAssertNotNil(ev, "mobilePilotPairingRejected 가 기록되어야 함")
        XCTAssertEqual(ev?.level, .warn)
    }

    // MARK: - 4. Lockout emit (3번 실패)

    func testLockoutAfterThreeFailsEmitsTelemetry() async throws {
        let harness = RecordingHarness()
        let pairing = MobileRelayPairing(initialCode: "777777")
        let server = MobileRelayServer(pairing: pairing,
                                       port: InMemorySafetyPort(),
                                       harness: harness,
                                       batteryVoltage: { 11.7 })

        for i in 0..<3 {
            let ch = InMemoryChannelV291()
            await server.handleClientConnected(ch,
                                               handshake: helloFrame(code: "wrong_\(i)"))
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let lockoutEv = harness.events.first { $0.kind == .mobilePilotLockoutTriggered }
        XCTAssertNotNil(lockoutEv, "mobilePilotLockoutTriggered 가 기록되어야 함")
        XCTAssertEqual(lockoutEv?.level, .warn)
    }

    // MARK: - 5. Command Accepted (walk) emit

    func testWalkCommandAcceptedEmitsTelemetry() async throws {
        let harness = RecordingHarness()
        let pairing = MobileRelayPairing(initialCode: "111111")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(pairing: pairing, port: port, harness: harness, batteryVoltage: { 11.7 })
        let channel = InMemoryChannelV291()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "111111"))
        let arm = makeFrame(type: "pilot.arm", id: "cmd_arm",
                            payload: ["cradleConfirmed": true, "operator": "Test"])
        await server.handleClientFrame(arm, from: channel)
        let walk = makeFrame(type: "pilot.walk", id: "cmd_walk",
                             payload: ["preset": "slowForward", "enabled": true,
                                       "xMm": 20.0, "yMm": 0.0, "aDeg": 0.0,
                                       "periodMs": 700, "footMm": 35.0, "hipPitchDeg": 13.0])
        await server.handleClientFrame(walk, from: channel)
        try await Task.sleep(nanoseconds: 100_000_000)

        let commandAccepted = harness.events.filter { $0.kind == .mobilePilotCommandAccepted }
        XCTAssertFalse(commandAccepted.isEmpty,
                       "walk command_accepted 가 기록되어야 함")
    }

    // MARK: - 6. Command Rejected (riskNotConfirmed) emit

    func testMotionRiskNotConfirmedEmitsTelemetry() async throws {
        let harness = RecordingHarness()
        let pairing = MobileRelayPairing(initialCode: "222222")
        let server = MobileRelayServer(pairing: pairing,
                                       port: InMemorySafetyPort(),
                                       harness: harness,
                                       batteryVoltage: { 11.7 })
        let channel = InMemoryChannelV291()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "222222"))
        // label 은 allowlist 에 없음 → riskNotConfirmed 거부
        let motion = makeFrame(type: "pilot.motion", id: "cmd_motion",
                               payload: ["slot": 0,
                                         "label": "dangerousFlip",
                                         "confirmRisk": false])
        await server.handleClientFrame(motion, from: channel)
        try await Task.sleep(nanoseconds: 50_000_000)

        let rejected = harness.events.filter { $0.kind == .mobilePilotCommandRejected }
        XCTAssertFalse(rejected.isEmpty, "riskNotConfirmed → command_rejected 기록 필요")
    }

    // MARK: - 7. Disconnected emit

    func testDisconnectedEmitsTelemetry() async throws {
        let harness = RecordingHarness()
        let pairing = MobileRelayPairing(initialCode: "333333")
        let server = MobileRelayServer(pairing: pairing,
                                       port: InMemorySafetyPort(),
                                       harness: harness,
                                       batteryVoltage: { 11.7 })
        let channel = InMemoryChannelV291()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "333333"))
        await server.handleClientDisconnected(channel, reason: "userClosed")
        try await Task.sleep(nanoseconds: 50_000_000)

        let discEv = harness.events.first { $0.kind == .mobilePilotDisconnected }
        XCTAssertNotNil(discEv, "mobilePilotDisconnected 가 기록되어야 함")
        XCTAssertEqual(discEv?.level, .info)
        XCTAssertEqual(discEv?.actor, .system)
    }

    // MARK: - 8. Watchdog Stop emit

    func testWatchdogStopEmitsTelemetry() async throws {
        let harness = RecordingHarness()
        let pairing = MobileRelayPairing(initialCode: "444444")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(
            configuration: .init(heartbeatIntervalMs: 20, watchdogTimeoutMs: 40),
            pairing: pairing, port: port, harness: harness,
            batteryVoltage: { 11.7 })
        let channel = InMemoryChannelV291()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "444444"))
        // activeCommandId 가 있어야 watchdog 이 fire
        let hb = makeFrame(type: "pilot.heartbeat", id: "cmd_hb",
                           payload: ["uiState": "commandActive",
                                     "activeCommandId": "cmd_walk"])
        await server.handleClientFrame(hb, from: channel)
        try await Task.sleep(nanoseconds: 200_000_000)

        let watchdogEv = harness.events.first { $0.kind == .mobilePilotWatchdogStop }
        XCTAssertNotNil(watchdogEv, "mobilePilotWatchdogStop 이 기록되어야 함")
        XCTAssertEqual(watchdogEv?.level, .warn)
    }

    // MARK: - 9. Code Rotated (manual) emit via MobileRelayController

    func testManualCodeRotationEmitsTelemetry() {
        let harness = RecordingHarness()
        let port = InMemorySafetyPort()
        let controller = MobileRelayController(port: port, harness: harness)

        controller.rotatePairingCode()

        let rotated = harness.events.first { $0.kind == .mobilePilotCodeRotated }
        XCTAssertNotNil(rotated, "rotatePairingCode → mobilePilotCodeRotated 기록 필요")
        XCTAssertEqual(rotated?.level, .info)
        XCTAssertEqual(rotated?.actor, .user)
    }

    // MARK: - 10. Payload schema 검증 (pairing_success deviceName/sessionId)

    func testPairingSuccessPayloadSchema() async throws {
        let harness = CapturingHarnessV291()
        let pairing = MobileRelayPairing(initialCode: "555555")
        let server = MobileRelayServer(pairing: pairing,
                                       port: InMemorySafetyPort(),
                                       harness: harness,
                                       batteryVoltage: { 11.7 })
        let channel = InMemoryChannelV291()

        await server.handleClientConnected(channel,
                                           handshake: helloFrame(code: "555555",
                                                                  deviceName: "TestiPhone"))
        try await Task.sleep(nanoseconds: 50_000_000)

        let ev = harness.captured.first { $0.0 == .mobilePilotPairingSuccess }
        XCTAssertNotNil(ev, "mobilePilotPairingSuccess 이벤트가 있어야 함")
        let data = ev?.1 ?? [:]
        XCTAssertEqual(data["deviceName"]?.value as? String, "TestiPhone")
        XCTAssertNotNil(data["sessionId"]?.value as? String)
    }

    // MARK: - 11. Stop command emits accepted

    func testStopCommandEmitsAccepted() async throws {
        let harness = RecordingHarness()
        let pairing = MobileRelayPairing(initialCode: "666666")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(pairing: pairing, port: port, harness: harness, batteryVoltage: { 11.7 })
        let channel = InMemoryChannelV291()

        await server.handleClientConnected(channel, handshake: helloFrame(code: "666666"))
        let stop = makeFrame(type: "pilot.stop", id: "cmd_stop",
                             payload: ["reason": "user"])
        await server.handleClientFrame(stop, from: channel)
        try await Task.sleep(nanoseconds: 50_000_000)

        let accepted = harness.events.filter { $0.kind == .mobilePilotCommandAccepted }
        XCTAssertFalse(accepted.isEmpty, "stop command → command_accepted 기록 필요")
    }

    // MARK: - Helpers

    private func helloFrame(code: String, deviceName: String = "TestPhone") -> Data {
        makeFrame(type: "session.hello", id: "cmd_hello",
                  payload: ["app": "ios",
                            "appVersion": "0.1.0",
                            "protocolVersion": 1,
                            "deviceName": deviceName,
                            "deviceId": "TEST",
                            "pairingCode": code])
    }

    private func makeFrame(type: String, id: String, payload: [String: Any]) -> Data {
        // CI fix (PR #42, 2026-05-26): sentAt 은 현재 시각 — server 의 latency
        // gate (walk: 150ms) 와 clockSkew(>10s) 가드를 통과시키려면 fixture 가
        // server clock 근처여야 한다.
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

// MARK: - InMemoryChannelV291

final class InMemoryChannelV291: RelayClientChannel, @unchecked Sendable {
    let clientId: String = UUID().uuidString
    private let lock = NSLock()
    private var _frames: [Data] = []
    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return _frames }

    func deliver(_ frame: Data) async throws {
        lock.lock(); _frames.append(frame); lock.unlock()
    }

    func disconnect(reason: String) async {}
}

// MARK: - CapturingHarnessV291
//
// payload 까지 캡처하는 확장 harness — payload schema 검증용.

@MainActor
final class CapturingHarnessV291: HarnessFacade {
    var captured: [(TelemetryKind, [String: AnyCodable])] = []

    func record(_ kind: TelemetryKind,
                level: TelemetryLevel,
                actor: TelemetryActor,
                data: [String: AnyCodable],
                context: TelemetryContext?) {
        captured.append((kind, data))
    }

    func bookmark(_ note: String) {}
    func flush() async {}
    func startHeartbeat(intervalSeconds: TimeInterval) {}
    func stopHeartbeat() {}
    func registerContextProvider(_ provider: @escaping @MainActor () -> TelemetryContext?) {}
    func start() {}
    func stop(reason: String) {}
}
