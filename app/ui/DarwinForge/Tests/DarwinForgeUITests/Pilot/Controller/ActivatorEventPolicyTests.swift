import XCTest
@testable import DarwinForgeUI

/// `ActivatorType.firesEvent` — 1회성 트리거(E-STOP/복구/볼트랙) 발화 정책.
///
/// `ActivatorState.updated()` 의 (isActive, fired) 출력을 트리거 이벤트로 번역하는
/// 순수 정책. hold = active rising edge 1회, toggle = active 플립마다 1회,
/// start/release/longPress/double = fired 그대로.
final class ActivatorEventPolicyTests: XCTestCase {

    func test_start_follows_fired() {
        XCTAssertTrue(ActivatorType.start.firesEvent(
            previousActive: false, isActive: true, fired: true))
        XCTAssertFalse(ActivatorType.start.firesEvent(
            previousActive: true, isActive: false, fired: false))
    }

    func test_longPress_follows_fired() {
        let t = ActivatorType.longPress(thresholdMs: 500)
        XCTAssertTrue(t.firesEvent(previousActive: false, isActive: true, fired: true))
        // 임계 도달 후 홀드 유지 — active 지속이어도 재발화 없음
        XCTAssertFalse(t.firesEvent(previousActive: true, isActive: true, fired: false))
    }

    func test_hold_fires_on_active_rising_edge_only() {
        XCTAssertTrue(ActivatorType.hold.firesEvent(
            previousActive: false, isActive: true, fired: false))
        XCTAssertFalse(ActivatorType.hold.firesEvent(
            previousActive: true, isActive: true, fired: false), "홀드 유지 중 재발화 금지")
        XCTAssertFalse(ActivatorType.hold.firesEvent(
            previousActive: true, isActive: false, fired: false))
    }

    func test_toggle_fires_on_every_flip() {
        XCTAssertTrue(ActivatorType.toggle.firesEvent(
            previousActive: false, isActive: true, fired: false), "토글 ON")
        XCTAssertTrue(ActivatorType.toggle.firesEvent(
            previousActive: true, isActive: false, fired: false), "토글 OFF")
        XCTAssertFalse(ActivatorType.toggle.firesEvent(
            previousActive: true, isActive: true, fired: false), "유지 중 재발화 금지")
    }
}
