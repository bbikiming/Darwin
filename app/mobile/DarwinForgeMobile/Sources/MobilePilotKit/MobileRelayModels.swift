import Foundation

// MARK: - Protocol version

public enum MobileRelayProtocol {
    public static let version: Int = 1
    public static let bonjourServiceType: String = "_darwinforge._tcp"
    public static let webSocketPath: String = "/mobile-relay"
    public static let heartbeatIntervalMs: Int = 100
    public static let watchdogTimeoutMs: Int = 500
}

// MARK: - Envelope

public struct RelayEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let v: Int
    public let id: String
    public let type: String
    public let sentAt: Date
    public let payload: Payload

    public init(v: Int = MobileRelayProtocol.version,
                id: String,
                type: String,
                sentAt: Date,
                payload: Payload) {
        self.v = v
        self.id = id
        self.type = type
        self.sentAt = sentAt
        self.payload = payload
    }
}

// MARK: - Commands (iOS → Mac)

public enum CommandType: String, Codable, Sendable, CaseIterable {
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
    /// V297-9 CRITICAL-1: 복구 전용 명령 — pilot.arm 재사용 race 해결.
    case pilotRecover = "pilot.recover"
    /// 볼 트래킹 (2026-06-02): 로봇 온보드 자동 헤드 추적 on/off.
    case pilotBallTrack = "pilot.ballTrack"
}

public enum DisarmReason: String, Codable, Sendable {
    case user
    case tabSwitch
    case appBackground
    case timeout
}

public enum EStopReason: String, Codable, Sendable {
    case user
    case watchdog
    case latencyGate
    case appBackground
    case disconnect
}

public enum StopReason: String, Codable, Sendable {
    case user
    case deadmanRelease
    case tabSwitch
    case appBackground
    case latencyGate
}

public enum UIStateTag: String, Codable, Sendable {
    case idle
    case armedReady
    case commandActive
    case estopping
}

public enum WalkPreset: String, Codable, Sendable, CaseIterable {
    case slowForward
    case turnLeft
    case turnRight
    case stop
    /// Freeform analog input — server uses raw x/y/turn/speedScale, not a fixed mapping.
    case freeform

    public var defaultParams: WalkParams {
        switch self {
        case .slowForward:
            return WalkParams(enabled: true, xMm: 20, yMm: 0, aDeg: 0,
                              periodMs: 700, footMm: 35, hipPitchDeg: 13)
        case .turnLeft:
            return WalkParams(enabled: true, xMm: 0, yMm: 0, aDeg: 8,
                              periodMs: 700, footMm: 35, hipPitchDeg: 13)
        case .turnRight:
            return WalkParams(enabled: true, xMm: 0, yMm: 0, aDeg: -8,
                              periodMs: 700, footMm: 35, hipPitchDeg: 13)
        case .stop, .freeform:
            return WalkParams(enabled: false, xMm: 0, yMm: 0, aDeg: 0,
                              periodMs: 700, footMm: 35, hipPitchDeg: 13)
        }
    }
}

public struct WalkParams: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let xMm: Double
    public let yMm: Double
    public let aDeg: Double
    public let periodMs: Int
    public let footMm: Double
    public let hipPitchDeg: Double

    public init(enabled: Bool, xMm: Double, yMm: Double, aDeg: Double,
                periodMs: Int, footMm: Double, hipPitchDeg: Double) {
        self.enabled = enabled
        self.xMm = xMm
        self.yMm = yMm
        self.aDeg = aDeg
        self.periodMs = periodMs
        self.footMm = footMm
        self.hipPitchDeg = hipPitchDeg
    }
}

public enum MotionRisk: String, Codable, Sendable {
    case safe
    case caution
    case highRisk

    public var requiresConfirm: Bool { self != .safe }
}

public struct MotionCatalogEntry: Sendable, Equatable {
    public let label: String
    public let slot: Int
    public let risk: MotionRisk
    public let koreanName: String

    public init(label: String, slot: Int, risk: MotionRisk, koreanName: String) {
        self.label = label
        self.slot = slot
        self.risk = risk
        self.koreanName = koreanName
    }
}

public enum SafeMotionCatalog {
    // P0-4 fix (truth-gap report, 2026-05-25): slot 41 is `talk2` long-chain
    // in docs/motion-format/page-catalog-motion4096.md — NOT bow. The `bow`
    // entry has been removed entirely to prevent the iOS button from
    // triggering a multi-page chain on the real robot.
    //
    // Re-add only after a verified slot is assigned and HIL-tested.
    public static let entries: [MotionCatalogEntry] = [
        .init(label: "walkReady",    slot: 9,  risk: .safe,     koreanName: "보행 자세"),
        .init(label: "basicPosture", slot: 1,  risk: .safe,     koreanName: "기본 자세"),
        .init(label: "sit",          slot: 15, risk: .caution,  koreanName: "앉기"),
        .init(label: "greeting",     slot: 4,  risk: .safe,     koreanName: "인사"),
        .init(label: "kickRight",    slot: 12, risk: .highRisk, koreanName: "오른발 차기"),
        .init(label: "kickLeft",     slot: 13, risk: .highRisk, koreanName: "왼발 차기")
    ]

    public static func entry(forLabel label: String) -> MotionCatalogEntry? {
        entries.first { $0.label == label }
    }

    public static var mvpEnabledLabels: Set<String> {
        ["walkReady", "basicPosture", "sit", "greeting"]
    }
}

// MARK: - Command payloads

public struct HelloPayload: Codable, Sendable, Equatable {
    public let app: String
    public let appVersion: String
    public let protocolVersion: Int
    public let deviceName: String
    public let deviceId: String
    public let pairingCode: String

    public init(app: String = "ios",
                appVersion: String,
                protocolVersion: Int = MobileRelayProtocol.version,
                deviceName: String,
                deviceId: String,
                pairingCode: String) {
        self.app = app
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.pairingCode = pairingCode
    }
}

public struct GoodbyePayload: Codable, Sendable, Equatable {
    public let reason: String
    public init(reason: String = "user") { self.reason = reason }
}

public struct HeartbeatPayload: Codable, Sendable, Equatable {
    public let uiState: UIStateTag
    public let activeCommandId: String?
    public init(uiState: UIStateTag, activeCommandId: String? = nil) {
        self.uiState = uiState
        self.activeCommandId = activeCommandId
    }
}

public struct ArmPayload: Codable, Sendable, Equatable {
    public let cradleConfirmed: Bool
    public let operator_: String

    public init(cradleConfirmed: Bool, operator: String) {
        self.cradleConfirmed = cradleConfirmed
        self.operator_ = `operator`
    }

    private enum CodingKeys: String, CodingKey {
        case cradleConfirmed
        case operator_ = "operator"
    }
}

public struct DisarmPayload: Codable, Sendable, Equatable {
    public let reason: DisarmReason
    public init(reason: DisarmReason = .user) { self.reason = reason }
}

public struct EStopPayload: Codable, Sendable, Equatable {
    public let reason: EStopReason
    public init(reason: EStopReason = .user) { self.reason = reason }
}

/// V297-9 CRITICAL-1 — 복구 전용 payload.
public struct RecoverPayload: Codable, Sendable, Equatable {
    public let cradleConfirmed: Bool
    public let operator_: String
    public init(cradleConfirmed: Bool, operator: String) {
        self.cradleConfirmed = cradleConfirmed
        self.operator_ = `operator`
    }
    private enum CodingKeys: String, CodingKey {
        case cradleConfirmed
        case operator_ = "operator"
    }
}

public struct MotionPayload: Codable, Sendable, Equatable {
    public let slot: Int
    public let label: String
    public let confirmRisk: Bool

    public init(slot: Int, label: String, confirmRisk: Bool = false) {
        self.slot = slot
        self.label = label
        self.confirmRisk = confirmRisk
    }
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
    /// 0.0 – 2.5 multiplier applied to xMm/yMm/aDeg. Server clamps if outside
    /// the safety policy window for the current build.
    public let speedScale: Double

    public init(preset: WalkPreset, params: WalkParams, speedScale: Double = 1.0) {
        self.preset = preset
        self.enabled = params.enabled
        self.xMm = params.xMm
        self.yMm = params.yMm
        self.aDeg = params.aDeg
        self.periodMs = params.periodMs
        self.footMm = params.footMm
        self.hipPitchDeg = params.hipPitchDeg
        self.speedScale = speedScale
    }

    public var params: WalkParams {
        WalkParams(enabled: enabled, xMm: xMm, yMm: yMm, aDeg: aDeg,
                   periodMs: periodMs, footMm: footMm, hipPitchDeg: hipPitchDeg)
    }
}

/// Freeform analog walk input from the joystick.
/// x ∈ [-1, 1] (right positive), y ∈ [-1, 1] (forward NEGATIVE per joystick
/// convention; server flips sign when translating to xMm), turn ∈ [-1, 1].
public struct WalkFreeformInput: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let turn: Double
    public let speedScale: Double

    public init(x: Double, y: Double, turn: Double, speedScale: Double = 1.0) {
        self.x = x
        self.y = y
        self.turn = turn
        self.speedScale = speedScale
    }

    public static let zero = WalkFreeformInput(x: 0, y: 0, turn: 0, speedScale: 1.0)
    public var isMoving: Bool { abs(x) > 0.05 || abs(y) > 0.05 || abs(turn) > 0.05 }
}

// MARK: - Head control

public struct HeadPayload: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let panDeg: Double
    public let tiltDeg: Double
    public let tracking: Bool

    public init(enabled: Bool, panDeg: Double, tiltDeg: Double, tracking: Bool) {
        self.enabled = enabled
        self.panDeg = panDeg
        self.tiltDeg = tiltDeg
        self.tracking = tracking
    }
}

public struct StopPayload: Codable, Sendable, Equatable {
    public let reason: StopReason
    public init(reason: StopReason = .user) { self.reason = reason }
}

/// 볼 트래킹 (2026-06-02) — 로봇 온보드 자동 헤드 추적 on/off. `pilot.ballTrack` payload.
public struct BallTrackPayload: Codable, Sendable, Equatable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

// MARK: - Response payloads (Mac → iOS)

public enum ResponseType: String, Codable, Sendable {
    case commandAccepted = "command.accepted"
    case commandRejected = "command.rejected"
    case commandAck      = "command.ack"
    case commandFailed   = "command.failed"
}

/// V297-5 HIGH-1: iOS strict enum 이 Mac 의 새 reason 코드 decode 실패시 연결이
/// 종료되던 회귀를 해결. 새 case 등록 + custom decoder 로 unknown fallback.
///
/// # 등록된 reason
///
/// 프로토콜 §7.2 표준 코드 + Mac 서버가 실제로 송신하는 모든 코드:
///   - 표준: notArmed, robotDisconnected, busBusy, pairingMismatch, alreadyOwned,
///           protocolMismatch, unknownPreset, riskNotConfirmed, simulated, latencyGate,
///           invalidPayload, internalError
///   - V297-4/5 추가: lowBattery, clockSkew, highRiskNotAllowed, dxlPowerOff,
///           headUnsupportedInMVP, preflightFailed, walkSessionUnavailable, cradleRequired,
///           invalidSlot, armFailed, estopVerificationFailed
///
/// # Forward compatibility
///
/// 미래에 Mac 이 새 reason 추가하면 iOS 가 자동으로 `.unknown` 으로 처리.
/// raw 값은 별도 `rawReasonString` 컨테이너 미보존 — UI 는 RejectedPayload.message 의
/// 사람이 읽을 수 있는 설명에 의존.
public enum RejectionReason: String, Codable, Sendable {
    case notArmed
    case robotDisconnected
    case busBusy
    case pairingMismatch
    case alreadyOwned
    case protocolMismatch
    case unknownPreset
    case riskNotConfirmed
    case simulated
    case latencyGate
    case invalidPayload
    case internalError
    // V297-4/5 추가 코드 — Mac 서버가 실제로 송신.
    case lowBattery
    case clockSkew
    case highRiskNotAllowed
    case dxlPowerOff
    case headUnsupportedInMVP
    case preflightFailed
    case walkSessionUnavailable
    case cradleRequired
    case invalidSlot
    case armFailed
    case estopVerificationFailed
    // Forward-compat fallback — 모르는 reason 은 여기로.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RejectionReason(rawValue: raw) ?? .unknown
    }
}

/// V297-5 HIGH-1: 동일 forward-compat 적용 — Mac 미래 추가 reason 도 .unknown fallback.
public enum FailureReason: String, Codable, Sendable {
    case noAck
    case staleCommand
    case transportError
    case safetyAbort
    case internalError
    case stopFailed
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FailureReason(rawValue: raw) ?? .unknown
    }
}

public struct RejectedPayload: Codable, Sendable, Equatable {
    public let reason: RejectionReason
    public let message: String?
    public init(reason: RejectionReason, message: String? = nil) {
        self.reason = reason
        self.message = message
    }
}

public struct AckPayload: Codable, Sendable, Equatable {
    public let latencyMs: Int
    public let robotAckId: String?
    public init(latencyMs: Int, robotAckId: String? = nil) {
        self.latencyMs = latencyMs
        self.robotAckId = robotAckId
    }
}

public struct FailedPayload: Codable, Sendable, Equatable {
    public let reason: FailureReason
    public let message: String?
    public let lastErrorAtMs: Int?
    public init(reason: FailureReason, message: String? = nil, lastErrorAtMs: Int? = nil) {
        self.reason = reason
        self.message = message
        self.lastErrorAtMs = lastErrorAtMs
    }
}

// MARK: - Events (Mac → iOS, broadcast)

public enum EventType: String, Codable, Sendable {
    case sessionWelcome   = "session.welcome"
    case sessionRejected  = "session.rejected"
    case telemetryState   = "telemetry.state"
    case armingProgress   = "arming.progress"
    case transportWarning = "transport.warning"
    case watchdogStop     = "watchdog.stop"
    case logEvent         = "log.event"
}

public struct WelcomePayload: Codable, Sendable, Equatable {
    public let macName: String
    public let macVersion: String
    public let relayProtocolVersion: Int
    public let sessionId: String
    public let heartbeatIntervalMs: Int
    public let watchdogTimeoutMs: Int
    /// V297-4 (2026-05-26): optional — Mac 서버가 어떤 명령을 실제로 지원하는지 명시.
    /// 없으면 모든 명령을 가정해 시도 (legacy backward compat).
    public let capabilities: WelcomeCapabilities?

    public init(macName: String, macVersion: String, relayProtocolVersion: Int,
                sessionId: String, heartbeatIntervalMs: Int, watchdogTimeoutMs: Int,
                capabilities: WelcomeCapabilities? = nil) {
        self.macName = macName
        self.macVersion = macVersion
        self.relayProtocolVersion = relayProtocolVersion
        self.sessionId = sessionId
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.watchdogTimeoutMs = watchdogTimeoutMs
        self.capabilities = capabilities
    }
}

/// V297-4/5/8/9 — Mac → iOS 의 capabilities 통보.
///
/// 의미체계 (V297-9 LOW-1/2 갱신 — 실 동작 반영):
///   - `head`: pilot.head 가 실제 로봇 헤드에 적용되는지. false 면 iOS UI 진입점 숨김.
///     nil capabilities (legacy Mac) 도 false 처리 — AppState.headControlSupported 정책.
///   - `walkFreeform`: freeform preset 을 서버가 처리하는지. false 면 reject. nil → false.
///   - `speedScaleAccepted`: WalkPayload.speedScale 필드를 **수신 + 실 적용** 하는지.
///     V297-8 부터 Mac 가 WalkLabSession.start(speedScale:) 로 amplitude 에 실 곱. nil → false.
public struct WelcomeCapabilities: Codable, Sendable, Equatable {
    public let head: Bool
    public let walkFreeform: Bool
    public let speedScaleAccepted: Bool
    /// 볼 트래킹 (2026-06-02): Mac 이 pilot.ballTrack 을 처리하는지. nil/false 면 버튼 숨김.
    public let ballTracking: Bool

    public init(head: Bool = false, walkFreeform: Bool = false,
                speedScaleAccepted: Bool = false, ballTracking: Bool = false) {
        self.head = head
        self.walkFreeform = walkFreeform
        self.speedScaleAccepted = speedScaleAccepted
        self.ballTracking = ballTracking
    }

    /// 누락 키 = false 로 관용 디코딩 (capabilities 는 버전마다 필드가 늘어나므로
    /// 구버전 Mac 이 보낸 일부 키 없는 JSON 도 깨지지 않아야 한다 — forward/backward compat).
    /// 종전 비-optional 필드들은 키 누락 시 throw 했으나, ballTracking 추가(2026-06-02)를
    /// 계기로 전 필드를 decodeIfPresent 로 통일.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.head = try c.decodeIfPresent(Bool.self, forKey: .head) ?? false
        self.walkFreeform = try c.decodeIfPresent(Bool.self, forKey: .walkFreeform) ?? false
        self.speedScaleAccepted = try c.decodeIfPresent(Bool.self, forKey: .speedScaleAccepted) ?? false
        self.ballTracking = try c.decodeIfPresent(Bool.self, forKey: .ballTracking) ?? false
    }
}

public enum MacConnectionState: String, Codable, Sendable {
    case connected
    case searching
    case lost
}

public enum RobotConnectionState: String, Codable, Sendable {
    case sim
    case connected
    case stale
    case busBusy
    case disconnected
    case estopped
}

public enum SafetyState: String, Codable, Sendable {
    case ready
    case arming
    case degraded
    case estopped
}

public enum PilotUIState: String, Codable, Sendable {
    case notPaired
    case macConnectedNoRobot
    case robotConnectedLocked
    case arming
    case armedReady
    case commandActive
    case staleStop
    case estopped
}

public struct TelemetryStatePayload: Codable, Sendable, Equatable {
    public let mac: MacConnectionState
    public let robot: RobotConnectionState
    public let endpoint: String?
    public let armed: Bool
    public let dxlPower: Bool
    public let batteryV: Double?
    public let maxTempC: Double?
    public let latencyMs: Int
    public let lastAckAgeMs: Int?
    public let safety: SafetyState
    public let uiState: PilotUIState

    public init(mac: MacConnectionState,
                robot: RobotConnectionState,
                endpoint: String?,
                armed: Bool,
                dxlPower: Bool,
                batteryV: Double?,
                maxTempC: Double?,
                latencyMs: Int,
                lastAckAgeMs: Int?,
                safety: SafetyState,
                uiState: PilotUIState) {
        self.mac = mac
        self.robot = robot
        self.endpoint = endpoint
        self.armed = armed
        self.dxlPower = dxlPower
        self.batteryV = batteryV
        self.maxTempC = maxTempC
        self.latencyMs = latencyMs
        self.lastAckAgeMs = lastAckAgeMs
        self.safety = safety
        self.uiState = uiState
    }
}

public enum ArmingStage: String, Codable, Sendable {
    case checkingChecklist
    case enablingPower
    case engagingTorque
    case walkReadyPose
    case armed
    case failed
}

public struct ArmingProgressPayload: Codable, Sendable, Equatable {
    public let commandId: String
    public let stage: ArmingStage
    public let progress: Double

    public init(commandId: String, stage: ArmingStage, progress: Double) {
        self.commandId = commandId
        self.stage = stage
        self.progress = progress
    }
}

public enum TransportWarningKind: String, Codable, Sendable {
    case highLatency
    case halfOpen
    case clockSkew
    case demoBusBusy
    case unknownType
}

public struct TransportWarningPayload: Codable, Sendable, Equatable {
    public let kind: TransportWarningKind
    public let latencyMs: Int?
    public let message: String?

    public init(kind: TransportWarningKind, latencyMs: Int? = nil, message: String? = nil) {
        self.kind = kind
        self.latencyMs = latencyMs
        self.message = message
    }
}

public enum WatchdogStopReason: String, Codable, Sendable {
    case heartbeatTimeout
    case transportDisconnect
    case appBackground
    case pairingRevoked
}

public struct WatchdogStopPayload: Codable, Sendable, Equatable {
    public let reason: WatchdogStopReason
    public let lastHeartbeatAgeMs: Int?

    public init(reason: WatchdogStopReason, lastHeartbeatAgeMs: Int? = nil) {
        self.reason = reason
        self.lastHeartbeatAgeMs = lastHeartbeatAgeMs
    }
}

public enum LogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public enum LogCategory: String, Codable, Sendable {
    case command
    case safety
    case connection
    case system
}

public struct LogEventPayload: Codable, Sendable, Equatable {
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let commandId: String?

    public init(level: LogLevel, category: LogCategory, message: String, commandId: String? = nil) {
        self.level = level
        self.category = category
        self.message = message
        self.commandId = commandId
    }
}

public struct SessionRejectedPayload: Codable, Sendable, Equatable {
    public let reason: RejectionReason
    public let message: String?
    public init(reason: RejectionReason, message: String? = nil) {
        self.reason = reason
        self.message = message
    }
}

// MARK: - Pairing QR payload

public struct PairingQRPayload: Codable, Sendable, Equatable {
    public let type: String
    public let host: String
    public let port: Int
    public let pairingCode: String
    public let service: String

    public init(host: String, port: Int, pairingCode: String,
                type: String = "darwinforge.mobileRelay",
                service: String = MobileRelayProtocol.bonjourServiceType) {
        self.type = type
        self.host = host
        self.port = port
        self.pairingCode = pairingCode
        self.service = service
    }
}

// MARK: - Endpoint descriptor

public struct RelayEndpoint: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let pairingCode: String

    public init(host: String, port: Int, pairingCode: String) {
        self.host = host
        self.port = port
        self.pairingCode = pairingCode
    }

    public var webSocketURL: URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = MobileRelayProtocol.webSocketPath
        return components.url
    }
}

// MARK: - JSON codec

public enum RelayCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return decoder
    }()

    public static func encode<P: Codable & Sendable>(_ envelope: RelayEnvelope<P>) throws -> Data {
        try encoder.encode(envelope)
    }

    public static func decode<P: Codable & Sendable>(_ data: Data, as: P.Type) throws -> RelayEnvelope<P> {
        try decoder.decode(RelayEnvelope<P>.self, from: data)
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    static var iso8601WithFractionalSeconds: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.fractional.string(from: date))
        }
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithFractionalSeconds: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.fractional.date(from: raw) {
                return date
            }
            if let fallback = ISO8601DateFormatter.plain.date(from: raw) {
                return fallback
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported ISO-8601 date: \(raw)"
            )
        }
    }
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Type-erased envelope dispatching

/// Lightweight peek at the envelope head before decoding the payload.
public struct RelayEnvelopeHead: Codable, Sendable {
    public let v: Int
    public let id: String
    public let type: String
    public let sentAt: Date
}

public enum InboundMessage: Sendable {
    case sessionWelcome(RelayEnvelope<WelcomePayload>)
    case sessionRejected(RelayEnvelope<SessionRejectedPayload>)
    case telemetryState(RelayEnvelope<TelemetryStatePayload>)
    case armingProgress(RelayEnvelope<ArmingProgressPayload>)
    case transportWarning(RelayEnvelope<TransportWarningPayload>)
    case watchdogStop(RelayEnvelope<WatchdogStopPayload>)
    case logEvent(RelayEnvelope<LogEventPayload>)
    case commandAccepted(RelayEnvelope<EmptyPayload>)
    case commandRejected(RelayEnvelope<RejectedPayload>)
    case commandAck(RelayEnvelope<AckPayload>)
    case commandFailed(RelayEnvelope<FailedPayload>)
    case unknown(RelayEnvelopeHead, Data)
}

public struct EmptyPayload: Codable, Sendable, Equatable {
    public init() {}
}

public enum InboundDecoder {
    public static func decode(_ data: Data) throws -> InboundMessage {
        let head = try RelayCodec.decoder.decode(RelayEnvelopeHead.self, from: data)
        switch head.type {
        case EventType.sessionWelcome.rawValue:
            return .sessionWelcome(try RelayCodec.decode(data, as: WelcomePayload.self))
        case EventType.sessionRejected.rawValue:
            return .sessionRejected(try RelayCodec.decode(data, as: SessionRejectedPayload.self))
        case EventType.telemetryState.rawValue:
            return .telemetryState(try RelayCodec.decode(data, as: TelemetryStatePayload.self))
        case EventType.armingProgress.rawValue:
            return .armingProgress(try RelayCodec.decode(data, as: ArmingProgressPayload.self))
        case EventType.transportWarning.rawValue:
            return .transportWarning(try RelayCodec.decode(data, as: TransportWarningPayload.self))
        case EventType.watchdogStop.rawValue:
            return .watchdogStop(try RelayCodec.decode(data, as: WatchdogStopPayload.self))
        case EventType.logEvent.rawValue:
            return .logEvent(try RelayCodec.decode(data, as: LogEventPayload.self))
        case ResponseType.commandAccepted.rawValue:
            return .commandAccepted(try RelayCodec.decode(data, as: EmptyPayload.self))
        case ResponseType.commandRejected.rawValue:
            return .commandRejected(try RelayCodec.decode(data, as: RejectedPayload.self))
        case ResponseType.commandAck.rawValue:
            return .commandAck(try RelayCodec.decode(data, as: AckPayload.self))
        case ResponseType.commandFailed.rawValue:
            return .commandFailed(try RelayCodec.decode(data, as: FailedPayload.self))
        default:
            return .unknown(head, data)
        }
    }
}
