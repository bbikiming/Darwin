import XCTest
@testable import DarwinForgeUI

/// `MockControllerSource` 동작 검증 — 결정론적 테스트 더블.
@MainActor
final class MockControllerSourceTests: XCTestCase {

    func test_capture_returns_current_snapshot_when_queue_empty() {
        let src = MockControllerSource(snapshot: .neutral)
        let s = ControllerSnapshot(axes: [0.3], buttons: [])
        src.snapshot = s
        XCTAssertEqual(src.capture(), s)
        XCTAssertEqual(src.capture(), s, "큐 비면 current 유지")
    }

    func test_capture_consumes_queue_fifo() {
        let src = MockControllerSource()
        let a = ControllerSnapshot(axes: [0.1], buttons: [])
        let b = ControllerSnapshot(axes: [0.2], buttons: [])
        src.enqueue(a, b)
        XCTAssertEqual(src.capture(), a)
        XCTAssertEqual(src.capture(), b)
        XCTAssertEqual(src.capture(), src.snapshot, "큐 소진 후 current")
    }

    func test_capture_nil_when_disconnected() {
        let src = MockControllerSource(isConnected: false)
        XCTAssertNil(src.capture())
    }

    func test_setConnected_fires_callback_on_change_only() {
        let src = MockControllerSource(isConnected: true)
        var events: [Bool] = []
        src.onConnectionChange = { events.append($0) }
        src.setConnected(true)   // 변화 없음 → no fire
        src.setConnected(false)  // fire false
        src.setConnected(false)  // 변화 없음
        src.setConnected(true)   // fire true
        XCTAssertEqual(events, [false, true])
    }
}
