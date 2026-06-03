import XCTest
@testable import DarwinForgeUI

/// `ControllerInputResolver` 순수 변환 검증 — M2 핵심.
///
/// - polarity 방향 성분만 취함
/// - axisTuning.shaped 적용(데드존)
/// - 반대 쌍 차감 → net 축
/// - 버튼/축 isPressed 임계
/// - unbound / 미설정 → 0
final class ControllerInputResolverTests: XCTestCase {

    // 단일 액션 1개만 바인딩한 최소 프로파일.
    private func profile(
        _ bindings: [CockpitAction: ControllerBinding],
        tuning: [Int: ControllerAxisTuning] = [:]
    ) -> ControllerBindingProfile {
        ControllerBindingProfile(name: "t", deviceKey: "t", bindings: bindings, axisTuning: tuning)
    }

    private func snapshot(axis index: Int, _ value: Double) -> ControllerSnapshot {
        var axes = Array(repeating: 0.0, count: ControllerSnapshot.standardAxisCount)
        axes[index] = value
        return ControllerSnapshot(axes: axes, buttons: Array(repeating: false, count: ControllerSnapshot.standardButtonCount))
    }

    // MARK: - magnitude: 축 polarity

    func test_magnitude_positive_polarity_takes_positive_component() {
        let p = profile([.moveForward: .axis(index: 0, polarity: .positive)])
        // 입력 +0.5 → positive 성분 = shaped(+0.5) > 0
        let m = ControllerInputResolver.magnitude(of: .moveForward, in: snapshot(axis: 0, 0.5), profile: p)
        XCTAssertEqual(m, ControllerAxisTuning().shaped(0.5), accuracy: 1e-9)
        // 반대 부호 입력 −0.5 → positive 성분 0
        let m2 = ControllerInputResolver.magnitude(of: .moveForward, in: snapshot(axis: 0, -0.5), profile: p)
        XCTAssertEqual(m2, 0.0, accuracy: 1e-9, "positive polarity 는 음의 입력에 0")
    }

    func test_magnitude_negative_polarity_takes_negative_component() {
        let p = profile([.moveForward: .axis(index: 1, polarity: .negative)])
        // 스틱 위 = 음수 입력 → negative 성분 = -shaped(-0.5) > 0
        let m = ControllerInputResolver.magnitude(of: .moveForward, in: snapshot(axis: 1, -0.5), profile: p)
        XCTAssertEqual(m, -ControllerAxisTuning().shaped(-0.5), accuracy: 1e-9)
        XCTAssertGreaterThan(m, 0.0)
        // 양의 입력 → negative 성분 0
        let m2 = ControllerInputResolver.magnitude(of: .moveForward, in: snapshot(axis: 1, 0.5), profile: p)
        XCTAssertEqual(m2, 0.0, accuracy: 1e-9)
    }

    // MARK: - magnitude: 데드존

    func test_magnitude_inside_deadzone_is_zero() {
        let p = profile([.moveForward: .axis(index: 0, polarity: .positive)])
        // 기본 deadzone 0.10, 입력 0.05 → shaped 0 → magnitude 0
        let m = ControllerInputResolver.magnitude(of: .moveForward, in: snapshot(axis: 0, 0.05), profile: p)
        XCTAssertEqual(m, 0.0, accuracy: 1e-9)
    }

    // MARK: - magnitude: 버튼 / unbound / 미설정

    func test_magnitude_button_pressed_is_one() {
        let p = profile([.emergencyStop: .button(index: 1)])
        var buttons = Array(repeating: false, count: ControllerSnapshot.standardButtonCount)
        buttons[1] = true
        let s = ControllerSnapshot(axes: [], buttons: buttons)
        XCTAssertEqual(ControllerInputResolver.magnitude(of: .emergencyStop, in: s, profile: p), 1.0)
    }

    func test_magnitude_unbound_and_missing_are_zero() {
        let p = profile([.moveForward: .unbound])
        XCTAssertEqual(ControllerInputResolver.magnitude(of: .moveForward, in: .neutral, profile: p), 0.0)
        // 미설정 액션(딕셔너리에 없음)
        XCTAssertEqual(ControllerInputResolver.magnitude(of: .turnLeft, in: .neutral, profile: p), 0.0)
    }

    // MARK: - 반대 쌍 차감

    func test_resolve_opposing_pair_nets_to_forward() {
        // 전진=axis1 neg, 후진=axis1 pos. 스틱 위(−0.5) → leftY 음수(전진).
        let p = profile([
            .moveForward:  .axis(index: 1, polarity: .negative),
            .moveBackward: .axis(index: 1, polarity: .positive),
        ])
        let r = ControllerInputResolver.resolve(snapshot(axis: 1, -0.5), profile: p)
        XCTAssertEqual(r.leftY, ControllerAxisTuning().shaped(-0.5), accuracy: 1e-9)
        XCTAssertLessThan(r.leftY, 0.0, "전진 → leftY 음수")
        XCTAssertEqual(r.leftX, 0.0)
        XCTAssertEqual(r.turn, 0.0)
    }

    func test_resolve_strafe_and_turn_sign() {
        let p = profile([
            .strafeLeft:  .axis(index: 0, polarity: .negative),
            .strafeRight: .axis(index: 0, polarity: .positive),
            .turnLeft:    .axis(index: 2, polarity: .negative),
            .turnRight:   .axis(index: 2, polarity: .positive),
        ])
        // axis0 +0.6 → strafeRight → leftX +
        XCTAssertGreaterThan(ControllerInputResolver.resolve(snapshot(axis: 0, 0.6), profile: p).leftX, 0)
        // axis0 −0.6 → strafeLeft → leftX −
        XCTAssertLessThan(ControllerInputResolver.resolve(snapshot(axis: 0, -0.6), profile: p).leftX, 0)
        // axis2 +0.6 → turnRight → turn +
        XCTAssertGreaterThan(ControllerInputResolver.resolve(snapshot(axis: 2, 0.6), profile: p).turn, 0)
    }

    // MARK: - 머리

    func test_resolve_head_pan_tilt_sign() {
        let p = profile([
            .headPanLeft:  .axis(index: 4, polarity: .positive),
            .headPanRight: .axis(index: 5, polarity: .positive),
            .headTiltUp:   .axis(index: 3, polarity: .negative),
            .headTiltDown: .axis(index: 3, polarity: .positive),
        ])
        // RT(axis5) 당김 → headPanRight → headPan +
        XCTAssertGreaterThan(ControllerInputResolver.resolve(snapshot(axis: 5, 0.7), profile: p).headPan, 0)
        // LT(axis4) 당김 → headPanLeft → headPan −
        XCTAssertLessThan(ControllerInputResolver.resolve(snapshot(axis: 4, 0.7), profile: p).headPan, 0)
        // RS Y 위(−0.7) → headTiltUp → headTilt +
        XCTAssertGreaterThan(ControllerInputResolver.resolve(snapshot(axis: 3, -0.7), profile: p).headTilt, 0)
    }

    // MARK: - isPressed 임계

    func test_isPressed_button_true_axis_threshold() {
        let p = profile([.emergencyStop: .button(index: 1)])
        var buttons = Array(repeating: false, count: ControllerSnapshot.standardButtonCount)
        buttons[1] = true
        XCTAssertTrue(ControllerInputResolver.isPressed(.emergencyStop, in: ControllerSnapshot(axes: [], buttons: buttons), profile: p))
        XCTAssertFalse(ControllerInputResolver.isPressed(.emergencyStop, in: .neutral, profile: p))
    }

    // MARK: - xbox 프리셋 통합

    func test_resolve_with_xbox_preset_forward_and_estop() {
        var buttons = Array(repeating: false, count: ControllerSnapshot.standardButtonCount)
        buttons[1] = true // B = emergencyStop
        var axes = Array(repeating: 0.0, count: ControllerSnapshot.standardAxisCount)
        axes[1] = -0.8 // LS Y 위 = 전진
        let s = ControllerSnapshot(axes: axes, buttons: buttons)
        let r = ControllerInputResolver.resolve(s, profile: .xbox)
        XCTAssertLessThan(r.leftY, 0.0, "전진")
        XCTAssertTrue(r.emergencyStop)
        XCTAssertFalse(r.recover)
    }
}
