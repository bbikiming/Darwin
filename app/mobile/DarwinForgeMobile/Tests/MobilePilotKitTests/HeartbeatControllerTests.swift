import XCTest
@testable import MobilePilotKit

final class HeartbeatControllerTests: XCTestCase {

    func testHeartbeatSendsWhileActive() async throws {
        let counter = Counter()
        let hb = HeartbeatController(
            intervalMs: 20,
            send: { _ in await counter.bump() },
            onStop: { _ in })
        await hb.start(uiState: .commandActive, activeCommandId: "cmd_walk")
        try await Task.sleep(nanoseconds: 120_000_000)
        await hb.stop(sendStop: false, reason: .user)
        let total = await counter.value
        XCTAssertGreaterThanOrEqual(total, 3,
                                    "Heartbeat should fire repeatedly while active (got \(total))")
    }

    func testHeartbeatStopsOnStop() async throws {
        let counter = Counter()
        let stopCalls = Counter()
        let hb = HeartbeatController(
            intervalMs: 20,
            send: { _ in await counter.bump() },
            onStop: { _ in await stopCalls.bump() })
        await hb.start(uiState: .commandActive, activeCommandId: "cmd_x")
        try await Task.sleep(nanoseconds: 80_000_000)
        await hb.stop(sendStop: true, reason: .deadmanRelease)
        let before = await counter.value
        try await Task.sleep(nanoseconds: 80_000_000)
        let after = await counter.value
        XCTAssertEqual(before, after, "Heartbeat should not continue after stop")
        let stops = await stopCalls.value
        XCTAssertEqual(stops, 1)
    }

    func testWatchdogPolicy() {
        let policy = WatchdogPolicy()
        XCTAssertFalse(policy.shouldStop(lastHeartbeatAgeMs: 200))
        XCTAssertTrue(policy.shouldStop(lastHeartbeatAgeMs: 500))
        XCTAssertFalse(policy.shouldDisarm(lastHeartbeatAgeMs: 800))
        XCTAssertTrue(policy.shouldDisarm(lastHeartbeatAgeMs: 2500))
    }
}

actor Counter {
    var value: Int = 0
    func bump() { value += 1 }
}
