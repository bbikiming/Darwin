import Foundation

/// Narrow port that the MobileRelayServer uses to talk to the rest of the
/// macOS app. Real production wiring forwards these calls into
/// `ConnectionStore` / `TeleopChannel` / `WalkLabOnboardBridge`; the test
/// suite uses an in-memory mock so the relay can be exercised without
/// touching the robot or the SwiftUI app state.
///
/// All methods are async and may suspend (network I/O, robot ACK round-trip).
public protocol RobotSafetyPort: AnyObject, Sendable {

    /// Snapshot the current telemetry that the relay should broadcast.
    func snapshot() async -> TelemetryStatePayload

    /// Execute the ARM sequence. Returns ack latency on success, throws on
    /// failure. Implementations are expected to publish `arming.progress`
    /// via the supplied callback.
    func arm(cradleConfirmed: Bool,
             operator: String,
             progress: @Sendable @escaping (String, Double) async -> Void) async throws -> Int

    /// Drop torque + bus and return latency. Should be idempotent.
    func disarm(reason: String) async throws -> Int

    /// Emergency stop. Should call the existing
    /// `ConnectionStore.emergencyStop()` immediately. Returns the round-trip
    /// latency once the safety chain is verified to have shut torque off.
    func emergencyStop(reason: String) async throws -> Int

    /// Execute a single motion slot. Caller has already validated the slot
    /// belongs to the MVP safe list. Returns ack latency.
    func runMotion(slot: Int, label: String, confirmRisk: Bool) async throws -> Int

    /// Send a walk command (preset already mapped). Returns ack latency.
    /// `enabled=false` should map to a stop (X/Y/A move amplitude = 0).
    func sendWalk(payload: WalkPayload) async throws -> (latencyMs: Int, robotAckId: String?)

    /// Send a stop command. Returns ack latency.
    func sendStop(reason: String) async throws -> Int

    /// Apply head pan/tilt (deg) + tracking flag. Returns ack latency.
    /// Implementations may safely no-op if the robot has no head servos
    /// (return latency=0).
    func setHead(payload: HeadPayload) async throws -> Int
}

public extension RobotSafetyPort {
    // Default no-op so existing tests/adapters without head support compile.
    func setHead(payload: HeadPayload) async throws -> Int { return 0 }
}

// MARK: - In-memory mock for tests

public final class InMemorySafetyPort: RobotSafetyPort, @unchecked Sendable {

    public enum Behavior: Sendable {
        case armed
        case rejectNotArmed
        case rejectBusBusy
        case ackTimeout
    }

    private let lock = NSLock()
    private var armed = false
    private var busy = false
    private var robot: RobotState = .connected
    private var endpoint: String? = "tcp://192.168.123.1:5530"
    public var latencyMs: Int = 40
    public var behavior: Behavior = .armed

    public init() {}

    public func setRobotState(_ state: RobotState) {
        lock.lock(); robot = state; lock.unlock()
    }

    public func snapshot() async -> TelemetryStatePayload {
        lock.lock(); defer { lock.unlock() }
        let safety: SafetyTag = armed ? .ready : (robot == .estopped ? .estopped : .ready)
        let ui: PilotUIStateTag = {
            switch robot {
            case .estopped: return .estopped
            case .busBusy: return .robotConnectedLocked
            case .stale: return .staleStop
            case .disconnected: return .macConnectedNoRobot
            case .sim: return .macConnectedNoRobot
            case .connected: return armed ? .armedReady : .robotConnectedLocked
            }
        }()
        return TelemetryStatePayload(
            mac: .connected, robot: robot, endpoint: endpoint,
            armed: armed, dxlPower: armed,
            batteryV: 11.7, maxTempC: 41,
            latencyMs: latencyMs, lastAckAgeMs: nil,
            safety: safety, uiState: ui)
    }

    public func arm(cradleConfirmed: Bool,
                    operator: String,
                    progress: @Sendable @escaping (String, Double) async -> Void) async throws -> Int {
        guard cradleConfirmed else { throw RelayServerError.rejected("cradleRequired") }
        await progress("checkingChecklist", 0.1)
        await progress("enablingPower", 0.4)
        await progress("engagingTorque", 0.7)
        await progress("walkReadyPose", 0.9)
        lock.lock(); armed = true; lock.unlock()
        await progress("armed", 1.0)
        return latencyMs
    }

    public func disarm(reason: String) async throws -> Int {
        lock.lock(); armed = false; lock.unlock()
        return latencyMs
    }

    public func emergencyStop(reason: String) async throws -> Int {
        lock.lock()
        armed = false
        robot = .estopped
        lock.unlock()
        return latencyMs
    }

    public func runMotion(slot: Int, label: String, confirmRisk: Bool) async throws -> Int {
        guard armed else { throw RelayServerError.rejected("notArmed") }
        return latencyMs
    }

    public func sendWalk(payload: WalkPayload) async throws -> (latencyMs: Int, robotAckId: String?) {
        guard armed else { throw RelayServerError.rejected("notArmed") }
        return (latencyMs, "mock-ack-\(payload.preset.rawValue)")
    }

    public func sendStop(reason: String) async throws -> Int {
        return latencyMs
    }
}

public enum RelayServerError: Error, Sendable, Equatable {
    case rejected(String)
    case failed(String)
}
