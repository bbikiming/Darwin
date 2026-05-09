import Foundation

public struct InstructionPacket: Sendable, Equatable {
    public let id: UInt8
    public let instruction: Instruction
    public let parameters: [UInt8]

    public init(id: UInt8, instruction: Instruction, parameters: [UInt8] = []) {
        self.id = id
        self.instruction = instruction
        self.parameters = parameters
    }
}

public struct StatusPacket: Sendable, Equatable {
    public let id: UInt8
    public let error: ErrorFlags
    public let parameters: [UInt8]

    public init(id: UInt8, error: ErrorFlags, parameters: [UInt8] = []) {
        self.id = id
        self.error = error
        self.parameters = parameters
    }
}

public struct ErrorFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let inputVoltage = ErrorFlags(rawValue: 0x01)
    public static let angleLimit   = ErrorFlags(rawValue: 0x02)
    public static let overheating  = ErrorFlags(rawValue: 0x04)
    public static let range        = ErrorFlags(rawValue: 0x08)
    public static let checksum     = ErrorFlags(rawValue: 0x10)
    public static let overload     = ErrorFlags(rawValue: 0x20)
    public static let instruction  = ErrorFlags(rawValue: 0x40)
}

public enum CodecError: Error, Equatable {
    case truncated
    case missingHeader
    case lengthMismatch(declared: Int, actual: Int)
    case checksumMismatch(expected: UInt8, actual: UInt8)
}

public enum Codec {
    public static func encode(_ packet: InstructionPacket) -> [UInt8] {
        let length = UInt8(packet.parameters.count + 2)
        var bytes: [UInt8] = [0xFF, 0xFF, packet.id, length, packet.instruction.rawValue]
        bytes.append(contentsOf: packet.parameters)
        bytes.append(checksum(id: packet.id,
                              length: length,
                              opcode: packet.instruction.rawValue,
                              parameters: packet.parameters))
        return bytes
    }

    public static func decodeStatus(_ bytes: [UInt8]) throws -> StatusPacket {
        guard bytes.count >= 6 else { throw CodecError.truncated }
        guard bytes[0] == 0xFF, bytes[1] == 0xFF else { throw CodecError.missingHeader }
        let id = bytes[2]
        let length = Int(bytes[3])
        let total = 4 + length
        guard bytes.count >= total else {
            throw CodecError.lengthMismatch(declared: total, actual: bytes.count)
        }
        let error = bytes[4]
        let params = Array(bytes[5..<(total - 1)])
        let received = bytes[total - 1]
        let expected = checksum(id: id,
                                length: UInt8(length),
                                opcode: error,
                                parameters: params)
        guard received == expected else {
            throw CodecError.checksumMismatch(expected: expected, actual: received)
        }
        return StatusPacket(id: id,
                            error: ErrorFlags(rawValue: error),
                            parameters: params)
    }

    static func checksum(id: UInt8, length: UInt8, opcode: UInt8, parameters: [UInt8]) -> UInt8 {
        var sum: UInt32 = UInt32(id) &+ UInt32(length) &+ UInt32(opcode)
        for byte in parameters { sum = sum &+ UInt32(byte) }
        return ~UInt8(truncatingIfNeeded: sum)
    }
}
