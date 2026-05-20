import XCTest
@testable import DarwinForgeUI

final class WalkSessionCodableTests: XCTestCase {

    func testHeaderV2RoundTrip() throws {
        let header = WalkSessionHeaderV2(
            sessionId: "test", startTimeIso: "2026-05-17T12:00:00.000Z",
            appVersion: "1.0", gitCommit: "abc123",
            isRealRobot: true, supportMode: "floor",
            preset: "march",
            walkTuning: WalkTuningSnapshot(periodMs: 600, xStrideM: 0.02, yStrideM: 0, aTurnRad: 0),
            balanceAlgorithmMode: "hybridBA",
            balanceSignConvention: "robotisWalkingCpp",
            balanceGainProfile: "v110Recommended",
            correctorIntensityLevelAtStart: 2,
            correctionApplyMode: "robotApplied",
            imuSourceAtStart: "real",
            comparisonTag: WalkComparisonTag(groupId: "g1", arm: "A",
                                              variableChanged: .algorithm)
        )
        let data = try JSONEncoder().encode(header)
        let restored = try JSONDecoder().decode(WalkSessionHeaderV2.self, from: data)
        XCTAssertEqual(restored, header)
    }

    func testSampleV2RoundTrip() throws {
        let s = WalkSessionSampleV2(
            tMs: 100, wallTimeIso: "2026-05-17T12:00:00.100Z",
            tickIndex: 2, tickDtMs: 50,
            preset: "march",
            walkPeriodMs: 600, walkCycleElapsedMs: 100, walkPhase01: 0.167,
            imuSource: "real", imuSampleAgeMs: 30,
            imuRollDeg: 0.5, imuPitchDeg: -10.0,
            balanceAlgorithmMode: "hybridBA",
            balanceSignConvention: "robotisWalkingCpp",
            balanceGainProfile: "v110Recommended",
            correctionAppliedToRobot: true, observeOnly: false,
            effectivePitchErrDeg: -10, effectiveRollErrDeg: 0.5,
            correctorDeltas: [0, 0, -0.1, 0.1, -0.3, 0.3, 0, 0],
            appliedDeltas: [0, 0, -0.1, 0.1, -0.3, 0.3, 0, 0],
            maxCorrectionDeg: 15, balanceState: "ok",
            intensityLevel: 2
        )
        let data = try JSONEncoder().encode(s)
        let restored = try JSONDecoder().decode(WalkSessionSampleV2.self, from: data)
        XCTAssertEqual(restored, s)
    }

    func testEventV2RoundTrip() throws {
        let e = WalkSessionEventV2(
            tMs: 100, wallTimeIso: "iso",
            kind: WalkSessionEventKind.algorithmModeChange.rawValue,
            severity: "info", message: "switched", payload: ["from": "off", "to": "hybridBA"]
        )
        let data = try JSONEncoder().encode(e)
        let restored = try JSONDecoder().decode(WalkSessionEventV2.self, from: data)
        XCTAssertEqual(restored, e)
    }

    func testQualityRoundTrip() throws {
        let q = WalkSessionDataQuality(
            useClass: .usableForBiasOnly, grade: .C, reasons: [.duplicateRatioTooHigh],
            durationSec: 8, sampleCount: 120, independentImuSampleCount: 12,
            imuDuplicateRatio: 0.9, nominalSampleRateHz: 15, effectiveImuRateHz: 1.5,
            medianImuAgeMs: 40, p95ImuAgeMs: 80, staleRatio: 0,
            busFailureCount: 0, emergencyCount: 0
        )
        let data = try JSONEncoder().encode(q)
        let restored = try JSONDecoder().decode(WalkSessionDataQuality.self, from: data)
        XCTAssertEqual(restored, q)
    }

    func testRecommendationRoundTrip() throws {
        let r = WalkSessionRecommendation(
            action: .markSignSuspicious, confidence: 0.6,
            reason: "lagged effectiveness negative",
            recommendedIntensityLevel: 2,
            trialPurpose: .signDiagnosticObserveOnly
        )
        let data = try JSONEncoder().encode(r)
        let restored = try JSONDecoder().decode(WalkSessionRecommendation.self, from: data)
        XCTAssertEqual(restored, r)
    }

    func testSummaryV2RoundTrip() throws {
        let q = WalkSessionDataQuality(
            useClass: .usableForBiasOnly, grade: .C, reasons: [.healthy],
            durationSec: 8, sampleCount: 120, independentImuSampleCount: 100,
            imuDuplicateRatio: 0.1, nominalSampleRateHz: 20, effectiveImuRateHz: 18,
            medianImuAgeMs: 25, p95ImuAgeMs: 60, staleRatio: 0,
            busFailureCount: 0, emergencyCount: 0
        )
        let r = WalkSessionRecommendation(action: .keepCurrent, confidence: 0.7, reason: "stable")
        let s = WalkSessionSummaryV2(
            id: "id", preset: "march", startTimeIso: "iso",
            durationSec: 8, sessionId: "sid", dataQuality: q,
            meanRollDeg: 0, meanPitchDeg: -1, meanAbsRollDeg: 2, meanAbsPitchDeg: 1,
            peakAbsRollDeg: 4, peakAbsPitchDeg: 3, rollStdevDeg: 2, pitchStdevDeg: 1,
            pitchBiasDeg: -1, rollBiasDeg: 0,
            recommendation: r
        )
        let data = try JSONEncoder().encode(s)
        let restored = try JSONDecoder().decode(WalkSessionSummaryV2.self, from: data)
        XCTAssertEqual(restored, s)
    }

    func testComparisonVariableCodable() throws {
        for variable in WalkComparisonVariable.allCases {
            let data = try JSONEncoder().encode(variable)
            let restored = try JSONDecoder().decode(WalkComparisonVariable.self, from: data)
            XCTAssertEqual(restored, variable)
        }
    }
}
