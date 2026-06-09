import XCTest
@testable import DarwinForgeUI

/// `VirtualControllerSource` — 온스크린 패드가 구동하는 소스.
@MainActor
final class VirtualControllerSourceTests: XCTestCase {

    func test_default_is_neutral_and_connected() {
        let s = VirtualControllerSource()
        XCTAssertEqual(s.snapshot, .neutral)
        XCTAssertTrue(s.isConnected)
        XCTAssertEqual(s.deviceKey, "gc.xbox")
    }

    func test_setAxis_updates_snapshot_and_clamps() {
        let s = VirtualControllerSource()
        s.setAxis(1, -0.5)
        XCTAssertEqual(s.snapshot.axis(1), -0.5, accuracy: 1e-9)
        s.setAxis(1, -3.0) // clamp
        XCTAssertEqual(s.snapshot.axis(1), -1.0, accuracy: 1e-9)
        s.setAxis(99, 1.0) // out of range no-op
        XCTAssertEqual(s.axes.count, ControllerSnapshot.standardAxisCount)
    }

    func test_setButton_updates_snapshot() {
        let s = VirtualControllerSource()
        s.setButton(1, true)
        XCTAssertTrue(s.snapshot.button(1))
        s.setButton(1, false)
        XCTAssertFalse(s.snapshot.button(1))
    }

    func test_resetAll_returns_to_neutral() {
        let s = VirtualControllerSource()
        s.setAxis(0, 0.9); s.setButton(2, true)
        s.resetAll()
        XCTAssertEqual(s.snapshot, .neutral)
    }

    func test_capture_nil_when_disconnected() {
        let s = VirtualControllerSource()
        s.setConnected(false)
        XCTAssertNil(s.capture())
    }

    func test_drives_cockpit_through_driver() {
        let state = CockpitState()
        let s = VirtualControllerSource()
        let driver = CockpitControllerDriver(state: state, source: s, profile: .xbox)
        // LS Y 위(전진) — 가상 패드가 axis 1 을 음수로.
        // .xbox 는 deadmanEnabled=true(버튼4=LB) — 데드맨 홀드(래치)를 함께 입력.
        s.setAxis(1, -0.8)
        s.setButton(4, true)
        driver.tick()
        XCTAssertLessThan(state.leftStick.y, 0.0, "가상 패드 전진 → cockpit 주입")
        XCTAssertEqual(state.lastSource, .gamepad)
    }
}
