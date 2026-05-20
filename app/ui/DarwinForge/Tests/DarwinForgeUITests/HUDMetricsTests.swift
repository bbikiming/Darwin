import XCTest
@testable import DarwinForgeUI

/// **v1.11.21 (2026-05-20)** — `HUDMetrics` derivation 단위 테스트.
///
/// SceneSpeedometerOverlay 의 derived metrics 정확성 검증:
/// 1. CoM offset = h × sin(angle)
/// 2. Ankle residual ON/OFF 분기
/// 3. Speed / cadence formula
/// 4. Lag tier 색 임계 (200/500/2000ms)
/// 5. NaN/Inf 가드
final class HUDMetricsTests: XCTestCase {

    // MARK: - 1. CoM offset

    func testComOffsetZeroAngle() {
        XCTAssertEqual(HUDMetrics.comOffsetMm(angleDeg: 0), 0, accuracy: 1e-9)
    }

    func testComOffsetSmallAngle() {
        // v1.11.22: h_com 220mm 정정. 5° → 220 × sin(5°) ≈ 220 × 0.0872 ≈ 19.2 mm.
        let off = HUDMetrics.comOffsetMm(angleDeg: 5)
        XCTAssertEqual(off, 19.18, accuracy: 0.1)
    }

    func testComOffsetSignFollowsAngle() {
        XCTAssertGreaterThan(HUDMetrics.comOffsetMm(angleDeg: 10), 0)
        XCTAssertLessThan(HUDMetrics.comOffsetMm(angleDeg: -10), 0)
    }

    func testComOffsetCustomHeight() {
        // h=100, 30° → 100 × 0.5 = 50
        let off = HUDMetrics.comOffsetMm(angleDeg: 30, h: 100)
        XCTAssertEqual(off, 50.0, accuracy: 1e-6)
    }

    func testComOffsetNaNGuard() {
        XCTAssertEqual(HUDMetrics.comOffsetMm(angleDeg: .nan), 0)
        XCTAssertEqual(HUDMetrics.comOffsetMm(angleDeg: .infinity), 0)
        XCTAssertEqual(HUDMetrics.comOffsetMm(angleDeg: -.infinity), 0)
    }

    // MARK: - 2. CoM saturation

    func testComSaturationAtBoundary() {
        // v1.11.22: polygonR 30mm 정정.
        let pct = HUDMetrics.comSaturationPct(offsetMm: 30)  // = polygonR
        XCTAssertEqual(pct, 100, accuracy: 1e-6)
    }

    func testComSaturationHalfway() {
        let pct = HUDMetrics.comSaturationPct(offsetMm: 15)  // = 30 / 2
        XCTAssertEqual(pct, 50, accuracy: 1e-6)
    }

    func testComSaturationExceedsCappedAt100() {
        let pct = HUDMetrics.comSaturationPct(offsetMm: 200)
        XCTAssertEqual(pct, 100)
    }

    func testComSaturationAbsoluteValue() {
        // 음수 offset 도 동일 % (방향만 다름).
        let pos = HUDMetrics.comSaturationPct(offsetMm: 20)
        let neg = HUDMetrics.comSaturationPct(offsetMm: -20)
        XCTAssertEqual(pos, neg)
    }

    func testComSaturationNaNGuard() {
        // v1.11.22.1 (Codex LOW-1 fix): NaN/Inf → 0 (min(100, NaN) misleading 차단).
        XCTAssertEqual(HUDMetrics.comSaturationPct(offsetMm: .nan), 0)
        XCTAssertEqual(HUDMetrics.comSaturationPct(offsetMm: .infinity), 0)
        XCTAssertEqual(HUDMetrics.comSaturationPct(offsetMm: -.infinity), 0)
    }

    func testDefaultModelConstants() {
        // v1.11.22 정합: spec 출처 명시된 정정값.
        XCTAssertEqual(HUDMetrics.comHeightMm, 220.0,
                       "ROBOTIS-OP2 height 454.5mm × 0.5 humanoid CoM ratio")
        XCTAssertEqual(HUDMetrics.supportRadiusMm, 30.0,
                       "발 width 60mm / 2 = single-foot stance lateral 안전 반경")
    }

    // MARK: - 3. Ankle residual

    func testAnkleResidualCorrectorOff() {
        // 보정 OFF → body pitch 그대로 잔여.
        let r = HUDMetrics.ankleResidualDeg(
            bodyPitch: 10, correctionAnklePitch: -8, correctorEnabled: false
        )
        XCTAssertEqual(r, 10)
    }

    func testAnkleResidualLeftMotorSignReducesResidual() {
        // v1.11.22 magnitude 기반: body 10°, L correction motor -8° (외부 dorsiflex)
        // → sign(10) × max(0, 10-8) = +2°.
        let r = HUDMetrics.ankleResidualDeg(
            bodyPitch: 10, correctionAnklePitch: -8, correctorEnabled: true
        )
        XCTAssertEqual(r, 2, accuracy: 1e-9)
    }

    func testAnkleResidualRightMotorSignSameMagnitudeReducesResidual() {
        // v1.11.22 정정: R 발도 L과 같은 외부 효과 (motor 부호만 mirror).
        // body 10°, R correction motor +8° (외부 dorsiflex) → magnitude 식 → +2°.
        // 종전 (잘못된) 식은 10 + 8 = +18° 였음 → 보정이 잔여를 증폭한다고 표시.
        let r = HUDMetrics.ankleResidualDeg(
            bodyPitch: 10, correctionAnklePitch: +8, correctorEnabled: true
        )
        XCTAssertEqual(r, 2, accuracy: 1e-9,
                       "R/L motor 부호 무관, 외부 footplate 효과는 동일 magnitude")
    }

    func testAnkleResidualNegativeBodyPreservesSign() {
        // body -10°, correction motor magnitude 8 → sign(-10) × max(0, 2) = -2°.
        let r = HUDMetrics.ankleResidualDeg(
            bodyPitch: -10, correctionAnklePitch: 8, correctorEnabled: true
        )
        XCTAssertEqual(r, -2, accuracy: 1e-9)
    }

    func testAnkleResidualOverCorrectionClampsAtZero() {
        // |correction| > |body| → 잔여 0 (over-correction 표시는 0 으로 clamp).
        let r = HUDMetrics.ankleResidualDeg(
            bodyPitch: 5, correctionAnklePitch: 10, correctorEnabled: true
        )
        XCTAssertEqual(r, 0, accuracy: 1e-9,
                       "over-correction 시 잔여 음수로 안 가고 0 으로 clamp")
    }

    func testAnkleResidualZeroBody() {
        // body 0 → 잔여 0 (보정 무관).
        let r = HUDMetrics.ankleResidualDeg(
            bodyPitch: 0, correctionAnklePitch: 5, correctorEnabled: true
        )
        XCTAssertEqual(r, 0)
    }

    func testAnkleResidualCorrectorOnButNilCorrection() {
        // 보정 ON 이지만 corrections 데이터 nil → body 그대로.
        let r = HUDMetrics.ankleResidualDeg(
            bodyPitch: 5, correctionAnklePitch: nil, correctorEnabled: true
        )
        XCTAssertEqual(r, 5)
    }

    func testAnkleResidualNaNBody() {
        let r = HUDMetrics.ankleResidualDeg(
            bodyPitch: .nan, correctionAnklePitch: 2, correctorEnabled: true
        )
        XCTAssertEqual(r, 0)
    }

    func testAnkleResidualNaNCorrectionFallsBackToBody() {
        let r = HUDMetrics.ankleResidualDeg(
            bodyPitch: 3, correctionAnklePitch: .nan, correctorEnabled: true
        )
        XCTAssertEqual(r, 3, "NaN correction → 무시, body pitch 그대로")
    }

    // MARK: - 4. Speed / Cadence

    func testSpeedKmhTypicalWalk() {
        // stride 80mm, period 600ms → 0.133 m/s × 3.6 = 0.48 km/h
        let v = HUDMetrics.speedKmh(strideMm: 80, periodMs: 600)
        XCTAssertEqual(v, 0.48, accuracy: 0.01)
    }

    func testSpeedKmhZeroStride() {
        XCTAssertEqual(HUDMetrics.speedKmh(strideMm: 0, periodMs: 600), 0)
    }

    func testSpeedKmhDivByZeroGuard() {
        // periodMs 0 → 50 으로 clamp.
        let v = HUDMetrics.speedKmh(strideMm: 100, periodMs: 0)
        // 100 / 50 = 2 m/s × 3.6 = 7.2 km/h
        XCTAssertEqual(v, 7.2, accuracy: 0.01)
    }

    func testSpeedKmhNaNGuard() {
        let v = HUDMetrics.speedKmh(strideMm: .nan, periodMs: 600)
        XCTAssertEqual(v, 0)
    }

    func testCadenceTypical() {
        // period 600ms → 2 × 60000 / 600 = 200 spm
        XCTAssertEqual(HUDMetrics.cadenceSpm(periodMs: 600), 200, accuracy: 1e-6)
    }

    func testCadenceDivByZeroGuard() {
        // period 0 → clamp 50ms → 2400 spm (한계 표시).
        XCTAssertEqual(HUDMetrics.cadenceSpm(periodMs: 0), 2400, accuracy: 1e-6)
    }

    // MARK: - 5. Lag tier

    func testLagTierExcellent() {
        XCTAssertEqual(HUDMetrics.lagTier(50), 0)
        XCTAssertEqual(HUDMetrics.lagTier(199), 0)
    }

    func testLagTierAcceptable() {
        XCTAssertEqual(HUDMetrics.lagTier(200), 1)
        XCTAssertEqual(HUDMetrics.lagTier(499), 1)
    }

    func testLagTierDegraded() {
        XCTAssertEqual(HUDMetrics.lagTier(500), 2)
        XCTAssertEqual(HUDMetrics.lagTier(1999), 2)
    }

    func testLagTierStale() {
        XCTAssertEqual(HUDMetrics.lagTier(2000), 3)
        XCTAssertEqual(HUDMetrics.lagTier(10_000), 3)
    }

    func testLagTierNegativeIsStale() {
        XCTAssertEqual(HUDMetrics.lagTier(-100), 3, "음수 lag = 비정상 → stale")
    }

    func testLagTierNaNIsStale() {
        XCTAssertEqual(HUDMetrics.lagTier(.nan), 3)
        XCTAssertEqual(HUDMetrics.lagTier(.infinity), 3)
    }

    // MARK: - 6. Lag formatting

    func testFormatLagSubSecond() {
        XCTAssertEqual(HUDMetrics.formatLag(150), "150ms")
        XCTAssertEqual(HUDMetrics.formatLag(999), "999ms")
    }

    func testFormatLagSeconds() {
        XCTAssertEqual(HUDMetrics.formatLag(1000), "1.0s")
        XCTAssertEqual(HUDMetrics.formatLag(5500), "5.5s")
    }

    func testFormatLagStale() {
        XCTAssertEqual(HUDMetrics.formatLag(60_000), "STALE")
        XCTAssertEqual(HUDMetrics.formatLag(.nan), "STALE")
    }

    // MARK: - 7. Phase parsing

    func testPhaseIndexValid() {
        XCTAssertEqual(HUDMetrics.phaseIndex(label: "PHASE3"), 3)
        XCTAssertEqual(HUDMetrics.phaseIndex(label: "PHASE0"), 0)
        XCTAssertEqual(HUDMetrics.phaseIndex(label: "PHASE5"), 5)
    }

    func testPhaseIndexClampedToMax5() {
        XCTAssertEqual(HUDMetrics.phaseIndex(label: "PHASE9"), 5,
                       "단일 숫자 phase index 는 0..5 clamp")
    }

    func testPhaseIndexInvalidReturnsNil() {
        XCTAssertNil(HUDMetrics.phaseIndex(label: "IDLE"))
        XCTAssertNil(HUDMetrics.phaseIndex(label: ""))
        XCTAssertNil(HUDMetrics.phaseIndex(label: "PHASE_"))
    }
}
