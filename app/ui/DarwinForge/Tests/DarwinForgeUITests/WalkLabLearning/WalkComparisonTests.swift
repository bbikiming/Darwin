import XCTest
@testable import DarwinForgeUI

final class WalkComparisonTests: XCTestCase {

    // 11) A/B 비교는 한 변수만 바뀐 session 끼리만 허용.
    func testABComparisonRequiresSingleChangedVariable() throws {
        let baselineFile = WalkSessionFixtures.v2CleanFile(
            sessionId: "baseline-A",
            algorithmMode: "robotisPControl",
            sign: "robotisWalkingCpp",
            gain: "robotisOriginal",
            durationSec: 12, sampleRateHz: 20, intensityLevel: 2
        )
        // 두 변수 바뀜: algorithm + sign.
        let expTwoChangesFile = WalkSessionFixtures.v2CleanFile(
            sessionId: "exp-two-changes",
            algorithmMode: "hybridBA",
            sign: "alternateDiagnostic",
            gain: "robotisOriginal",
            durationSec: 12, sampleRateHz: 20, intensityLevel: 2
        )
        let baseline = try WalkSessionDecoder.decode(lines: baselineFile.split(separator: "\n").map(String.init))
        let expTwo = try WalkSessionDecoder.decode(lines: expTwoChangesFile.split(separator: "\n").map(String.init))
        let eligTwo = WalkComparisonEngine.eligibility(baseline: baseline, experiment: expTwo)
        XCTAssertFalse(eligTwo.isEligible, "변수 두 개가 동시에 바뀌면 비교 불가")

        // 한 변수만 바뀜.
        let expOneChangeFile = WalkSessionFixtures.v2CleanFile(
            sessionId: "exp-one-change",
            algorithmMode: "hybridBA",
            sign: "robotisWalkingCpp",
            gain: "robotisOriginal",
            durationSec: 12, sampleRateHz: 20, intensityLevel: 2
        )
        let expOne = try WalkSessionDecoder.decode(lines: expOneChangeFile.split(separator: "\n").map(String.init))
        let eligOne = WalkComparisonEngine.eligibility(baseline: baseline, experiment: expOne)
        XCTAssertTrue(eligOne.isEligible, "한 변수만 바뀌면 비교 가능. reasons: \(eligOne.reasons)")
    }

    func testIncomparableWhenPresetDiffers() throws {
        let aFile = WalkSessionFixtures.v2CleanFile(sessionId: "a", preset: "march",
                                                     durationSec: 12, sampleRateHz: 20)
        let bFile = WalkSessionFixtures.v2CleanFile(sessionId: "b", preset: "slowWalk",
                                                     durationSec: 12, sampleRateHz: 20)
        let a = try WalkSessionDecoder.decode(lines: aFile.split(separator: "\n").map(String.init))
        let b = try WalkSessionDecoder.decode(lines: bFile.split(separator: "\n").map(String.init))
        let elig = WalkComparisonEngine.eligibility(baseline: a, experiment: b)
        XCTAssertFalse(elig.isEligible)
        XCTAssertTrue(elig.reasons.contains(where: { $0.contains("preset") }))
    }

    func testIncomparableWhenBaselineQualityIsPoor() throws {
        let poorFile = WalkSessionFixtures.v1LegacyFile(durationSec: 8, sampleRateHz: 14.8)
        let goodFile = WalkSessionFixtures.v2CleanFile(durationSec: 12, sampleRateHz: 20,
                                                        intensityLevel: 3)
        let poor = try WalkSessionDecoder.decode(lines: poorFile.split(separator: "\n").map(String.init))
        let good = try WalkSessionDecoder.decode(lines: goodFile.split(separator: "\n").map(String.init))
        let elig = WalkComparisonEngine.eligibility(baseline: poor, experiment: good)
        XCTAssertFalse(elig.isEligible)
    }
}
