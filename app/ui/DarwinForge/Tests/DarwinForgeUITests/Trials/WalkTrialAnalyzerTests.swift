import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.15.0 (2026-05-21) Phase 1 — WalkTrialAnalyzer 순수 함수 단위 테스트**.
///
/// 핵심: 각 metric (stability, smoothness, energy, distribution) 의 edge case 검증.
/// - 빈 배열, 1 sample, 모두 nil, all normal, all emergency 등.
/// - 가중치 일관성 (overall = 0.5×s + 0.3×sm + 0.2×e).
final class WalkTrialAnalyzerTests: XCTestCase {

    // MARK: - BalanceState distribution

    func testEmptyDistribution_AllZero() {
        let dist = WalkTrialAnalyzer.balanceStateDistribution(samples: [])
        XCTAssertEqual(dist["normal"] ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(dist["caution"] ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(dist["warning"] ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(dist["danger"] ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(dist["emergency"] ?? -1, 0, accuracy: 1e-9)
    }

    func testAllNormal_OneHundredPercent() {
        let samples = (0..<10).map { _ in sampleWithState("normal") }
        let dist = WalkTrialAnalyzer.balanceStateDistribution(samples: samples)
        XCTAssertEqual(dist["normal"] ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(dist["danger"] ?? -1, 0, accuracy: 1e-9)
    }

    func testMixedDistribution_SumsToOne() {
        let samples = [
            sampleWithState("normal"),
            sampleWithState("normal"),
            sampleWithState("caution"),
            sampleWithState("warning"),
        ]
        let dist = WalkTrialAnalyzer.balanceStateDistribution(samples: samples)
        XCTAssertEqual(dist["normal"] ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(dist["caution"] ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(dist["warning"] ?? -1, 0.25, accuracy: 1e-9)
        // Sum 계산 — 명시적 sub-expression 으로 type-checker 도움.
        let normal = dist["normal"] ?? 0
        let caution = dist["caution"] ?? 0
        let warning = dist["warning"] ?? 0
        let danger = dist["danger"] ?? 0
        let emergency = dist["emergency"] ?? 0
        let sum = normal + caution + warning + danger + emergency
        XCTAssertEqual(sum, 1.0, accuracy: 1e-9, "분포 합 = 1")
    }

    // MARK: - Fall events

    func testNoFalls() {
        let samples = (0..<10).map { _ in sampleWithFall(false) }
        XCTAssertEqual(WalkTrialAnalyzer.countFallEvents(samples: samples), 0)
    }

    func testSingleFallEvent_ConsecutiveTrueCountedOnce() {
        let samples = [
            sampleWithFall(false), sampleWithFall(false),
            sampleWithFall(true), sampleWithFall(true), sampleWithFall(true),  // 1 event
            sampleWithFall(false),
        ]
        XCTAssertEqual(WalkTrialAnalyzer.countFallEvents(samples: samples), 1,
                       "연속 true 는 1 event 로 묶임")
    }

    func testTwoSeparateFallEvents() {
        let samples = [
            sampleWithFall(true),  sampleWithFall(false),  // event 1
            sampleWithFall(false), sampleWithFall(false),
            sampleWithFall(true),  sampleWithFall(true),   // event 2
        ]
        XCTAssertEqual(WalkTrialAnalyzer.countFallEvents(samples: samples), 2)
    }

    func testFallStartingFromFirstSample() {
        let samples = [sampleWithFall(true), sampleWithFall(true), sampleWithFall(false)]
        XCTAssertEqual(WalkTrialAnalyzer.countFallEvents(samples: samples), 1)
    }

    // MARK: - Stability score

    func testStabilityScore_PerfectAllNormalSuccess() {
        let dist = ["normal": 1.0, "caution": 0, "warning": 0, "danger": 0, "emergency": 0]
        let s = WalkTrialAnalyzer.stabilityScore(
            stateDistribution: dist, fallEventCount: 0, endReason: .userStop)
        XCTAssertEqual(s, 1.0, accuracy: 1e-9, "all normal + no fall + success = 1.0")
    }

    func testStabilityScore_EmergencyEndPenalty() {
        let dist = ["normal": 1.0, "caution": 0, "warning": 0, "danger": 0, "emergency": 0]
        let s = WalkTrialAnalyzer.stabilityScore(
            stateDistribution: dist, fallEventCount: 0, endReason: .emergencyStop)
        XCTAssertEqual(s, 0.8, accuracy: 1e-9, "endReason 페널티 -0.2")
    }

    func testStabilityScore_FallPenaltyCappedAt0_5() {
        let dist = ["normal": 1.0, "caution": 0, "warning": 0, "danger": 0, "emergency": 0]
        let s = WalkTrialAnalyzer.stabilityScore(
            stateDistribution: dist, fallEventCount: 100, endReason: .userStop)
        XCTAssertEqual(s, 0.5, accuracy: 1e-9, "fall 100 × 0.1 = 10, but capped at 0.5 → 1.0 - 0.5 = 0.5")
    }

    func testStabilityScore_DangerDominant() {
        let dist = ["normal": 0, "caution": 0, "warning": 0, "danger": 1.0, "emergency": 0]
        let s = WalkTrialAnalyzer.stabilityScore(
            stateDistribution: dist, fallEventCount: 0, endReason: .userStop)
        XCTAssertEqual(s, 0.1, accuracy: 1e-9, "all danger weighted at 0.1")
    }

    func testStabilityScore_ClampedAtZero() {
        let dist = ["normal": 0, "caution": 0, "warning": 0, "danger": 0, "emergency": 1.0]
        let s = WalkTrialAnalyzer.stabilityScore(
            stateDistribution: dist, fallEventCount: 10, endReason: .emergencyStop)
        XCTAssertEqual(s, 0.0, accuracy: 1e-9, "all emergency + fall + bad endReason → 0 clamp")
    }

    // MARK: - Smoothness score

    func testSmoothnessScore_EmptyOrNilSamples_Neutral() {
        XCTAssertEqual(WalkTrialAnalyzer.smoothnessScore(samples: []), 0.5,
                       "빈 배열 → 중립 0.5")
    }

    func testSmoothnessScore_ZeroJitter_Max() {
        // 모든 sample 의 accel = (0, 0, 1) → std-dev 0 → smoothness 1.
        let samples = (0..<20).map { _ in sampleWithAccel(0, 0, 1) }
        let s = WalkTrialAnalyzer.smoothnessScore(samples: samples)
        XCTAssertEqual(s, 1.0, accuracy: 1e-9)
    }

    func testSmoothnessScore_HighJitter_Low() {
        // 극단적 jitter — accel z 1g vs 2g 교차 (magnitude 0 vs 1).
        // 종전 (±0.5, 0, 1) 패턴은 magnitude (sqrt) 으로 같은 값 → std 0 → 1.0 잘못된 통과.
        // magnitude 가 실제로 변하는 패턴 (z 축 가속도) 으로 수정.
        let samples = (0..<20).map { i in
            sampleWithAccel(0, 0, (i % 2 == 0) ? 1 : 2)
        }
        let s = WalkTrialAnalyzer.smoothnessScore(samples: samples)
        XCTAssertLessThan(s, 0.5, "큰 jitter = 낮은 smoothness")
    }

    // MARK: - Energy score

    func testEnergyScore_NoStepsExecuted_Neutral() {
        // 시뮬 모드 (step 0) → energy 측정 불가, 1.0 (중립 max).
        let s = WalkTrialAnalyzer.energyScore(peakMotorTempC: 0, stepsExecuted: 0, durationSec: 10)
        XCTAssertEqual(s, 1.0)
    }

    func testEnergyScore_NoTempRise_Max() {
        // peak temp = 35 (idle baseline) → rise 0 → score 1.
        let s = WalkTrialAnalyzer.energyScore(peakMotorTempC: 35, stepsExecuted: 100, durationSec: 10)
        XCTAssertEqual(s, 1.0, accuracy: 1e-9)
    }

    func testEnergyScore_HighTempRise_Low() {
        // peak temp = 65 → rise 30 → score 0.
        let s = WalkTrialAnalyzer.energyScore(peakMotorTempC: 65, stepsExecuted: 100, durationSec: 10)
        XCTAssertEqual(s, 0.0, accuracy: 1e-9)
    }

    // MARK: - Overall

    func testWeightedOverall_AllOne_One() {
        XCTAssertEqual(WalkTrialAnalyzer.weightedOverall(stability: 1, smoothness: 1, energy: 1), 1.0)
    }

    func testWeightedOverall_Weights_50_30_20() {
        let s = WalkTrialAnalyzer.weightedOverall(stability: 0.8, smoothness: 0.6, energy: 0.5)
        let expected = 0.8 * 0.5 + 0.6 * 0.3 + 0.5 * 0.2
        XCTAssertEqual(s, expected, accuracy: 1e-9)
    }

    // MARK: - End-to-end analyze

    func testAnalyze_PerfectTrial_HighScore() {
        let samples = (0..<60).map { _ in
            sampleFull(state: "normal", fall: false, roll: 0, pitch: 0, accelXYZ: (0, 0, 1), temp: 36)
        }
        let outcome = WalkTrialAnalyzer.analyze(
            samples: samples, endReason: .userStop, durationSec: 6, stepsExecuted: 30, busWriteFailures: 0)
        XCTAssertEqual(outcome.stabilityScore, 1.0, accuracy: 0.01)
        XCTAssertEqual(outcome.smoothnessScore, 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(outcome.energyScore, 0.9)
        XCTAssertGreaterThan(outcome.overallScore, 0.9)
        XCTAssertEqual(outcome.fallEventCount, 0)
        XCTAssertTrue(outcome.isGoodTrial, "perfect trial = good")
    }

    func testAnalyze_BadTrial_LowScore() {
        let samples = (0..<60).map { i in
            sampleFull(
                state: (i % 3 == 0) ? "danger" : "warning",
                fall: i % 10 == 0,  // 6 falls
                roll: 30, pitch: 25,
                accelXYZ: (Double(i % 2) * 0.4, 0, 1),
                temp: 60
            )
        }
        let outcome = WalkTrialAnalyzer.analyze(
            samples: samples, endReason: .emergencyStop, durationSec: 6, stepsExecuted: 30, busWriteFailures: 5)
        XCTAssertLessThan(outcome.stabilityScore, 0.5, "danger dominant + emergency 종료")
        XCTAssertGreaterThan(outcome.fallEventCount, 0)
        XCTAssertFalse(outcome.isGoodTrial, "bad trial != good")
    }

    // MARK: - Test fixtures

    private func sampleWithState(_ state: String) -> WalkSessionSample {
        sampleFull(state: state, fall: false, roll: 0, pitch: 0, accelXYZ: nil, temp: nil)
    }

    private func sampleWithFall(_ isFall: Bool) -> WalkSessionSample {
        sampleFull(state: "normal", fall: isFall, roll: 0, pitch: 0, accelXYZ: nil, temp: nil)
    }

    private func sampleWithAccel(_ x: Double, _ y: Double, _ z: Double) -> WalkSessionSample {
        sampleFull(state: "normal", fall: false, roll: 0, pitch: 0, accelXYZ: (x, y, z), temp: nil)
    }

    private func sampleFull(
        state: String, fall: Bool,
        roll: Double, pitch: Double,
        accelXYZ: (Double, Double, Double)?,
        temp: Double?,
        correctionApplied: Bool? = nil
    ) -> WalkSessionSample {
        WalkSessionSample(
            t: 0,
            preset: "march",
            intensityLevel: 2,
            imuRollDeg: roll,
            imuPitchDeg: pitch,
            correctorRollErrDeg: 0,
            correctorPitchErrDeg: 0,
            balanceState: state,
            correctorDeltas: [0, 0, 0, 0, 0, 0, 0, 0],
            imuSource: "sim",
            batteryVolts: nil,
            motorAvgTemp: temp,
            correctionAppliedToRobot: correctionApplied,
            rawAccelXG: accelXYZ?.0,
            rawAccelYG: accelXYZ?.1,
            rawAccelZG: accelXYZ?.2,
            fallRecommendEmergency: fall
        )
    }

    // MARK: - 사이클 165 (P1-3 wire-up): correctionEffectMetric

    /// 빈 배열 → nil.
    func testCorrectionEffectMetricEmptyReturnsNil() {
        let metric = WalkTrialAnalyzer.correctionEffectMetric(samples: [])
        XCTAssertNil(metric)
    }

    /// 모든 sample correctionApplied=true → corrected only group.
    func testCorrectionEffectMetricAllCorrected() {
        let samples = [
            sampleFull(state: "normal", fall: false, roll: 3, pitch: 2,
                       accelXYZ: nil, temp: nil, correctionApplied: true),
            sampleFull(state: "normal", fall: false, roll: -5, pitch: 4,
                       accelXYZ: nil, temp: nil, correctionApplied: true)
        ]
        let metric = WalkTrialAnalyzer.correctionEffectMetric(samples: samples)
        XCTAssertNotNil(metric)
        XCTAssertEqual(metric?.correctedSampleCount, 2)
        XCTAssertEqual(metric?.uncorrectedSampleCount, 0)
        XCTAssertEqual(metric?.correctionApplyRatio ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(metric?.correctedPeakAbsRollDeg ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(metric?.correctedPeakAbsPitchDeg ?? 0, 4, accuracy: 1e-9)
        XCTAssertNil(metric?.uncorrectedPeakAbsRollDeg)
        XCTAssertNil(metric?.uncorrectedPeakAbsPitchDeg)
    }

    /// mixed — corrected 와 uncorrected 모두 peak abs 계산.
    func testCorrectionEffectMetricMixed() {
        let samples = [
            sampleFull(state: "normal", fall: false, roll: 8, pitch: 3,
                       accelXYZ: nil, temp: nil, correctionApplied: true),
            sampleFull(state: "normal", fall: false, roll: -2, pitch: 1,
                       accelXYZ: nil, temp: nil, correctionApplied: true),
            sampleFull(state: "normal", fall: false, roll: 15, pitch: -10,
                       accelXYZ: nil, temp: nil, correctionApplied: false),
            sampleFull(state: "normal", fall: false, roll: 12, pitch: -7,
                       accelXYZ: nil, temp: nil, correctionApplied: false)
        ]
        let metric = WalkTrialAnalyzer.correctionEffectMetric(samples: samples)
        XCTAssertNotNil(metric)
        XCTAssertEqual(metric?.correctedSampleCount, 2)
        XCTAssertEqual(metric?.uncorrectedSampleCount, 2)
        XCTAssertEqual(metric?.correctionApplyRatio ?? 0, 0.5, accuracy: 1e-9)
        // corrected peak abs = max(|8|, |-2|) = 8
        XCTAssertEqual(metric?.correctedPeakAbsRollDeg ?? 0, 8, accuracy: 1e-9)
        // uncorrected peak abs = max(|15|, |12|) = 15
        XCTAssertEqual(metric?.uncorrectedPeakAbsRollDeg ?? 0, 15, accuracy: 1e-9)
        XCTAssertEqual(metric?.uncorrectedPeakAbsPitchDeg ?? 0, 10, accuracy: 1e-9)
    }

    /// nil (legacy) 은 uncorrected 로 분류 (보수적).
    func testCorrectionEffectMetricNilCountsAsUncorrected() {
        let samples = [
            sampleFull(state: "normal", fall: false, roll: 5, pitch: 3,
                       accelXYZ: nil, temp: nil, correctionApplied: nil)
        ]
        let metric = WalkTrialAnalyzer.correctionEffectMetric(samples: samples)
        XCTAssertEqual(metric?.correctedSampleCount, 0)
        XCTAssertEqual(metric?.uncorrectedSampleCount, 1)
        XCTAssertEqual(metric?.correctionApplyRatio ?? 1, 0.0, accuracy: 1e-9)
    }

    /// summaryLabel 검증.
    func testCorrectionEffectMetricSummaryLabel() {
        let allOn = TrialOutcome.CorrectionEffectMetric(
            correctedSampleCount: 100, uncorrectedSampleCount: 0,
            correctionApplyRatio: 1.0,
            correctedPeakAbsRollDeg: 5, correctedPeakAbsPitchDeg: 3,
            uncorrectedPeakAbsRollDeg: nil, uncorrectedPeakAbsPitchDeg: nil,
            blockedSampleCount: 0, degradedSampleCount: 0)
        XCTAssertTrue(allOn.summaryLabel.contains("100%"))

        let allOff = TrialOutcome.CorrectionEffectMetric(
            correctedSampleCount: 0, uncorrectedSampleCount: 50,
            correctionApplyRatio: 0.0,
            correctedPeakAbsRollDeg: nil, correctedPeakAbsPitchDeg: nil,
            uncorrectedPeakAbsRollDeg: 8, uncorrectedPeakAbsPitchDeg: 6,
            blockedSampleCount: 0, degradedSampleCount: 0)
        XCTAssertTrue(allOff.summaryLabel.contains("비활성"))

        let mixed = TrialOutcome.CorrectionEffectMetric(
            correctedSampleCount: 30, uncorrectedSampleCount: 70,
            correctionApplyRatio: 0.3,
            correctedPeakAbsRollDeg: 5, correctedPeakAbsPitchDeg: 3,
            uncorrectedPeakAbsRollDeg: 12, uncorrectedPeakAbsPitchDeg: 8,
            blockedSampleCount: 0, degradedSampleCount: 0)
        XCTAssertTrue(mixed.summaryLabel.contains("30%"))
        XCTAssertTrue(mixed.summaryLabel.contains("ON"))
        XCTAssertTrue(mixed.summaryLabel.contains("OFF"))
    }

    /// analyze() 가 correctionEffectMetric 을 TrialOutcome 에 포함.
    func testAnalyzeIncludesCorrectionEffectMetric() {
        let samples = [
            sampleFull(state: "normal", fall: false, roll: 2, pitch: 1,
                       accelXYZ: nil, temp: 40, correctionApplied: true),
            sampleFull(state: "normal", fall: false, roll: 3, pitch: 2,
                       accelXYZ: nil, temp: 40, correctionApplied: true)
        ]
        let outcome = WalkTrialAnalyzer.analyze(
            samples: samples,
            endReason: .userStop, durationSec: 2.0,
            stepsExecuted: 4, busWriteFailures: 0
        )
        XCTAssertNotNil(outcome.correctionEffectMetric,
            "analyze() 가 correctionEffectMetric 을 TrialOutcome 에 포함")
        XCTAssertEqual(outcome.correctionEffectMetric?.correctedSampleCount, 2)
    }
}
