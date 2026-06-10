import XCTest
@testable import DarwinForgeUI

/// **Wave 0 레이턴시/안전 고도화 (2026-06-11)** 회귀 가드.
///
/// - S2: 컨트롤러 끊김 failsafe — stale 스틱 명령이 잔존하지 않고 zero 로 수렴.
/// - J3: 콕핏 throttle→periodMs derive 가 실모터 `mobileFreeformClamp` 범위와 정합.
@MainActor
final class CockpitWave0HardeningTests: XCTestCase {

    private func makeAxes(_ pairs: [(Int, Double)]) -> [Double] {
        var axes = Array(repeating: 0.0, count: ControllerSnapshot.standardAxisCount)
        for (i, v) in pairs { axes[i] = v }
        return axes
    }

    private var noButtons: [Bool] {
        Array(repeating: false, count: ControllerSnapshot.standardButtonCount)
    }

    // MARK: - S2: disconnect failsafe

    func test_disconnect_injects_zero_stop_command() {
        let state = CockpitState()
        var noDeadman = ControllerBindingProfile.xbox
        noDeadman.deadmanEnabled = false
        let src = MockControllerSource()
        let driver = CockpitControllerDriver(state: state, source: src, profile: noDeadman)
        driver.start()
        defer { driver.stop() }

        // 전진 주입 → 비-zero 명령.
        driver.inject(ControllerSnapshot(axes: makeAxes([(1, -0.9)]), buttons: noButtons))
        XCTAssertLessThan(state.leftStick.y, 0.0, "전진 중 — leftStick.y 음수")
        XCTAssertFalse(state.lastCommand.isStop, "주행 중 lastCommand 는 stop 아님")

        // 끊김 → failsafe 발화.
        src.setConnected(false)

        XCTAssertEqual(state.leftStick, .zero, "끊김 시 leftStick zero")
        XCTAssertEqual(state.rightStick, .zero, "끊김 시 rightStick zero")
        XCTAssertTrue(state.lastCommand.isStop, "끊김 시 lastCommand = stop (stale 잔존 금지)")
    }

    func test_inputSourceLost_zeros_drive_and_head() {
        let state = CockpitState()
        state.apply(leftX: 0.5, leftY: -0.5, turn: 0.3, from: .gamepad)
        state.applyHead(panNorm: 0.8, tiltNorm: -0.4)
        XCTAssertFalse(state.lastCommand.isStop)

        state.inputSourceLost()

        XCTAssertEqual(state.leftStick, .zero)
        XCTAssertEqual(state.rightStick, .zero)
        XCTAssertTrue(state.lastCommand.isStop)
    }

    // MARK: - J3: cadence ↔ 실모터 clamp 정합

    func test_periodMs_stays_within_freeform_clamp_range() {
        let state = CockpitState()
        let range = WalkMotionLibrary.mobileFreeformPeriodRange
        // throttle 전 구간 [0.5, 1.5] 을 스윕 — 모든 derive 값이 clamp 범위 안.
        for scale in stride(from: 0.5, through: 1.5, by: 0.05) {
            state.setSpeedScale(scale)
            XCTAssertGreaterThanOrEqual(state.periodMs, range.lowerBound,
                                        "throttle \(scale): periodMs \(state.periodMs) ≥ \(range.lowerBound)")
            XCTAssertLessThanOrEqual(state.periodMs, range.upperBound,
                                     "throttle \(scale): periodMs \(state.periodMs) ≤ \(range.upperBound)")
        }
    }

    func test_periodMs_endpoints_map_to_full_range() {
        let state = CockpitState()
        let range = WalkMotionLibrary.mobileFreeformPeriodRange
        state.setSpeedScale(0.5)
        XCTAssertEqual(state.periodMs, range.upperBound, accuracy: 1e-6, "느림 끝 → 최대 period")
        state.setSpeedScale(1.5)
        XCTAssertEqual(state.periodMs, range.lowerBound, accuracy: 1e-6, "빠름 끝 → 최소 period")
    }

    func test_clamp_passes_through_cockpit_period_unchanged() {
        // 콕핏이 만든 periodMs 가 mobileFreeformClamp 를 통과해도 변형되지 않아야
        // (dead zone 부재) — 직진(turn=0) 기준.
        let state = CockpitState()
        for scale in [0.5, 0.75, 1.0, 1.25, 1.5] {
            state.setSpeedScale(scale)
            let tuning = WalkMotionLibrary.AdvancedTuning(
                strideMm: 20, sideMm: 0, turnDeg: 0,
                periodMs: state.periodMs, footHeightMm: 30, balanceGain: 0)
            let clamped = WalkMotionLibrary.mobileFreeformClamp(tuning)
            XCTAssertEqual(clamped.periodMs, state.periodMs, accuracy: 1e-6,
                           "throttle \(scale): 콕핏 period \(state.periodMs) 가 clamp 통과 시 불변")
        }
    }
}
