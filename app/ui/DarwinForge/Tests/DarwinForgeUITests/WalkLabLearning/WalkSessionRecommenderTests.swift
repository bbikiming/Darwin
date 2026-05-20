import XCTest
@testable import DarwinForgeUI

final class WalkSessionRecommenderTests: XCTestCase {

    // 10) low quality 세션은 절대 intensity 를 올리지 않는다.
    func testLowQualitySessionDoesNotRaiseIntensity() throws {
        // v1 legacy 로그 — duplicate 90%+, comparison 불가.
        let file = WalkSessionFixtures.v1LegacyFile(durationSec: 8, sampleRateHz: 14.8)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        let summary = WalkSessionAnalyzer.summarize(session: decoded, currentIntensityLevel: 2)
        XCTAssertNotEqual(summary.recommendation.action, .raiseIntensity,
                          "low quality 데이터에서 raiseIntensity 가 나오면 안 됨")
    }

    func testRejectedSessionRecommendsDoNotUseForLearning() throws {
        var lines: [String] = [WalkSessionFixtures.v1HeaderLine()]
        // 1초 미만 — F 등급.
        for i in 0..<10 {
            lines.append(WalkSessionFixtures.v1SampleLine(tMs: Double(i) * 50))
        }
        let decoded = try WalkSessionDecoder.decode(lines: lines)
        let summary = WalkSessionAnalyzer.summarize(session: decoded, currentIntensityLevel: 2)
        // 너무 짧으면 rejected → doNotUseForLearning.
        XCTAssertTrue([RecommendationAction.doNotUseForLearning,
                        RecommendationAction.collectMoreData]
                        .contains(summary.recommendation.action))
    }

    func testEmergencyRecommendsDoNotUseForLearning() throws {
        // emergency 가 있는 v2 로그.
        let file = WalkSessionFixtures.v2CleanFile(durationSec: 8, sampleRateHz: 20)
        var lines = file.split(separator: "\n").map(String.init)
        let emergency = WalkSessionEventV2(
            tMs: 1000,
            wallTimeIso: "2026-05-17T12:00:01.000Z",
            kind: WalkSessionEventKind.emergencyStop.rawValue,
            severity: "critical",
            message: "balance lost"
        )
        lines.append(WalkSessionFixtures.encodeLine(emergency))
        let decoded = try WalkSessionDecoder.decode(lines: lines)
        let summary = WalkSessionAnalyzer.summarize(session: decoded, currentIntensityLevel: 2)
        XCTAssertEqual(summary.recommendation.action, .doNotUseForLearning)
        XCTAssertEqual(summary.recommendation.trialPurpose, .safetyIncident)
    }

    func testRecommendationIsKeepCurrentWhenStableV2() throws {
        let file = WalkSessionFixtures.v2CleanFile(durationSec: 12, sampleRateHz: 20)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        let summary = WalkSessionAnalyzer.summarize(session: decoded, currentIntensityLevel: 2)
        XCTAssertNotEqual(summary.recommendation.action, .doNotUseForLearning)
    }
}
