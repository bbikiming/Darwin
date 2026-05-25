import Foundation

/// Mac-side mirror of the iOS `MobilePilotKit` protocol types. Kept narrow
/// and self-contained — this file does not pull in any DarwinForge UI types
/// so the relay server can be unit-tested without the rest of the app.
///
/// If the iOS schema in
/// `docs/protocols/mobile-relay-v1.md` changes, update both this file and
/// `app/mobile/DarwinForgeMobile/Sources/MobilePilotKit/MobileRelayModels.swift`.

public enum MobileRelayWireProtocol {
    public static let version: Int = 1
    public static let bonjourServiceType: String = "_darwinforge._tcp"
    public static let webSocketPath: String = "/mobile-relay"
    public static let heartbeatIntervalMs: Int = 100
    public static let watchdogTimeoutMs: Int = 500
}

// MARK: - Envelope

public struct RelayEnvelopeHead: Codable, Sendable {
    public let v: Int
    public let id: String
    public let type: String
    public let sentAt: Date
}

public struct RelayEnvelope<P: Codable & Sendable>: Codable, Sendable {
    public let v: Int
    public let id: String
    public let type: String
    public let sentAt: Date
    public let payload: P

    public init(v: Int = MobileRelayWireProtocol.version,
                id: String, type: String, sentAt: Date, payload: P) {
        self.v = v; self.id = id; self.type = type
        self.sentAt = sentAt; self.payload = payload
    }
}

// MARK: - Command / response / event types

public enum InboundCommandType: String, Codable, Sendable {
    case sessionHello = "session.hello"
    case sessionGoodbye = "session.goodbye"
    case pilotHeartbeat = "pilot.heartbeat"
    case pilotArm = "pilot.arm"
    case pilotDisarm = "pilot.disarm"
    case pilotEstop = "pilot.estop"
    case pilotMotion = "pilot.motion"
    case pilotWalk = "pilot.walk"
    case pilotStop = "pilot.stop"
    case pilotHead = "pilot.head"
}

public enum OutboundResponseType: String, Codable, Sendable {
    case commandAccepted = "command.accepted"
    case commandRejected = "command.rejected"
    case commandAck      = "command.ack"
    case commandFailed   = "command.failed"
}

public enum OutboundEventType: String, Codable, Sendable {
    case sessionWelcome   = "session.welcome"
    case sessionRejected  = "session.rejected"
    case telemetryState   = "telemetry.state"
    case armingProgress   = "arming.progress"
    case transportWarning = "transport.warning"
    case watchdogStop     = "watchdog.stop"
    case logEvent         = "log.event"
}

// MARK: - Inbound payloads

public struct HelloPayload: Codable, Sendable, Equatable {
    public let app: String
    public let appVersion: String
    public let protocolVersion: Int
    public let deviceName: String
    public let deviceId: String
    public let pairingCode: String
}

public struct GoodbyePayload: Codable, Sendable, Equatable {
    public let reason: String
}

public struct HeartbeatPayload: Codable, Sendable, Equatable {
    public let uiState: String
    public let activeCommandId: String?
}

public struct ArmPayload: Codable, Sendable, Equatable {
    public let cradleConfirmed: Bool
    public let operator_: String

    private enum CodingKeys: String, CodingKey {
        case cradleConfirmed
        case operator_ = "operator"
    }

    public init(cradleConfirmed: Bool, operator: String) {
        self.cradleConfirmed = cradleConfirmed
        self.operator_ = `operator`
    }
}

public struct DisarmPayload: Codable, Sendable, Equatable {
    public let reason: String
}

public struct EStopPayload: Codable, Sendable, Equatable {
    public let reason: String
}

public struct MotionPayload: Codable, Sendable, Equatable {
    public let slot: Int
    public let label: String
    public let confirmRisk: Bool
}

public enum WalkPreset: String, Codable, Sendable, CaseIterable {
    case slowForward, turnLeft, turnRight, stop, freeform
}

public struct WalkPayload: Codable, Sendable, Equatable {
    public let preset: WalkPreset
    public let enabled: Bool
    public let xMm: Double
    public let yMm: Double
    public let aDeg: Double
    public let periodMs: Int
    public let footMm: Double
    public let hipPitchDeg: Double
    /// Optional in v1.1 — older clients may omit. Server defaults to 1.0.
    public let speedScale: Double?
}

public struct HeadPayload: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let panDeg: Double
    public let tiltDeg: Double
    public let tracking: Bool
}

public struct StopPayload: Codable, Sendable, Equatable {
    public let reason: String
}

// MARK: - Outbound payloads

public struct WelcomePayload: Codable, Sendable, Equatable {
    public let macName: String
    public let macVersion: String
    public let relayProtocolVersion: Int
    public let sessionId: String
    public let heartbeatIntervalMs: Int
    public let watchdogTimeoutMs: Int
}

public struct SessionRejectedPayload: Codable, Sendable, Equatable {
    public let reason: String
    public let message: String?
}

public enum RobotState: String, Codable, Sendable {
    case sim, connected, stale, busBusy, disconnected, estopped
}

public enum MacState: String, Codable, Sendable {
    case connected, searching, lost
}

public enum SafetyTag: String, Codable, Sendable {
    case ready, arming, degraded, estopped
}

public enum PilotUIStateTag: String, Codable, Sendable {
    case notPaired, macConnectedNoRobot, robotConnectedLocked,
         arming, armedReady, commandActive, staleStop, estopped
}

public struct TelemetryStatePayload: Codable, Sendable, Equatable {
    public let mac: MacState
    public let robot: RobotState
    public let endpoint: String?
    public let armed: Bool
    public let dxlPower: Bool
    public let batteryV: Double?
    public let maxTempC: Double?
    public let latencyMs: Int
    public let lastAckAgeMs: Int?
    public let safety: SafetyTag
    public let uiState: PilotUIStateTag

    public init(mac: MacState, robot: RobotState, endpoint: String?,
                armed: Bool, dxlPower: Bool,
                batteryV: Double?, maxTempC: Double?,
                latencyMs: Int, lastAckAgeMs: Int?,
                safety: SafetyTag, uiState: PilotUIStateTag) {
        self.mac = mac; self.robot = robot; self.endpoint = endpoint
        self.armed = armed; self.dxlPower = dxlPower
        self.batteryV = batteryV; self.maxTempC = maxTempC
        self.latencyMs = latencyMs; self.lastAckAgeMs = lastAckAgeMs
        self.safety = safety; self.uiState = uiState
    }
}

public struct ArmingProgressPayload: Codable, Sendable, Equatable {
    public let commandId: String
    public let stage: String
    public let progress: Double
}

public struct TransportWarningPayload: Codable, Sendable, Equatable {
    public let kind: String
    public let latencyMs: Int?
    public let message: String?
}

public struct WatchdogStopPayload: Codable, Sendable, Equatable {
    public let reason: String
    public let lastHeartbeatAgeMs: Int?
}

public struct LogEventPayload: Codable, Sendable, Equatable {
    public let level: String
    public let category: String
    public let message: String
    public let commandId: String?
}

public struct EmptyPayload: Codable, Sendable, Equatable { public init() {} }

public struct RejectedPayload: Codable, Sendable, Equatable {
    public let reason: String
    public let message: String?
}

public struct AckPayload: Codable, Sendable, Equatable {
    public let latencyMs: Int
    public let robotAckId: String?
}

public struct FailedPayload: Codable, Sendable, Equatable {
    public let reason: String
    public let message: String?
    public let lastErrorAtMs: Int?
}

// MARK: - JSON codec

public enum RelayCodec {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter.relayFractional.string(from: date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            if let date = ISO8601DateFormatter.relayFractional.date(from: raw) {
                return date
            }
            if let fallback = ISO8601DateFormatter.relayPlain.date(from: raw) {
                return fallback
            }
            throw DecodingError.dataCorruptedError(in: c,
                debugDescription: "Unsupported ISO-8601 date: \(raw)")
        }
        return d
    }()
}

extension ISO8601DateFormatter {
    static let relayFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let relayPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
