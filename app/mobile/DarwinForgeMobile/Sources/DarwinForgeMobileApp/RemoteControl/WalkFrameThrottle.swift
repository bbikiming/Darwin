import Foundation
import MobilePilotKit

/// Latest-wins time throttle for freeform walk frames (W1b(a)).
///
/// 비유: 1초에 열 번만 우표를 찍어주는 우체국 창구. 그 사이 들어온 편지(중간
/// 스틱 프레임)는 *큐에 쌓지 않고* 버리고, 창구가 열리는 순간 책상 위 **가장 최신**
/// 편지 하나만 보낸다. 단, "정지(stop)" 우편은 줄을 서지 않고 즉시 통과한다.
///
/// The iOS gamepad adapter polls at 30Hz; forwarding every poll spams the relay
/// (and the Mac→robot wire) at 3× the useful rate while building a stale-stick
/// backlog. This throttles the MOVING path to ~10Hz latest-wins — parity with the
/// touch path's `scheduleStream` (100ms). A non-moving (stop/release) frame ALWAYS
/// bypasses so a stop is never delayed or coalesced away (safety).
///
/// Pure value type, injected clock → fully host-testable with no timers.
public struct WalkFrameThrottle: Sendable {

    /// Minimum spacing between emitted moving frames (default 100ms = ~10Hz).
    public let intervalSeconds: TimeInterval

    /// Time (in the caller's clock domain) of the last emitted moving frame.
    /// `nil` = window is "ready" (never emitted, or just reset by a stop) so the
    /// next moving frame emits immediately.
    private var lastEmit: TimeInterval?

    public init(intervalSeconds: TimeInterval = 0.1) {
        self.intervalSeconds = max(0, intervalSeconds)
    }

    /// Offer a frame at time `now`. Returns the frame to emit, or `nil` to drop it.
    ///
    /// - Non-moving (stop/release): always returns the frame AND resets the window
    ///   so the next move emits promptly — a stop is never throttled.
    /// - Moving within the window: returns `nil` (dropped; the newest later frame
    ///   wins — this is latest-wins because the caller always offers its freshest
    ///   value each poll).
    /// - Moving at/after the window boundary: emits and re-arms the window.
    public mutating func offer(_ input: WalkFreeformInput, now: TimeInterval) -> WalkFreeformInput? {
        guard input.isMoving else {
            lastEmit = nil            // stop/release → window ready for next move
            return input              // never throttle a stop
        }
        if let last = lastEmit, now - last < intervalSeconds {
            return nil                // within window → drop (latest-wins)
        }
        lastEmit = now
        return input
    }

    /// Re-arm the window so the next moving frame emits immediately (called when
    /// the adapter takes the release branch outside `offer`).
    public mutating func reset() {
        lastEmit = nil
    }
}
