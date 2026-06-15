import XCTest
@testable import DarwinForgeUI

/// 사이클 183 (P1 #3.5 fix, cycle 177 audit): TrialComparisonModel pure logic 검증.
///
/// # 비유
///
/// 학생 의 성적표 비교 — "수학 80→85 (+5↑ 개선)" 같은 한 줄 verdict 가 정확해야 학생 +
/// 부모 가 의사결정 가능. 본 테스트 는 모든 metric 의 방향 (lower vs higher is better) +
/// 라벨 + 개선 비율 정확성 확인.
final class TrialComparisonModelTests: XCTestCase {

    // MARK: - MetricDelta

    /// **분류 검증 #1**: lowerIsBetter=true (peak roll) + delta 음수 → 개선.
    func testLowerIsBetterNegativeDeltaIsImprovement() {
        let m = TrialComparisonModel.MetricDelta(
            label: "최대 roll",
            baseline: 15.0, candidate: 10.0,
            unit: "°", decimals: 1, lowerIsBetter: true
        )
        XCTAssertEqual(m.delta, -5.0, accuracy: 1e-9)
        XCTAssertTrue(m.isImprovement, "peak roll 5→10 줄어듬은 개선")
        XCTAssertTrue(m.koreanLabel.contains("↓"),
                      "lowerIsBetter + 개선 → ↓ 화살표")
        XCTAssertTrue(m.koreanLabel.contains("개선"))
    }

    /// **분류 검증 #2**: lowerIsBetter=true + delta 양수 → 악화.
    func testLowerIsBetterPositiveDeltaIsRegression() {
        let m = TrialComparisonModel.MetricDelta(
            label: "최대 roll",
            baseline: 5.0, candidate: 12.0,
            unit: "°", decimals: 1, lowerIsBetter: true
        )
        XCTAssertEqual(m.delta, 7.0, accuracy: 1e-9)
        XCTAssertFalse(m.isImprovement, "peak roll 5→12 증가는 악화")
        XCTAssertTrue(m.koreanLabel.contains("↑"))
        XCTAssertTrue(m.koreanLabel.contains("악화"))
    }

    /// **분류 검증 #3**: lowerIsBetter=false (안정성 score) + delta 양수 → 개선.
    func testHigherIsBetterPositiveDeltaIsImprovement() {
        let m = TrialComparisonModel.MetricDelta(
            label: "안정성",
            baseline: 0.7, candidate: 0.9,
            unit: "", decimals: 2, lowerIsBetter: false
        )
        XCTAssertTrue(m.isImprovement, "score 0.7→0.9 증가는 개선")
        XCTAssertTrue(m.koreanLabel.contains("↑"),
                      "higherIsBetter + 개선 → ↑")
    }

    /// **분류 검증 #4**: delta ≈ 0 (1e-5) → 동일 라벨.
    func testTinyDeltaShowsEqual() {
        let m = TrialComparisonModel.MetricDelta(
            label: "안정성",
            baseline: 0.85, candidate: 0.85,
            unit: "", decimals: 2, lowerIsBetter: false
        )
        XCTAssertEqual(m.delta, 0, accuracy: 1e-9)
        XCTAssertTrue(m.koreanLabel.contains("≈"))
        XCTAssertTrue(m.koreanLabel.contains("동일"))
    }

    /// **분류 검증 #5**: 라벨 format — baseline, candidate, +/- delta, unit 모두 포함.
    func testKoreanLabelContainsAllFields() {
        let m = TrialComparisonModel.MetricDelta(
            label: "최대 pitch",
            baseline: 8.7, candidate: 6.3,
            unit: "°", decimals: 1, lowerIsBetter: true
        )
        let label = m.koreanLabel
        XCTAssertTrue(label.contains("8.7°"), "baseline 포함: \(label)")
        XCTAssertTrue(label.contains("6.3°"), "candidate 포함")
        XCTAssertTrue(label.contains("-2.4°"), "음수 delta: \(label)")
    }

    // MARK: - Comparison

    /// **유기 검증 #6**: 4 metric 모두 개선 → improvementRatio = 1.0.
    func testAllMetricsImprovedRatioOne() {
        let cmp = makeComparison(
            baselineStab: 0.5, baselineSmooth: 0.5, baselineRoll: 10, baselinePitch: 10,
            candidateStab: 0.9, candidateSmooth: 0.9, candidateRoll: 3, candidatePitch: 4
        )
        XCTAssertEqual(cmp.improvementRatio, 1.0, accuracy: 1e-9)
        XCTAssertTrue(cmp.summaryLabel.contains("4 개선"),
                      "전부 개선 라벨: \(cmp.summaryLabel)")
        XCTAssertTrue(cmp.summaryLabel.contains("100%"))
    }

    /// **유기 검증 #7**: 4 중 2 개선 → improvementRatio = 0.5.
    func testHalfMetricsImproved() {
        let cmp = makeComparison(
            baselineStab: 0.5, baselineSmooth: 0.9, baselineRoll: 10, baselinePitch: 3,
            candidateStab: 0.9, candidateSmooth: 0.6, candidateRoll: 3, candidatePitch: 8
        )
        // stab 개선 (0.5→0.9), smooth 악화 (0.9→0.6),
        // roll 개선 (10→3, lower better), pitch 악화 (3→8).
        XCTAssertEqual(cmp.improvementRatio, 0.5, accuracy: 1e-9)
        XCTAssertTrue(cmp.summaryLabel.contains("4 중 2"))
    }

    /// **유기 검증 #8**: 4 metric labels 의 의미.
    func testComparisonAlwaysReturnsFourMetrics() {
        let cmp = makeComparison()
        XCTAssertEqual(cmp.metrics.count, 4,
                       "현재 4 핵심 metric — 안정성/부드러움/최대roll/최대pitch")
        let labels = cmp.metrics.map { $0.label }
        XCTAssertEqual(labels, ["안정성", "부드러움", "최대 |roll|", "최대 |pitch|"])
    }

    /// **유기 검증 #9**: 의미 별 lowerIsBetter 정확 설정.
    func testMetricDirectionalityCorrect() {
        let cmp = makeComparison()
        // stab + smooth — higher is better.
        XCTAssertFalse(cmp.metrics[0].lowerIsBetter, "안정성 score: higher better")
        XCTAssertFalse(cmp.metrics[1].lowerIsBetter, "부드러움 score: higher better")
        // roll + pitch — lower is better.
        XCTAssertTrue(cmp.metrics[2].lowerIsBetter, "최대 |roll|: lower better")
        XCTAssertTrue(cmp.metrics[3].lowerIsBetter, "최대 |pitch|: lower better")
    }

    /// **유기 검증 #10**: id 보존 — UI 가 baselineId / candidateId 로 trial 다시 load.
    func testIdsPreserved() {
        let cmp = TrialComparisonModel.compare(
            baselineId: "trial-A",
            candidateId: "trial-B",
            baseline: makeOutcome(),
            candidate: makeOutcome()
        )
        XCTAssertEqual(cmp.baselineId, "trial-A")
        XCTAssertEqual(cmp.candidateId, "trial-B")
    }

    // MARK: - Helpers

    private func makeOutcome(
        stab: Double = 0.8, smooth: Double = 0.7,
        roll: Double = 8, pitch: Double = 6
    ) -> TrialOutcome {
        TrialOutcome(
            stabilityScore: stab,
            smoothnessScore: smooth,
            energyScore: 0.7,
            overallScore: (stab * 0.5 + smooth * 0.3 + 0.7 * 0.2),
            stateDistribution: ["normal": 1.0],
            fallEventCount: 0,
            meanTimeBetweenFallsSec: nil,
            peakAbsRollDeg: roll,
            peakAbsPitchDeg: pitch,
            meanAbsRollDeg: roll * 0.6,
            meanAbsPitchDeg: pitch * 0.6,
            peakMotorTempC: 40,
            busWriteFailures: 0,
            stepsExecuted: 10,
            sampleCount: 100
        )
    }

    private func makeComparison(
        baselineStab: Double = 0.8, baselineSmooth: Double = 0.7,
        baselineRoll: Double = 8, baselinePitch: Double = 6,
        candidateStab: Double = 0.9, candidateSmooth: Double = 0.85,
        candidateRoll: Double = 5, candidatePitch: Double = 4
    ) -> TrialComparisonModel.Comparison {
        TrialComparisonModel.compare(
            baselineId: "b",
            candidateId: "c",
            baseline: makeOutcome(stab: baselineStab, smooth: baselineSmooth,
                                  roll: baselineRoll, pitch: baselinePitch),
            candidate: makeOutcome(stab: candidateStab, smooth: candidateSmooth,
                                   roll: candidateRoll, pitch: candidatePitch)
        )
    }
}
