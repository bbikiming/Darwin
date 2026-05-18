import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.3 (2026-05-18) — P1.0/P1.1/P1.3 회귀 가드**.
///
/// 정적 캘리브레이션 + pitch 부호 정규화 인프라의 회귀 보호.
/// - StaticTiltCalibration.Capture.Summary 통계 정확성
/// - StaticTiltCalibration.diagnose() 의 5축 부호 판정
/// - BalanceExperimentConfig.pitchInputConvention default = .imuRaw (현재 동작 보존)
/// - opt-in `.negateForwardIsNegative` 이면 hybridCorrections / P-control 양쪽 입력 부호 반전
/// - Codable backward-compat (기존 JSON 디코드 시 .imuRaw fallback)
@MainActor
final class WalkLabV113PitchSignTests: XCTestCase {

    // MARK: - 1. StaticTiltCalibration.Summary

    /// 합성 sample → mean/std/min/max 정확.
    func testCaptureSummaryStatistics() {
        let samples: [StaticTiltCalibration.Sample] = (0..<10).map { i in
            // pitch 가 -10 ± 1 사이 진동.
            StaticTiltCalibration.Sample(
                rollDeg: 0,
                pitchDeg: -10.0 + (Double(i) - 4.5) * 0.2,  // -10.9 .. -9.1
                tMs: Double(i) * 50
            )
        }
        let cap = StaticTiltCalibration.Capture(
            axis: .forward30, startTimeIso: "2026-05-18T00:00:00Z",
            durationSec: 0.5, samples: samples, imuSource: "sim"
        )
        let s = cap.summary
        XCTAssertEqual(s.sampleCount, 10)
        XCTAssertEqual(s.meanPitch, -10.0, accuracy: 1e-6)
        XCTAssertEqual(s.meanRoll, 0, accuracy: 1e-6)
        XCTAssertEqual(s.minPitch, -10.9, accuracy: 1e-6)
        XCTAssertEqual(s.maxPitch, -9.1, accuracy: 1e-6)
        XCTAssertGreaterThan(s.stdPitch, 0)
    }

    /// 빈 sample → 0 으로 fallback (NaN 없이).
    func testCaptureSummaryEmptyDoesNotNaN() {
        let cap = StaticTiltCalibration.Capture(
            axis: .upright, startTimeIso: "x",
            durationSec: 0, samples: [], imuSource: "sim"
        )
        let s = cap.summary
        XCTAssertEqual(s.sampleCount, 0)
        XCTAssertEqual(s.meanPitch, 0)
        XCTAssertEqual(s.stdPitch, 0)
        XCTAssertFalse(s.meanPitch.isNaN)
    }

    // MARK: - 2. Diagnosis — 5축 부호 판정

    /// **현재 실 robot 가설 (2026-05-18 데이터)**: forward 자세 → imuPitch 음수.
    /// → diagnose() 가 `pitchPositiveMeansForward = false` 판정 + 정규화 권고 메시지.
    func testDiagnoseRealRobotForwardIsNegative() {
        let captures = [
            mockCapture(axis: .upright,    meanPitch: 0,    meanRoll: 0),
            mockCapture(axis: .forward30,  meanPitch: -30,  meanRoll: 0),
            mockCapture(axis: .backward30, meanPitch: +30,  meanRoll: 0),
            mockCapture(axis: .right30,    meanPitch: 0,    meanRoll: -30),
            mockCapture(axis: .left30,     meanPitch: 0,    meanRoll: +30),
        ]
        let d = StaticTiltCalibration.diagnose(captures: captures)
        XCTAssertEqual(d.pitchPositiveMeansForward, false,
            "forward=-30°, backward=+30° → 양수는 backward → 코드 컨벤션과 반대")
        XCTAssertEqual(d.rollPositiveMeansRight, false,
            "right=-30°, left=+30° → 양수는 left → 코드 컨벤션과 반대")
        XCTAssertGreaterThan(d.confidence, 0.5, "30°+30°=60° 격차 → confidence 1.0")
    }

    /// **코드 컨벤션 일치 케이스**: forward 자세 → imuPitch 양수.
    /// → diagnose() 가 `pitchPositiveMeansForward = true` 판정.
    func testDiagnoseCodeConventionMatches() {
        let captures = [
            mockCapture(axis: .upright,    meanPitch: 0,    meanRoll: 0),
            mockCapture(axis: .forward30,  meanPitch: +30,  meanRoll: 0),
            mockCapture(axis: .backward30, meanPitch: -30,  meanRoll: 0),
            mockCapture(axis: .right30,    meanPitch: 0,    meanRoll: +30),
            mockCapture(axis: .left30,     meanPitch: 0,    meanRoll: -30),
        ]
        let d = StaticTiltCalibration.diagnose(captures: captures)
        XCTAssertEqual(d.pitchPositiveMeansForward, true,
            "forward=+30°, backward=-30° → 코드 컨벤션 일치")
        XCTAssertEqual(d.rollPositiveMeansRight, true)
        XCTAssertGreaterThan(d.confidence, 0.5)
    }

    /// **데이터 모호**: forward/backward 차이가 15° 미만이면 verdict = nil.
    func testDiagnoseInconclusiveWhenSmallSeparation() {
        let captures = [
            mockCapture(axis: .forward30,  meanPitch: 5),
            mockCapture(axis: .backward30, meanPitch: -3),
        ]
        let d = StaticTiltCalibration.diagnose(captures: captures)
        XCTAssertNil(d.pitchPositiveMeansForward,
            "|Δ|=8° < 15° threshold → 진단 불가")
        XCTAssertEqual(d.confidence, 0, accuracy: 0.01)
    }

    /// **데이터 부족**: forward 만 있고 backward 없으면 verdict = nil.
    func testDiagnoseMissingAxes() {
        let captures = [mockCapture(axis: .forward30, meanPitch: -30)]
        let d = StaticTiltCalibration.diagnose(captures: captures)
        XCTAssertNil(d.pitchPositiveMeansForward)
        XCTAssertNil(d.rollPositiveMeansRight)
    }

    // MARK: - 3. BalanceExperimentConfig.pitchInputConvention default

    /// **회귀 가드 — 기존 동작 보존**: default init 시 `.imuRaw`.
    /// 이 테스트가 깨지면 default 보행 경로 부호가 무의식적으로 변경됐다는 뜻.
    func testPitchInputConventionDefaultsToImuRaw() {
        let c = BalanceExperimentConfig()
        XCTAssertEqual(c.pitchInputConvention, .imuRaw,
            "default 는 .imuRaw 여야 함 — 기존 보행 경로 동작 보존")
        // defaultRobotis preset 도 동일.
        XCTAssertEqual(BalanceExperimentConfig.defaultRobotis.pitchInputConvention, .imuRaw)
    }

    /// **Codable backward-compat**: pitchInputConvention 필드 없는 JSON 디코드 → .imuRaw fallback.
    func testPitchInputConventionBackwardCompatDecode() throws {
        let legacyJson = """
        {
          "algorithmMode": "robotisPControl",
          "signConvention": "robotisWalkingCpp",
          "gainProfile": "robotisOriginal",
          "applyToRobot": true
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BalanceExperimentConfig.self, from: legacyJson)
        XCTAssertEqual(decoded.pitchInputConvention, .imuRaw,
            "기존 JSON (v1.11.2 이하) 디코드 시 .imuRaw fallback")
    }

    /// 명시적 .negate 케이스 인코드/디코드 roundtrip.
    func testPitchInputConventionEncodeDecodeRoundtrip() throws {
        let c = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .negateForwardIsNegative
        )
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(BalanceExperimentConfig.self, from: data)
        XCTAssertEqual(decoded, c)
        XCTAssertEqual(decoded.pitchInputConvention, .negateForwardIsNegative)
    }

    // MARK: - 4. 정규화 인프라 효과 검증 — applyBalanceCorrectionIfEnabled

    /// **회귀 가드 — 기존 동작 보존**: pitchInputConvention=.imuRaw 면 corrections 결과
    /// 가 imuPitchDeg 부호 그대로 사용 (= 변경 전 동작).
    ///
    /// 합성 시나리오: imuPitch=-10° (실 robot 부호). default `.imuRaw` → corrections()
    /// 에 -10° 가 그대로 전달 → anklePitch R 음수 (= 현재 baseline 동작).
    func testImuRawConventionPreservesLegacyBehavior() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .imuRaw  // default
        )
        s.enableBalanceCorrection = true
        // sim 모드 — IMU 직접 set (보행 시작 안 함).
        s.imuPitchDeg = -10.0
        s.imuRollDeg = 0
        _ = s.applyBalanceCorrectionIfEnabled(to: RobotPose.walkReady)
        // P-control 의 LPF 가 첫 호출이라 correctorFilteredPitch ~ -5° (alpha=0.5 EMA),
        // deadband(2.5) 차감 후 effPitch < 0 → corrections 의 anklePitch R 음수.
        let c = s.lastRawCandidate
        XCTAssertNotNil(c, "applyBalanceCorrectionIfEnabled 이 corrections 계산해야")
        if let c = c {
            XCTAssertLessThanOrEqual(c.rAnklePitch, 0,
                ".imuRaw 면 imuPitch -10° 입력 → corrections 식 +m×pitchErr×gain 음수 (legacy)")
        }
    }

    /// **opt-in 검증**: pitchInputConvention=.negateForwardIsNegative 이면 동일 imuPitch=-10°
    /// 입력 시 corrections() 가 +10° 로 정규화된 부호 → anklePitch R 양수 (회복 방향).
    func testNegateConventionFlipsCorrectionDirection() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .negateForwardIsNegative  // opt-in
        )
        s.enableBalanceCorrection = true
        s.imuPitchDeg = -10.0
        s.imuRollDeg = 0
        _ = s.applyBalanceCorrectionIfEnabled(to: RobotPose.walkReady)
        let c = s.lastRawCandidate
        XCTAssertNotNil(c)
        if let c = c {
            XCTAssertGreaterThanOrEqual(c.rAnklePitch, 0,
                ".negate 면 imuPitch -10° → +10° 정규화 → anklePitch R 양수 (앞기울 회복)")
        }
    }

    /// **roll 부호는 정규화 X**: pitchInputConvention 토글이 roll 에 영향 없어야.
    /// (P1.1 은 pitch 만 정규화 — roll 은 raw 유지)
    func testNegateConventionDoesNotAffectRoll() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .negateForwardIsNegative
        )
        s.enableBalanceCorrection = true
        s.imuRollDeg = +10.0
        s.imuPitchDeg = 0
        _ = s.applyBalanceCorrectionIfEnabled(to: RobotPose.walkReady)
        let c = s.lastRawCandidate
        XCTAssertNotNil(c)
        if let c = c {
            // roll +10° → hipRoll, ankleRoll 음수 (legacy 동작) — pitch 정규화 무관.
            XCTAssertLessThanOrEqual(c.rHipRoll, 0,
                "roll 부호는 pitchInputConvention 과 무관")
        }
    }

    // MARK: - Helpers

    /// 진단 테스트용 mock capture (단일 sample 평균값 = meanPitch / meanRoll).
    private func mockCapture(
        axis: StaticTiltCalibration.Axis,
        meanPitch: Double = 0,
        meanRoll: Double = 0
    ) -> StaticTiltCalibration.Capture {
        let samples = (0..<20).map { i in
            StaticTiltCalibration.Sample(
                rollDeg: meanRoll, pitchDeg: meanPitch, tMs: Double(i) * 50
            )
        }
        return StaticTiltCalibration.Capture(
            axis: axis, startTimeIso: "2026-05-18T00:00:00Z",
            durationSec: 1.0, samples: samples, imuSource: "sim"
        )
    }
}
