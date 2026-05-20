import XCTest
@testable import DarwinForgeUI

final class WalkSessionQualityTests: XCTestCase {

    // 3) Duplicate ratio 높은 세션은 comparison 등급 받지 않는다.
    func testDataQualityRejectsHighDuplicateRatio() throws {
        let file = WalkSessionFixtures.v1LegacyFile(durationSec: 12, sampleRateHz: 14.8)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        let quality = WalkSessionQualityAnalyzer.analyze(session: decoded)
        XCTAssertGreaterThan(quality.imuDuplicateRatio, 0.6)
        XCTAssertNotEqual(quality.useClass, .usableForComparison,
                          "duplicate ratio 가 높은 v1 로그가 comparison 으로 분류되면 안 됨")
        XCTAssertTrue(quality.reasons.contains(.duplicateRatioTooHigh) ||
                      quality.reasons.contains(.legacySchemaMissingFields))
    }

    // 4) sampleCount 가 아니라 independent IMU 기준.
    func testDataQualityUsesIndependentImuSampleCount() throws {
        // 200 sample 인데 IMU 가 5개만 변하는 경우 — 독립 샘플 부족으로 분류.
        var lines: [String] = [WalkSessionFixtures.v1HeaderLine()]
        for i in 0..<200 {
            let group = i / 40 // 5 unique IMU values 만 사용
            let roll = Double(group) * 0.5
            let pitch = -10 + Double(group) * 0.3
            lines.append(WalkSessionFixtures.v1SampleLine(tMs: Double(i) * 50, imuRoll: roll, imuPitch: pitch))
        }
        let decoded = try WalkSessionDecoder.decode(lines: lines)
        let quality = WalkSessionQualityAnalyzer.analyze(session: decoded)
        XCTAssertEqual(quality.sampleCount, 200)
        XCTAssertLessThan(quality.independentImuSampleCount, 10)
        XCTAssertTrue(quality.reasons.contains(.independentImuTooLow))
        // 200 sample 있어도 comparison 등급은 안 됨.
        XCTAssertNotEqual(quality.useClass, .usableForComparison)
    }

    // 5) 짧은 세션은 inconclusive.
    func testShortSessionIsInconclusive() throws {
        let file = WalkSessionFixtures.v1LegacyFile(durationSec: 2.5, sampleRateHz: 14.8)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        let quality = WalkSessionQualityAnalyzer.analyze(session: decoded)
        XCTAssertTrue([WalkSessionUseClass.inconclusive, .rejected].contains(quality.useClass))
        XCTAssertEqual(quality.grade, .D)
    }

    // 6) algorithm/sign 필드가 없는 v1 로그는 comparison 불가.
    func testMissingAlgorithmFieldsPreventsComparisonUse() throws {
        let file = WalkSessionFixtures.v1LegacyFile(durationSec: 12, sampleRateHz: 14.8)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        let quality = WalkSessionQualityAnalyzer.analyze(session: decoded)
        XCTAssertNil(decoded.header.balanceAlgorithmMode)
        XCTAssertNotEqual(quality.useClass, .usableForComparison)
        XCTAssertTrue(quality.reasons.contains(.algorithmFieldsMissing) ||
                      quality.reasons.contains(.legacySchemaMissingFields))
    }

    func testCleanV2SessionGetsHighGrade() throws {
        let file = WalkSessionFixtures.v2CleanFile(durationSec: 12, sampleRateHz: 20)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        let quality = WalkSessionQualityAnalyzer.analyze(session: decoded)
        XCTAssertEqual(quality.useClass, .usableForComparison)
        XCTAssertTrue([WalkSessionGrade.A, .B].contains(quality.grade))
    }

    func testEmergencyMarksSafetyReview() throws {
        var lines: [String] = []
        let header = WalkSessionHeaderV2(
            sessionId: "test-emergency",
            startTimeIso: "2026-05-17T12:00:00.000Z",
            appVersion: "1.0.0-test",
            isRealRobot: true,
            preset: "march",
            walkTuning: WalkTuningSnapshot(periodMs: 600, xStrideM: 0, yStrideM: 0, aTurnRad: 0),
            balanceAlgorithmMode: "robotisPControl",
            balanceSignConvention: "robotisWalkingCpp",
            balanceGainProfile: "robotisOriginal",
            correctorIntensityLevelAtStart: 2,
            correctionApplyMode: "robotApplied",
            imuSourceAtStart: "real"
        )
        lines.append(WalkSessionFixtures.encodeLine(header))
        for i in 0..<100 {
            let s = WalkSessionSampleV2(
                tMs: Double(i) * 50,
                wallTimeIso: "2026-05-17T12:00:00.000Z",
                tickIndex: i,
                tickDtMs: 50,
                preset: "march",
                walkPeriodMs: 600,
                walkCycleElapsedMs: 0,
                walkPhase01: 0.1,
                imuSource: "real",
                imuRollDeg: Double(i) * 0.3,
                imuPitchDeg: -10,
                balanceAlgorithmMode: "robotisPControl",
                balanceSignConvention: "robotisWalkingCpp",
                balanceGainProfile: "robotisOriginal",
                correctionAppliedToRobot: true,
                observeOnly: false,
                effectivePitchErrDeg: -10,
                effectiveRollErrDeg: 0,
                correctorDeltas: [0,0,0,0,0,0,0,0],
                appliedDeltas: [0,0,0,0,0,0,0,0],
                maxCorrectionDeg: 15,
                balanceState: "danger",
                intensityLevel: 2
            )
            lines.append(WalkSessionFixtures.encodeLine(s))
        }
        let emergency = WalkSessionEventV2(
            tMs: 5000,
            wallTimeIso: "2026-05-17T12:00:05.000Z",
            kind: WalkSessionEventKind.emergencyStop.rawValue,
            severity: "critical",
            message: "balance lost"
        )
        lines.append(WalkSessionFixtures.encodeLine(emergency))
        let decoded = try WalkSessionDecoder.decode(lines: lines)
        let quality = WalkSessionQualityAnalyzer.analyze(session: decoded)
        XCTAssertGreaterThan(quality.emergencyCount, 0)
        XCTAssertEqual(quality.useClass, .usableForSafetyReview)
        XCTAssertEqual(quality.grade, .F)
    }
}
