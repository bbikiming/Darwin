import XCTest
import MobilePilotKit
@testable import DarwinForgeMobileApp

/// Adapter behaviour:
/// - Each `pollOnce()` reads the source once and routes the snapshot into the
///   bridge.
/// - A non-centred stick triggers `streamWalk`.
/// - A centred stick after a move triggers exactly one `releaseWalk` (no spam).
/// - Buttons are edge-triggered (1-shot per press).
/// - Emergency stop is exclusive: same frame stick handling is skipped.
@MainActor
final class ExternalControllerAdapterTests: XCTestCase {

    final class SpyBridge: RemoteControlBridge {
        var streamCalls: [WalkFreeformInput] = []
        var releaseCalls: Int = 0
        var eStopCalls: Int = 0
        var recoverCalls: Int = 0
        var ballTrackCalls: Int = 0

        func streamWalk(_ input: WalkFreeformInput) async {
            streamCalls.append(input)
        }
        func releaseWalk() async { releaseCalls += 1 }
        func performEStop() async { eStopCalls += 1 }
        func performRecover() async { recoverCalls += 1 }
        func toggleBallTracking() async { ballTrackCalls += 1 }
    }

    /// A bridge whose `streamWalk` actually SUSPENDS (yields) before recording,
    /// while `releaseWalk` records immediately. With the old design (one unstructured
    /// `Task` per dispatch) the release Task — which never suspends — finishes BEFORE
    /// the still-suspended move Tasks resume, so `.release` lands before `.move`
    /// (the reorder bug). A strictly-serial FIFO channel must await each move to
    /// completion before the release runs, so `.release` is always last.
    final class SuspendingSpyBridge: RemoteControlBridge {
        enum Event: Equatable { case move, release, recover, ballTrack }
        var events: [Event] = []

        func streamWalk(_ input: WalkFreeformInput) async {
            // Suspend a couple of times so an out-of-order release has a window
            // to overtake an in-flight move under a non-serialized dispatcher.
            await Task.yield()
            await Task.yield()
            events.append(.move)
        }
        func releaseWalk() async { events.append(.release) }
        func performEStop() async {}
        func performRecover() async { events.append(.recover) }
        func toggleBallTracking() async { events.append(.ballTrack) }
    }

    private func waitForBridgeTasks() async {
        // Bridge calls drain through the adapter's single serial consumer Task.
        // Yield generously so a small buffer (a held stick can queue ~10 frames)
        // fully drains; all current tests buffer well under this bound.
        for _ in 0..<32 { await Task.yield() }
    }

    /// Cooperatively yield until `condition` holds (or a safety bound is hit), so a
    /// suspending bridge's serial consumer can fully drain without timer-based sleeps.
    private func yieldUntil(_ condition: () -> Bool, max: Int = 5_000) async {
        var i = 0
        while !condition() && i < max {
            await Task.yield()
            i += 1
        }
    }

    // MARK: - Sticks

    func test_centre_stick_does_not_call_bridge() async {
        let bridge = SpyBridge()
        let source = MockExternalController()
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source)
        adapter.pollOnce()
        await waitForBridgeTasks()
        XCTAssertEqual(bridge.streamCalls.count, 0)
        XCTAssertEqual(bridge.releaseCalls, 0)
    }

    func test_stick_forward_streams_walk() async {
        let bridge = SpyBridge()
        let source = MockExternalController()
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source)

        source.setSticks(leftY: +1)  // GameController: up
        adapter.pollOnce()
        await waitForBridgeTasks()

        XCTAssertEqual(bridge.streamCalls.count, 1)
        XCTAssertEqual(bridge.streamCalls.first?.y ?? 0, -1, accuracy: 0.001,
                       "GameController +1 (up) → DSJoystick -1 (forward)")
        XCTAssertTrue(bridge.streamCalls.first?.isMoving ?? false)
    }

    func test_stick_release_after_move_emits_single_release() async {
        let bridge = SpyBridge()
        let source = MockExternalController()
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source)

        source.setSticks(leftY: +1)
        adapter.pollOnce()
        await waitForBridgeTasks()
        source.reset()
        adapter.pollOnce()
        await waitForBridgeTasks()
        adapter.pollOnce()
        await waitForBridgeTasks()

        XCTAssertEqual(bridge.streamCalls.count, 1)
        XCTAssertEqual(bridge.releaseCalls, 1,
                       "release only on the first centred frame after a move — no spam")
    }

    /// W1b(a) — a held stick polled at 30Hz must not emit `streamWalk` faster than
    /// ~10Hz (was up to 30 Task-per-poll). Injected clock drives the throttle window.
    func test_held_stick_does_not_spam_streamWalk_above_10Hz() async {
        let bridge = SpyBridge()
        let source = MockExternalController()
        var clock = 0.0
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source, now: { clock })

        source.setSticks(leftY: +1)   // held forward for the whole window
        for _ in 0..<30 {             // 30 polls across a simulated 1.0s
            adapter.pollOnce()
            clock += 1.0 / 30.0
        }
        await waitForBridgeTasks()

        XCTAssertLessThanOrEqual(bridge.streamCalls.count, 11,
            "30Hz held stick downsampled to ≤~10Hz")
        XCTAssertGreaterThanOrEqual(bridge.streamCalls.count, 9,
            "still streams at ~10Hz, not starved")
    }

    /// W1b(a) SAFETY (e2e): a release that lands INSIDE an open throttle window
    /// (right after a moving emit) must still fire exactly one `releaseWalk`,
    /// un-delayed — the stop path is never gated by the throttle. Injected clock
    /// holds the window open so this exercises the real adapter wiring, not just
    /// the throttle unit.
    func test_stop_within_open_throttle_window_releases_immediately() async {
        let bridge = SpyBridge()
        let source = MockExternalController()
        var clock = 0.0
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source, now: { clock })

        source.setSticks(leftY: +1)   // move → emits at t=0, throttle window now open
        adapter.pollOnce()
        await waitForBridgeTasks()
        XCTAssertEqual(bridge.streamCalls.count, 1)

        clock = 0.02                  // still well inside the 100ms window
        source.reset()                // centre the stick → release
        adapter.pollOnce()
        await waitForBridgeTasks()

        XCTAssertEqual(bridge.releaseCalls, 1,
            "release fires exactly once even inside an open throttle window (stop never gated)")
    }

    /// W1b(a) REORDER FIX (HIGH): rapid moves followed by a release must reach the
    /// bridge strictly FIFO — the release can NEVER be delivered before a still-in-
    /// flight move (which would leave the robot walking until the 500ms heartbeat).
    /// The bridge here genuinely suspends inside `streamWalk`, the exact condition
    /// under which independent unstructured Tasks reorder. Asserts the release is the
    /// LAST event and fires exactly once, with every move ahead of it.
    func test_release_is_delivered_after_in_flight_moves_under_suspending_bridge() async {
        let bridge = SuspendingSpyBridge()
        let source = MockExternalController()
        var clock = 0.0
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source, now: { clock })

        // Five rapid moves — advance the clock well past the 100ms throttle window
        // each poll (a full second, no float-boundary ambiguity) so every move is
        // enqueued (not coalesced), then centre → release.
        for _ in 0..<5 {
            source.setSticks(leftY: +1)
            clock += 1.0
            adapter.pollOnce()
        }
        source.reset()
        adapter.pollOnce()   // release, enqueued immediately after the last move

        // Drain until all six events have landed (5 moves + 1 release).
        await yieldUntil { bridge.events.count >= 6 }

        XCTAssertEqual(bridge.events.last, .release,
            "release must be delivered AFTER its preceding move frames (strict FIFO)")
        XCTAssertEqual(bridge.events.filter { $0 == .release }.count, 1,
            "release fires exactly once")
        let releaseIndex = bridge.events.firstIndex(of: .release)
        XCTAssertEqual(releaseIndex, bridge.events.count - 1,
            "no move is delivered after the release")
        XCTAssertEqual(bridge.events.prefix(5), [.move, .move, .move, .move, .move],
            "all five moves precede the release, in order")
    }

    // MARK: - Buttons

    func test_emergency_stop_button_fires_once_per_press() async {
        let bridge = SpyBridge()
        let source = MockExternalController()
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source)

        source.setButtons(emergencyStop: true)
        adapter.pollOnce()
        await waitForBridgeTasks()
        adapter.pollOnce() // still held
        await waitForBridgeTasks()
        XCTAssertEqual(bridge.eStopCalls, 1, "held button must not spam")

        source.setButtons(emergencyStop: false)
        adapter.pollOnce()
        await waitForBridgeTasks()
        source.setButtons(emergencyStop: true)
        adapter.pollOnce()
        await waitForBridgeTasks()
        XCTAssertEqual(bridge.eStopCalls, 2, "fresh press fires again")
    }

    func test_recover_button_fires_once_per_press() async {
        let bridge = SpyBridge()
        let source = MockExternalController()
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source)
        source.setButtons(recover: true)
        adapter.pollOnce()
        await waitForBridgeTasks()
        adapter.pollOnce()
        await waitForBridgeTasks()
        XCTAssertEqual(bridge.recoverCalls, 1)
    }

    /// 볼 트래킹 (2026-06-02): X 버튼 엣지 → toggleBallTracking 1회 (홀드 spam 금지).
    func test_ballTrack_button_toggles_once_per_press() async {
        let bridge = SpyBridge()
        let source = MockExternalController()
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source)

        source.setButtons(ballTrackToggle: true)
        adapter.pollOnce()
        await waitForBridgeTasks()
        adapter.pollOnce() // still held — must not re-fire
        await waitForBridgeTasks()
        XCTAssertEqual(bridge.ballTrackCalls, 1, "홀드는 1회만")

        source.setButtons(ballTrackToggle: false)
        adapter.pollOnce()
        await waitForBridgeTasks()
        source.setButtons(ballTrackToggle: true)
        adapter.pollOnce()
        await waitForBridgeTasks()
        XCTAssertEqual(bridge.ballTrackCalls, 2, "새 누름은 다시 토글")
    }

    func test_emergency_stop_skips_stick_processing_on_same_frame() async {
        let bridge = SpyBridge()
        let source = MockExternalController()
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source)

        source.setSticks(leftY: +1)
        source.setButtons(emergencyStop: true)
        adapter.pollOnce()
        await waitForBridgeTasks()
        XCTAssertEqual(bridge.eStopCalls, 1)
        XCTAssertEqual(bridge.streamCalls.count, 0,
                       "panic input wins — sticks must not stream on the same frame")
    }

    // MARK: - Lifecycle

    func test_start_stop_propagates_to_source() {
        let bridge = SpyBridge()
        let source = MockExternalController()
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source)
        adapter.start(pollInterval: 1.0) // long interval — we drive pollOnce by hand
        XCTAssertTrue(adapter.isRunning)
        XCTAssertEqual(source.startCalls, 1)
        adapter.stop()
        XCTAssertFalse(adapter.isRunning)
        XCTAssertEqual(source.stopCalls, 1)
    }

    func test_stop_after_active_stick_releases_walk() async {
        let bridge = SpyBridge()
        let source = MockExternalController()
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source)

        adapter.start(pollInterval: 1.0)
        source.setSticks(leftY: +1)
        adapter.pollOnce()
        await waitForBridgeTasks()

        adapter.stop()
        await waitForBridgeTasks()

        XCTAssertEqual(bridge.streamCalls.count, 1)
        XCTAssertEqual(bridge.releaseCalls, 1,
                       "screen/controller teardown must not leave freeform walking active")
    }

    // MARK: - speedScale

    func test_speedScale_is_forwarded_to_input() async {
        let bridge = SpyBridge()
        let source = MockExternalController()
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source)
        adapter.setSpeedScale(1.4)
        source.setSticks(leftY: +1)
        adapter.pollOnce()
        await waitForBridgeTasks()
        XCTAssertEqual(bridge.streamCalls.first?.speedScale ?? 0, 1.4)
    }

    func test_speedScale_is_clamped_to_safe_range() {
        let bridge = SpyBridge()
        let source = MockExternalController()
        let adapter = ExternalControllerAdapter(bridge: bridge, source: source)
        adapter.setSpeedScale(5.0)
        XCTAssertEqual(adapter.speedScale, 1.5, "clamped to upper bound")
        adapter.setSpeedScale(0.1)
        XCTAssertEqual(adapter.speedScale, 0.5, "clamped to lower bound")
    }
}
