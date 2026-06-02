import XCTest
@testable import DarwinForgeUI

/// 다축 명령 스무딩(EMA) + 결합 안전한계 + snap-to-stop 검증.
final class CockpitCommandSmootherTests: XCTestCase {

    // MARK: - EMA

    func test_ema_converges_toward_target() {
        var v = 0.0
        for _ in 0..<200 { v = CockpitCommandSmoother.ema(v, 10, alpha: 0.25) }
        XCTAssertEqual(v, 10, accuracy: 0.001)
    }

    func test_ema_first_step_is_alpha_fraction() {
        XCTAssertEqual(CockpitCommandSmoother.ema(0, 10, alpha: 0.25), 2.5, accuracy: 1e-9)
    }

    func test_ema_clamps_alpha_range() {
        XCTAssertEqual(CockpitCommandSmoother.ema(0, 10, alpha: 2.0), 10, accuracy: 1e-9)  // >1 → 즉시
        XCTAssertEqual(CockpitCommandSmoother.ema(5, 10, alpha: -1), 5, accuracy: 1e-9)    // <0 → 정지
    }

    // MARK: - 결합 안전한계

    /// 단일 축 전속(전진만 max)은 결합크기 1 → 불변.
    func test_combined_clamp_single_axis_unchanged() {
        let c = WalkingCommand(strideMm: 38, sideMm: 0, turnDeg: 0)
        let r = CockpitCommandSmoother.combinedClamp(c, strideMax: 38, sideMax: 22, turnMax: 12)
        XCTAssertEqual(r.strideMm, 38, accuracy: 1e-9)
        XCTAssertEqual(r.sideMm, 0, accuracy: 1e-9)
        XCTAssertEqual(r.turnDeg, 0, accuracy: 1e-9)
    }

    /// 세 축 동시 max → 결합크기 √3 → 각 축 /√3, 결합크기 정확히 1.
    func test_combined_clamp_all_axes_max_scaled_to_unit() {
        let c = WalkingCommand(strideMm: 38, sideMm: 22, turnDeg: 12)
        let r = CockpitCommandSmoother.combinedClamp(c, strideMax: 38, sideMax: 22, turnMax: 12)
        let n = (pow(r.strideMm / 38, 2) + pow(r.sideMm / 22, 2) + pow(r.turnDeg / 12, 2)).squareRoot()
        XCTAssertEqual(n, 1.0, accuracy: 1e-6)
    }

    /// 축소 시 방향 비율 보존 (조종 의도 유지).
    func test_combined_clamp_preserves_direction_ratio() {
        let c = WalkingCommand(strideMm: 38, sideMm: 22, turnDeg: 12)
        let r = CockpitCommandSmoother.combinedClamp(c, strideMax: 38, sideMax: 22, turnMax: 12)
        XCTAssertEqual(r.strideMm / r.sideMm, 38.0 / 22.0, accuracy: 1e-6)
        XCTAssertEqual(r.sideMm / r.turnDeg, 22.0 / 12.0, accuracy: 1e-6)
    }

    // MARK: - step (EMA → 결합제한 → snap)

    func test_step_ramps_not_instant() {
        let target = WalkingCommand(strideMm: 38, sideMm: 0, turnDeg: 0)
        let r = CockpitCommandSmoother.step(current: .stop, target: target, alpha: 0.25,
                                            strideMax: 38, sideMax: 22, turnMax: 12)
        XCTAssertEqual(r.strideMm, 9.5, accuracy: 0.01)   // 38 × 0.25, 즉시 아님
        XCTAssertFalse(r.isStop)
    }

    func test_step_snaps_to_stop_when_target_zero() {
        var c = WalkingCommand(strideMm: 38, sideMm: 0, turnDeg: 0)
        for _ in 0..<200 {
            c = CockpitCommandSmoother.step(current: c, target: .stop, alpha: 0.25,
                                            strideMax: 38, sideMax: 22, turnMax: 12)
        }
        XCTAssertTrue(c.isStop)   // EMA 점근 잔류가 snap 으로 정확히 0 → 잔존 보행 없음
    }

    func test_step_converges_to_target_over_time() {
        var c = WalkingCommand.stop
        let target = WalkingCommand(strideMm: 30, sideMm: 0, turnDeg: 0)  // 단일 축(결합 불변)
        for _ in 0..<200 {
            c = CockpitCommandSmoother.step(current: c, target: target, alpha: 0.25,
                                            strideMax: 38, sideMax: 22, turnMax: 12)
        }
        XCTAssertEqual(c.strideMm, 30, accuracy: 0.05)
    }
}
