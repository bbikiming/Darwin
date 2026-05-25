import Foundation

/// Production relay client backed by URLSessionWebSocketTask. Pairs with
/// the Mac `MobileRelayServer` over local network.
public final class WebSocketRelayClient: MobileRelayClient, @unchecked Sendable {

    public let transportStream: AsyncStream<TransportState>
    private let transportContinuation: AsyncStream<TransportState>.Continuation

    public let eventStream: AsyncStream<InboundMessage>
    private let eventContinuation: AsyncStream<InboundMessage>.Continuation

    private let session: URLSession
    private let clock: PilotClock
    private let ackTimeoutMs: Int

    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<CommandReceipt, Error>] = [:]
    private var sessionId: String = ""
    private var connected = false

    public init(session: URLSession = .shared,
                clock: PilotClock = LiveClock(),
                ackTimeoutMs: Int = 1500) {
        self.session = session
        self.clock = clock
        self.ackTimeoutMs = ackTimeoutMs
        var tCont: AsyncStream<TransportState>.Continuation!
        self.transportStream = AsyncStream { tCont = $0 }
        self.transportContinuation = tCont
        var eCont: AsyncStream<InboundMessage>.Continuation!
        self.eventStream = AsyncStream { eCont = $0 }
        self.eventContinuation = eCont
        transportContinuation.yield(.idle)
    }

    public func connect(_ request: RelayConnectRequest) async throws {
        // P0-3 fix (truth-gap report, 2026-05-25): the receive loop must NOT
        // be started before the welcome handshake completes. Both paths used
        // to call `socket.receive()` concurrently, racing on the first frame.
        // New order:
        //   1. open socket
        //   2. send session.hello
        //   3. await session.welcome (single receive owner = awaitWelcome)
        //   4. mark connected + yield .connected
        //   5. start long-running receiveLoop
        try withLock {
            if connected { throw RelayClientError.alreadyConnected }
        }
        guard let url = request.endpoint.webSocketURL else {
            throw RelayClientError.transportFailure("invalid URL")
        }
        transportContinuation.yield(.connecting)
        let socket = session.webSocketTask(with: url)
        withLock { task = socket }
        socket.resume()
        transportContinuation.yield(.handshaking)

        let helloEnvelope = RelayEnvelope(id: "cmd_hello",
                                          type: CommandType.sessionHello.rawValue,
                                          sentAt: clock.now(),
                                          payload: request.hello)

        do {
            try await sendRaw(helloEnvelope)
            let welcome = try await awaitWelcome()
            withLock {
                sessionId = welcome.payload.sessionId
                connected = true
            }
            transportContinuation.yield(.connected(sessionId: sessionId))
            // Only now start the persistent receive loop.
            receiveTask = Task { [weak self] in await self?.receiveLoop() }
        } catch {
            // Clean up the socket and surface the failure as a disconnected
            // transport state so observers can react.
            withLock {
                task = nil
                connected = false
            }
            socket.cancel(with: .goingAway, reason: "handshakeFailed".data(using: .utf8))
            transportContinuation.yield(.disconnected(reason: "handshakeFailed: \(error)"))
            throw error
        }
    }

    public func send<P: Codable & Sendable>(_ envelope: RelayEnvelope<P>) async throws -> CommandReceipt {
        try ensureConnected()
        return try await withCheckedThrowingContinuation { (cont: CheckedThrowingContinuation<CommandReceipt, Error>) in
            withLock { pending[envelope.id] = cont }
            Task { [self] in
                do {
                    try await sendRaw(envelope)
                    await scheduleAckTimeout(commandId: envelope.id)
                } catch {
                    resolve(commandId: envelope.id, with: .failure(error))
                }
            }
        }
    }

    public func sendFireAndForget<P: Codable & Sendable>(_ envelope: RelayEnvelope<P>) async throws {
        try ensureConnected()
        try await sendRaw(envelope)
    }

    public func close(reason: String) async {
        let (socket, pendingCopy) = withLock {
            let socket = task
            task = nil
            connected = false
            let pendingCopy = pending
            pending.removeAll()
            return (socket, pendingCopy)
        }
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: reason.data(using: .utf8))
        transportContinuation.yield(.disconnected(reason: reason))
        for (_, cont) in pendingCopy {
            cont.resume(throwing: RelayClientError.transportFailure("closed: \(reason)"))
        }
    }

    // MARK: - Private

    private func ensureConnected() throws {
        try withLock {
            if !connected { throw RelayClientError.notConnected }
        }
    }

    private func sendRaw<P: Codable & Sendable>(_ envelope: RelayEnvelope<P>) async throws {
        let socket = withLock { task }
        guard let socket else { throw RelayClientError.notConnected }
        let data: Data
        do {
            data = try RelayCodec.encode(envelope)
        } catch {
            throw RelayClientError.encodingFailure
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RelayClientError.encodingFailure
        }
        do {
            try await socket.send(.string(text))
        } catch {
            throw RelayClientError.transportFailure(String(describing: error))
        }
    }

    private func awaitWelcome() async throws -> RelayEnvelope<WelcomePayload> {
        let socket = withLock { task }
        guard let socket else { throw RelayClientError.notConnected }
        let timeoutMs = 5_000
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            let message: URLSessionWebSocketTask.Message
            let remainingMs = max(1, Int(deadline.timeIntervalSinceNow * 1000))
            do {
                message = try await receiveWithTimeout(socket: socket,
                                                       timeoutMs: remainingMs)
            } catch {
                throw RelayClientError.handshakeFailed(String(describing: error))
            }
            guard let data = data(from: message) else { continue }
            let inbound = try InboundDecoder.decode(data)
            switch inbound {
            case .sessionWelcome(let env):
                return env
            case .sessionRejected(let env):
                throw RelayClientError.handshakeFailed(env.payload.reason.rawValue)
            default:
                continue
            }
        }
        throw RelayClientError.handshakeFailed("timeout")
    }

    private func receiveWithTimeout(socket: URLSessionWebSocketTask,
                                    timeoutMs: Int) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await socket.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                throw RelayClientError.handshakeFailed("timeout")
            }
            defer { group.cancelAll() }
            guard let message = try await group.next() else {
                throw RelayClientError.handshakeFailed("timeout")
            }
            return message
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            let socket = withLock { task }
            guard let socket else { return }
            do {
                let message = try await socket.receive()
                guard let data = data(from: message) else { continue }
                let inbound = try InboundDecoder.decode(data)
                dispatch(inbound: inbound)
            } catch {
                await close(reason: "receive error: \(error)")
                return
            }
        }
    }

    private func dispatch(inbound: InboundMessage) {
        switch inbound {
        case .commandAccepted(let env):
            // Accepted is informational — keep waiting for ack/failed.
            eventContinuation.yield(.commandAccepted(env))
        case .commandRejected(let env):
            resolve(commandId: env.id,
                    with: .success(CommandReceipt(commandId: env.id,
                                                  outcome: .rejected(reason: env.payload.reason,
                                                                     message: env.payload.message))))
            eventContinuation.yield(.commandRejected(env))
        case .commandAck(let env):
            resolve(commandId: env.id,
                    with: .success(CommandReceipt(commandId: env.id,
                                                  outcome: .acked(latencyMs: env.payload.latencyMs))))
            eventContinuation.yield(.commandAck(env))
        case .commandFailed(let env):
            resolve(commandId: env.id,
                    with: .success(CommandReceipt(commandId: env.id,
                                                  outcome: .failed(reason: env.payload.reason,
                                                                   message: env.payload.message))))
            eventContinuation.yield(.commandFailed(env))
        case .telemetryState, .armingProgress, .transportWarning, .watchdogStop, .logEvent,
             .sessionWelcome, .sessionRejected, .unknown:
            eventContinuation.yield(inbound)
        }
    }

    private func resolve(commandId: String, with result: Result<CommandReceipt, Error>) {
        let cont = withLock { pending.removeValue(forKey: commandId) }
        switch result {
        case .success(let receipt): cont?.resume(returning: receipt)
        case .failure(let error): cont?.resume(throwing: error)
        }
    }

    private func scheduleAckTimeout(commandId: String) async {
        let timeoutMs = ackTimeoutMs
        try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
        let cont = withLock { pending.removeValue(forKey: commandId) }
        cont?.resume(throwing: RelayClientError.ackTimeout(commandId: commandId))
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let d): return d
        case .string(let s): return s.data(using: .utf8)
        @unknown default: return nil
        }
    }
}

// Pre-Swift-5.10 typealias guard: continuation type already exists in Concurrency.
typealias CheckedThrowingContinuation<T, E: Error> = CheckedContinuation<T, Error>
