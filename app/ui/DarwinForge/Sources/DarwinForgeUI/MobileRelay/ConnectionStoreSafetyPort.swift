import Foundation

/// Production adapter that wires `MobileRelayServer` into the existing
/// macOS app surface. Bridges between the wire-protocol enums (defined in
/// `MobileRelayCommand.swift`) and the live `ConnectionStore` +
/// `TeleopChannel` + `WalkLabOnboardBridge` APIs.
///
/// This adapter intentionally takes the live MainActor types via closures so
/// that the relay server can stay actor-isolated and call back into the UI
/// store without leaking @MainActor through the protocol. All real I/O
/// (torque on/off, walking line publishing) happens on @MainActor.
@MainActor
public final class ConnectionStoreSafetyPort: RobotSafetyPort {

    public struct Hooks {
        /// `() async -> Bool` — performs `TeleopChannel.arm()` and returns whether it succeeded.
        public var armAsync: @MainActor () async -> Bool
        /// `() -> Void` — `TeleopChannel.disarm()` synchronously.
        public var disarmSync: @MainActor () -> Void
        /// `() -> Void` — `ConnectionStore.emergencyStop()` synchronously.
        public var emergencyStopSync: @MainActor () -> Void
        /// `(UInt8, Bool) async -> Bool` — `TeleopChannel.sendMotion(slot:confirmRisk:)`.
        public var sendMotion: @MainActor (UInt8, Bool) async -> Bool
        /// `(WalkPayload) async throws -> Bool` — translates a walk payload into an
        /// existing WalkLab onboard brokering call (returns true on ACK).
        /// Throw `RelayServerError.rejected(reason)` to send `command.rejected` to iOS.
        /// Throw `RelayServerError.failed(reason)` or generic error for `command.failed`.
        public var sendWalk: @MainActor (WalkPayload) async throws -> Bool
        /// `(String) async -> Bool` — stop active walking (X/Y/A move amplitude = 0).
        public var sendStop: @MainActor (String) async -> Bool
        /// `() async -> TelemetryStatePayload` — build a telemetry snapshot from live state.
        public var snapshot: @MainActor () async -> TelemetryStatePayload

        public init(armAsync: @escaping @MainActor () async -> Bool,
                    disarmSync: @escaping @MainActor () -> Void,
                    emergencyStopSync: @escaping @MainActor () -> Void,
                    sendMotion: @escaping @MainActor (UInt8, Bool) async -> Bool,
                    sendWalk: @escaping @MainActor (WalkPayload) async throws -> Bool,
                    sendStop: @escaping @MainActor (String) async -> Bool,
                    snapshot: @escaping @MainActor () async -> TelemetryStatePayload) {
            self.armAsync = armAsync
            self.disarmSync = disarmSync
            self.emergencyStopSync = emergencyStopSync
            self.sendMotion = sendMotion
            self.sendWalk = sendWalk
            self.sendStop = sendStop
            self.snapshot = snapshot
        }
    }

    private let hooks: Hooks

    public init(hooks: Hooks) { self.hooks = hooks }

    // MARK: - RobotSafetyPort

    public nonisolated func snapshot() async -> TelemetryStatePayload {
        await MainActor.run { /* peel into MainActor */ }
        return await hooks.snapshot()
    }

    public nonisolated func arm(cradleConfirmed: Bool,
                                operator: String,
                                progress: @Sendable @escaping (String, Double) async -> Void) async throws -> Int {
        guard cradleConfirmed else { throw RelayServerError.rejected("cradleRequired") }
        await progress("checkingChecklist", 0.1)
        await progress("enablingPower", 0.4)
        let start = Date()
        let ok = await hooks.armAsync()
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if !ok {
            await progress("failed", 1.0)
            throw RelayServerError.rejected("armFailed")
        }
        await progress("walkReadyPose", 0.9)
        await progress("armed", 1.0)
        return elapsed
    }

    public nonisolated func disarm(reason: String) async throws -> Int {
        let start = Date()
        await hooks.disarmSync()
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    public nonisolated func emergencyStop(reason: String) async throws -> Int {
        let start = Date()
        await hooks.emergencyStopSync()
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    public nonisolated func runMotion(slot: Int, label: String, confirmRisk: Bool) async throws -> Int {
        guard let slot8 = UInt8(exactly: slot) else {
            throw RelayServerError.rejected("invalidSlot")
        }
        let start = Date()
        let ok = await hooks.sendMotion(slot8, confirmRisk)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if !ok { throw RelayServerError.rejected("notArmed") }
        return elapsed
    }

    public nonisolated func sendWalk(payload: WalkPayload) async throws -> (latencyMs: Int, robotAckId: String?) {
        let start = Date()
        // Propagate RelayServerError.rejected / .failed from the hook directly.
        let ok = try await hooks.sendWalk(payload)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if !ok { throw RelayServerError.failed("noAck") }
        return (elapsed, nil)
    }

    public nonisolated func sendStop(reason: String) async throws -> Int {
        let start = Date()
        let ok = await hooks.sendStop(reason)
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        if !ok { throw RelayServerError.failed("stopFailed") }
        return elapsed
    }

    public nonisolated func setHead(payload: HeadPayload) async throws -> Int {
        throw RelayServerError.rejected("headUnsupportedInMVP")
    }
}

// MARK: - Convenience: produce a TelemetryStatePayload from common Mac state

public enum MobileRelayTelemetryFactory {

    public static func make(macConnected: Bool,
                            robotConnected: Bool,
                            armed: Bool,
                            dxlPower: Bool,
                            busBusy: Bool,
                            endpoint: String?,
                            batteryV: Double?,
                            maxTempC: Double?,
                            latencyMs: Int,
                            lastAckAgeMs: Int?,
                            estopActive: Bool) -> TelemetryStatePayload {
        let mac: MacState = macConnected ? .connected : .lost
        let robot: RobotState = {
            if estopActive { return .estopped }
            if busBusy { return .busBusy }
            if !macConnected { return .disconnected }
            if !robotConnected { return .sim }
            if let age = lastAckAgeMs, age > 1500 { return .stale }
            return .connected
        }()
        let safety: SafetyTag = {
            if estopActive { return .estopped }
            if armed { return .ready }
            return .ready
        }()
        let uiState: PilotUIStateTag = {
            if estopActive { return .estopped }
            if !macConnected { return .notPaired }
            switch robot {
            case .busBusy: return .robotConnectedLocked
            case .stale: return .staleStop
            case .disconnected, .sim: return .macConnectedNoRobot
            case .connected: return armed ? .armedReady : .robotConnectedLocked
            case .estopped: return .estopped
            }
        }()
        return TelemetryStatePayload(
            mac: mac, robot: robot, endpoint: endpoint,
            armed: armed, dxlPower: dxlPower,
            batteryV: batteryV, maxTempC: maxTempC,
            latencyMs: latencyMs, lastAckAgeMs: lastAckAgeMs,
            safety: safety, uiState: uiState)
    }
}
