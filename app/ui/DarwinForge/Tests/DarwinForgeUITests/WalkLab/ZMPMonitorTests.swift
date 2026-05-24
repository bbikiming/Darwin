import XCTest
@testable import DarwinForgeUI

/// **V287-2 (2026-05-24)** — ZMP stability gate 회귀 가드.
///
/// # 비유
///
/// 줄타기 안전 매트 체크. 매트(polygon) 가 발 아래 있을 때 (safe), 가장자리 근처
/// (borderline), 매트 밖 (unsafe/veto) 의 3 상태 분류 검증.
///
/// # Spec 검증
///
/// 1. **standstill safe** — IMU=0, 양 발 표준 위치 → margin > threshold, verdict=safe
/// 2. **large tilt + enforce + hysteresis** — 30° pitch 2회 연속 → veto
/// 3. **observe-only no-veto** — enforce=false 면 5회 연속 위험에도 veto 발화 X
///
/// # 회귀 위험
///
/// LOW — pure value calculation, hardware 무관. Vukobratović CoP 식 단순 wrapping.
@MainActor
final class ZMPMonitorTests: XCTestCase {

    // MARK: - 1. Standstill — safe verdict

    /// IMU=0 + 양 발 ±5cm — CoP at origin, margin ≈ min(0.05+0.05, 0.03) = 0.03m
    /// margin >= threshold (0.02m) → verdict = .safe.
    func testZMPMonitor_StandStill_Safe() {
        let m = ZMPMonitor()
        let v = m.evaluate(
            imuRollDeg: 0,
            imuPitchDeg: 0,
            leftFootCenter: (x: -0.05, y: 0),
            rightFootCenter: (x: 0.05, y: 0)
        )
        XCTAssertEqual(v, .safe)
        XCTAssertGreaterThan(m.lastMargin, ZMPMonitor.marginThresholdMeters)
    }

    // MARK: - 2. Large tilt → veto (hysteresis 충족 + enforce ON)

    /// pitch=30° → CoP_x = sin(30°) × 0.30 = 0.15m (앞쪽).
    /// support polygon x edge = max(-0.05, 0.05) + 0.05 = +0.10m.
    /// → margin_x = 0.10 - 0.15 = -0.05m (< 0 — polygon 밖).
    /// enforce=true + 2 회 연속 → verdict = .veto.
    func testZMPMonitor_LargeTilt_UnsafeWithHysteresis() {
        let m = ZMPMonitor()
        m.enforceEnabled = true

        // 1st evaluate — dangerCycleCount 1 → .unsafe(consecutive: 1).
        let v1 = m.evaluate(
            imuRollDeg: 0,
            imuPitchDeg: 30,
            leftFootCenter: (x: -0.05, y: 0),
            rightFootCenter: (x: 0.05, y: 0)
        )
        XCTAssertEqual(v1, .unsafe(consecutive: 1))

        // 2nd evaluate — hysteresis 충족 → .veto.
        let v2 = m.evaluate(
            imuRollDeg: 0,
            imuPitchDeg: 30,
            leftFootCenter: (x: -0.05, y: 0),
            rightFootCenter: (x: 0.05, y: 0)
        )
        XCTAssertEqual(v2, .veto, "enforce=true + 2 회 연속 위험 시 veto 기대")
        XCTAssertLessThan(m.lastMargin, 0, "margin 음수 = polygon 밖 확인")
    }

    // MARK: - 3. Observe-only — veto 발화 안 함

    /// enforce=false (default) — 5 회 연속 위험에도 .unsafe(consecutive: N) 까지만.
    /// 절대 .veto 로 escalate 안 함. 사용자가 명시 토글하지 않은 conservative gate.
    func testZMPMonitor_ObserveOnly_NoVeto() {
        let m = ZMPMonitor()
        XCTAssertFalse(m.enforceEnabled, "default = observe-only")

        for _ in 0..<5 {
            _ = m.evaluate(
                imuRollDeg: 0,
                imuPitchDeg: 30,
                leftFootCenter: (x: -0.05, y: 0),
                rightFootCenter: (x: 0.05, y: 0)
            )
        }

        if case .veto = m.lastVerdict {
            XCTFail("enforce=false 면 veto 발화 안 해야 함. 실제: \(m.lastVerdict)")
        }
    }

    // MARK: - 4. Reset — counter 0 복귀

    /// reset() 호출 후 danger counter / margin / verdict 초기화.
    /// start/stop/recovery 시 stale state 잔존 방지.
    func testZMPMonitor_Reset_ClearsState() {
        let m = ZMPMonitor()
        m.enforceEnabled = true

        // 위험 state 적재.
        _ = m.evaluate(
            imuRollDeg: 0, imuPitchDeg: 30,
            leftFootCenter: (x: -0.05, y: 0),
            rightFootCenter: (x: 0.05, y: 0)
        )
        XCTAssertLessThan(m.lastMargin, 0)

        m.reset()

        XCTAssertEqual(m.lastMargin, 0)
        XCTAssertEqual(m.lastVerdict, .safe)
    }

    // MARK: - 5. Borderline — margin 0..threshold

    /// pitch ≈ 5° → CoP_x ≈ sin(5°) × 0.30 ≈ 0.026m.
    /// polygon x edge = 0.10m → margin_x = 0.074m.
    /// pitch ≈ 14° → CoP_x ≈ sin(14°) × 0.30 ≈ 0.0726m → margin_x ≈ 0.027m (>threshold)
    /// pitch ≈ 16° → CoP_x ≈ 0.0827m → margin_x ≈ 0.017m (<threshold, >=0) → borderline
    func testZMPMonitor_Borderline_NoCounterIncrement() {
        let m = ZMPMonitor()
        m.enforceEnabled = true

        // 16° pitch — borderline range.
        let v = m.evaluate(
            imuRollDeg: 0, imuPitchDeg: 16,
            leftFootCenter: (x: -0.05, y: 0),
            rightFootCenter: (x: 0.05, y: 0)
        )
        XCTAssertEqual(v, .borderline, "0 <= margin < threshold → borderline")
        XCTAssertGreaterThanOrEqual(m.lastMargin, 0)
        XCTAssertLessThan(m.lastMargin, ZMPMonitor.marginThresholdMeters)
    }
}
