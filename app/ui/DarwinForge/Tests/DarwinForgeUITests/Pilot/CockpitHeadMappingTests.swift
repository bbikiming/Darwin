import XCTest
@testable import DarwinForgeUI

/// 조종 시뮬 고도화 — 머리 동작 할당 + rate 적분 + 뒤로 걷기 잔존(snap-to-zero) 검증.
final class CockpitHeadMappingTests: XCTestCase {

    // MARK: - djiMode2 기본 머리 바인딩 (미사용 축 Z/Y 재활용)

    func test_djiMode2_binds_four_head_actions() {
        let p = DJIBindingProfile.djiMode2
        XCTAssertEqual(p.bindings[.headTiltUp],   .axis(.z, polarity: .positive))
        XCTAssertEqual(p.bindings[.headTiltDown], .axis(.z, polarity: .negative))
        XCTAssertEqual(p.bindings[.headPanRight], .axis(.y, polarity: .positive))
        XCTAssertEqual(p.bindings[.headPanLeft],  .axis(.y, polarity: .negative))
    }

    /// 머리 액션 추가 후에도 djiMode2 가 모든 action 을 바인딩(안전 invariant).
    func test_djiMode2_all_actions_bound_including_head() {
        let p = DJIBindingProfile.djiMode2
        for a in CockpitAction.allCases {
            XCTAssertFalse((p.bindings[a] ?? .unbound).isUnbound, "\(a) 가 unbound")
        }
    }

    func test_head_group_has_four_actions() {
        let headActions = CockpitAction.allCases.filter { $0.group == .head }
        XCTAssertEqual(Set(headActions),
                       [.headPanLeft, .headPanRight, .headTiltUp, .headTiltDown])
    }

    // MARK: - profile 기반 머리 norm 합성

    func test_map_tilt_up_from_Z_positive() {
        let s = DJIVirtualJoystickMapper.map(
            DJIVirtualJoystickReport(axisZ: 1.0, buttons: []), profile: .djiMode2)
        XCTAssertEqual(s.headTiltNorm, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.headPanNorm, 0, accuracy: 1e-9)
        // 보행 축은 영향 없음.
        XCTAssertEqual(s.leftX, 0, accuracy: 1e-9)
        XCTAssertEqual(s.leftY, 0, accuracy: 1e-9)
        XCTAssertEqual(s.turn, 0, accuracy: 1e-9)
    }

    func test_map_tilt_down_from_Z_negative() {
        let s = DJIVirtualJoystickMapper.map(
            DJIVirtualJoystickReport(axisZ: -1.0, buttons: []), profile: .djiMode2)
        XCTAssertEqual(s.headTiltNorm, -1.0, accuracy: 1e-9)
    }

    func test_map_pan_right_from_Y_positive() {
        let s = DJIVirtualJoystickMapper.map(
            DJIVirtualJoystickReport(axisY: 1.0, buttons: []), profile: .djiMode2)
        XCTAssertEqual(s.headPanNorm, 1.0, accuracy: 1e-9)   // +pan = 우
        XCTAssertEqual(s.headTiltNorm, 0, accuracy: 1e-9)
    }

    /// 같은 축에 양극을 잘못 매핑해도 상쇄(0) — robot 폭주 방지 안전 invariant.
    func test_head_same_axis_opposite_polarity_cancels() {
        let p = DJIBindingProfile(name: "t", bindings: [
            .headTiltUp:   .axis(.z, polarity: .positive),
            .headTiltDown: .axis(.z, polarity: .positive),
        ])
        let s = DJIVirtualJoystickMapper.map(
            DJIVirtualJoystickReport(axisZ: 1.0, buttons: []), profile: p)
        XCTAssertEqual(s.headTiltNorm, 0, accuracy: 1e-9)
    }

    /// legacy inversion 경로(profile 없음)는 머리 norm 0 (backward compat).
    func test_legacy_inversion_map_has_zero_head() {
        let s = DJIVirtualJoystickMapper.map(
            DJIVirtualJoystickReport(axisRy: 1.0, buttons: []))
        XCTAssertEqual(s.headPanNorm, 0, accuracy: 1e-9)
        XCTAssertEqual(s.headTiltNorm, 0, accuracy: 1e-9)
    }

    // MARK: - rate 적분 (공식 한계 clamp + 손 떼면 유지)

    func test_head_integrate_accumulates() {
        let d = CockpitHeadKinematics.integrate(
            currentDeg: 0, inputNorm: 1.0, rateDegPerSec: 90, dt: 0.5, limit: -90...90)
        XCTAssertEqual(d, 45, accuracy: 1e-9)
    }

    func test_head_integrate_clamps_to_official_limit() {
        let pan = CockpitHeadKinematics.integrate(
            currentDeg: 80, inputNorm: 1.0, rateDegPerSec: 90, dt: 1.0, limit: -90...90)
        XCTAssertEqual(pan, 90, accuracy: 1e-9)               // headPan +90° 한계
        let tilt = CockpitHeadKinematics.integrate(
            currentDeg: -40, inputNorm: -1.0, rateDegPerSec: 60, dt: 1.0, limit: -45...45)
        XCTAssertEqual(tilt, -45, accuracy: 1e-9)             // headTilt -45° 한계
    }

    func test_head_integrate_zero_input_holds_angle() {
        let d = CockpitHeadKinematics.integrate(
            currentDeg: 33, inputNorm: 0, rateDegPerSec: 90, dt: 0.5, limit: -90...90)
        XCTAssertEqual(d, 33, accuracy: 1e-9)                 // 손 떼면 그 각도 유지
    }

    /// 드드득 fix 회귀: 작은 입력(frame 당 <1°)도 연속 적분으로 누적되어야 한다.
    /// 종전 1° 양자화는 이를 삼켜 멈췄다가 1° 씩 튀었다.
    func test_head_integrate_small_input_accumulates_smoothly() {
        var deg = 0.0
        for _ in 0..<10 {   // smallNorm 0.1 × 90°/s = 9°/s → 0.3°/frame @30Hz
            deg = CockpitHeadKinematics.integrate(
                currentDeg: deg, inputNorm: 0.1,
                rateDegPerSec: 90, dt: 1.0 / 30.0, limit: -90...90)
        }
        XCTAssertEqual(deg, 3.0, accuracy: 0.01)              // 10 × 0.3° = 3° 누적
    }

    // MARK: - 모터 moving-speed 변환 (부드러운 추종)

    func test_moving_speed_units_proportional_to_rate() {
        XCTAssertEqual(CockpitHeadKinematics.movingSpeedUnits(forRateDegPerSec: 90), 132)
        XCTAssertEqual(CockpitHeadKinematics.movingSpeedUnits(forRateDegPerSec: 60), 88)
        // pan(90°/s)이 tilt(60°/s)보다 빠른 속도 단위.
        XCTAssertGreaterThan(
            CockpitHeadKinematics.movingSpeedUnits(forRateDegPerSec: 90),
            CockpitHeadKinematics.movingSpeedUnits(forRateDegPerSec: 60))
    }

    func test_moving_speed_units_clamped_to_valid_range() {
        XCTAssertEqual(CockpitHeadKinematics.movingSpeedUnits(forRateDegPerSec: 0), 1)
        XCTAssertEqual(CockpitHeadKinematics.movingSpeedUnits(forRateDegPerSec: 99999), 1023)
    }

    // MARK: - 뒤로 걷기 잔존 제거 (deadzone 0.10 + snap-to-zero)

    /// 로그(cockpit-…114831Z) 잔존 후진 재현: DJI 스틱 중앙 drift(≈0.06~0.09)가
    /// 종전 deadzone 0.05 를 넘겨 미세 후진을 무한 dispatch 했다. 0.10 으로 stop.
    func test_cockpit_center_drift_is_stop() {
        for driftY in [0.06, 0.08, -0.07, 0.09] {
            let cmd = VirtualJoystickMapper.map(
                x: 0, y: driftY, turn: 0,
                strideMmMax: VirtualJoystickMapper.cockpitStrideMm)
            XCTAssertTrue(cmd.isStop, "drift y=\(driftY) 는 stop 이어야 함")
        }
    }

    /// deadzone 통과한 미세 turn(스틱 0.105 → 1.89° < epsilon 2.0°)도 snap-to-zero
    /// 로 정확히 0 → isStop true (정지/auto-disarm 경로 보장).
    func test_snap_to_zero_past_deadzone_turn() {
        let cmd = VirtualJoystickMapper.map(
            x: 0, y: 0, turn: 0.105,
            turnDegMax: VirtualJoystickMapper.cockpitTurnDeg)
        XCTAssertTrue(cmd.isStop)
    }

    /// 정상 전진은 보행 유지 — deadzone/snap 이 정상 조종을 막지 않음.
    func test_normal_forward_still_walks() {
        let cmd = VirtualJoystickMapper.map(
            x: 0, y: -0.6, turn: 0,
            strideMmMax: VirtualJoystickMapper.cockpitStrideMm)
        XCTAssertFalse(cmd.isStop)
        XCTAssertGreaterThan(cmd.strideMm, 10)               // 전진 보폭 유지
    }
}
