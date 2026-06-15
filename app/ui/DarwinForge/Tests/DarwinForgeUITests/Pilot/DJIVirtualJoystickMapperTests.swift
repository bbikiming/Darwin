import XCTest
@testable import DarwinForgeUI

/// `DJIVirtualJoystickMapper.map(_:inversion:)` 의 결정론 검증.
///
/// 부호 컨벤션 (cockpit ↔ DJI HID) 의 핵심을 고정하므로, 향후 cockpit 또는 HID
/// 디스크립터가 바뀌더라도 의도된 매핑이 회귀 없이 유지됨을 보장한다.
final class DJIVirtualJoystickMapperTests: XCTestCase {

    private func make(x: Double = 0, y: Double = 0, z: Double = 0,
                      rx: Double = 0, ry: Double = 0,
                      buttons: [Bool] = Array(repeating: false, count: 24))
                      -> DJIVirtualJoystickReport {
        DJIVirtualJoystickReport(
            axisX: x, axisY: y, axisZ: z,
            axisRx: rx, axisRy: ry, buttons: buttons)
    }

    // MARK: - Default DJI inversion (forward + turn flipped)

    func test_right_stick_forward_with_default_inversion_yields_negative_leftY() {
        // DJI Mode 2: 우 스틱 위 = pitch forward = Ry +1.
        // cockpit leftY 컨벤션: -1 = forward → invertForward=true 이 default.
        let r = make(ry: 1.0)
        let s = DJIVirtualJoystickMapper.map(r)
        XCTAssertEqual(s.leftY, -1.0, accuracy: 0.0001)
        XCTAssertEqual(s.leftX, 0.0,  accuracy: 0.0001)
        XCTAssertEqual(s.turn,  0.0,  accuracy: 0.0001)
    }

    func test_right_stick_right_with_default_inversion_yields_positive_leftX() {
        // DJI Mode 2: 우 스틱 오른쪽 = roll right = Rx +1.
        // cockpit leftX 컨벤션: +1 = right → invertLateral=false 이 default.
        let r = make(rx: 1.0)
        let s = DJIVirtualJoystickMapper.map(r)
        XCTAssertEqual(s.leftX, 1.0, accuracy: 0.0001)
    }

    func test_left_stick_right_yaw_with_default_inversion_yields_negative_turn() {
        // DJI Mode 2: 좌 스틱 오른쪽 = yaw right = X +1.
        // cockpit turn 컨벤션: +1 = 좌회전 → invertTurn=true 가 default.
        let r = make(x: 1.0)
        let s = DJIVirtualJoystickMapper.map(r)
        XCTAssertEqual(s.turn, -1.0, accuracy: 0.0001)
    }

    func test_neutral_report_yields_all_zero() {
        let s = DJIVirtualJoystickMapper.map(make())
        XCTAssertEqual(s, .zero)
    }

    // MARK: - Inversion toggles

    func test_disabling_forward_inversion_flips_sign() {
        let r = make(ry: 1.0)
        let s = DJIVirtualJoystickMapper.map(
            r,
            inversion: DJIVirtualJoystickMapper.Inversion(
                invertForward: false, invertLateral: false, invertTurn: false))
        XCTAssertEqual(s.leftY, 1.0, accuracy: 0.0001)
    }

    func test_disabling_turn_inversion_flips_yaw() {
        let r = make(x: 1.0)
        let s = DJIVirtualJoystickMapper.map(
            r,
            inversion: DJIVirtualJoystickMapper.Inversion(
                invertForward: true, invertLateral: false, invertTurn: false))
        XCTAssertEqual(s.turn, 1.0, accuracy: 0.0001)
    }

    func test_enabling_lateral_inversion_flips_lateral() {
        let r = make(rx: 1.0)
        let s = DJIVirtualJoystickMapper.map(
            r,
            inversion: DJIVirtualJoystickMapper.Inversion(
                invertForward: true, invertLateral: true, invertTurn: true))
        XCTAssertEqual(s.leftX, -1.0, accuracy: 0.0001)
    }

    // MARK: - Deadzone

    func test_under_deadzone_yields_zero() {
        // deadzone = 0.10 (뒤로 걷기 잔존 fix 로 0.05→0.10 상향). 0.08 은 미만 → 0.
        let r = make(x: 0.08, rx: 0.08, ry: 0.08)
        let s = DJIVirtualJoystickMapper.map(r)
        XCTAssertEqual(s, DJIVirtualJoystickMapper.StickInput.zero)
    }

    func test_at_or_above_deadzone_passes_through() {
        // deadzone 0.10 초과 입력은 그대로 통과.
        let r = make(rx: 0.15)
        let s = DJIVirtualJoystickMapper.map(r)
        XCTAssertEqual(s.leftX, 0.15, accuracy: 0.0001)
    }

    // MARK: - Buttons → actions

    func test_button_1_maps_to_emergency_only() {
        var btns = Array(repeating: false, count: 24)
        btns[0] = true
        let actions = DJIVirtualJoystickMapper.ButtonActions.from(btns)
        XCTAssertTrue(actions.emergencyStop)
        XCTAssertFalse(actions.recover)
    }

    func test_button_2_maps_to_recover_only() {
        var btns = Array(repeating: false, count: 24)
        btns[1] = true
        let actions = DJIVirtualJoystickMapper.ButtonActions.from(btns)
        XCTAssertFalse(actions.emergencyStop)
        XCTAssertTrue(actions.recover)
    }

    func test_no_buttons_means_no_actions() {
        let actions = DJIVirtualJoystickMapper.ButtonActions.from(
            Array(repeating: false, count: 24))
        XCTAssertFalse(actions.emergencyStop)
        XCTAssertFalse(actions.recover)
        XCTAssertFalse(actions.ballTracking)
    }

    /// 볼 트래킹 (2026-06-02): Button 3 (index 2) = 헤드 추적 토글.
    func test_button_3_maps_to_ballTracking_only() {
        var btns = Array(repeating: false, count: 24)
        btns[2] = true
        let actions = DJIVirtualJoystickMapper.ButtonActions.from(btns)
        XCTAssertTrue(actions.ballTracking)
        XCTAssertFalse(actions.emergencyStop)
        XCTAssertFalse(actions.recover)
    }

    /// djiMode2 기본 프로파일이 ballTracking 을 Button 3 에 바인딩 → buttonActions 평가.
    func test_djiMode2_ballTracking_bound_to_button3() {
        XCTAssertEqual(DJIBindingProfile.djiMode2.bindings[.ballTracking], .button(2),
                       "ballTracking 기본 = Button 3 (index 2)")
        var btns = Array(repeating: false, count: 24)
        btns[2] = true
        let report = DJIVirtualJoystickReport(
            axisX: 0, axisY: 0, axisZ: 0, axisRx: 0, axisRy: 0, buttons: btns)
        let actions = DJIVirtualJoystickMapper.buttonActions(
            report: report, profile: .djiMode2)
        XCTAssertTrue(actions.ballTracking, "profile 경로로도 Button 3 → ballTracking")
    }

    /// ballTracking 은 안전 action 아님 — unbound 허용(사용자가 끌 수 있음).
    func test_ballTracking_not_safety_critical() {
        XCTAssertFalse(CockpitAction.ballTracking.isSafetyCritical)
    }

    func test_short_button_array_does_not_crash() {
        // 잘못된 디바이스가 짧은 array 를 보내도 OOB 없이 false 반환.
        let actions = DJIVirtualJoystickMapper.ButtonActions.from([])
        XCTAssertFalse(actions.emergencyStop)
        XCTAssertFalse(actions.recover)
    }

    // MARK: - End-to-end (decode → map)

    /// 실 디바이스가 보낼 법한 13-byte report 를 만들어 decode → map 까지 전체
    /// 파이프라인을 검증.
    func test_full_pipeline_right_stick_forward_neutral_yaw() {
        // Bytes 0..2 : no buttons
        // Bytes 3..4 : X = 0
        // Bytes 5..6 : Y = 0
        // Bytes 7..8 : Z = 0
        // Bytes 9..10: Rx = 0
        // Bytes 11..12: Ry = +660 (full forward on right stick)
        var d = Data(count: 13)
        d[11] = 0x94   // 660 = 0x0294, LE → 94 02
        d[12] = 0x02
        let report = DJIVirtualJoystickReport.decode(d)!
        let stick = DJIVirtualJoystickMapper.map(report)
        XCTAssertEqual(stick.leftY, -1.0, accuracy: 0.0001) // forward
        XCTAssertEqual(stick.leftX, 0.0,  accuracy: 0.0001)
        XCTAssertEqual(stick.turn,  0.0,  accuracy: 0.0001)
    }
}
