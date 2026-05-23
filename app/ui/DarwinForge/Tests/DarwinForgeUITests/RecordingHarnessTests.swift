import XCTest
@testable import DarwinForgeUI

// MARK: - RecordingHarnessTests (Wave 3 Phase 3.1, 사이클 241)
//
// `RecordingHarness` 캡처 동작의 regression guard.
// record / bookmark / flush / heartbeat / start / stop / reset 의 6 책임 검증.

/// 사이클 241 — RecordingHarness 캡처 동작 regression guard.
@MainActor
final class RecordingHarnessTests: XCTestCase {

    // MARK: record() 누적

    func testRecordAccumulatesEvents() {
        let harness = RecordingHarness()
        XCTAssertEqual(harness.events.count, 0)

        harness.record(.connectAttempt, level: .info, actor: .system, data: [:], context: nil)
        harness.record(.connectSuccess, level: .notice, actor: .system, data: [:], context: nil)

        XCTAssertEqual(harness.events.count, 2)
        XCTAssertEqual(harness.events[0].kind, .connectAttempt)
        XCTAssertEqual(harness.events[0].level, .info)
        XCTAssertEqual(harness.events[1].kind, .connectSuccess)
        XCTAssertEqual(harness.events[1].level, .notice)
    }

    // MARK: heartbeat lifecycle

    func testHeartbeatStateTracking() {
        let harness = RecordingHarness()
        XCTAssertFalse(harness.heartbeatActive)
        XCTAssertEqual(harness.heartbeatInterval, 0)

        harness.startHeartbeat(intervalSeconds: 2.0)
        XCTAssertTrue(harness.heartbeatActive)
        XCTAssertEqual(harness.heartbeatInterval, 2.0)

        harness.stopHeartbeat()
        XCTAssertFalse(harness.heartbeatActive)
        // interval 값은 stop 후에도 마지막 값 유지 — reset() 시에만 0 으로 복귀.
        XCTAssertEqual(harness.heartbeatInterval, 2.0)
    }

    // MARK: reset() 전체 초기화 (flush 의 async 처리 포함)

    func testResetClearsAllState() async {
        let harness = RecordingHarness()
        harness.record(.connectAttempt, level: .info, actor: .system, data: [:], context: nil)
        harness.bookmark("test note")
        await harness.flush()
        harness.startHeartbeat(intervalSeconds: 1.0)
        harness.start()
        harness.stop(reason: "user")

        // 모든 상태가 채워졌는지 사전 검증.
        XCTAssertEqual(harness.events.count, 1)
        XCTAssertEqual(harness.bookmarks.count, 1)
        XCTAssertEqual(harness.flushCount, 1)
        XCTAssertTrue(harness.heartbeatActive)
        XCTAssertEqual(harness.startCount, 1)
        XCTAssertEqual(harness.stopReasons, ["user"])

        harness.reset()

        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertTrue(harness.bookmarks.isEmpty)
        XCTAssertEqual(harness.flushCount, 0)
        XCTAssertFalse(harness.heartbeatActive)
        XCTAssertEqual(harness.heartbeatInterval, 0)
        XCTAssertFalse(harness.contextProviderRegistered)
        XCTAssertEqual(harness.startCount, 0)
        XCTAssertTrue(harness.stopReasons.isEmpty)
    }
}
