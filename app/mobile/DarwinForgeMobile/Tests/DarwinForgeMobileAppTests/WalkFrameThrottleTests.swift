import XCTest
import MobilePilotKit
@testable import DarwinForgeMobileApp

/// W1b(a) — iOS gamepad walk path 30Hz → 10Hz latest-wins throttle.
///
/// Parity with the touch path's `scheduleStream` (RemotePilotScreen.swift:700,
/// 100ms = ~10Hz). The throttle is latest-wins for MOVING frames only; a
/// stop/release (non-moving) frame ALWAYS bypasses so a stop is never delayed
/// or coalesced (safety).
final class WalkFrameThrottleTests: XCTestCase {

    private let moving = WalkFreeformInput(x: 0.5, y: -0.5, turn: 0.2)
    private let stop = WalkFreeformInput.zero

    func test_rapid30HzInput_emitsAtMost10HzLatestWins() {
        var throttle = WalkFrameThrottle(intervalSeconds: 0.1)
        var emitted: [WalkFreeformInput] = []
        // 30 frames across 1.0s (dt = 1/30); each frame's x is distinct so we
        // can prove the emitted frame is the LATEST at its tick, not a queued one.
        for i in 0..<30 {
            let now = Double(i) / 30.0
            let input = WalkFreeformInput(x: Double(i) / 30.0, y: -0.5, turn: 0)
            if let out = throttle.offer(input, now: now) { emitted.append(out) }
        }
        XCTAssertLessThanOrEqual(emitted.count, 11, "≤ ~10 frames over 1s (30→10Hz)")
        XCTAssertGreaterThanOrEqual(emitted.count, 9, "still emits at ~10Hz, not starved")
        XCTAssertEqual(emitted.first?.x ?? -1, 0.0, accuracy: 1e-9,
                       "first moving frame emits promptly at t=0")
        if emitted.count >= 2 {
            // Equality (not lower-bound): the 2nd emit must be EXACTLY the frame at
            // the 100ms boundary (i=3, x=3/30) — proves newest-wins, not a queued
            // intermediate (i=1) nor a future frame.
            XCTAssertEqual(emitted[1].x, 3.0 / 30.0, accuracy: 1e-9,
                "2nd emit is the latest value at the 100ms boundary (intermediates dropped, not queued)")
        }
    }

    func test_stopOrReleaseInput_emitsImmediately_notThrottled() {
        var throttle = WalkFrameThrottle(intervalSeconds: 0.1)
        _ = throttle.offer(moving, now: 0.0)                         // prime the window
        XCTAssertNil(throttle.offer(moving, now: 0.02),
                     "a moving frame within the window is dropped")
        XCTAssertNotNil(throttle.offer(stop, now: 0.03),
                        "a stop/non-moving frame NEVER throttles (safety)")
    }

    func test_idleThenMove_firstMoveEmitsPromptly() {
        var throttle = WalkFrameThrottle(intervalSeconds: 0.1)
        _ = throttle.offer(stop, now: 0.0)                           // release resets the window
        XCTAssertNotNil(throttle.offer(moving, now: 0.01),
                        "first move after idle is not swallowed by the throttle window")
    }
}
