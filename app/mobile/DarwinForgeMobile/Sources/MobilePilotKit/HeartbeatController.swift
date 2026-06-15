import Foundation

/// Drives the 100ms heartbeat send loop while the iOS UI is in an active
/// control state, and triggers a stop callback when the loop stops (touch
/// release, app background, navigation, or explicit cancel).
public actor HeartbeatController {

    public typealias Send = @Sendable (HeartbeatPayload) async -> Void
    public typealias OnStop = @Sendable (StopReason) async -> Void

    private let intervalMs: Int
    private let clock: PilotClock
    private let send: Send
    private let onStop: OnStop
    private var task: Task<Void, Never>?
    private var currentState: UIStateTag = .idle
    private var activeCommandId: String?

    public init(intervalMs: Int = MobileRelayProtocol.heartbeatIntervalMs,
                clock: PilotClock = LiveClock(),
                send: @escaping Send,
                onStop: @escaping OnStop) {
        self.intervalMs = intervalMs
        self.clock = clock
        self.send = send
        self.onStop = onStop
    }

    public func start(uiState: UIStateTag, activeCommandId: String?) async {
        await stop(sendStop: false, reason: .user)
        currentState = uiState
        self.activeCommandId = activeCommandId
        task = Task { [intervalMs, clock] in
            while !Task.isCancelled {
                let state = await self.currentState
                let id = await self.activeCommandId
                guard state == .commandActive || state == .estopping else { break }
                await self.send(HeartbeatPayload(uiState: state, activeCommandId: id))
                await clock.sleep(milliseconds: intervalMs)
            }
        }
    }

    public func update(uiState: UIStateTag, activeCommandId: String?) {
        self.currentState = uiState
        self.activeCommandId = activeCommandId
    }

    public func stop(sendStop: Bool, reason: StopReason) async {
        task?.cancel()
        task = nil
        currentState = .idle
        let savedId = activeCommandId
        activeCommandId = nil
        if sendStop {
            await onStop(reason)
            _ = savedId
        }
    }

    public var isRunning: Bool { task != nil }
}

// MARK: - Watchdog policy (server-side reference; iOS uses this for tests)

public struct WatchdogPolicy: Sendable {
    public let intervalMs: Int
    public let timeoutMs: Int

    public init(intervalMs: Int = MobileRelayProtocol.heartbeatIntervalMs,
                timeoutMs: Int = MobileRelayProtocol.watchdogTimeoutMs) {
        self.intervalMs = intervalMs
        self.timeoutMs = timeoutMs
    }

    public func shouldStop(lastHeartbeatAgeMs: Int) -> Bool {
        lastHeartbeatAgeMs >= timeoutMs
    }

    public func shouldDisarm(lastHeartbeatAgeMs: Int) -> Bool {
        lastHeartbeatAgeMs >= timeoutMs * 4
    }
}
