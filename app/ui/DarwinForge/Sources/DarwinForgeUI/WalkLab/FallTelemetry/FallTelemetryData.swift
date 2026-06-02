import Foundation

// MARK: - Fall Telemetry Schemas
//
// JSONL format mirroring CockpitPilotRecorder / WalkSessionLogger patterns.
// All fields are backward-compatible optional where applicable.
// Directory: ~/Library/Application Support/DarwinForge/FallEvents/<sessionId>/

/// Manifest written as the first line in fall-<ISO>.jsonl.
/// Identifies the session, thresholds, and app context for post-analysis.
public struct FallTelemetryManifest: Codable, Sendable {
    public let sessionId: String
    /// ISO 8601 wall-clock at the moment of fall detection.
    public let startedAtISO: String
    public let appVersion: String
    /// Robot model string (e.g. "darwin-op2"). nil = not yet identified.
    public let robotModel: String?
    /// Thresholds active when this event was recorded (mirrors AutoFallRecovery constants).
    public let thresholds: FallThresholds

    public struct FallThresholds: Codable, Sendable {
        public let fallenThresholdDeg: Double
        public let settleGyroDps: Double
    }

    public init(
        sessionId: String,
        startedAtISO: String,
        appVersion: String,
        robotModel: String? = nil,
        thresholds: FallThresholds
    ) {
        self.sessionId = sessionId
        self.startedAtISO = startedAtISO
        self.appVersion = appVersion
        self.robotModel = robotModel
        self.thresholds = thresholds
    }
}

/// One high-density sensor sample captured at ~10 Hz during the fall window.
///
/// Rate: tied to the WalkLab tick cadence (10 Hz after v1.14.8 perf #2 change to 100ms).
/// Ring buffer holds ~150 samples = ~15 s pre-fall + recovery window.
public struct FallTelemetrySample: Codable, Sendable {
    /// Milliseconds since session start (matches WalkSessionSample.t field for alignment).
    public let tMs: Double
    /// IMU roll (degrees).
    public let imuRollDeg: Double
    /// IMU pitch (degrees).
    public let imuPitchDeg: Double
    /// Gyro X rate (dps).
    public let gyroXDps: Double
    /// Gyro Y rate (dps).
    public let gyroYDps: Double
    /// Gyro Z rate (dps).
    public let gyroZDps: Double
    /// Accel X (g).
    public let accelXG: Double
    /// Accel Y (g).
    public let accelYG: Double
    /// Accel Z (g).
    public let accelZG: Double
    /// Balance state rawValue string (normal/caution/warning/danger/emergency).
    public let balanceState: String
    /// Auto-recovery phase rawValue string at this tick.
    public let autoRecoveryPhase: String
    /// Per-joint load (Dynamixel raw UInt16 as Double). nil = telemetry not received this tick.
    public let perJointLoad: [String: Double]?
    /// Per-joint temperature (°C as Double). nil = telemetry not received this tick.
    public let perJointTemp: [String: Double]?
    /// Walking stride command (mm) at this tick. nil = no active walk command.
    public let cmdStrideMm: Double?
    /// Walking side command (mm).
    public let cmdSideMm: Double?
    /// Walking turn command (deg).
    public let cmdTurnDeg: Double?
    /// Head pan servo position (deg). nil = head not tracked.
    public let headPanDeg: Double?
    /// Head tilt servo position (deg).
    public let headTiltDeg: Double?

    public init(
        tMs: Double,
        imuRollDeg: Double,
        imuPitchDeg: Double,
        gyroXDps: Double,
        gyroYDps: Double,
        gyroZDps: Double,
        accelXG: Double,
        accelYG: Double,
        accelZG: Double,
        balanceState: String,
        autoRecoveryPhase: String,
        perJointLoad: [String: Double]? = nil,
        perJointTemp: [String: Double]? = nil,
        cmdStrideMm: Double? = nil,
        cmdSideMm: Double? = nil,
        cmdTurnDeg: Double? = nil,
        headPanDeg: Double? = nil,
        headTiltDeg: Double? = nil
    ) {
        self.tMs = tMs
        self.imuRollDeg = imuRollDeg
        self.imuPitchDeg = imuPitchDeg
        self.gyroXDps = gyroXDps
        self.gyroYDps = gyroYDps
        self.gyroZDps = gyroZDps
        self.accelXG = accelXG
        self.accelYG = accelYG
        self.accelZG = accelZG
        self.balanceState = balanceState
        self.autoRecoveryPhase = autoRecoveryPhase
        self.perJointLoad = perJointLoad
        self.perJointTemp = perJointTemp
        self.cmdStrideMm = cmdStrideMm
        self.cmdSideMm = cmdSideMm
        self.cmdTurnDeg = cmdTurnDeg
        self.headPanDeg = headPanDeg
        self.headTiltDeg = headTiltDeg
    }
}

/// Outcome record written as the last line of fall-<ISO>.jsonl after recovery completes.
public struct FallTelemetryOutcome: Codable, Sendable {
    /// JSONL line type marker — "fall_outcome".
    public let type: String
    /// Fall direction ("forward" / "backward").
    public let direction: String
    /// ROBOTIS get-up page used (10=forward, 11=backward).
    public let getUpPage: UInt8
    /// Time from fall detection to gyro settling below threshold (ms).
    public let settleMs: Double
    /// Number of get-up motion attempts.
    public let attempts: Int
    /// True = recovery reached .done (robot upright).
    public let success: Bool
    /// Total time from fall detection to .done/.failed (ms).
    public let recoveryTotalMs: Double
    /// Peak leg-joint load (Dynamixel raw) observed during recovery. nil = no data.
    public let peakLegLoad: Double?

    public init(
        direction: String,
        getUpPage: UInt8,
        settleMs: Double,
        attempts: Int,
        success: Bool,
        recoveryTotalMs: Double,
        peakLegLoad: Double? = nil
    ) {
        self.type = "fall_outcome"
        self.direction = direction
        self.getUpPage = getUpPage
        self.settleMs = settleMs
        self.attempts = attempts
        self.success = success
        self.recoveryTotalMs = recoveryTotalMs
        self.peakLegLoad = peakLegLoad
    }
}
