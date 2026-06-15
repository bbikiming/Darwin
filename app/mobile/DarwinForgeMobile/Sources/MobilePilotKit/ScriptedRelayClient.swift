import Foundation

/// Scripted relay client — replays a deterministic sequence of telemetry,
/// command results, and transport events. Used for fault-injection tests
/// (latency spikes, half-open sockets, watchdog stop scenarios).
public final class ScriptedRelayClient: MobileRelayClient, @unchecked Sendable {

    public enum Step: Sendable {
        case wait(milliseconds: Int)
        case telemetry(TelemetryStatePayload)
        case watchdogStop(WatchdogStopReason)
        case transportWarning(TransportWarningKind, latencyMs: Int?, message: String?)
        case log(String, LogLevel, LogCategory)
        case disconnect(reason: String)
        case rejectNextCommand(reason: RejectionReason, message: String?)
        case failNextCommand(reason: FailureReason, message: String?)
        case setAckLatency(ms: Int)
    }

    private let lock = NSLock()
    private let clock: PilotClock
    private var script: [Step]
    private var connected = false
    private var pendingReject: RejectedPayload?
    private var pendingFail: FailedPayload?
    private var ackLatencyMs: Int = 40
    private var eventCounter: UInt64 = 0
    private var sessionId: String = "ses_SCRIPT"
    private var scriptTask: Task<Void, Never>?

    public let transportStream: AsyncStream<TransportState>
    private let transportContinuation: AsyncStream<TransportState>.Continuation
    public let eventStream: AsyncStream<InboundMessage>
    private let eventContinuation: AsyncStream<InboundMessage>.Continuation

    public init(script: [Step], clock: PilotClock = LiveClock()) {
        self.script = script
        self.clock = clock
        var tCont: AsyncStream<TransportState>.Continuation!
        self.transportStream = AsyncStream { tCont = $0 }
        self.transportContinuation = tCont
        var eCont: AsyncStream<InboundMessage>.Continuation!
        self.eventStream = AsyncStream { eCont = $0 }
        self.eventContinuation = eCont
        transportContinuation.yield(.idle)
    }

    public func connect(_ request: RelayConnectRequest) async throws {
        lock.lock()
        if connected { lock.unlock(); throw RelayClientError.alreadyConnected }
        connected = true
        lock.unlock()
        transportContinuation.yield(.connecting)
        transportContinuation.yield(.handshaking)
        let env = RelayEnvelope(
            id: nextEventId(),
            type: EventType.sessionWelcome.rawValue,
            sentAt: clock.now(),
            payload: WelcomePayload(macName: "Scripted Mac",
                                    macVersion: "0.0.0-scripted",
                                    relayProtocolVersion: MobileRelayProtocol.version,
                                    sessionId: sessionId,
                                    heartbeatIntervalMs: MobileRelayProtocol.heartbeatIntervalMs,
                                    watchdogTimeoutMs: MobileRelayProtocol.watchdogTimeoutMs))
        eventContinuation.yield(.sessionWelcome(env))
        transportContinuation.yield(.connected(sessionId: sessionId))
        scriptTask = Task { [weak self] in await self?.runScript() }
    }

    public func send<P: Codable & Sendable>(_ envelope: RelayEnvelope<P>) async throws -> CommandReceipt {
        try ensureConnected()
        try await sendFireAndForget(envelope)

        lock.lock()
        let reject = pendingReject; pendingReject = nil
        let fail = pendingFail; pendingFail = nil
        let latency = ackLatencyMs
        lock.unlock()

        if let r = reject {
            let env = RelayEnvelope(id: envelope.id,
                                    type: ResponseType.commandRejected.rawValue,
                                    sentAt: clock.now(),
                                    payload: r)
            eventContinuation.yield(.commandRejected(env))
            return CommandReceipt(commandId: envelope.id,
                                  outcome: .rejected(reason: r.reason, message: r.message))
        }
        if let f = fail {
            let env = RelayEnvelope(id: envelope.id,
                                    type: ResponseType.commandFailed.rawValue,
                                    sentAt: clock.now(),
                                    payload: f)
            eventContinuation.yield(.commandFailed(env))
            return CommandReceipt(commandId: envelope.id,
                                  outcome: .failed(reason: f.reason, message: f.message))
        }

        await clock.sleep(milliseconds: latency)
        let env = RelayEnvelope(id: envelope.id,
                                type: ResponseType.commandAck.rawValue,
                                sentAt: clock.now(),
                                payload: AckPayload(latencyMs: latency))
        eventContinuation.yield(.commandAck(env))
        return CommandReceipt(commandId: envelope.id,
                              outcome: .acked(latencyMs: latency))
    }

    public func sendFireAndForget<P: Codable & Sendable>(_ envelope: RelayEnvelope<P>) async throws {
        try ensureConnected()
        _ = envelope
    }

    public func close(reason: String) async {
        scriptTask?.cancel()
        scriptTask = nil
        lock.lock(); connected = false; lock.unlock()
        transportContinuation.yield(.disconnected(reason: reason))
    }

    // MARK: - Internal

    private func runScript() async {
        for step in script {
            if Task.isCancelled { return }
            switch step {
            case .wait(let ms):
                await clock.sleep(milliseconds: ms)
            case .telemetry(let payload):
                let env = RelayEnvelope(id: nextEventId(),
                                        type: EventType.telemetryState.rawValue,
                                        sentAt: clock.now(),
                                        payload: payload)
                eventContinuation.yield(.telemetryState(env))
            case .watchdogStop(let reason):
                let env = RelayEnvelope(id: nextEventId(),
                                        type: EventType.watchdogStop.rawValue,
                                        sentAt: clock.now(),
                                        payload: WatchdogStopPayload(reason: reason,
                                                                     lastHeartbeatAgeMs: 520))
                eventContinuation.yield(.watchdogStop(env))
            case .transportWarning(let kind, let latency, let message):
                let env = RelayEnvelope(id: nextEventId(),
                                        type: EventType.transportWarning.rawValue,
                                        sentAt: clock.now(),
                                        payload: TransportWarningPayload(kind: kind,
                                                                         latencyMs: latency,
                                                                         message: message))
                eventContinuation.yield(.transportWarning(env))
            case .log(let message, let level, let category):
                let env = RelayEnvelope(id: nextEventId(),
                                        type: EventType.logEvent.rawValue,
                                        sentAt: clock.now(),
                                        payload: LogEventPayload(level: level,
                                                                 category: category,
                                                                 message: message))
                eventContinuation.yield(.logEvent(env))
            case .disconnect(let reason):
                transportContinuation.yield(.disconnected(reason: reason))
                lock.lock(); connected = false; lock.unlock()
                return
            case .rejectNextCommand(let reason, let message):
                lock.lock(); pendingReject = RejectedPayload(reason: reason, message: message); lock.unlock()
            case .failNextCommand(let reason, let message):
                lock.lock(); pendingFail = FailedPayload(reason: reason, message: message); lock.unlock()
            case .setAckLatency(let ms):
                lock.lock(); ackLatencyMs = ms; lock.unlock()
            }
        }
    }

    private func ensureConnected() throws {
        lock.lock(); defer { lock.unlock() }
        if !connected { throw RelayClientError.notConnected }
    }

    private func nextEventId() -> String {
        lock.lock(); defer { lock.unlock() }
        eventCounter &+= 1
        return String(format: "evt_%06llu", eventCounter)
    }
}
