import XCTest
@testable import DarwinForgeUI

/// 자이로 **각속도(gyro rate) PD D-term** 검증 — 넘어짐 선행 대응 + 회귀 0 보장.
final class BalanceCorrectorPDTests: XCTestCase {

    private let c = BalanceCorrector.robotisOriginal   // derivativeTimeSec 0.12 (baseline-aware D-term)

    /// **회귀 보장**: rate=0 이면 각속도 D-term 추가 전(순수 P)과 비트 단위로 동일.
    func test_rate_zero_matches_pure_P() {
        let p = c.corrections(rollErrDeg: 10, pitchErrDeg: 8)
        let pd0 = c.corrections(rollErrDeg: 10, pitchErrDeg: 8,
                                rollRateDps: 0, pitchRateDps: 0)
        XCTAssertEqual(p.rAnklePitch, pd0.rAnklePitch, accuracy: 1e-12)
        XCTAssertEqual(p.lAnklePitch, pd0.lAnklePitch, accuracy: 1e-12)
        XCTAssertEqual(p.rAnkleRoll,  pd0.rAnkleRoll,  accuracy: 1e-12)
        XCTAssertEqual(p.rKnee,       pd0.rKnee,       accuracy: 1e-12)
        XCTAssertEqual(p.rHipRoll,    pd0.rHipRoll,    accuracy: 1e-12)
    }

    /// **각속도만(angle=0)으로도 선제 보정**: 빠르게 앞으로 기우는 중(pitchRate>0)이면
    /// 각도가 아직 0이어도 발목을 미리 보정.
    /// derivativeTimeSec=0.12 (baseline-aware balance): effPitch = 0 + 0.12×100 = 12° 와 등가.
    func test_rate_only_produces_anticipatory_correction() {
        let still = c.corrections(rollErrDeg: 0, pitchErrDeg: 0)
        XCTAssertEqual(still.rAnklePitch, 0, accuracy: 1e-12)   // 정지 → 보정 0

        let d = c.corrections(rollErrDeg: 0, pitchErrDeg: 0,
                              rollRateDps: 0, pitchRateDps: 100)
        // robotisOriginal.derivativeTimeSec = 0.12 → effPitch = 0.12 × 100 = 12°
        let equivAngle = c.corrections(rollErrDeg: 0, pitchErrDeg: 12)
        XCTAssertEqual(d.rAnklePitch, equivAngle.rAnklePitch, accuracy: 1e-9)
        XCTAssertNotEqual(d.rAnklePitch, 0)   // 선제 보정 발생
    }

    /// **PD 합산**: 각도(P) + 각속도×derivativeTime(D) = effective error.
    /// derivativeTimeSec=0.12: angle 3 + rate 40×0.12(=4.8) → eff 7.8.
    func test_PD_sum_equals_combined_error() {
        let pd = c.corrections(rollErrDeg: 0, pitchErrDeg: 3,
                               rollRateDps: 0, pitchRateDps: 40)
        // robotisOriginal.derivativeTimeSec = 0.12 → D-term = 40 × 0.12 = 4.8 → eff = 7.8
        let equiv = c.corrections(rollErrDeg: 0, pitchErrDeg: 7.8)
        XCTAssertEqual(pd.rAnklePitch, equiv.rAnklePitch, accuracy: 1e-9)
        XCTAssertEqual(pd.lAnklePitch, equiv.lAnklePitch, accuracy: 1e-9)
    }

    /// roll 축도 동일하게 동작.
    /// derivativeTimeSec=0.12: rollRateDps 60 → eff roll = 60 × 0.12 = 7.2°.
    func test_roll_rate_d_term() {
        let d = c.corrections(rollErrDeg: 0, pitchErrDeg: 0,
                              rollRateDps: 60, pitchRateDps: 0)        // eff roll = 7.2 (0.12×60)
        // robotisOriginal.derivativeTimeSec = 0.12 → eff = 7.2°
        let equiv = c.corrections(rollErrDeg: 7.2, pitchErrDeg: 0)
        XCTAssertEqual(d.rAnkleRoll, equiv.rAnkleRoll, accuracy: 1e-9)
        XCTAssertEqual(d.rHipRoll,   equiv.rHipRoll,   accuracy: 1e-9)
    }

    /// **±maxCorrectionDeg(15°) clamp 유지** — 큰 각속도에도 과보정 차단.
    func test_clamp_preserved_with_large_rate() {
        let d = c.corrections(rollErrDeg: 0, pitchErrDeg: 0,
                              rollRateDps: 0, pitchRateDps: 100_000)
        XCTAssertLessThanOrEqual(abs(d.rAnklePitch), 15.0 + 1e-9)
        XCTAssertLessThanOrEqual(abs(d.lAnklePitch), 15.0 + 1e-9)
    }

    /// derivativeTimeSec 가 클수록 D 기여 증가 (튜닝 가능성 확인).
    func test_derivative_time_scales_d_term() {
        let small = BalanceCorrector(hipRollGain: 0.5, kneeGain: 0.3,
                                     anklePitchGain: 0.9, ankleRollGain: 1.0,
                                     derivativeTimeSec: 0.05)
        let big = BalanceCorrector(hipRollGain: 0.5, kneeGain: 0.3,
                                   anklePitchGain: 0.9, ankleRollGain: 1.0,
                                   derivativeTimeSec: 0.10)
        let s = small.corrections(rollErrDeg: 0, pitchErrDeg: 0, pitchRateDps: 50)
        let b = big.corrections(rollErrDeg: 0, pitchErrDeg: 0, pitchRateDps: 50)
        XCTAssertGreaterThan(abs(b.rAnklePitch), abs(s.rAnklePitch))
    }

    /// derivativeTimeSec=0 이면 rate 무시(순수 P) — 안전 fallback.
    func test_zero_derivative_time_ignores_rate() {
        let pOnly = BalanceCorrector(hipRollGain: 0.5, kneeGain: 0.3,
                                     anklePitchGain: 0.9, ankleRollGain: 1.0,
                                     derivativeTimeSec: 0.0)
        let withRate = pOnly.corrections(rollErrDeg: 4, pitchErrDeg: 4,
                                         rollRateDps: 999, pitchRateDps: 999)
        let noRate = pOnly.corrections(rollErrDeg: 4, pitchErrDeg: 4)
        XCTAssertEqual(withRate.rAnklePitch, noRate.rAnklePitch, accuracy: 1e-12)
    }
}
