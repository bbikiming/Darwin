import Foundation

/// Stores the active pairing code and tracks failure attempts. A 5-minute
/// lockout is enforced after 3 wrong attempts, matching the protocol spec.
public final class MobileRelayPairing: @unchecked Sendable {

    public static let codeLength = 6
    public static let maxAttempts = 3
    public static let lockoutSeconds: TimeInterval = 300

    private let lock = NSLock()
    private var current: String
    private var attempts: Int = 0
    private var lockedUntil: Date?

    public init(initialCode: String? = nil) {
        self.current = initialCode ?? Self.generateCode()
    }

    public func currentCode() -> String {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func rotate() -> String {
        lock.lock(); defer { lock.unlock() }
        current = Self.generateCode()
        attempts = 0
        lockedUntil = nil
        return current
    }

    public enum ValidationOutcome: Sendable, Equatable {
        case ok
        case locked(until: Date)
        case mismatch(remainingAttempts: Int)
    }

    public func validate(_ candidate: String, now: Date = Date()) -> ValidationOutcome {
        lock.lock(); defer { lock.unlock() }
        if let lockedUntil, now < lockedUntil {
            return .locked(until: lockedUntil)
        }
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        if trimmed == current {
            attempts = 0
            lockedUntil = nil
            return .ok
        }
        attempts += 1
        if attempts >= Self.maxAttempts {
            let until = now.addingTimeInterval(Self.lockoutSeconds)
            lockedUntil = until
            // rotate the code so a leaked one becomes useless
            current = Self.generateCode()
            attempts = 0
            return .locked(until: until)
        }
        return .mismatch(remainingAttempts: Self.maxAttempts - attempts)
    }

    public static func generateCode() -> String {
        let value = Int.random(in: 0...999_999)
        return String(format: "%06d", value)
    }
}

/// Pairing QR payload — printed/displayed on the Mac side as a JSON string.
public struct PairingQRPayload: Codable, Sendable, Equatable {
    public let type: String
    public let host: String
    public let port: Int
    public let pairingCode: String
    public let service: String

    public init(host: String, port: Int, pairingCode: String,
                type: String = "darwinforge.mobileRelay",
                service: String = MobileRelayWireProtocol.bonjourServiceType) {
        self.type = type
        self.host = host
        self.port = port
        self.pairingCode = pairingCode
        self.service = service
    }

    public func encode() throws -> String {
        let data = try RelayCodec.encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
