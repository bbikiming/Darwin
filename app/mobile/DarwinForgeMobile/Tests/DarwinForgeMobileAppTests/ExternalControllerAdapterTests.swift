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

    private func waitForBridgeTasks() async {
        // Bridge calls are dispatched on Tasks. Yield twice to let them run.
        await Task.yield()
        await Task.yield()
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
