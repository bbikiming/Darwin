import XCTest
@testable import DarwinForgeUI

/// **v1.11.19 (2026-05-20) — ImuAttitudeDisplayMapping 단위 테스트**.
///
/// 검증:
/// 1. convention 정규화 (imuRaw / negateForwardIsNegative)
/// 2. NaN / Inf → 0 치환
/// 3. ±50° clamp
/// 4. roll 은 convention 무관
/// 5. WalkLabSession displayImu* computed property 정합
final class ImuAttitudeDisplayMappingTests: XCTestCase {

    // MARK: - 1. Convention 정규화

    func testImuRawConventionPassesThrough() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: 10, rawPitch: -15, convention: .imuRaw
        )
        XCTAssertEqual(result.roll, 10)
        XCTAssertEqual(result.pitch, -15)
    }

    func testNegateConventionFlipsPitch() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: 10, rawPitch: -15, convention: .negateForwardIsNegative
        )
        XCTAssertEqual(result.roll, 10, "roll 은 convention 무관")
        XCTAssertEqual(result.pitch, 15, "pitch 부호 반전")
    }

    func testNegateConventionPositivePitch() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: 0, rawPitch: 20, convention: .negateForwardIsNegative
        )
        XCTAssertEqual(result.pitch, -20)
    }

    func testZeroPitchUnchangedByConvention() {
        let raw = ImuAttitudeDisplayMapping.map(
            rawRoll: 5, rawPitch: 0, convention: .imuRaw
        )
        let negate = ImuAttitudeDisplayMapping.map(
            rawRoll: 5, rawPitch: 0, convention: .negateForwardIsNegative
        )
        XCTAssertEqual(raw.pitch, 0)
        XCTAssertEqual(negate.pitch, 0)
    }

    // MARK: - 2. NaN / Inf → 0

    func testNaNRollBecomesZero() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: .nan, rawPitch: 10, convention: .imuRaw
        )
        XCTAssertEqual(result.roll, 0)
        XCTAssertEqual(result.pitch, 10)
    }

    func testNaNPitchBecomesZero() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: 5, rawPitch: .nan, convention: .imuRaw
        )
        XCTAssertEqual(result.roll, 5)
        XCTAssertEqual(result.pitch, 0)
    }

    func testInfinityRollBecomesZero() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: .infinity, rawPitch: 10, convention: .imuRaw
        )
        XCTAssertEqual(result.roll, 0)
    }

    func testNegativeInfinityPitchBecomesZero() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: 0, rawPitch: -.infinity, convention: .imuRaw
        )
        XCTAssertEqual(result.pitch, 0)
    }

    func testBothNaN() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: .nan, rawPitch: .nan, convention: .negateForwardIsNegative
        )
        XCTAssertEqual(result.roll, 0)
        XCTAssertEqual(result.pitch, 0)
    }

    // MARK: - 3. ±50° Clamp

    func testClampPositiveRoll() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: 80, rawPitch: 0, convention: .imuRaw
        )
        XCTAssertEqual(result.roll, 50)
    }

    func testClampNegativeRoll() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: -75, rawPitch: 0, convention: .imuRaw
        )
        XCTAssertEqual(result.roll, -50)
    }

    func testClampPositivePitch() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: 0, rawPitch: 60, convention: .imuRaw
        )
        XCTAssertEqual(result.pitch, 50)
    }

    func testClampNegativePitch() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: 0, rawPitch: -90, convention: .imuRaw
        )
        XCTAssertEqual(result.pitch, -50)
    }

    func testClampAfterNegate() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: 0, rawPitch: -60, convention: .negateForwardIsNegative
        )
        XCTAssertEqual(result.pitch, 50, "negate(-60)=60 → clamp 50")
    }

    func testWithinRangeNotClamped() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: 30, rawPitch: -25, convention: .imuRaw
        )
        XCTAssertEqual(result.roll, 30)
        XCTAssertEqual(result.pitch, -25)
    }

    func testCustomClampDeg() {
        let result = ImuAttitudeDisplayMapping.map(
            rawRoll: 40, rawPitch: 40, convention: .imuRaw, clampDeg: 30
        )
        XCTAssertEqual(result.roll, 30)
        XCTAssertEqual(result.pitch, 30)
    }

    // MARK: - 4. sanitize (단일 축)

    func testSanitizeNormal() {
        XCTAssertEqual(ImuAttitudeDisplayMapping.sanitize(25), 25)
    }

    func testSanitizeNaN() {
        XCTAssertEqual(ImuAttitudeDisplayMapping.sanitize(.nan), 0)
    }

    func testSanitizeInfinity() {
        XCTAssertEqual(ImuAttitudeDisplayMapping.sanitize(.infinity), 0,
                       "+Inf → !isFinite → 0")
    }

    func testSanitizeNegativeInfinity() {
        XCTAssertEqual(ImuAttitudeDisplayMapping.sanitize(-.infinity), 0,
                       "-Inf → !isFinite → 0")
    }

    func testSanitizeClamp() {
        XCTAssertEqual(ImuAttitudeDisplayMapping.sanitize(80), 50)
        XCTAssertEqual(ImuAttitudeDisplayMapping.sanitize(-70), -50)
    }

    // MARK: - 5. defaultClampDeg = BalanceState.emergency 정합

    func testDefaultClampMatchesEmergencyThreshold() {
        XCTAssertEqual(ImuAttitudeDisplayMapping.defaultClampDeg, 50,
                       "display clamp = BalanceState.emergency 임계 50° 정합")
    }

    // MARK: - 6. WalkLabSession display computed properties

    @MainActor
    func testSessionDisplayRollUsesMapping() {
        let session = WalkLabSession()
        session.imuRollDeg = 30
        XCTAssertEqual(session.displayImuRollDeg, 30)

        session.imuRollDeg = 80
        XCTAssertEqual(session.displayImuRollDeg, 50, "clamp 적용")
    }

    @MainActor
    func testSessionDisplayPitchRespectsConvention() {
        let session = WalkLabSession()
        session.imuPitchDeg = -10

        session.balanceExperimentConfig = BalanceExperimentConfig(
            pitchInputConvention: .imuRaw
        )
        XCTAssertEqual(session.displayImuPitchDeg, -10)

        session.balanceExperimentConfig = BalanceExperimentConfig(
            pitchInputConvention: .negateForwardIsNegative
        )
        XCTAssertEqual(session.displayImuPitchDeg, 10, "negate convention")
    }

    @MainActor
    func testSessionDisplayPitchNaNGuard() {
        let session = WalkLabSession()
        session.imuPitchDeg = .nan
        XCTAssertEqual(session.displayImuPitchDeg, 0)
    }

    @MainActor
    func testSessionDisplayRollNaNGuard() {
        let session = WalkLabSession()
        session.imuRollDeg = .nan
        XCTAssertEqual(session.displayImuRollDeg, 0)
    }

    // MARK: - 7. normalizeConvention (unclamped)

    func testNormalizeConventionNoClamp() {
        let result = ImuAttitudeDisplayMapping.normalizeConvention(
            rawRoll: 80, rawPitch: -70, convention: .imuRaw
        )
        XCTAssertEqual(result.roll, 80, "clamp 없음 — raw 80 유지")
        XCTAssertEqual(result.pitch, -70, "clamp 없음 — raw -70 유지")
    }

    func testNormalizeConventionNegateNoClamp() {
        let result = ImuAttitudeDisplayMapping.normalizeConvention(
            rawRoll: 10, rawPitch: -60, convention: .negateForwardIsNegative
        )
        XCTAssertEqual(result.roll, 10)
        XCTAssertEqual(result.pitch, 60, "negate 적용, clamp 없음")
    }

    func testNormalizeConventionNaNGuard() {
        let result = ImuAttitudeDisplayMapping.normalizeConvention(
            rawRoll: .nan, rawPitch: .infinity, convention: .imuRaw
        )
        XCTAssertEqual(result.roll, 0)
        XCTAssertEqual(result.pitch, 0)
    }
}
