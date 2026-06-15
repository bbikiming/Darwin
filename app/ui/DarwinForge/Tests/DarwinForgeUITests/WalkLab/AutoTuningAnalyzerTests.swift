import XCTest
@testable import DarwinForgeUI

/// **데이터 기반 자동 튜닝 (2026-05-30)**: WalkSessionAnalyzer 안정성 권고 (pure).
///
/// # Coverage (9 tests)
/// - D항: over-correction 하향 / under-correction 상향 / fall 가속 상향금지 /
///   caution 낮음 유지 / 데이터부족 유지 / floor.
/// - tau: baseline 미추종 하향 / 추종 유지 / floor.
final class AutoTuningAnalyzerTests: XCTestCase {

    private let n = WalkSessionAnalyzer.minSampleCountForRecommendation + 10

    // MARK: - D항 권고

    /// 진동 높음 + tilt 낮음 → over-correction → D항 하향.
    func test_dTerm_overCorrection_lowers() {
        let r = WalkSessionAnalyzer.recommendDerivativeTimeSec(
            current: 0.12, meanTilt: 2.0, oscillation: 6.0,
            correlation: 0.5, cautionRatio: 0.05, sampleCount: n)
        XCTAssertLessThan(r.value, 0.12, "진동 over-correction → D항 하향")
        XCTAssertGreaterThan(r.confidence, 0.5)
    }

    /// tilt 높음 + 진동 낮음 + 회복 정상 + caution↑ → under-correction → D항 상향.
    func test_dTerm_underCorrection_raises() {
        let r = WalkSessionAnalyzer.recommendDerivativeTimeSec(
            current: 0.12, meanTilt: 15.0, oscillation: 1.0,
            correlation: 0.4, cautionRatio: 0.25, sampleCount: n)
        XCTAssertGreaterThan(r.value, 0.12, "under-correction → D항 상향")
    }

    /// correlation 음수(fall 가속) → 상향 금지 (유지).
    func test_dTerm_fallAccel_holdsNoRaise() {
        let r = WalkSessionAnalyzer.recommendDerivativeTimeSec(
            current: 0.12, meanTilt: 15.0, oscillation: 1.0,
            correlation: -0.6, cautionRatio: 0.25, sampleCount: n)
        XCTAssertEqual(r.value, 0.12, accuracy: 1e-12, "fall 가속 시 D항 상향 금지")
    }

    /// caution 낮으면 tilt 높아도 상향 안 함 (corroboration 부족).
    func test_dTerm_lowCaution_holds() {
        let r = WalkSessionAnalyzer.recommendDerivativeTimeSec(
            current: 0.12, meanTilt: 15.0, oscillation: 1.0,
            correlation: 0.4, cautionRatio: 0.02, sampleCount: n)
        XCTAssertEqual(r.value, 0.12, accuracy: 1e-12)
    }

    /// 데이터 부족 → 유지 + confidence 0.
    func test_dTerm_insufficientData_holdsZeroConf() {
        let r = WalkSessionAnalyzer.recommendDerivativeTimeSec(
            current: 0.12, meanTilt: 15.0, oscillation: 1.0,
            correlation: 0.4, cautionRatio: 0.25, sampleCount: 5)
        XCTAssertEqual(r.value, 0.12, accuracy: 1e-12)
        XCTAssertEqual(r.confidence, 0.0)
    }

    /// 하향 시 floor 0.0 미만 안 됨.
    func test_dTerm_floor() {
        let r = WalkSessionAnalyzer.recommendDerivativeTimeSec(
            current: 0.0, meanTilt: 2.0, oscillation: 6.0,
            correlation: 0.5, cautionRatio: 0.05, sampleCount: n)
        XCTAssertGreaterThanOrEqual(r.value, 0.0)
    }

    // MARK: - tau 권고

    /// corrector 오차 큼(>동적*1.5) → baseline 미추종 → tau 하향.
    func test_tau_baselineLagging_lowers() {
        let r = WalkSessionAnalyzer.recommendBaselineTauSec(
            current: 5.0, meanAbsCorrectorPitchErr: 18.0, pitchStdev: 5.0, sampleCount: n)
        XCTAssertLessThan(r.value, 5.0, "baseline 미추종 → tau 하향")
    }

    /// corrector 오차 작음 → 유지.
    func test_tau_tracking_holds() {
        let r = WalkSessionAnalyzer.recommendBaselineTauSec(
            current: 5.0, meanAbsCorrectorPitchErr: 3.0, pitchStdev: 4.0, sampleCount: n)
        XCTAssertEqual(r.value, 5.0, accuracy: 1e-12)
    }

    /// tau floor 2.0.
    func test_tau_floor() {
        let r = WalkSessionAnalyzer.recommendBaselineTauSec(
            current: 2.0, meanAbsCorrectorPitchErr: 18.0, pitchStdev: 5.0, sampleCount: n)
        XCTAssertGreaterThanOrEqual(r.value, 2.0)
    }
}
