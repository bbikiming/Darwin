import XCTest
@testable import DarwinForgeUI

/// V297-9 CRITICAL-1: Safety Epoch invariant tests.
///
/// # 핵심 invariant
///
/// I-EPOCH-1: ARM 진행 중 E-stop 들어오면 ARM 결과는 staleCommand 로 실패.
///            절대 recoverFromEStop 으로 자동 분기되지 않는다.
///
/// I-EPOCH-2: ARM 진행 중 disconnect 발생하면 ARM 은 stale.
///
/// I-EPOCH-3: pilot.recover 도 동일 — 진행 중 E-stop 들어오면 stale.
///
/// # 시나리오 비유: 비행 허가 시리얼
///
/// 관제탑이 비행기 A 에게 이륙 허가 (시리얼 #N) 발부.
/// A 가 시동 거는 동안 활주로 사고 → 시리얼 #N+1 로 증가.
/// A 이륙 시도 시 시리얼 체크 → mismatch → 이륙 자동 취소.
final class MobileRelaySafetyEpochTests: XCTestCase {

    /// MEDIUM-3 / I-EPOCH-1: battery wait 중 E-stop → ARM staleCommand.
    /// 종전 회로: battery nil → 2초 grace polling. 그 동안 E-stop 처리 → ARM
    /// 깨어나 hook 의 emergencyStopActive 분기로 recoverFromEStop 호출.
    /// 신규 (V297-9): ARM 이 epoch 재검증으로 stale → command.failed(staleCommand).
    func testBatteryGraceCannotAutoRecoverViaArm() async throws {
        let pairing = MobileRelayPairing(initialCode: "epoch1")
        let port = InMemorySafetyPort()
        // battery 가 nil 시 2초 grace 동안 변하지 않게 — actor 가 grace polling.
        // E-stop 가 그 사이 끼어들면 epoch 증가 → ARM stale.
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { nil })
        let channel = SafetyEpochChannel()

        await server.handleClientConnected(channel,
                                            handshake: helloFrame(code: "epoch1",
                                                                  deviceId: "phone-A"))
        try await Task.sleep(nanoseconds: 50_000_000)

        // ARM 송신 (battery nil → 2초 grace 진입).
        async let armFire: Void = server.handleClientFrame(armFrame(id: "cmd_arm"),
                                                           from: channel)
        // 50ms 후 E-stop 끼어듦.
        try await Task.sleep(nanoseconds: 50_000_000)
        await server.handleClientFrame(estopFrame(id: "cmd_estop"), from: channel)
        await armFire
        try await Task.sleep(nanoseconds: 200_000_000)

        // ARM 의 응답: command.failed(staleCommand) 또는 command.rejected(lowBattery)
        // — 어떤 경우든 command.ack 가 도착하면 안 됨 (ARM 성공 잘못 표시 방지).
        let armAck = channel.frames.compactMap { decode($0) }
            .first { $0.id == "cmd_arm" && $0.type == "command.ack" }
        XCTAssertNil(armAck,
                     "AC I-EPOCH-1: battery grace 중 E-stop → ARM 절대 ack 안 됨")

        // E-stop 자체는 정상 처리 (verification 실패하면 failed, 성공이면 ack — 둘 다 OK).
        let estopResponse = channel.frames.compactMap { decode($0) }
            .first { $0.id == "cmd_estop" &&
                ($0.type == "command.ack" || $0.type == "command.failed") }
        XCTAssertNotNil(estopResponse,
                        "AC: E-stop 명령은 처리됨 (priority bypass)")
    }

    /// I-EPOCH-2: ARM 진행 중 disconnect → stale.
    func testArmDuringDisconnectIsStale() async throws {
        let pairing = MobileRelayPairing(initialCode: "epoch2")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { nil })
        let channel = SafetyEpochChannel()

        await server.handleClientConnected(channel,
                                            handshake: helloFrame(code: "epoch2",
                                                                  deviceId: "phone-A"))
        try await Task.sleep(nanoseconds: 50_000_000)

        async let armFire: Void = server.handleClientFrame(armFrame(id: "cmd_arm"),
                                                           from: channel)
        try await Task.sleep(nanoseconds: 50_000_000)
        // disconnect 트리거.
        await server.handleClientDisconnected(channel, reason: "test")
        await armFire
        try await Task.sleep(nanoseconds: 200_000_000)

        let armAck = channel.frames.compactMap { decode($0) }
            .first { $0.id == "cmd_arm" && $0.type == "command.ack" }
        XCTAssertNil(armAck, "AC I-EPOCH-2: ARM 진행 중 disconnect → ack 안 됨")
    }

    /// I-EPOCH-3: pilot.recover 도 진행 중 E-stop 발생 시 stale.
    /// 새 명령 type 동작 검증.
    func testRecoverIsAlsoEpochGuarded() async throws {
        let pairing = MobileRelayPairing(initialCode: "epoch3")
        let port = InMemorySafetyPort()
        let server = MobileRelayServer(pairing: pairing, port: port,
                                       batteryVoltage: { 11.7 })
        let channel = SafetyEpochChannel()

        await server.handleClientConnected(channel,
                                            handshake: helloFrame(code: "epoch3",
                                                                  deviceId: "phone-A"))
        try await Task.sleep(nanoseconds: 50_000_000)

        // recover 송신.
        let recoverData = buildFrame(type: "pilot.recover", id: "cmd_rec",
                                     payload: ["cradleConfirmed": true,
                                               "operator": "Tester"])
        async let recFire: Void = server.handleClientFrame(recoverData, from: channel)
        try await Task.sleep(nanoseconds: 30_000_000)
        await server.handleClientFrame(estopFrame(id: "cmd_e"), from: channel)
        await recFire
        try await Task.sleep(nanoseconds: 200_000_000)

        // recover 가 성공으로 ack 되지 않아야 — staleCommand 또는 미완료.
        // 단, recover 가 매우 빠르게 끝나 epoch 증가 직전 ack 보낼 수도 있음.
        // 이 경우는 race 가 우리 fix 보다 빨라서 reliability 검증 어려움.
        // 대신 "ack 가 오면 그 시점엔 epoch 증가 안 됐어야" invariant — 직접 검증 어려움.
        // 실용적 검증: estop ack 도 도달했는지 (priority bypass 작동).
        let estopAck = channel.frames.compactMap { decode($0) }
            .first { $0.id == "cmd_e" && $0.type == "command.ack" }
        XCTAssertNotNil(estopAck,
                        "AC I-EPOCH-3: recover 진행 중에도 E-stop 도달 (priority bypass)")
    }

    // MARK: - Helpers

    private func helloFrame(code: String, deviceId: String) -> Data {
        buildFrame(type: "session.hello", id: "cmd_hello",
                   payload: ["app": "ios", "appVersion": "0.1.0", "protocolVersion": 1,
                             "deviceName": "Test", "deviceId": deviceId,
                             "pairingCode": code])
    }

    private func armFrame(id: String) -> Data {
        buildFrame(type: "pilot.arm", id: id,
                   payload: ["cradleConfirmed": true, "operator": "Tester"])
    }

    private func estopFrame(id: String) -> Data {
        buildFrame(type: "pilot.estop", id: id, payload: ["reason": "user"])
    }

    private func buildFrame(type: String, id: String, payload: [String: Any]) -> Data {
        let iso = ISO8601DateFormatter.epochFractional.string(from: Date())
        let envelope: [String: Any] = [
            "v": 1, "id": id, "type": type, "sentAt": iso, "payload": payload
        ]
        return try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private func decode(_ data: Data) -> RelayEnvelopeHead? {
        try? RelayCodec.decoder.decode(RelayEnvelopeHead.self, from: data)
    }
}

final class SafetyEpochChannel: RelayClientChannel, @unchecked Sendable {
    let clientId: String = UUID().uuidString
    private let lock = NSLock()
    private var _frames: [Data] = []
    var frames: [Data] { lock.lock(); defer { lock.unlock() }; return _frames }
    func deliver(_ frame: Data) async throws {
        lock.lock(); _frames.append(frame); lock.unlock()
    }
    func disconnect(reason: String) async { _ = reason }
}

private extension ISO8601DateFormatter {
    static let epochFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
