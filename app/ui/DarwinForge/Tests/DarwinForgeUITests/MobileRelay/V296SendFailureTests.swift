import XCTest
@testable import DarwinForgeUI

// V296-1: Send failure counter + closeSession trigger tests.
//
// Covers the silent-swallow bug fix in MobileRelayServer.send(_:to:):
//   - Single failure → session alive, telemetry emitted
//   - Three consecutive failures → closeSession("deliveryFailed"), session=nil
//   - Success between failures resets counter (no closeSession on non-consecutive)
//   - send() after closeSession is a no-op (session=nil guard)

@MainActor
final class V296SendFailureTests: XCTestCase {

    // MARK: - 1. Single failure: session still active, telemetry recorded

    func testSingleSendFailureKeepsSession() async throws {
        let harness = V296SpyHarness()
        let pairing = MobileRelayPairing(initialCode: "296001")
        // Toggle channel: starts succeeding, caller flips shouldFail once to inject 1 failure.
        let channel = V296ToggleChannel()
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort(),
                                       harness: harness)

        // Establish session (all setup sends succeed).
        await server.handleClientConnected(channel, handshake: helloFrame(code: "296001"))
        try await Task.sleep(nanoseconds: 30_000_000)
        let hasSession1 = await server.hasActiveSession()
        XCTAssertTrue(hasSession1, "precondition: session must be active after welcome")

        // Arm channel to fail the next deliver → 1 failure.
        channel.failNext = true
        let failFrame = makeFrame(type: "unknown.fail", id: "cmd_fail1", payload: [:])
        await server.handleClientFrame(failFrame, from: channel)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Session must still be active (1 failure < threshold of 3).
        let hasSessionAfter = await server.hasActiveSession()
        XCTAssertTrue(hasSessionAfter,
                      "Session must stay active after a single send failure")

        // Telemetry must record mobilePilotSendFailed.
        let failedEvents = harness.events.filter { $0 == "mobile_pilot.send_failed" }
        XCTAssertFalse(failedEvents.isEmpty,
                       "mobilePilotSendFailed telemetry must be emitted on first failure")
    }

    // MARK: - 2. Three consecutive failures → closeSession

    func testThreeConsecutiveFailuresClosesSession() async throws {
        let harness = V296SpyHarness()
        let pairing = MobileRelayPairing(initialCode: "296003")
        // acceptHello sends 3 frames (welcome + emitLog + broadcastTelemetry) — succeed all.
        // Delivers #4, #5, #6 (3 unknown frames) all fail → counter reaches 3 → closeSession.
        let channel = V296DelayedFailingChannel(succeedFirst: 3)
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort(),
                                       harness: harness)

        await server.handleClientConnected(channel, handshake: helloFrame(code: "296003"))
        try await Task.sleep(nanoseconds: 30_000_000)
        let hasSession = await server.hasActiveSession()
        XCTAssertTrue(hasSession, "precondition: session must be active")

        // 3 unknown frames → 3 consecutive failures → closeSession.
        for i in 0..<3 {
            let frame = makeFrame(type: "unknown.cmd.\(i)", id: "cmd_v296_\(i)", payload: [:])
            await server.handleClientFrame(frame, from: channel)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let hasSessionAfter = await server.hasActiveSession()
        XCTAssertFalse(hasSessionAfter,
                       "Session must be closed after 3 consecutive send failures")
    }

    // MARK: - 3. Success resets counter — non-consecutive failures don't close session

    func testSuccessBetweenFailuresResetsCounter() async throws {
        let harness = V296SpyHarness()
        let pairing = MobileRelayPairing(initialCode: "296004")
        let channel = V296ToggleChannel()
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort(),
                                       harness: harness)

        await server.handleClientConnected(channel, handshake: helloFrame(code: "296004"))
        try await Task.sleep(nanoseconds: 30_000_000)
        let hasSession = await server.hasActiveSession()
        XCTAssertTrue(hasSession, "precondition: session established")

        // Fail → counter=1. Then succeed → counter=0 (reset). Then fail → counter=1. Never 3.
        channel.failNext = true
        await server.handleClientFrame(makeFrame(type: "unknown.a", id: "ka", payload: [:]),
                                       from: channel)
        try await Task.sleep(nanoseconds: 10_000_000)

        // success — resets counter
        await server.handleClientFrame(makeFrame(type: "unknown.b", id: "kb", payload: [:]),
                                       from: channel)
        try await Task.sleep(nanoseconds: 10_000_000)

        // fail again — counter=1 (not 2 because reset happened)
        channel.failNext = true
        await server.handleClientFrame(makeFrame(type: "unknown.c", id: "kc", payload: [:]),
                                       from: channel)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Session must survive — consecutive counter never reached 3.
        let hasSessionAfter = await server.hasActiveSession()
        XCTAssertTrue(hasSessionAfter,
                      "Session must survive when failures are non-consecutive (counter resets on success)")
    }

    // MARK: - 4. send() after closeSession is safe (no-op, no crash)

    func testSendAfterCloseSessionIsNoop() async throws {
        let harness = V296SpyHarness()
        let pairing = MobileRelayPairing(initialCode: "296005")
        let channel = V296InMemoryChannel()
        let server = MobileRelayServer(pairing: pairing, port: InMemorySafetyPort(),
                                       harness: harness)

        await server.handleClientConnected(channel, handshake: helloFrame(code: "296005"))
        try await Task.sleep(nanoseconds: 30_000_000)
        let hasSession = await server.hasActiveSession()
        XCTAssertTrue(hasSession, "precondition: session must be active")

        // Explicitly close session.
        await server.closeSession(reason: "test")
        let hasSessionAfterClose = await server.hasActiveSession()
        XCTAssertFalse(hasSessionAfterClose, "session must be nil after explicit close")

        // Subsequent frames must not crash.
        let frame = makeFrame(type: "unknown.after.close", id: "cmd_safe", payload: [:])
        await server.handleClientFrame(frame, from: channel)
        try await Task.sleep(nanoseconds: 30_000_000)

        let hasSessionFinal = await server.hasActiveSession()
        XCTAssertFalse(hasSessionFinal,
                       "session must remain nil after explicit close — send must be no-op")
    }

    // MARK: - Helpers

    private func helloFrame(code: String) -> Data {
        makeFrame(type: "session.hello", id: "cmd_hello",
                  payload: ["app": "ios",
                            "appVersion": "0.1.0",
                            "protocolVersion": 1,
                            "deviceName": "TestiPhone",
                            "deviceId": "V296_TEST",
                            "pairingCode": code])
    }

    private func makeFrame(type: String, id: String, payload: [String: Any]) -> Data {
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

// MARK: - Test Doubles

/// Simple in-memory channel: every deliver succeeds.
final class V296InMemoryChannel: RelayClientChannel, @unchecked Sendable {
    let clientId: String = UUID().uuidString
    private let lock = NSLock()
    private var _frames: [Data] = []
    var frames: [Data] { lock.withLock { _frames } }

    func deliver(_ frame: Data) async throws {
        lock.withLock { _frames.append(frame) }
    }
    func disconnect(reason: String) async {}
}

/// Channel that succeeds for the first `succeedFirst` delivers, then fails every call after.
final class V296DelayedFailingChannel: RelayClientChannel, @unchecked Sendable {
    let clientId: String = UUID().uuidString
    private let lock = NSLock()
    private var callCount = 0
    private let succeedFirst: Int

    init(succeedFirst: Int) { self.succeedFirst = succeedFirst }

    func deliver(_ frame: Data) async throws {
        let shouldFail = lock.withLock { () -> Bool in
            callCount += 1
            return callCount > succeedFirst
        }
        if shouldFail { throw URLError(.networkConnectionLost) }
    }
    func disconnect(reason: String) async {}
}

/// Channel controlled by a boolean flag. Succeeds by default; caller sets `failNext = true`
/// to fail the very next deliver call (then auto-resets to succeed again).
final class V296ToggleChannel: RelayClientChannel, @unchecked Sendable {
    let clientId: String = UUID().uuidString
    private let lock = NSLock()
    /// Set to true before a frame to make the next deliver throw. Auto-resets after the call.
    var failNext: Bool = false

    func deliver(_ frame: Data) async throws {
        let shouldFail = lock.withLock { () -> Bool in
            let v = failNext; failNext = false; return v
        }
        if shouldFail { throw URLError(.networkConnectionLost) }
    }
    func disconnect(reason: String) async {}
}

/// Spy harness that records TelemetryKind rawValues. Implements HarnessFacade.
@MainActor
final class V296SpyHarness: HarnessFacade {
    private(set) var events: [String] = []

    // HarnessRecording
    func record(_ kind: TelemetryKind, level: TelemetryLevel,
                actor: TelemetryActor, data: [String: AnyCodable],
                context: TelemetryContext?) {
        events.append(kind.rawValue)
    }
    func bookmark(_ note: String) {}
    func flush() async {}

    // HarnessHeartbeat
    func startHeartbeat(intervalSeconds: TimeInterval) {}
    func stopHeartbeat() {}

    // HarnessContext
    func registerContextProvider(_ provider: @escaping @MainActor () -> TelemetryContext?) {}

    // HarnessLifecycle
    func start() {}
    func stop(reason: String) {}
}
