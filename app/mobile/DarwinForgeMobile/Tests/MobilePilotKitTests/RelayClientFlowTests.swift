import XCTest
@testable import MobilePilotKit

final class RelayClientFlowTests: XCTestCase {

    func testMockRelayConnectsAndAcksArm() async throws {
        let mock = MockRelayClient(ackLatencyMs: 10)
        try await mock.connect(.init(
            endpoint: .init(host: "mock", port: 0, pairingCode: "000000"),
            hello: .init(appVersion: "0.1", deviceName: "Test", deviceId: "id",
                         pairingCode: "000000")))
        let builder = CommandBuilder()
        let env = builder.arm(.init(cradleConfirmed: true, operator: "Test"))
        let receipt = try await mock.send(env)
        guard case .acked(let ms) = receipt.outcome else {
            XCTFail("expected acked, got \(receipt.outcome)")
            return
        }
        XCTAssertEqual(ms, 10)
    }

    func testMockRelayRejection() async throws {
        let mock = MockRelayClient(ackLatencyMs: 10)
        mock.setSimulateRejectAll(true, reason: .notArmed)
        try await mock.connect(.init(
            endpoint: .init(host: "mock", port: 0, pairingCode: "000000"),
            hello: .init(appVersion: "0.1", deviceName: "Test", deviceId: "id",
                         pairingCode: "000000")))
        let env = CommandBuilder().walk(.slowForward)
        let receipt = try await mock.send(env)
        guard case .rejected(let reason, _) = receipt.outcome else {
            XCTFail("expected rejected, got \(receipt.outcome)")
            return
        }
        XCTAssertEqual(reason, .notArmed)
    }

    func testScriptedRelayWatchdogStopArrives() async throws {
        let scripted = ScriptedRelayClient(script: [
            .telemetry(MockTelemetrySeed.armed),
            .wait(milliseconds: 10),
            .watchdogStop(.heartbeatTimeout)
        ])
        try await scripted.connect(.init(
            endpoint: .init(host: "scripted", port: 0, pairingCode: "000000"),
            hello: .init(appVersion: "0.1", deviceName: "Test", deviceId: "id",
                         pairingCode: "000000")))
        var seenWatchdog = false
        var seenTelemetry = false
        let task = Task {
            for await message in scripted.eventStream {
                switch message {
                case .watchdogStop: seenWatchdog = true
                case .telemetryState: seenTelemetry = true
                default: break
                }
                if seenWatchdog && seenTelemetry { break }
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        XCTAssertTrue(seenTelemetry)
        XCTAssertTrue(seenWatchdog)
    }

    func testPairingCodeValidation() {
        XCTAssertTrue(PairingCode.validate("123456"))
        XCTAssertFalse(PairingCode.validate("12345"))
        XCTAssertFalse(PairingCode.validate("12345a"))
    }

    func testQRPairingDecode() throws {
        let json = """
        {"type":"darwinforge.mobileRelay","host":"10.0.0.4","port":17370,"pairingCode":"482913","service":"_darwinforge._tcp"}
        """
        let payload = try QRPairingDecoder.decode(json)
        XCTAssertEqual(payload.host, "10.0.0.4")
        XCTAssertEqual(payload.port, 17370)
        XCTAssertEqual(payload.pairingCode, "482913")
    }
}
