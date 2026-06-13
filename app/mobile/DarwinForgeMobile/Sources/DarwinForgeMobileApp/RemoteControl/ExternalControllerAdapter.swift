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
    /// `reset()` and enqueues `releaseWalk` un-gated, so a stop is never throttled
    /// (it is still FIFO-ordered behind its preceding moves via the command channel).
    private var walkThrottle = WalkFrameThrottle(intervalSeconds: 0.1)
    /// Monotonic clock for the throttle — injectable for deterministic tests.
    /// Non-Sendable + called only on the MainActor-isolated adapter, so a test can
    /// inject a closure over a mutable clock var without a data race.
    private let now: () -> TimeInterval

    // MARK: - Serial bridge dispatch (W1b(a) reorder fix)

    /// One serialized command the adapter forwards to the bridge. E-STOP is *not*
    /// modelled here — it keeps its own immediate path (panic input must never queue
    /// behind walk frames).
    private enum BridgeCommand: Sendable {
        case streamWalk(WalkFreeformInput)
        case releaseWalk
        case recover
        case toggleBallTracking
    }

    /// FIFO channel for every non-E-STOP bridge call. Each dispatch was previously an
    /// independent unstructured `Task { await bridge.… }`; because those Tasks are not
    /// serialized, under `await` suspension *inside* the bridge their delivery order is
    /// not guaranteed to match enqueue order — a `releaseWalk` could overtake a still-
    /// in-flight final `streamWalk`, leaving the robot walking after the user centred
    /// the stick (until the 500ms heartbeat watchdog catches it). The ~10Hz throttle
    /// widened that window by making the moving stream sparse while releases stayed
    /// immediate. Routing every dispatch through one channel drained by a single long-
    /// lived consumer makes frames reach the bridge strictly in enqueue order, so a
    /// release always follows its preceding move frames.
    private let commandContinuation: AsyncStream<BridgeCommand>.Continuation
    /// The single consumer draining `commandContinuation` in order. Lives for the whole
    /// adapter lifetime (independent of start/stop) so start→stop→start re-uses it.
    private var commandConsumer: Task<Void, Never>?

    // MARK: - Init

    public init(bridge: RemoteControlBridge?,
                source: ExternalControllerInputSource,
                now: @escaping () -> TimeInterval = {
                    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                }) {
        self.bridge = bridge
        self.source = source
        self.now = now

        // Unbounded FIFO so a release is never dropped by a buffering policy; the
        // ~10Hz throttle already bounds the moving-frame rate and `streamWalk` is
        // fire-and-forget on the bridge, so the buffer stays shallow in practice.
        let (stream, continuation) = AsyncStream<BridgeCommand>.makeStream()
        self.commandContinuation = continuation
        self.commandConsumer = nil   // finish stored-property init before capturing self

        self.commandConsumer = Task { @MainActor [weak self] in
            for await command in stream {
                await self?.dispatch(command)
            }
        }
    }

    deinit {
        commandContinuation.finish()   // ends the for-await loop → consumer completes
        commandConsumer?.cancel()
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
            // Through the serial channel so this teardown release still follows any
            // frames already queued ahead of it (and re-arm the throttle).
            walkThrottle.reset()
            enqueue(.releaseWalk)
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
        processSticks(snapshot.sticks)
    }

    private func processSticks(_ sticks: ExternalControllerStickState) {
        let snapshot = ExternalControllerSnapshot(
            controllerName: connectedControllerName,
            sticks: sticks,
            buttons: .init())
        let input = ExternalControllerStickMapper.map(snapshot, speedScale: speedScale)
        if input.isMoving {
            // W1b(a): downsample the moving stream to ~10Hz latest-wins. Within the
            // window the freshest poll wins and intermediates are dropped (not queued).
            if let throttled = walkThrottle.offer(input, now: now()) {
                enqueue(.streamWalk(throttled))
                lastActionLabel = "stick move"
            }
            previousStickWasZero = false
        } else if !previousStickWasZero {
            // Release re-arms the throttle so the next move emits promptly, and is
            // itself never throttled (stop must not be delayed). It enters the SAME
            // FIFO channel as the moves, so it is always delivered after them.
            walkThrottle.reset()
            enqueue(.releaseWalk)
            lastActionLabel = "stick release"
            previousStickWasZero = true
        }
    }

    @discardableResult
    private func processButtons(_ buttons: ExternalControllerButtonState,
                                bridge: RemoteControlBridge) -> Bool {
        // Emergency first — exclusive. E-STOP keeps its own IMMEDIATE path (never the
        // FIFO channel) so a panic input can never queue behind walk frames. The Mac
        // side disarms on E-STOP, so any move still draining the channel afterwards is
        // a no-op (`streamWalk` early-returns when not armed).
        if buttons.emergencyStop && !previousButtons.emergencyStop {
            Task { @MainActor [weak bridge] in await bridge?.performEStop() }
            lastActionLabel = "emergency stop"
            return true
        }
        if buttons.recover && !previousButtons.recover {
            enqueue(.recover)
            lastActionLabel = "recover"
        }
        if buttons.stopMotion && !previousButtons.stopMotion {
            enqueue(.releaseWalk)
            lastActionLabel = "stop motion"
        }
        // 볼 트래킹 (2026-06-02): X 버튼 엣지 → 로봇 온보드 헤드 추적 on/off 토글.
        if buttons.ballTrackToggle && !previousButtons.ballTrackToggle {
            enqueue(.toggleBallTracking)
            lastActionLabel = "ball track toggle"
        }
        return false
    }

    // MARK: - Serial dispatch plumbing

    /// Enqueue a command for the single FIFO consumer. Unbounded, so nothing is
    /// dropped; ordering is enqueue order.
    private func enqueue(_ command: BridgeCommand) {
        commandContinuation.yield(command)
    }

    /// Runs on the consumer Task, one command at a time. Reads `bridge` weakly at
    /// execution (same nil-if-gone semantics as the old `[weak bridge]` capture) and
    /// awaits each call to completion before the next command is pulled.
    private func dispatch(_ command: BridgeCommand) async {
        guard let bridge else { return }
        switch command {
        case .streamWalk(let input): await bridge.streamWalk(input)
        case .releaseWalk:           await bridge.releaseWalk()
        case .recover:               await bridge.performRecover()
        case .toggleBallTracking:    await bridge.toggleBallTracking()
        }
    }
}
