import Foundation

// MARK: - Transport state

public enum TransportState: Equatable, Sendable {
    case idle
    case connecting
    case handshaking
    case connected(sessionId: String)
    case disconnected(reason: String)
}

// MARK: - Command receipt

public struct CommandReceipt: Sendable, Equatable {
    public enum Outcome: Equatable, Sendable {
        case accepted
        case acked(latencyMs: Int)
        case rejected(reason: RejectionReason, message: String?)
        case failed(reason: FailureReason, message: String?)
    }

    public let commandId: String
    public let outcome: Outcome

    public init(commandId: String, outcome: Outcome) {
        self.commandId = commandId
        self.outcome = outcome
    }
}

public enum RelayClientError: Error, Sendable, Equatable {
    case notConnected
    case alreadyConnected
    case handshakeFailed(String)
    case transportFailure(String)
    case ackTimeout(commandId: String)
    case encodingFailure
    case decodingFailure
}

// MARK: - Connection request

public struct RelayConnectRequest: Sendable, Equatable {
    public let endpoint: RelayEndpoint
    public let hello: HelloPayload
    public init(endpoint: RelayEndpoint, hello: HelloPayload) {
        self.endpoint = endpoint
        self.hello = hello
    }
}

// MARK: - Client protocol

public protocol MobileRelayClient: AnyObject, Sendable {

    /// Live transport state. Hot stream — late subscribers get the current state.
    var transportStream: AsyncStream<TransportState> { get }

    /// Inbound event stream (telemetry, watchdog, log events). Per-command
    /// responses are routed through ``send(_:)``'s return value.
    var eventStream: AsyncStream<InboundMessage> { get }

    /// Open the relay connection and complete the hello/welcome handshake.
    func connect(_ request: RelayConnectRequest) async throws

    /// Send a command and wait for the terminal outcome (ack/rejected/failed).
    /// Returns a receipt. For E-stop the caller should call
    /// ``sendEStopOptimistic(_:)`` instead to avoid blocking the UI.
    func send<P: Codable & Sendable>(_ envelope: RelayEnvelope<P>) async throws -> CommandReceipt

    /// Send without awaiting the terminal outcome — used for heartbeats and
    /// for the optimistic E-stop UI flip.
    func sendFireAndForget<P: Codable & Sendable>(_ envelope: RelayEnvelope<P>) async throws

    /// Close the connection. Idempotent.
    func close(reason: String) async
}
