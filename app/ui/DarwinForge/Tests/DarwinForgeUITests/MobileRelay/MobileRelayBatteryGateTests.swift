import XCTest
@testable import DarwinForgeUI

/// V291-10 — handleArm 배터리 재검증 (defense-in-depth, V288-4 일관).
///
/// # 비유: 연료 게이지 0 — 시동 거부
/// iOS preflight 가 1차 방어선이지만, stale voltage 또는 spoofed 패킷에 대비해
/// Mac 측에서 최신 전압을 재검증한다. 연료가 없으면 엔진 자체를 걸지 않는다.
///
/// # 기술
/// `MobileRelayServer.handleArm` 은 `batteryVoltage` 클로저로 Mac-side 전압을 조회.
/// - voltage >= 10.5V → 정상 ARM 진행
/// - voltage < 10.5V  → commandRejected reason "lowBattery"
/// - voltage == nil   → commandRejected reason "lowBattery" (보수 정책)
final class MobileRelayBatteryGateTests: XCTestCase {

    // MARK: - Helpers

    private func makeServer(voltage: Double?) -> (MobileRelayServer, InMemoryBatteryChannel) {
        let pairing = MobileRelayPairing(initialCode: "bat01")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(
            pairing: pairing,
            port: port,
            batteryVoltage: { voltage }
        )
        let channel = InMemoryBatteryChannel()
        return (server, channel)
    }

    private func connectAndSendArm(
        server: MobileRelayServer,
        channel: InMemoryBatteryChannel
    ) async throws {
        let hello = makeFrame(
            type: "session.hello",
            id: "cmd_hello",
            payload: ["app": "ios", "appVersion": "0.1.0",
                      "protocolVersion": 1, "deviceName": "BatteryTestPhone",
                      "deviceId": "BAT01", "pairingCode": "bat01"]
        )
        await server.handleClientConnected(channel, handshake: hello)
        let arm = makeFrame(
            type: "pilot.arm",
            id: "cmd_arm_bat",
            payload: ["cradleConfirmed": true, "operator": "BatteryTester"]
        )
        await server.handleClientFrame(arm, from: channel)
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - Test cases

    /// 11.0V — 임계 초과 → ARM 통과 (command.ack 수신)
    func testArm_aboveThreshold_passes() async throws {
        let (server, channel) = makeServer(voltage: 11.0)
        try await connectAndSendArm(server: server, channel: channel)

        let acks = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_arm_bat" && $0.type == "command.ack" }
        XCTAssertFalse(acks.isEmpty, "11.0V 이상에서 ARM은 command.ack 를 받아야 한다")
    }

    /// 10.5V — 경계값 통과 (threshold 포함)
    func testArm_atThreshold_passes() async throws {
        let (server, channel) = makeServer(voltage: 10.5)
        try await connectAndSendArm(server: server, channel: channel)

        let acks = channel.frames.compactMap { decode($0) }
            .filter { $0.id == "cmd_arm_bat" && $0.type == "command.ack" }
        XCTAssertFalse(acks.isEmpty, "10.5V (경계) 에서 ARM은 command.ack 를 받아야 한다")
    }

    /// 10.4V — 임계 미만 → commandRejected reason "lowBattery"
    func testArm_belowThreshold_rejected() async throws {
        let (server, channel) = makeServer(voltage: 10.4)
        try await connectAndSendArm(server: server, channel: channel)

        let rejected = channel.frames.compactMap { decodeRejected($0) }
            .filter { $0.id == "cmd_arm_bat" }
        XCTAssertFalse(rejected.isEmpty, "10.4V 에서 ARM은 command.rejected 를 받아야 한다")

        let reasons = rejected.compactMap { $0.reason }
        XCTAssertTrue(reasons.contains("lowBattery"),
                      "reason 은 'lowBattery' 여야 한다. 실제: \(reasons)")
    }

    /// nil voltage — 측정 불가 → 보수 정책: commandRejected reason "lowBattery"
    func testArm_nilVoltage_rejected() async throws {
        let (server, channel) = makeServer(voltage: nil)
        try await connectAndSendArm(server: server, channel: channel)

        let rejected = channel.frames.compactMap { decodeRejected($0) }
            .filter { $0.id == "cmd_arm_bat" }
        XCTAssertFalse(rejected.isEmpty, "nil voltage 에서 ARM은 command.rejected 를 받아야 한다")

        let reasons = rejected.compactMap { $0.reason }
        XCTAssertTrue(reasons.contains("lowBattery"),
                      "reason 은 'lowBattery' 여야 한다. 실제: \(reasons)")
    }

    /// 10.4V reject 시 iPhone 이 받는 message 에 voltage 와 threshold 포함 확인
    func testArm_rejectMessage_containsVoltageAndThreshold() async throws {
        let (server, channel) = makeServer(voltage: 10.4)
        try await connectAndSendArm(server: server, channel: channel)

        let rejected = channel.frames.compactMap { decodeRejectedFull($0) }
            .filter { $0.id == "cmd_arm_bat" }
        XCTAssertFalse(rejected.isEmpty)

        let message = rejected.first?.message ?? ""
        XCTAssertTrue(message.contains("10.4"), "메시지에 전압 10.4 포함: \(message)")
        XCTAssertTrue(message.contains("10.5"), "메시지에 임계 10.5 포함: \(message)")
    }

    // MARK: - Private decode helpers

    private struct Head: Decodable {
        let id: String
        let type: String
    }

    private struct RejHead: Decodable {
        let id: String
        let type: String
        let reason: String?
    }

    private struct RejFull: Decodable {
        let id: String
        let type: String
        let message: String?
    }

    private func decode(_ data: Data) -> Head? {
        // Decode envelope head and pull reason from payload if type is command.rejected
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let type_ = obj["type"] as? String else { return nil }
        return Head(id: id, type: type_)
    }

    private func decodeRejected(_ data: Data) -> RejHead? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let type_ = obj["type"] as? String,
              type_ == "command.rejected",
              let payload = obj["payload"] as? [String: Any] else { return nil }
        let reason = payload["reason"] as? String
        return RejHead(id: id, type: type_, reason: reason)
    }

    private func decodeRejectedFull(_ data: Data) -> RejFull? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let type_ = obj["type"] as? String,
              type_ == "command.rejected",
              let payload = obj["payload"] as? [String: Any] else { return nil }
        let message = payload["message"] as? String
        return RejFull(id: id, type: type_, message: message)
    }

    private func makeFrame(type: String, id: String, payload: [String: Any]) -> Data {
        let envelope: [String: Any] = [
            "v": 1, "id": id, "type": type,
            "sentAt": "2026-05-25T12:00:00.000Z",
            "payload": payload
        ]
        return try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }
}

// MARK: - In-memory channel for battery gate tests

final class InMemoryBatteryChannel: RelayClientChannel, @unchecked Sendable {
    let clientId: String = UUID().uuidString
    private let lock = NSLock()
    private var _frames: [Data] = []
    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return _frames }

    func deliver(_ frame: Data) async throws {
        lock.lock(); _frames.append(frame); lock.unlock()
    }

    func disconnect(reason: String) async { _ = reason }
}
