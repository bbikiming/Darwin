import Foundation

/// In-memory mock relay used for unit/UI tests and Review Mode.
///
/// Mock client never sends real hardware commands and reports every command
/// with `command.ack` (with the configured latency). E-stop is acknowledged
/// immediately. The accompanying telemetry generator emits the canned states
/// that the iOS UI needs to render every screen variant.
public final class MockRelayClient: MobileRelayClient, @unchecked Sendable {

    private let transportContinuation: AsyncStream<TransportState>.Continuation
    public let transportStream: AsyncStream<TransportState>

    private let eventContinuation: AsyncStream<InboundMessage>.Continuation
    public let eventStream: AsyncStream<InboundMessage>

    private let lock = NSLock()
    private var connected = false
    private var ackLatencyMs: Int
    private var simulateAckMissing = false
    private var simulateRejectAll = false
    private var rejectReason: RejectionReason = .simulated
    private var sessionId: String = "ses_MOCK01"
    private var eventIdCounter: UInt64 = 0
    private let clock: PilotClock

    public init(ackLatencyMs: Int = 40, clock: PilotClock = LiveClock()) {
        self.ackLatencyMs = ackLatencyMs
        self.clock = clock
        var tCont: AsyncStream<TransportState>.Continuation!
        self.transportStream = AsyncStream { tCont = $0 }
        self.transportContinuation = tCont
        var eCont: AsyncStream<InboundMessage>.Continuation!
        self.eventStream = AsyncStream { eCont = $0 }
        self.eventContinuation = eCont
        transportContinuation.yield(.idle)
    }

    // MARK: - Test knobs

    public func setAckLatency(ms: Int) {
        lock.lock(); ackLatencyMs = ms; lock.unlock()
    }

    public func setSimulateAckMissing(_ flag: Bool) {
        lock.lock(); simulateAckMissing = flag; lock.unlock()
    }

    public func setSimulateRejectAll(_ flag: Bool, reason: RejectionReason = .simulated) {
        lock.lock(); simulateRejectAll = flag; rejectReason = reason; lock.unlock()
    }

    public func injectTelemetry(_ payload: TelemetryStatePayload) {
        let env = RelayEnvelope(id: nextEventId(),
                                type: EventType.telemetryState.rawValue,
                                sentAt: clock.now(),
                                payload: payload)
        eventContinuation.yield(.telemetryState(env))
    }

    public func injectWatchdogStop(_ reason: WatchdogStopReason) {
        let env = RelayEnvelope(id: nextEventId(),
                                type: EventType.watchdogStop.rawValue,
                                sentAt: clock.now(),
                                payload: WatchdogStopPayload(reason: reason, lastHeartbeatAgeMs: 600))
        eventContinuation.yield(.watchdogStop(env))
    }

    public func injectTransportClose(reason: String = "mock") {
        transportContinuation.yield(.disconnected(reason: reason))
        lock.lock(); connected = false; lock.unlock()
    }

    public func injectLog(message: String, level: LogLevel = .info,
                          category: LogCategory = .system,
                          commandId: String? = nil) {
        let env = RelayEnvelope(id: nextEventId(),
                                type: EventType.logEvent.rawValue,
                                sentAt: clock.now(),
                                payload: LogEventPayload(level: level,
                                                         category: category,
                                                         message: message,
                                                         commandId: commandId))
        eventContinuation.yield(.logEvent(env))
    }

    // MARK: - MobileRelayClient

    public func connect(_ request: RelayConnectRequest) async throws {
        lock.lock()
        if connected { lock.unlock(); throw RelayClientError.alreadyConnected }
        connected = true
        lock.unlock()
        transportContinuation.yield(.connecting)
        await clock.sleep(milliseconds: 20)
        transportContinuation.yield(.handshaking)
        let welcome = WelcomePayload(
            macName: "Mock Mac",
            macVersion: "0.0.0-mock",
            relayProtocolVersion: MobileRelayProtocol.version,
            sessionId: sessionId,
            heartbeatIntervalMs: MobileRelayProtocol.heartbeatIntervalMs,
            watchdogTimeoutMs: MobileRelayProtocol.watchdogTimeoutMs)
        let env = RelayEnvelope(id: nextEventId(),
                                type: EventType.sessionWelcome.rawValue,
                                sentAt: clock.now(),
                                payload: welcome)
        eventContinuation.yield(.sessionWelcome(env))
        transportContinuation.yield(.connected(sessionId: sessionId))

        // Seed with a sim telemetry frame so the UI exits notPaired immediately.
        injectTelemetry(TelemetryStatePayload(
            mac: .connected, robot: .sim, endpoint: "mock://review",
            armed: false, dxlPower: false,
            batteryV: 11.7, maxTempC: 38,
            latencyMs: ackLatencyMs, lastAckAgeMs: nil,
            safety: .ready, uiState: .macConnectedNoRobot))
    }

    public func send<P: Codable & Sendable>(_ envelope: RelayEnvelope<P>) async throws -> CommandReceipt {
        try ensureConnected()
        try await sendFireAndForget(envelope)

        if shouldReject() {
            let payload = RejectedPayload(reason: rejectReason,
                                          message: "Mock relay rejected: \(rejectReason.rawValue)")
            let env = RelayEnvelope(id: envelope.id,
                                    type: ResponseType.commandRejected.rawValue,
                                    sentAt: clock.now(),
                                    payload: payload)
            eventContinuation.yield(.commandRejected(env))
            return CommandReceipt(commandId: envelope.id,
                                  outcome: .rejected(reason: payload.reason, message: payload.message))
        }

        if simulateAckMissing && envelope.type != CommandType.pilotEstop.rawValue {
            try await clock.sleep(milliseconds: 600)
            let env = RelayEnvelope(id: envelope.id,
                                    type: ResponseType.commandFailed.rawValue,
                                    sentAt: clock.now(),
                                    payload: FailedPayload(reason: .noAck,
                                                           message: "Mock ACK missing",
                                                           lastErrorAtMs: 600))
            eventContinuation.yield(.commandFailed(env))
            return CommandReceipt(commandId: envelope.id,
                                  outcome: .failed(reason: .noAck, message: "Mock ACK missing"))
        }

        await clock.sleep(milliseconds: ackLatencyMs)
        let env = RelayEnvelope(id: envelope.id,
                                type: ResponseType.commandAck.rawValue,
                                sentAt: clock.now(),
                                payload: AckPayload(latencyMs: ackLatencyMs, robotAckId: nil))
        eventContinuation.yield(.commandAck(env))
        return CommandReceipt(commandId: envelope.id,
                              outcome: .acked(latencyMs: ackLatencyMs))
    }

    public func sendFireAndForget<P: Codable & Sendable>(_ envelope: RelayEnvelope<P>) async throws {
        try ensureConnected()
        // No-op for mock; we just acknowledge.
        _ = envelope
    }

    public func close(reason: String) async {
        lock.lock(); connected = false; lock.unlock()
        transportContinuation.yield(.disconnected(reason: reason))
    }

    // MARK: - helpers

    private func ensureConnected() throws {
        lock.lock(); defer { lock.unlock() }
        if !connected { throw RelayClientError.notConnected }
    }

    private func shouldReject() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return simulateRejectAll
    }

    private func nextEventId() -> String {
        lock.lock(); defer { lock.unlock() }
        eventIdCounter &+= 1
        return String(format: "evt_%06llu", eventIdCounter)
    }

    private func clockNow() -> Date { clock.now() }
}

// Convenience telemetry seeds used by tests and Review Mode.
public enum MockTelemetrySeed {
    public static let macOnly = TelemetryStatePayload(
        mac: .connected, robot: .disconnected, endpoint: nil,
        armed: false, dxlPower: false,
        batteryV: nil, maxTempC: nil,
        latencyMs: 28, lastAckAgeMs: nil,
        safety: .ready, uiState: .macConnectedNoRobot)

    public static let robotConnectedLocked = TelemetryStatePayload(
        mac: .connected, robot: .connected, endpoint: "tcp://192.168.123.1:5530",
        armed: false, dxlPower: false,
        batteryV: 11.8, maxTempC: 41,
        latencyMs: 34, lastAckAgeMs: 88,
        safety: .ready, uiState: .robotConnectedLocked)

    public static let armed = TelemetryStatePayload(
        mac: .connected, robot: .connected, endpoint: "tcp://192.168.123.1:5530",
        armed: true, dxlPower: true,
        batteryV: 11.7, maxTempC: 43,
        latencyMs: 32, lastAckAgeMs: 90,
        safety: .ready, uiState: .armedReady)

    public static let highLatency = TelemetryStatePayload(
        mac: .connected, robot: .connected, endpoint: "tcp://192.168.123.1:5530",
        armed: true, dxlPower: true,
        batteryV: 11.6, maxTempC: 45,
        latencyMs: 220, lastAckAgeMs: 220,
        safety: .ready, uiState: .armedReady)

    public static let busBusy = TelemetryStatePayload(
        mac: .connected, robot: .busBusy, endpoint: "tcp://192.168.123.1:5530",
        armed: false, dxlPower: false,
        batteryV: 11.7, maxTempC: 42,
        latencyMs: 30, lastAckAgeMs: nil,
        safety: .degraded, uiState: .robotConnectedLocked)

    public static let estopped = TelemetryStatePayload(
        mac: .connected, robot: .estopped, endpoint: "tcp://192.168.123.1:5530",
        armed: false, dxlPower: false,
        batteryV: 11.6, maxTempC: 41,
        latencyMs: 28, lastAckAgeMs: nil,
        safety: .estopped, uiState: .estopped)
}
