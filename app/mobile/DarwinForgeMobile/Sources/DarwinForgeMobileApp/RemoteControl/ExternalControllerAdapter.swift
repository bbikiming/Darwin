import Foundation
import Observation
import MobilePilotKit

/// External controller adapter — polls the source 30 Hz and routes the
/// normalised state through the bridge as freeform walk frames and edge-
/// triggered safety actions.
///
/// # Mirrors `DJIControllerAdapter` on macOS
///
/// `app/ui/DarwinForge/Sources/DarwinForgeUI/WalkLab/Pilot/DJI/DJIControllerAdapter.swift`
/// uses the same shape (`bridge` + `source` + Timer-driven `pollOnce()`). Both
/// adapters live in the same conceptual tier so the user-facing behaviour is
/// identical regardless of which platform owns the controller link.
///
/// # Polling discipline
///
/// Each `pollOnce()`:
/// 1. Reads `source.snapshot()` once (race-free capture).
/// 2. Refreshes `connectedControllerName` for the UI chip.
/// 3. Processes buttons first — emergency-stop is exclusive (skips stick
///    handling on the same frame so a panic input never races a stick frame).
/// 4. Forwards the sticks to the bridge via `ExternalControllerStickMapper`.
///
/// Repeated centred-stick frames collapse into a single `releaseWalk` so the
/// bridge doesn't see redundant "stop" calls.
@MainActor
public final class ExternalControllerAdapter: ObservableObject {

    // MARK: - Dependencies

    public weak var bridge: RemoteControlBridge?
    private let source: ExternalControllerInputSource

    // MARK: - Observable UI state

    @Published public private(set) var connectedControllerName: String?
    @Published public private(set) var isRunning: Bool = false
    /// Most recent action label — useful for both the UI status chip and tests.
    @Published public private(set) var lastActionLabel: String?

    // MARK: - Tunables

    /// Speed multiplier applied when forwarding sticks to `streamWalk`. The
    /// `RemotePilotScreen` keeps the UI speed tier in sync with this via
    /// `setSpeedScale`.
    public private(set) var speedScale: Double = 1.0

    // MARK: - Internal state

    private var previousButtons: ExternalControllerButtonState = .init()
    private var previousStickWasZero: Bool = true
    private var pollTimer: Timer?

    /// W1b(a) — latest-wins ~10Hz throttle on the moving walk-stream path (above
    /// the ~5Hz robot dispatch). Polling stays 30Hz (button/E-STOP edges must not
    /// be slowed); only the velocity stream is downsampled. The release/stop path
    /// (`processSticks` else-branch) does NOT go through the throttle — it calls
    /// `reset()` + `releaseWalk()` directly, so a stop is never gated.
    private var walkThrottle = WalkFrameThrottle(intervalSeconds: 0.1)
    /// Monotonic clock for the throttle — injectable for deterministic tests.
    /// Non-Sendable + called only on the MainActor-isolated adapter, so a test can
    /// inject a closure over a mutable clock var without a data race.
    private let now: () -> TimeInterval

    // MARK: - Init

    public init(bridge: RemoteControlBridge?,
                source: ExternalControllerInputSource,
                now: @escaping () -> TimeInterval = {
                    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                }) {
        self.bridge = bridge
        self.source = source
        self.now = now
    }

    // MARK: - Lifecycle

    public func start(pollInterval: TimeInterval = 1.0 / 30.0) {
        guard !isRunning else { return }
        isRunning = true
        source.start()
        // Capture name right away so the UI chip flips before the first poll.
        connectedControllerName = source.controllerName

        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollOnce() }
        }
        pollTimer = timer
    }

    public func stop() {
        let shouldRelease = !previousStickWasZero
        if isRunning {
            isRunning = false
            pollTimer?.invalidate()
            pollTimer = nil
            source.stop()
        }
        previousButtons = .init()
        previousStickWasZero = true
        if shouldRelease {
            Task { @MainActor [weak bridge] in
                await bridge?.releaseWalk()
            }
        }
    }

    public func setSpeedScale(_ scale: Double) {
        speedScale = min(max(0.5, scale), 1.5)
    }

    // MARK: - Polling

    /// Test entry point + Timer callback. Reads the source once and routes the
    /// snapshot to the bridge.
    public func pollOnce() {
        guard let bridge else { return }
        let snapshot = source.snapshot()
        connectedControllerName = snapshot.controllerName

        // 1. Buttons first — emergency wins and short-circuits stick handling.
        let emergencyFired = processButtons(snapshot.buttons, bridge: bridge)
        previousButtons = snapshot.buttons
        if emergencyFired { return }

        // 2. Sticks → freeform walk.
        processSticks(snapshot.sticks, bridge: bridge)
    }

    private func processSticks(_ sticks: ExternalControllerStickState,
                               bridge: RemoteControlBridge) {
        let snapshot = ExternalControllerSnapshot(
            controllerName: connectedControllerName,
            sticks: sticks,
            buttons: .init())
        let input = ExternalControllerStickMapper.map(snapshot, speedScale: speedScale)
        if input.isMoving {
            // W1b(a): downsample the moving stream to ~10Hz latest-wins. Within the
            // window the freshest poll wins and intermediates are dropped (not queued).
            if let throttled = walkThrottle.offer(input, now: now()) {
                Task { @MainActor [weak bridge] in
                    await bridge?.streamWalk(throttled)
                }
                lastActionLabel = "stick move"
            }
            previousStickWasZero = false
        } else if !previousStickWasZero {
            // Release re-arms the throttle so the next move emits promptly, and is
            // itself never throttled (stop must not be delayed).
            walkThrottle.reset()
            Task { @MainActor [weak bridge] in
                await bridge?.releaseWalk()
            }
            lastActionLabel = "stick release"
            previousStickWasZero = true
        }
    }

    @discardableResult
    private func processButtons(_ buttons: ExternalControllerButtonState,
                                bridge: RemoteControlBridge) -> Bool {
        // Emergency first — exclusive.
        if buttons.emergencyStop && !previousButtons.emergencyStop {
            Task { @MainActor [weak bridge] in await bridge?.performEStop() }
            lastActionLabel = "emergency stop"
            return true
        }
        if buttons.recover && !previousButtons.recover {
            Task { @MainActor [weak bridge] in await bridge?.performRecover() }
            lastActionLabel = "recover"
        }
        if buttons.stopMotion && !previousButtons.stopMotion {
            Task { @MainActor [weak bridge] in await bridge?.releaseWalk() }
            lastActionLabel = "stop motion"
        }
        // 볼 트래킹 (2026-06-02): X 버튼 엣지 → 로봇 온보드 헤드 추적 on/off 토글.
        if buttons.ballTrackToggle && !previousButtons.ballTrackToggle {
            Task { @MainActor [weak bridge] in await bridge?.toggleBallTracking() }
            lastActionLabel = "ball track toggle"
        }
        return false
    }
}
