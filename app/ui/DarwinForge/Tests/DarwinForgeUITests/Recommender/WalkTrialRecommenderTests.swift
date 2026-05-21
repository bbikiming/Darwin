import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.16.0 (2026-05-21) Phase 2 — Recommender 단위 테스트**.
///
/// Rule-based + Coordinate Descent 의 결정 logic 검증.
/// - 데이터 부족 (< 3 trial) → nil
/// - good trial 평균 계산
/// - coord descent 축 round-robin + ±10% nudge
@MainActor
final class WalkTrialRecommenderTests: XCTestCase {

    private var tempDir: URL!
    private var store: WalkTrialStore!
    private var recommender: WalkTrialRecommender!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecommenderTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = WalkTrialStore(testDirectory: tempDir)
        recommender = WalkTrialRecommender(store: store)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        store = nil
        recommender = nil
        try await super.tearDown()
    }

    // MARK: - Rule-based

    func testRuleBasedReturnsNilWhenFewerThan3Trials() {
        store.append(makeTrial(id: "a", preset: "march", score: 0.9, falls: 0))
        store.append(makeTrial(id: "b", preset: "march", score: 0.85, falls: 0))
        let rec = recommender.ruleBased(for: "march")
        XCTAssertNil(rec, "trial < 3 → nil")
    }

    func testRuleBasedReturnsNilWhenNoGoodTrials() {
        for i in 0..<5 {
            store.append(makeTrial(id: "low\(i)", preset: "march", score: 0.5, falls: 2))
        }
        let rec = recommender.ruleBased(for: "march")
        XCTAssertNil(rec, "good trial 0개 → nil")
    }

    func testRuleBasedReturnsAverageOfTopTrials() {
        // 3개 good trial + 1개 bad — bad 는 무시.
        store.append(makeTrial(id: "g1", preset: "march", score: 0.9, falls: 0, stride: 20))
        store.append(makeTrial(id: "g2", preset: "march", score: 0.9, falls: 0, stride: 30))
        store.append(makeTrial(id: "g3", preset: "march", score: 0.9, falls: 0, stride: 25))
        store.append(makeTrial(id: "bad", preset: "march", score: 0.3, falls: 2, stride: 100))
        let rec = recommender.ruleBased(for: "march")
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.strategy, .ruleBased)
        XCTAssertEqual(rec?.preset, "march")
        XCTAssertEqual(rec?.tuning.strideMm ?? 0, 25, accuracy: 1e-9,
                       "good trial 3개 평균 = 25 (bad 의 100 미반영)")
        XCTAssertEqual(rec?.sourceSampleIds.count, 3)
    }

    func testRuleBasedDataMaturityScalesWithSampleCount() {
        for i in 0..<3 {
            store.append(makeTrial(id: "g\(i)", preset: "march", score: 0.85, falls: 0))
        }
        let rec3 = recommender.ruleBased(for: "march")
        XCTAssertEqual(rec3?.dataMaturity ?? 0, 0.6, accuracy: 1e-9, "3/5 = 0.6")

        for i in 0..<2 {
            store.append(makeTrial(id: "g\(i+3)", preset: "march", score: 0.85, falls: 0))
        }
        let rec5 = recommender.ruleBased(for: "march")
        XCTAssertEqual(rec5?.dataMaturity ?? 0, 1.0, accuracy: 1e-9, "5/5 = 1.0")
    }

    // MARK: - Coordinate Descent

    func testCoordDescentReturnsNilWhenFewerThan5Trials() {
        for i in 0..<3 {
            store.append(makeTrial(id: "t\(i)", preset: "march", score: 0.7, falls: 0))
        }
        let rec = recommender.coordinateDescent(for: "march")
        XCTAssertNil(rec, "trial < 5 → nil")
    }

    func testCoordDescentUsesBestTrialAsBaseline() {
        store.append(makeTrial(id: "low", preset: "march", score: 0.3, falls: 0, stride: 10))
        store.append(makeTrial(id: "mid", preset: "march", score: 0.6, falls: 0, stride: 15))
        store.append(makeTrial(id: "best", preset: "march", score: 0.95, falls: 0, stride: 20))
        store.append(makeTrial(id: "mid2", preset: "march", score: 0.5, falls: 0, stride: 30))
        store.append(makeTrial(id: "low2", preset: "march", score: 0.2, falls: 0, stride: 40))
        let rec = recommender.coordinateDescent(for: "march")
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.strategy, .coordinateDescent)
        XCTAssertEqual(rec?.sourceSampleIds, ["best"], "최고 score trial 이 baseline")
    }

    func testCoordDescentNudgesOneAxisByTenPercent() {
        // 5개 trial — period 600ms baseline.
        for i in 0..<5 {
            store.append(makeTrial(id: "t\(i)", preset: "march", score: 0.5 + Double(i) * 0.1,
                                   falls: 0, periodMs: 600))
        }
        let rec = recommender.coordinateDescent(for: "march")
        XCTAssertNotNil(rec)
        // period 가 baseline 600 에서 ±10% 변화 했는지 또는 다른 축 변화.
        // 5 trial → axis = 5 % 4 = 1 (stride 축). baseline stride 20 → 18 or 22 (±10%).
        // 정확한 axis 검증은 다른 트래커 — 여기선 baseline 과 다른 값 보장만.
        let tuning = rec?.tuning
        let baseline = TuningSnapshot(strideMm: 20, sideMm: 0, turnDeg: 0,
                                      periodMs: 600, footHeightMm: 40, balanceGain: 1.0)
        let same = (tuning?.strideMm == baseline.strideMm
                    && tuning?.periodMs == baseline.periodMs
                    && tuning?.balanceGain == baseline.balanceGain)
                && (rec?.intensityLevel == 2)
        XCTAssertFalse(same, "baseline 과 한 축이 ±10% 다름")
    }

    // MARK: - 통합 recommend()

    func testRecommendReturnsMultipleStrategiesWhenEnoughData() {
        // 5개 good trial — 두 strategy 모두 발화.
        for i in 0..<5 {
            store.append(makeTrial(id: "g\(i)", preset: "march", score: 0.85, falls: 0))
        }
        let recs = recommender.recommend(for: "march")
        XCTAssertGreaterThanOrEqual(recs.count, 2,
                                    "rule-based + coord descent 둘 다 활성")
        let strategies = Set(recs.map { $0.strategy })
        XCTAssertTrue(strategies.contains(.ruleBased))
        XCTAssertTrue(strategies.contains(.coordinateDescent))
    }

    func testRecommendReturnsEmptyWhenNoData() {
        let recs = recommender.recommend(for: "march")
        XCTAssertTrue(recs.isEmpty)
    }

    // MARK: - Fixtures

    private func makeTrial(
        id: String, preset: String, score: Double, falls: Int,
        stride: Double = 20, periodMs: Double = 600
    ) -> WalkTrial {
        WalkTrial(
            id: id,
            startedAtIso: "2026-05-21T10:00:00Z",
            endedAtIso: "2026-05-21T10:00:10Z",
            durationSec: 10,
            endReason: .userStop,
            config: TrialConfig(
                preset: preset, presetSafety: "safe", intensityLevel: 2,
                balanceConfig: .defaultRobotis,
                enableBalanceCorrection: true,
                tuning: TuningSnapshot(strideMm: stride, sideMm: 0, turnDeg: 0,
                                       periodMs: periodMs, footHeightMm: 40, balanceGain: 1.0),
                walkingEngine: "macSparseKeyframe",
                isRealRobot: false
            ),
            outcome: TrialOutcome(
                stabilityScore: score, smoothnessScore: score, energyScore: score,
                overallScore: score,
                stateDistribution: ["normal": 1.0, "caution": 0, "warning": 0, "danger": 0, "emergency": 0],
                fallEventCount: falls, meanTimeBetweenFallsSec: nil,
                peakAbsRollDeg: 0, peakAbsPitchDeg: 0, meanAbsRollDeg: 0, meanAbsPitchDeg: 0,
                peakMotorTempC: 35, busWriteFailures: 0, stepsExecuted: 30, sampleCount: 100
            ),
            label: nil,
            timeseries: nil
        )
    }
}
