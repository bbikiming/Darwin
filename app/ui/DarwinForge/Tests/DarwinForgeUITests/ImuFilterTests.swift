/// 사이클 237 — ImuFilter complementary filter 정확성 regression guard.
import ForgeCore
import XCTest

final class ImuFilterTests: XCTestCase {

    // MARK: - Helper

    private func sample(
        gyroX: UInt16 = 512, gyroY: UInt16 = 512, gyroZ: UInt16 = 512,
        accelX: UInt16 = 512, accelY: UInt16 = 512, accelZ: UInt16 = 512,
        rollDeg: Double = 0, pitchDeg: Double = 0
    ) -> ImuRaw {
        ImuRaw(
            gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ,
            accelX: accelX, accelY: accelY, accelZ: accelZ,
            rollDeg: rollDeg, pitchDeg: pitchDeg
        )
    }

    private let refDate = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - 1. Init — Default

    func testDefaultInit() {
        let f = ImuFilter()
        XCTAssertEqual(f.tau, 0.5, accuracy: 0.01)
        XCTAssertEqual(f.rollDeg, 0, accuracy: 0.01)
        XCTAssertEqual(f.pitchDeg, 0, accuracy: 0.01)
        XCTAssertEqual(f.sampleCount, 0)
        XCTAssertNil(f.lastUpdatedAt)
    }

    // MARK: - 2. Init — Custom

    func testCustomInit() {
        let f = ImuFilter(tau: 1.0, rollDeg: 5, pitchDeg: -3)
        XCTAssertEqual(f.tau, 1.0, accuracy: 0.01)
        XCTAssertEqual(f.rollDeg, 5, accuracy: 0.01)
        XCTAssertEqual(f.pitchDeg, -3, accuracy: 0.01)
        XCTAssertEqual(f.sampleCount, 0)
        XCTAssertNil(f.lastUpdatedAt)
    }

    // MARK: - 3. Init — Tau clamped to minimum

    func testTauClampedToMinimum() {
        let f = ImuFilter(tau: 0.01)
        XCTAssertEqual(f.tau, 0.05, accuracy: 0.001,
                       "tau below 0.05 must be clamped to 0.05")
    }

    // MARK: - 4. First Update — accel-only init

    func testFirstUpdateSetsRollPitchFromSample() {
        var f = ImuFilter()
        let s = sample(rollDeg: 12.5, pitchDeg: -8.3)
        f.update(s, at: refDate)
        XCTAssertEqual(f.rollDeg, 12.5, accuracy: 0.01)
        XCTAssertEqual(f.pitchDeg, -8.3, accuracy: 0.01)
    }

    // MARK: - 5. First Update — sampleCount

    func testFirstUpdateSetsSampleCountToOne() {
        var f = ImuFilter()
        f.update(sample(), at: refDate)
        XCTAssertEqual(f.sampleCount, 1)
    }

    // MARK: - 6. First Update — lastUpdatedAt

    func testFirstUpdateSetsLastUpdatedAt() {
        var f = ImuFilter()
        f.update(sample(), at: refDate)
        XCTAssertEqual(f.lastUpdatedAt, refDate)
    }

    // MARK: - 7. Subsequent — zero gyro + stable accel stays at accel angle

    func testZeroGyroStableAccelStaysAtAccelAngle() {
        var f = ImuFilter(tau: 0.5)
        let accelSample = sample(rollDeg: 10.0, pitchDeg: -5.0)

        // First update — accel only init.
        f.update(accelSample, at: refDate)

        // Second update — gyro centered (512 = 0 dps), same accel angles, dt = 0.2s.
        let t2 = refDate.addingTimeInterval(0.2)
        f.update(accelSample, at: t2)

        // With zero gyro and same accel: rollGyroIntegrated = 10 + 0*0.2 = 10,
        // accelRoll = 10, result = alpha*10 + (1-alpha)*10 = 10.
        XCTAssertEqual(f.rollDeg, 10.0, accuracy: 0.01)
        XCTAssertEqual(f.pitchDeg, -5.0, accuracy: 0.01)
    }

    // MARK: - 8. Subsequent — non-zero gyro blended result

    func testNonZeroGyroBlendedResult() {
        var f = ImuFilter(tau: 0.5)
        // First update — init from accel.
        f.update(sample(rollDeg: 0.0, pitchDeg: 0.0), at: refDate)

        // Second update — gyro X = 640 => (640-512) * (2000/512) = 128 * 3.90625 = 500 dps.
        // Accel still says 0 deg. dt = 0.2s.
        // alpha = 0.5 / (0.5 + 0.2) = 0.714...
        // rollGyroIntegrated = 0 + 500 * 0.2 = 100
        // result = 0.714.. * 100 + 0.286.. * 0 = 71.43..
        let t2 = refDate.addingTimeInterval(0.2)
        let s2 = sample(gyroX: 640, rollDeg: 0.0, pitchDeg: 0.0)
        f.update(s2, at: t2)

        let expectedAlpha = 0.5 / (0.5 + 0.2)
        let expectedRoll = expectedAlpha * 100.0
        XCTAssertEqual(f.rollDeg, expectedRoll, accuracy: 0.01)
    }

    // MARK: - 9. Multiple updates — sampleCount increments

    func testSampleCountIncrements() {
        var f = ImuFilter()
        let s = sample()
        f.update(s, at: refDate)
        XCTAssertEqual(f.sampleCount, 1)

        f.update(s, at: refDate.addingTimeInterval(0.2))
        XCTAssertEqual(f.sampleCount, 2)

        f.update(s, at: refDate.addingTimeInterval(0.4))
        XCTAssertEqual(f.sampleCount, 3)

        f.update(s, at: refDate.addingTimeInterval(0.6))
        XCTAssertEqual(f.sampleCount, 4)
    }

    // MARK: - 10. Very small dt — alpha near 1.0 (gyro dominated)

    func testVerySmallDtGyroDominated() {
        var f = ImuFilter(tau: 0.5)
        f.update(sample(rollDeg: 10.0, pitchDeg: 0.0), at: refDate)

        // dt = 0.001s (clamped minimum), alpha = 0.5/(0.5+0.001) = 0.998..
        // Gyro centered = 0 dps, so rollGyroIntegrated = 10 + 0 = 10.
        // Accel says 20 deg.
        // result = 0.998 * 10 + 0.002 * 20 ≈ 10.02
        let t2 = refDate.addingTimeInterval(0.001)
        f.update(sample(rollDeg: 20.0, pitchDeg: 0.0), at: t2)

        let alpha = 0.5 / (0.5 + 0.001)
        let expected = alpha * 10.0 + (1 - alpha) * 20.0
        XCTAssertEqual(f.rollDeg, expected, accuracy: 0.01)
        // Result should be very close to the gyro-integrated value (10).
        XCTAssertTrue(f.rollDeg < 10.1, "With tiny dt, gyro dominates — roll should stay near 10")
    }

    // MARK: - 11. Very large dt (clamped to 1.0) — accel weighted

    func testLargeDtClampedAccelWeighted() {
        var f = ImuFilter(tau: 0.5)
        f.update(sample(rollDeg: 10.0, pitchDeg: 0.0), at: refDate)

        // dt = 5.0s actual, but clamped to 1.0s internally.
        // alpha = 0.5 / (0.5 + 1.0) = 0.333..
        // gyro centered = 0, so rollGyroIntegrated = 10 + 0 = 10.
        // Accel says 20 deg.
        // result = 0.333.. * 10 + 0.667.. * 20 = 3.33 + 13.33 = 16.67
        let t2 = refDate.addingTimeInterval(5.0)
        f.update(sample(rollDeg: 20.0, pitchDeg: 0.0), at: t2)

        let alpha = 0.5 / (0.5 + 1.0)
        let expected = alpha * 10.0 + (1 - alpha) * 20.0
        XCTAssertEqual(f.rollDeg, expected, accuracy: 0.01)
    }

    // MARK: - 12. Alpha calculation — tau=0.5, dt=0.2

    func testAlphaCalculationTau05Dt02() {
        var f = ImuFilter(tau: 0.5)
        // Init with roll=0.
        f.update(sample(rollDeg: 0.0, pitchDeg: 0.0), at: refDate)

        // Apply a known gyro + accel divergence to verify alpha.
        // gyro X = 512 (0 dps), accel roll = 100 deg.
        // alpha = 0.5 / 0.7 = 0.7142857..
        // rollGyroIntegrated = 0 + 0 = 0
        // result = alpha * 0 + (1-alpha) * 100 = 28.57..
        let t2 = refDate.addingTimeInterval(0.2)
        f.update(sample(rollDeg: 100.0, pitchDeg: 0.0), at: t2)

        let alpha = 0.5 / (0.5 + 0.2) // 0.7142857..
        XCTAssertEqual(alpha, 0.714, accuracy: 0.001)
        let expected = (1 - alpha) * 100.0 // ~28.57
        XCTAssertEqual(f.rollDeg, expected, accuracy: 0.01)
    }

    // MARK: - 13. Alpha calculation — tau=0.5, dt=0.5 (equal weight)

    func testAlphaEqualWeightWhenDtEqualsTau() {
        var f = ImuFilter(tau: 0.5)
        f.update(sample(rollDeg: 0.0, pitchDeg: 0.0), at: refDate)

        // dt = 0.5, alpha = 0.5 / (0.5 + 0.5) = 0.5 (equal weight).
        // gyro = 0 dps, rollGyroIntegrated = 0.
        // accel = 100. result = 0.5 * 0 + 0.5 * 100 = 50.
        let t2 = refDate.addingTimeInterval(0.5)
        f.update(sample(rollDeg: 100.0, pitchDeg: 0.0), at: t2)

        XCTAssertEqual(f.rollDeg, 50.0, accuracy: 0.01)
    }

    // MARK: - 14. Stale — never updated

    func testIsStaleNeverUpdatedReturnsFalse() {
        let f = ImuFilter()
        XCTAssertFalse(f.isStale(), "Never-updated filter should not be stale")
    }

    // MARK: - 15. Stale — just updated

    func testIsStaleJustUpdatedReturnsFalse() {
        var f = ImuFilter()
        let now = Date()
        f.update(sample(), at: now)
        XCTAssertFalse(f.isStale(now: now))
    }

    // MARK: - 16. Stale — 6 seconds ago

    func testIsStale6SecondsAgoReturnsTrue() {
        var f = ImuFilter()
        let then = Date(timeIntervalSince1970: 1_000_000)
        f.update(sample(), at: then)
        let now = then.addingTimeInterval(6.0)
        XCTAssertTrue(f.isStale(now: now))
    }

    // MARK: - 17. Stale — exactly 5 seconds (boundary)

    func testIsStaleExactly5SecondsIsNotStale() {
        var f = ImuFilter()
        let then = Date(timeIntervalSince1970: 1_000_000)
        f.update(sample(), at: then)
        let now = then.addingTimeInterval(5.0)
        XCTAssertFalse(f.isStale(now: now),
                       "Exactly 5.0s should NOT be stale (> 5.0 required)")
    }

    // MARK: - 18. Reset — clears roll and pitch

    func testResetClearsRollAndPitch() {
        var f = ImuFilter()
        f.update(sample(rollDeg: 15.0, pitchDeg: -10.0), at: refDate)
        f.reset()
        XCTAssertEqual(f.rollDeg, 0, accuracy: 0.01)
        XCTAssertEqual(f.pitchDeg, 0, accuracy: 0.01)
    }

    // MARK: - 19. Reset — clears lastUpdatedAt

    func testResetClearsLastUpdatedAt() {
        var f = ImuFilter()
        f.update(sample(), at: refDate)
        XCTAssertNotNil(f.lastUpdatedAt)
        f.reset()
        XCTAssertNil(f.lastUpdatedAt)
    }

    // MARK: - 20. Reset — clears sampleCount

    func testResetClearsSampleCount() {
        var f = ImuFilter()
        f.update(sample(), at: refDate)
        f.update(sample(), at: refDate.addingTimeInterval(0.2))
        XCTAssertEqual(f.sampleCount, 2)
        f.reset()
        XCTAssertEqual(f.sampleCount, 0)
    }

    // MARK: - 21. Equatable — identically configured filters

    func testEquatableIdenticalFilters() {
        let f1 = ImuFilter(tau: 0.5, rollDeg: 0, pitchDeg: 0)
        let f2 = ImuFilter(tau: 0.5, rollDeg: 0, pitchDeg: 0)
        XCTAssertEqual(f1, f2)
    }
}
