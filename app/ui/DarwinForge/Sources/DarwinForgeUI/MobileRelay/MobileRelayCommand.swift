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

    /// V297-5 CRITICAL-1: priority command 분류.
    ///
    /// # 비유
    ///
    /// 비행기 관제탑에 일반 교신 / "MAYDAY" 두 채널. 일반 교신이 길게 늘어져도
    /// MAYDAY 는 즉시 처리되어야 한다. E-stop/stop 도 동일 — ARM battery wait 같은
    /// long-running command 가 actor 점유 중이어도 frame 단계에서 우회 dispatch.
    ///
    /// # 정책
    ///
    /// WSChannel 의 frame Task chain 은 hello → 일반 명령의 순서 보장에 필요하지만,
    /// E-stop 는 그 chain 에 묶이면 안 된다. `pilot.estop` / `pilot.stop` 만 priority 분류.
    /// `session.hello` 는 첫 frame 이라 chain 시작점 — priority 분류 불요.
    public static let priorityCommandTypes: Set<String> = [
        InboundCommandType.pilotEstop.rawValue,
        InboundCommandType.pilotStop.rawValue,
    ]

    public static func isPriorityCommand(_ type: String) -> Bool {
        priorityCommandTypes.contains(type)
    }
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
    /// V297-9 CRITICAL-1: E-stop 복구 전용 명령. 종전엔 pilot.arm 을 재사용했으나
    /// "ARM stale 도착 → recoverFromEStop 자동 분기" 위험 발생. 별도 명령으로 분리해
    /// 의도를 명확히 한다 — pilot.arm 은 절대 복구 분기 불가.
    case pilotRecover = "pilot.recover"
    /// **볼 트래킹 (2026-06-02)**: 로봇 온보드 자동 헤드 추적 on/off. 조종기 버튼/콕핏 토글이
    /// 발사 → session.ballTrackingEnabled set → OnboardBridge 가 serializedLine 으로 전달.
    case pilotBallTrack = "pilot.ballTrack"
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
    case cockpitTelemetry = "cockpit.telemetry"
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

/// V297-9 CRITICAL-1: pilot.recover payload. iOS "복구" 버튼 전용.
public struct RecoverPayload: Codable, Sendable, Equatable {
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

/// **볼 트래킹 (2026-06-02)** — 로봇 온보드 자동 헤드 추적 on/off.
/// `pilot.ballTrack` 명령의 payload. true 면 robot-side 브로커리지가 카메라+ColorFinder+
/// BallTracker 로 자체 헤드를 움직인다(기본 데모와 동일). Mac head 명령은 무시된다.
public struct BallTrackPayload: Codable, Sendable, Equatable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

// MARK: - Outbound payloads

public struct WelcomePayload: Codable, Sendable, Equatable {
    public let macName: String
    public let macVersion: String
    public let relayProtocolVersion: Int
    public let sessionId: String
    public let heartbeatIntervalMs: Int
    public let watchdogTimeoutMs: Int
    /// V297-4: optional — older iOS 클라이언트는 무시 (forward compatible).
    /// 서버가 어떤 명령을 실제로 지원하는지 명시 → iOS UI 가 미지원 명령 버튼 숨김.
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

/// V297-4 / V297-5 / V297-8 / V297-9 — 서버 capabilities 통보.
///
/// 의미체계 (V297-9 LOW-1 갱신 — 실 동작 반영):
///   - `head`: pilot.head 명령을 실제 robot 에 전달하는지. false 면 iOS UI 숨김.
///   - `walkFreeform`: pilot.walk(preset=freeform) 을 처리하는지. false 면 highRiskNotAllowed reject.
///   - `speedScaleAccepted`: WalkPayload.speedScale 필드를 **수신 + 실 적용** 하는지.
///     V297-8 부터 Mac WalkLabSession.start(speedScale:) 로 amplitude (cmd.x/y/a) 에
///     실 적용. period 는 보존. iOS 가 이 값을 보면 "전달 + 효과 보장" 으로 해석 가능.
public struct WelcomeCapabilities: Codable, Sendable, Equatable {
    public let head: Bool
    public let walkFreeform: Bool
    public let speedScaleAccepted: Bool
    /// **볼 트래킹 (2026-06-02)**: pilot.ballTrack 명령(로봇 온보드 헤드 추적)을 처리하는지.
    /// false/누락이면 iOS 가 볼트래킹 버튼 숨김 (forward-compat — 옛 클라이언트는 무시).
    public let ballTracking: Bool

    public init(head: Bool = false, walkFreeform: Bool = false,
                speedScaleAccepted: Bool = false, ballTracking: Bool = false) {
        self.head = head
        self.walkFreeform = walkFreeform
        self.speedScaleAccepted = speedScaleAccepted
        self.ballTracking = ballTracking
    }
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

/// 실 robot 자세 텔레메트리 — `cockpit.telemetry` 이벤트 페이로드.
/// iOS `RobotAttitudePayload`(MobilePilotKit)와 필드명·타입이 1:1 일치(JSON 키가 곧 계약).
public struct RobotAttitudePayload: Codable, Sendable, Equatable {
    public let rollDeg: Double          // 실 IMU roll(+우측 기울임)
    public let pitchDeg: Double         // 실 IMU pitch(+전방 숙임)
    public let balanceState: String?    // "normal"/"correcting"
    public let autoRecoveryPhase: String?  // "idle"/"fallen"/"settling"/"gettingUp"/"done"/"failed"
    public let fallDirection: String?   // "forward"/"backward"/nil

    public init(rollDeg: Double, pitchDeg: Double,
                balanceState: String? = nil,
                autoRecoveryPhase: String? = nil,
                fallDirection: String? = nil) {
        self.rollDeg = rollDeg
        self.pitchDeg = pitchDeg
        self.balanceState = balanceState
        self.autoRecoveryPhase = autoRecoveryPhase
        self.fallDirection = fallDirection
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
