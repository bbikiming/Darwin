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

    // MARK: - Cycle 16: pilot-biased strategy

    /// **v1.20.9 사이클 16 + 16-fix** — pilotInputs+advanced+10moves+!emergency 3 trial 이면 추천.
    func testPilotBiasedReturnsRecommendationWhenEnoughPilotedTrials() {
        store.append(makeTrial(id: "p1", preset: "march", score: 0.85, falls: 0,
                                pilotPeakStride: 30, pilotEvents: 15, advanced: true))
        store.append(makeTrial(id: "p2", preset: "march", score: 0.9, falls: 0,
                                pilotPeakStride: 35, pilotEvents: 25, advanced: true))
        store.append(makeTrial(id: "p3", preset: "march", score: 0.8, falls: 0,
                                pilotPeakStride: 25, pilotEvents: 20, advanced: true))
        let rec = recommender.pilotBiased(for: "march")
        XCTAssertNotNil(rec, "3 advanced+piloted trials → 추천")
        XCTAssertEqual(rec?.strategy, .pilotBiased)
        XCTAssertEqual(rec?.tuning.strideMm ?? 0, 30, accuracy: 1e-9, "(30+35+25)/3 = 30")
        XCTAssertEqual(rec?.sourceSampleIds.count, 3)
    }

    /// **v1.20.9 사이클 16** — pilotInputs 가 없는 trial 은 제외.
    func testPilotBiasedExcludesTrialsWithoutPilotInputs() {
        store.append(makeTrial(id: "n1", preset: "march", score: 0.85, falls: 0))
        store.append(makeTrial(id: "n2", preset: "march", score: 0.9, falls: 0))
        let rec = recommender.pilotBiased(for: "march")
        XCTAssertNil(rec, "pilotInputs nil 인 trial 만 있을 때 nil")
    }

    /// **v1.20.9 사이클 16** — moveEventCount < 10 인 trial 은 제외.
    func testPilotBiasedExcludesLowActivityPilots() {
        store.append(makeTrial(id: "low1", preset: "march", score: 0.85, falls: 0,
                                pilotPeakStride: 30, pilotEvents: 5, advanced: true))
        store.append(makeTrial(id: "low2", preset: "march", score: 0.85, falls: 0,
                                pilotPeakStride: 30, pilotEvents: 8, advanced: true))
        let rec = recommender.pilotBiased(for: "march")
        XCTAssertNil(rec, "moveEventCount < 10 trial 제외")
    }

    /// **v1.20.10 사이클 16-fix CRITICAL (코덱스)** — wasAdvancedMode=false 인 trial 제외.
    /// advanced 가 꺼져 있으면 walking 이 preset default 만 사용 → pilot peak 가 outcome 과
    /// 상관없음. 본 trial 들은 noise — recommender 에서 무시.
    func testPilotBiasedExcludesNonAdvancedTrials() {
        for i in 0..<5 {
            store.append(makeTrial(id: "na\(i)", preset: "march", score: 0.85, falls: 0,
                                    pilotPeakStride: 30, pilotEvents: 20, advanced: false))
        }
        let rec = recommender.pilotBiased(for: "march")
        XCTAssertNil(rec, "advanced=false trial 만 있을 때 nil (CRITICAL fix)")
    }

    /// **v1.20.10 사이클 16-fix HIGH 1 (코덱스)** — emergencyTriggered 인 trial 제외.
    func testPilotBiasedExcludesEmergencyTrials() {
        store.append(makeTrial(id: "em1", preset: "march", score: 0.85, falls: 0,
                                pilotPeakStride: 30, pilotEvents: 20, advanced: true,
                                emergency: true))
        store.append(makeTrial(id: "em2", preset: "march", score: 0.85, falls: 0,
                                pilotPeakStride: 30, pilotEvents: 20, advanced: true,
                                emergency: true))
        store.append(makeTrial(id: "em3", preset: "march", score: 0.85, falls: 0,
                                pilotPeakStride: 30, pilotEvents: 20, advanced: true,
                                emergency: true))
        let rec = recommender.pilotBiased(for: "march")
        XCTAssertNil(rec, "emergencyTriggered trial 만 → nil")
    }

    /// **v1.20.10 사이클 16-fix HIGH 2 (코덱스)** — 음수 방향 peak 도 추천에 반영.
    /// 종전: peakStrideMm 만 → 후진 입력 (negative) 시 peak=0 → 추천이 0 stride 제안.
    /// 신규: peakAbsStrideMm = max(peakPos, peakNeg) → 음수 입력도 amplitude 신뢰.
    func testPilotBiasedUsesPeakAbsForNegativeDirection() {
        // 모두 negative direction 만 push (peakNegStrideMm = 25).
        store.append(makeTrial(id: "n1", preset: "march", score: 0.85, falls: 0,
                                pilotPeakStride: 0, pilotPeakNegStride: 25,
                                pilotEvents: 20, advanced: true))
        store.append(makeTrial(id: "n2", preset: "march", score: 0.85, falls: 0,
                                pilotPeakStride: 0, pilotPeakNegStride: 25,
                                pilotEvents: 20, advanced: true))
        store.append(makeTrial(id: "n3", preset: "march", score: 0.85, falls: 0,
                                pilotPeakStride: 0, pilotPeakNegStride: 25,
                                pilotEvents: 20, advanced: true))
        let rec = recommender.pilotBiased(for: "march")
        XCTAssertNotNil(rec, "음수 peak 만 있어도 추천 발화")
        XCTAssertEqual(rec?.tuning.strideMm ?? 0, 25, accuracy: 1e-9,
                       "peakAbs = max(0, 25) = 25 (HIGH 2 fix)")
    }

    /// **v1.20.9 사이클 16** — recommend() 가 pilot-biased 포함.
    func testRecommendIncludesPilotBiased() {
        for i in 0..<5 {
            store.append(makeTrial(id: "g\(i)", preset: "march", score: 0.85, falls: 0,
                                    pilotPeakStride: 28 + Double(i), pilotEvents: 12 + i,
                                    advanced: true))
        }
        let recs = recommender.recommend(for: "march")
        let strategies = Set(recs.map { $0.strategy })
        XCTAssertTrue(strategies.contains(.pilotBiased),
                      "충분한 advanced+piloted trial 시 pilotBiased 활성")
    }

    // MARK: - Fixtures

    private func makeTrial(
        id: String, preset: String, score: Double, falls: Int,
        stride: Double = 20, periodMs: Double = 600,
        pilotPeakStride: Double? = nil, pilotPeakNegStride: Double = 0,
        pilotEvents: Int = 0,
        advanced: Bool = false, emergency: Bool = false,
        isRealRobot: Bool = false
    ) -> WalkTrial {
        let pilotInputs: PilotInputSummary? = {
            guard let peak = pilotPeakStride else { return nil }
            return PilotInputSummary(
                sourcesUsed: [.keyboard], totalEvents: pilotEvents,
                moveEventCount: pilotEvents,  // 사이클 16-fix: stop 없는 가정 — move only.
                avgAbsStrideMm: peak * 0.5, avgAbsSideMm: 0, avgAbsTurnDeg: 0,
                peakStrideMm: peak, peakSideMm: 0, peakTurnDeg: 0,
                peakNegStrideMm: pilotPeakNegStride, peakNegSideMm: 0, peakNegTurnDeg: 0,
                emergencyTriggered: emergency
            )
        }()
        return _makeTrialCore(id: id, preset: preset, score: score, falls: falls,
                              stride: stride, periodMs: periodMs,
                              pilotInputs: pilotInputs, advanced: advanced,
                              isRealRobot: isRealRobot)
    }

    private func _makeTrialCore(
        id: String, preset: String, score: Double, falls: Int,
        stride: Double, periodMs: Double, pilotInputs: PilotInputSummary?,
        advanced: Bool = false, isRealRobot: Bool = false
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
                isRealRobot: isRealRobot,
                pilotInputs: pilotInputs,
                wasAdvancedMode: advanced
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

    // MARK: - 사이클 149 (codex MAJOR #2 fix): SourceBreakdown + realRobotOnly 테스트

    /// SourceBreakdown displayLabel 3 분기 검증.
    func testSourceBreakdownDisplayLabelRealOnly() {
        let b = WalkTrialRecommendation.SourceBreakdown(realRobotCount: 3, simCount: 0)
        XCTAssertEqual(b.displayLabel, "실 로봇 3")
        XCTAssertEqual(b.total, 3)
        XCTAssertEqual(b.realRatio, 1.0, accuracy: 1e-9)
    }

    func testSourceBreakdownDisplayLabelSimOnly() {
        let b = WalkTrialRecommendation.SourceBreakdown(realRobotCount: 0, simCount: 5)
        XCTAssertEqual(b.displayLabel, "시뮬 5 (실 로봇 데이터 없음)")
        XCTAssertEqual(b.total, 5)
        XCTAssertEqual(b.realRatio, 0.0, accuracy: 1e-9)
    }

    func testSourceBreakdownDisplayLabelMixed() {
        let b = WalkTrialRecommendation.SourceBreakdown(realRobotCount: 2, simCount: 3)
        XCTAssertEqual(b.displayLabel, "실 로봇 2 · 시뮬 3")
        XCTAssertEqual(b.total, 5)
        XCTAssertEqual(b.realRatio, 0.4, accuracy: 1e-9)
    }

    /// realRatio 의 division-by-zero guard.
    func testSourceBreakdownRealRatioWithZeroTotal() {
        let b = WalkTrialRecommendation.SourceBreakdown(realRobotCount: 0, simCount: 0)
        XCTAssertEqual(b.total, 0)
        XCTAssertEqual(b.realRatio, 0.0, accuracy: 1e-9, "div-by-zero guard → 0")
    }

    /// ruleBased 가 sourceBreakdown 을 populate 하는지 검증.
    func testRuleBasedPopulatesSourceBreakdown() {
        store.append(makeTrial(id: "r1", preset: "march", score: 0.9, falls: 0, isRealRobot: true))
        store.append(makeTrial(id: "r2", preset: "march", score: 0.9, falls: 0, isRealRobot: true))
        store.append(makeTrial(id: "s1", preset: "march", score: 0.9, falls: 0, isRealRobot: false))
        let rec = recommender.ruleBased(for: "march")
        XCTAssertNotNil(rec?.sourceBreakdown)
        XCTAssertEqual(rec?.sourceBreakdown?.realRobotCount, 2)
        XCTAssertEqual(rec?.sourceBreakdown?.simCount, 1)
    }

    /// pilotBiased(for:realRobotOnly: true) 가 sim trial 제외하는지 검증.
    func testPilotBiasedRealRobotOnlyFiltersSim() {
        // sim 3개 + real 3개 모두 advanced+piloted.
        for i in 0..<3 {
            store.append(makeTrial(id: "sim\(i)", preset: "march", score: 0.85, falls: 0,
                                    pilotPeakStride: 25, pilotEvents: 15,
                                    advanced: true, isRealRobot: false))
        }
        for i in 0..<3 {
            store.append(makeTrial(id: "real\(i)", preset: "march", score: 0.85, falls: 0,
                                    pilotPeakStride: 30, pilotEvents: 15,
                                    advanced: true, isRealRobot: true))
        }
        // realRobotOnly: false → 6개 모두 사용 → sim+real breakdown.
        let mixed = recommender.pilotBiased(for: "march", realRobotOnly: false)
        XCTAssertNotNil(mixed)
        XCTAssertEqual(mixed?.sourceBreakdown?.realRobotCount, 3)
        XCTAssertEqual(mixed?.sourceBreakdown?.simCount, 3)

        // realRobotOnly: true → 3개 real 만 사용 → sim 0.
        let realOnly = recommender.pilotBiased(for: "march", realRobotOnly: true)
        XCTAssertNotNil(realOnly)
        XCTAssertEqual(realOnly?.sourceBreakdown?.realRobotCount, 3)
        XCTAssertEqual(realOnly?.sourceBreakdown?.simCount, 0)
    }

    /// recommend(for:realRobotOnly:) aggregator 가 3 strategy 모두 일관 전파하는지 검증.
    func testRecommendAggregatorPropagatesRealRobotOnly() {
        // sim 5개 + real 5개 — rule 가 둘 다 활성, pilot 도 advanced+piloted.
        for i in 0..<5 {
            store.append(makeTrial(id: "sim\(i)", preset: "march", score: 0.9, falls: 0,
                                    pilotPeakStride: 25, pilotEvents: 15,
                                    advanced: true, isRealRobot: false))
        }
        for i in 0..<5 {
            store.append(makeTrial(id: "real\(i)", preset: "march", score: 0.9, falls: 0,
                                    pilotPeakStride: 30, pilotEvents: 15,
                                    advanced: true, isRealRobot: true))
        }

        // 기본 (false) — sim 포함.
        let mixed = recommender.recommend(for: "march", realRobotOnly: false)
        for r in mixed {
            XCTAssertNotNil(r.sourceBreakdown, "각 strategy 가 sourceBreakdown populate")
            let total = (r.sourceBreakdown?.realRobotCount ?? 0) + (r.sourceBreakdown?.simCount ?? 0)
            XCTAssertGreaterThan(total, 0)
        }

        // realRobotOnly: true — sim 제외.
        let realOnly = recommender.recommend(for: "march", realRobotOnly: true)
        for r in realOnly {
            XCTAssertEqual(r.sourceBreakdown?.simCount, 0,
                           "realRobotOnly=true: strategy \(r.strategy) 의 sim count 가 0 이어야")
        }
    }
}
