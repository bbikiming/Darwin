import Foundation

public protocol DynamixelBus: Sendable {
    func send(_ packet: InstructionPacket) async throws
    func receive(timeout: Duration) async throws -> StatusPacket
}

public extension DynamixelBus {
    func ping(id: UInt8) async throws -> StatusPacket {
        try await send(InstructionPacket(id: id, instruction: .ping))
        return try await receive(timeout: .milliseconds(100))
    }

    func read(id: UInt8, address: UInt8, length: UInt8) async throws -> [UInt8] {
        try await send(InstructionPacket(id: id,
                                         instruction: .readData,
                                         parameters: [address, length]))
        let status = try await receive(timeout: .milliseconds(100))
        return status.parameters
    }

    func write(id: UInt8, address: UInt8, bytes: [UInt8]) async throws {
        try await send(InstructionPacket(id: id,
                                         instruction: .writeData,
                                         parameters: [address] + bytes))
        _ = try await receive(timeout: .milliseconds(100))
    }
}

/// In-memory bus used for unit tests. Records every sent packet and
/// returns canned status responses.
public final class LoopbackBus: DynamixelBus, @unchecked Sendable {
    public private(set) var sent: [InstructionPacket] = []
    public var responder: @Sendable (InstructionPacket) -> StatusPacket

    public init(responder: @escaping @Sendable (InstructionPacket) -> StatusPacket =
                { StatusPacket(id: $0.id, error: []) }) {
        self.responder = responder
    }

    private var pendingResponse: StatusPacket?

    public func send(_ packet: InstructionPacket) async throws {
        sent.append(packet)
        pendingResponse = responder(packet)
    }

    public func receive(timeout: Duration) async throws -> StatusPacket {
        guard let response = pendingResponse else {
            throw CodecError.truncated
        }
        pendingResponse = nil
        return response
    }
}
