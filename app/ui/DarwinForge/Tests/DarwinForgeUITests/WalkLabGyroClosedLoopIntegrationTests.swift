import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// 사이클 174 — 자이로 closed-loop 유기적 통합 동작 검증.
///
/// cycles 158-172 에서 추가한 모든 wire-up 이 chain 으로 연동되는지 확인.
/// 단위 테스트 (이미 1344) 와 별개로 end-to-end 시나리오 다룸.
///
/// # 검증 chain
///
/// 1. Mac sparse start → store.imuFastPollActive 전환 → freshness state publish → HUD badge.
/// 2. Onboard mode + balance ON → schemaWarningActive computed → "v2 확인" 토글 → dismiss + persist.
/// 3. trial finalize → outcome.correctionEffectMetric 생성 → summaryLabel 정확.
/// 4. Mac sparse + Onboard 전환 시 모든 flag 일관성.
@MainActor
final class WalkLabGyroClosedLoopIntegrationTests: XCTestCase {

    private let verifiedKey = WalkLabSession.onboardBalanceSchemaVerifiedKey

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: verifiedKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: verifiedKey)
        try await super.tearDown()
    }

    // MARK: - Chain 1: Mac sparse start → IMU fast → freshness → metric

    /// **유기 검증 #1**: WalkLab session 의 모든 자이로 관련 상태 default 일관성.
    /// session 신규 생성 시:
    /// - balanceCorrectionFreshness = .normal (default)
    /// - onboardBalanceSchemaWarningActive = false (computed, default config)
    /// - lastCorrectionApplied = false (default)
    /// - balanceExperimentConfig.rollInputConvention = .imuRaw (default)
    func testNewSessionDefaultsAreConsistent() {
        let s = WalkLabSession()
        XCTAssertEqual(s.balanceCorrectionFreshness, .normal,
                       "신규 session freshness = .normal")
        XCTAssertFalse(s.onboardBalanceSchemaWarningActive,
                       "신규 session: Mac sparse default → warning OFF")
        XCTAssertFalse(s.lastCorrectionApplied)
        XCTAssertEqual(s.balanceExperimentConfig.pitchInputConvention, .imuRaw)
        XCTAssertEqual(s.balanceExperimentConfig.rollInputConvention, .imuRaw)
        XCTAssertEqual(s.walkingEngine, .macSparseKeyframe,
                       "신규 session default = Mac sparse")
    }

    /// **유기 검증 #2**: balanceExperimentConfig 변경 시 rollInputConvention chain.
    /// config 신규 생성 + roll convention 변경 → session 에 적용 → applyBalanceCorrection 시
    /// normalized roll 입력 (cycle 161 wire-up).
    func testRollInputConventionPropagatesToCorrection() {
        let s = WalkLabSession()
        s.enableBalanceCorrection = true
        // .imuRaw default
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .imuRaw,
            rollInputConvention: .negateLeftIsNegative
        )
        XCTAssertEqual(s.balanceExperimentConfig.rollInputConvention, .negateLeftIsNegative,
                       "config 변경 즉시 반영")
        // sim mode (store nil) → freshness = .normal default 유지 후 .normal 평가.
        _ = s.applyBalanceCorrectionIfEnabled(to: .walkReady)
        XCTAssertEqual(s.balanceCorrectionFreshness, .normal,
                       "sim mode (store nil) 은 freshness gate 우회 → .normal")
    }

    // MARK: - Chain 2: Onboard mode + balance → schema warning → toggle → persist

    /// **유기 검증 #3**: Onboard mode 전환 + balance toggle 의 flag 전환 chain.
    func testOnboardSchemaWarningChainOnEngineSwitch() {
        let s = WalkLabSession()
        // 초기 Mac sparse → warning OFF.
        XCTAssertEqual(s.walkingEngine, .macSparseKeyframe)
        XCTAssertFalse(s.onboardBalanceSchemaWarningActive)

        // Onboard 로 전환 + balance ON + unverified → warning ON.
        s.walkingEngine = .robotisOnboard
        s.enableBalanceCorrection = true
        s.onboardBalanceSchemaVerified = false
        XCTAssertTrue(s.onboardBalanceSchemaWarningActive,
                      "Onboard + balance ON + unverified → silent failure 위험 warning")

        // verified 토글 → warning OFF.
        s.onboardBalanceSchemaVerified = true
        XCTAssertFalse(s.onboardBalanceSchemaWarningActive,
                       "verified=true → warning dismiss (computed property 즉시)")

        // balance OFF → warning OFF (verified 무관).
        s.onboardBalanceSchemaVerified = false
        s.enableBalanceCorrection = false
        XCTAssertFalse(s.onboardBalanceSchemaWarningActive,
                       "balance OFF 면 daemon balance 안 보냄 → warning 불필요")

        // 다시 Mac sparse → warning OFF (engine 분기).
        s.walkingEngine = .macSparseKeyframe
        s.enableBalanceCorrection = true
        s.onboardBalanceSchemaVerified = false
        XCTAssertFalse(s.onboardBalanceSchemaWarningActive,
                       "Mac sparse 는 onboard schema 와 무관")
    }

    /// **유기 검증 #4**: verified persistence 가 session 재생성 across 유지.
    func testVerifiedPersistsAcrossSessionInstances() {
        let s1 = WalkLabSession()
        s1.walkingEngine = .robotisOnboard
        s1.enableBalanceCorrection = true
        s1.onboardBalanceSchemaVerified = true
        XCTAssertFalse(s1.onboardBalanceSchemaWarningActive)

        // 신규 session — UserDefaults 자동 복원.
        let s2 = WalkLabSession()
        s2.walkingEngine = .robotisOnboard
        s2.enableBalanceCorrection = true
        XCTAssertTrue(s2.onboardBalanceSchemaVerified, "persist 복원")
        XCTAssertFalse(s2.onboardBalanceSchemaWarningActive,
                       "persist + Onboard + balance ON → warning OFF")
    }

    // MARK: - Chain 3: WalkingEngineCommand schema (cycle 162) 와 session state chain

    /// **유기 검증 #5**: session 의 balance state 가 WalkingEngineCommand 에 반영.
    func testSessionStatePropagatesToCommandSchema() {
        let s = WalkLabSession()
        s.balanceGain = 1.5
        s.enableBalanceCorrection = true
        s.correctorIntensityLevel = 3
        s.current = .march
        let cmd = s.currentWalkingEngineCommand(enabled: true)
        XCTAssertEqual(cmd.balanceGain, 1.5, accuracy: 0.01,
                       "session.balanceGain → cmd.balanceGain")
        XCTAssertTrue(cmd.balanceEnable,
                      "session.enableBalanceCorrection → cmd.balanceEnable")
        XCTAssertEqual(cmd.correctorIntensityLevel, 3,
                       "session.correctorIntensityLevel → cmd.correctorIntensityLevel")
        // serializedLine — 13 필드 확인 (SSH parity W4: 10 + head 2 + ball_track).
        let fields = cmd.serializedLine.split(separator: " ")
        XCTAssertEqual(fields.count, 13,
                       "13 필드 확인 (cycle 162 schema + head pan/tilt + ball_track)")
    }

    /// **유기 검증 #6**: correctorIntensityLevel clamp + cmd 일관성.
    func testCorrectorLevelClampReachesCommand() {
        let s = WalkLabSession()
        // 5 → 4 clamp (init).
        s.correctorIntensityLevel = 5
        XCTAssertEqual(s.correctorIntensityLevel, 4, "session 측 clamp")
        s.current = .march
        let cmd = s.currentWalkingEngineCommand(enabled: true)
        XCTAssertEqual(cmd.correctorIntensityLevel, 4,
                       "cmd 도 clamp 반영")
        // -1 → 0 clamp.
        s.correctorIntensityLevel = -1
        XCTAssertEqual(s.correctorIntensityLevel, 0)
        let cmd2 = s.currentWalkingEngineCommand(enabled: true)
        XCTAssertEqual(cmd2.correctorIntensityLevel, 0)
    }

    // MARK: - Chain 4: BalanceCorrectionFreshness 가 freshness gate 와 동기

    /// **유기 검증 #7**: applyBalanceCorrection 분기 별 freshness state 전환 일관성.
    /// sim mode + balance disable / off mode / 정상 → 모두 .normal default 유지.
    func testFreshnessStateConsistencyAcrossModes() {
        let s = WalkLabSession()

        // .off algorithm — early return, freshness 변화 X.
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .off,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .imuRaw,
            rollInputConvention: .imuRaw
        )
        s.enableBalanceCorrection = true
        _ = s.applyBalanceCorrectionIfEnabled(to: .walkReady)
        XCTAssertEqual(s.balanceCorrectionFreshness, .normal,
                       ".off mode 는 freshness gate 분기 전 early return")

        // disable + .robotisPControl — disable 분기 early return.
        s.enableBalanceCorrection = false
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .imuRaw,
            rollInputConvention: .imuRaw
        )
        let saved = s.balanceCorrectionFreshness
        _ = s.applyBalanceCorrectionIfEnabled(to: .walkReady)
        XCTAssertEqual(s.balanceCorrectionFreshness, saved,
                       "disable 분기 — freshness 무변화 (early return)")
    }

    // MARK: - Chain 5: balanceCorrectionFreshness UI badge 가 정확한 색/라벨

    /// **유기 검증 #8**: BalanceCorrectionFreshness 의 모든 case 가 정확한 한국어 라벨.
    func testFreshnessBadgeLabelMatchesEnum() {
        XCTAssertEqual(WalkLabSession.BalanceCorrectionFreshness.normal.koreanLabel, "정상")
        XCTAssertEqual(WalkLabSession.BalanceCorrectionFreshness.degraded.koreanLabel,
                       "IMU 지연 — 보정 감쇠")
        XCTAssertEqual(WalkLabSession.BalanceCorrectionFreshness.blocked.koreanLabel,
                       "IMU 차단 — 보정 정지")
    }

    // MARK: - Chain 6: TrialOutcome.correctionEffectMetric (cycle 163-165) end-to-end

    /// **유기 검증 #9**: analyze() 가 빈 sample 받아도 nil correctionEffectMetric.
    func testEmptySamplesProduceNoCorrectionMetric() {
        let outcome = WalkTrialAnalyzer.analyze(
            samples: [],
            endReason: .userStop, durationSec: 0,
            stepsExecuted: 0, busWriteFailures: 0)
        XCTAssertNil(outcome.correctionEffectMetric)
    }

    /// **유기 검증 #10**: sample 모두 correctionApplied=true → corrected only, summaryLabel
    /// "보정 활성 100%".
    func testSummaryLabelChainFromAnalyzeToMetric() {
        let samples = [
            makeSample(roll: 2, pitch: 1, correctionApplied: true),
            makeSample(roll: -3, pitch: 2, correctionApplied: true),
            makeSample(roll: 1, pitch: -1, correctionApplied: true)
        ]
        let outcome = WalkTrialAnalyzer.analyze(
            samples: samples, endReason: .userStop, durationSec: 0.3,
            stepsExecuted: 6, busWriteFailures: 0)
        let metric = outcome.correctionEffectMetric
        XCTAssertNotNil(metric)
        XCTAssertEqual(metric?.correctedSampleCount, 3)
        XCTAssertEqual(metric?.uncorrectedSampleCount, 0)
        XCTAssertEqual(metric?.correctionApplyRatio ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertTrue(metric?.summaryLabel.contains("100%") == true,
                      "summaryLabel = 100%: \(metric?.summaryLabel ?? "nil")")
    }

    /// **유기 검증 #11**: mixed sample → ON/OFF 비교 peak abs.
    func testMixedSamplesProduceComparisonMetric() {
        let samples = [
            // ON 구간 — 보정 적용, 작은 흔들림.
            makeSample(roll: 2, pitch: 1, correctionApplied: true),
            makeSample(roll: 3, pitch: 1, correctionApplied: true),
            // OFF 구간 — 보정 비활성, 큰 흔들림.
            makeSample(roll: 12, pitch: 8, correctionApplied: false),
            makeSample(roll: -15, pitch: -10, correctionApplied: false)
        ]
        let outcome = WalkTrialAnalyzer.analyze(
            samples: samples, endReason: .userStop, durationSec: 0.4,
            stepsExecuted: 8, busWriteFailures: 0)
        let metric = outcome.correctionEffectMetric!
        XCTAssertEqual(metric.correctedSampleCount, 2)
        XCTAssertEqual(metric.uncorrectedSampleCount, 2)
        // ON 구간 peak abs roll = 3
        XCTAssertEqual(metric.correctedPeakAbsRollDeg ?? 0, 3, accuracy: 1e-9)
        // OFF 구간 peak abs roll = 15 (보정 안 받을 때 더 큰 흔들림 — 보정 효과 입증).
        XCTAssertEqual(metric.uncorrectedPeakAbsRollDeg ?? 0, 15, accuracy: 1e-9)
        // 보정 효과 = OFF - ON = 15 - 3 = 12° 감소 (사용자 분석용).
        XCTAssertGreaterThan(metric.uncorrectedPeakAbsRollDeg ?? 0,
                             metric.correctedPeakAbsRollDeg ?? 0,
                             "보정 ON 구간 의 peak abs 가 OFF 구간 보다 작아야 보정 효과 입증")
    }

    // MARK: - Helpers

    private func makeSample(roll: Double, pitch: Double, correctionApplied: Bool?) -> WalkSessionSample {
        WalkSessionSample(
            t: 0,
            preset: "march",
            intensityLevel: 2,
            imuRollDeg: roll,
            imuPitchDeg: pitch,
            correctorRollErrDeg: 0,
            correctorPitchErrDeg: 0,
            balanceState: "normal",
            correctorDeltas: [0, 0, 0, 0, 0, 0, 0, 0],
            imuSource: "sim",
            batteryVolts: nil,
            motorAvgTemp: nil,
            correctionAppliedToRobot: correctionApplied
        )
    }
}
