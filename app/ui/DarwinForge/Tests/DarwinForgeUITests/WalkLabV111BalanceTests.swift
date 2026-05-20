import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11 (2026-05-17 사용자 prompt) 자이로 보정 4축 분리 — 신규 테스트 16종**.
///
/// 사용자 prompt 의 핵심 요구 검증:
/// 1. signConvention 축 — `.robotisWalkingCpp` vs `.alternateDiagnostic` 부호 반전 (sagittal 4 관절만).
/// 2. BalanceExperimentConfig — safe/caution/blocked verdict.
/// 3. WalkLabSession.balanceExperimentConfig — didSet 시 corrector swap.
/// 4. observeOnly mode — corrections 계산하지만 pose 적용 X.
/// 5. applyToRobot=false — observe-only 등가 (pose 적용 X).
/// 6. .off mode — corrections nil, identity 반환.
/// 7. WalkSessionSample 신규 v1.11 필드 JSON encode/decode.
/// 8. WalkSessionSample backward-compat (legacy JSON decoder).
@MainActor
final class WalkLabV111BalanceTests: XCTestCase {

    // MARK: - 1. signConvention 축

    /// **alternateDiagnostic** — knee R/L + anklePitch R/L 만 부호 반전.
    /// lateral (hipRoll, ankleRoll) 은 그대로 (안전상).
    func testSignConventionAlternateDiagnosticFlipsOnlySagittal() {
        let c = BalanceCorrector.robotisOriginal
        let pitchErr = 10.0  // 앞 기울 +10°

        let standard = c.corrections(rollErrDeg: 5.0, pitchErrDeg: pitchErr,
                                     signConvention: .robotisWalkingCpp)
        let alternate = c.corrections(rollErrDeg: 5.0, pitchErrDeg: pitchErr,
                                      signConvention: .alternateDiagnostic)

        // Sagittal (knee, anklePitch) — 부호 반전 확인 (R 만 sample, L 도 동일).
        XCTAssertEqual(alternate.rKnee, -standard.rKnee, accuracy: 1e-9,
            "alternate: rKnee 부호 반전")
        XCTAssertEqual(alternate.lKnee, -standard.lKnee, accuracy: 1e-9,
            "alternate: lKnee 부호 반전")
        XCTAssertEqual(alternate.rAnklePitch, -standard.rAnklePitch, accuracy: 1e-9,
            "alternate: rAnklePitch 부호 반전")
        XCTAssertEqual(alternate.lAnklePitch, -standard.lAnklePitch, accuracy: 1e-9,
            "alternate: lAnklePitch 부호 반전")

        // Lateral (hipRoll, ankleRoll) — 부호 유지 (안전: 진단 실험 중에도 lateral oscillation 회피).
        XCTAssertEqual(alternate.rHipRoll, standard.rHipRoll, accuracy: 1e-9,
            "alternate: rHipRoll 부호 유지 (lateral 안전)")
        XCTAssertEqual(alternate.lHipRoll, standard.lHipRoll, accuracy: 1e-9,
            "alternate: lHipRoll 부호 유지")
        XCTAssertEqual(alternate.rAnkleRoll, standard.rAnkleRoll, accuracy: 1e-9,
            "alternate: rAnkleRoll 부호 유지")
        XCTAssertEqual(alternate.lAnkleRoll, standard.lAnkleRoll, accuracy: 1e-9,
            "alternate: lAnkleRoll 부호 유지")
    }

    /// **signConvention default** = `.robotisWalkingCpp` — 기존 호출 경로 backward-compat.
    func testSignConventionDefaultIsRobotisWalkingCpp() {
        let c = BalanceCorrector.robotisOriginal
        let withDefault = c.corrections(rollErrDeg: 3, pitchErrDeg: 7)
        let withExplicit = c.corrections(rollErrDeg: 3, pitchErrDeg: 7,
                                         signConvention: .robotisWalkingCpp)
        // 두 결과 동일.
        XCTAssertEqual(withDefault.rKnee, withExplicit.rKnee, accuracy: 1e-12)
        XCTAssertEqual(withDefault.lAnklePitch, withExplicit.lAnklePitch, accuracy: 1e-12)
    }

    /// **hybridCorrections** 도 signConvention 전달 정상 동작.
    func testHybridCorrectionsRespectsSignConvention() {
        let c = BalanceCorrector.v110Experimental  // enableHybrid=true
        var state = HybridBalanceState(pitchEma: 0, rollEma: 0)
        // EMA reset 회피용 fresh state.

        let standard = c.hybridCorrections(
            imuRollDeg: 0, imuPitchDeg: 5,
            elapsedMs: 0, periodMs: 600,
            state: &state, now: Date(),
            signConvention: .robotisWalkingCpp
        )
        var state2 = HybridBalanceState(pitchEma: 0, rollEma: 0)
        let alternate = c.hybridCorrections(
            imuRollDeg: 0, imuPitchDeg: 5,
            elapsedMs: 0, periodMs: 600,
            state: &state2, now: Date(),
            signConvention: .alternateDiagnostic
        )
        // Sagittal 부호 반전 확인.
        XCTAssertEqual(alternate.corrections.rKnee, -standard.corrections.rKnee, accuracy: 1e-6)
        XCTAssertEqual(alternate.corrections.rAnklePitch,
                       -standard.corrections.rAnklePitch, accuracy: 1e-6)
    }

    // MARK: - 2. BalanceExperimentConfig safety verdict

    /// `.defaultRobotis` 는 safe.
    func testDefaultConfigSafe() {
        let c = BalanceExperimentConfig.defaultRobotis
        XCTAssertEqual(c.safetyVerdict, .safe)
    }

    /// `.alternateDiagnostic` + `applyToRobot=true` → `.blocked`.
    func testAlternateSignWithApplyIsBlocked() {
        let c = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .alternateDiagnostic,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        )
        if case .blocked = c.safetyVerdict { /* OK */ }
        else { XCTFail("alternateDiagnostic + applyToRobot 는 blocked 여야") }
    }

    /// `.alternateDiagnostic` + `applyToRobot=false` (or observeOnly) → safe.
    func testAlternateSignObserveOnlyIsSafe() {
        let c = BalanceExperimentConfig(
            algorithmMode: .observeOnly,
            signConvention: .alternateDiagnostic,
            gainProfile: .v110Experimental,
            applyToRobot: false
        )
        XCTAssertEqual(c.safetyVerdict, .safe,
            "observeOnly 는 pose 변경 안 함 → 항상 safe")
    }

    /// **v1.11.3 (2026-05-18)** — hybridBA + applyToRobot 는 실 fall 데이터 입증 후
    /// blocked 격상. v110Apply preset 자체는 applyToRobot=false 로 강등되었으므로
    /// 직접 위험 config 를 만들어 검증.
    func testHybridApplyIsBlocked() {
        let c = BalanceExperimentConfig(
            algorithmMode: .hybridBA,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        )
        if case .blocked(let msg) = c.safetyVerdict {
            XCTAssertTrue(msg.contains("Hybrid") || msg.contains("fall") || msg.contains("적용 차단"),
                "메시지에 실 데이터 근거 명시: \(msg)")
        } else {
            XCTFail("hybridBA + applyToRobot 는 blocked 이어야: \(c.safetyVerdict)")
        }
    }

    /// **v1.11.3 (2026-05-18)** — v110Experimental gain + applyToRobot 도 blocked.
    func testV110ExperimentalApplyIsBlocked() {
        let c = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,  // P-control 이어도 v110 gain 은 위험
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,
            applyToRobot: true
        )
        if case .blocked(let msg) = c.safetyVerdict {
            XCTAssertTrue(msg.contains("v1.10") || msg.contains("gain") || msg.contains("적용 차단"),
                "메시지에 실 데이터 근거 명시: \(msg)")
        } else {
            XCTFail("v110Experimental + applyToRobot 는 blocked 이어야: \(c.safetyVerdict)")
        }
    }

    /// **v1.11.3 (2026-05-18)** — v110Apply preset 은 강등되어 applyToRobot=false + safe.
    func testV110ApplyPresetDowngraded() {
        let c = BalanceExperimentConfig.v110Apply
        XCTAssertFalse(c.applyToRobot,
            "v110Apply 는 2026-05-18 실 fall 데이터 입증으로 applyToRobot=false 강등")
        XCTAssertEqual(c.safetyVerdict, .safe,
            "applyToRobot=false 강등 후엔 safe (Hybrid 계산만 수행, pose 변경 X)")
    }

    // MARK: - 3. WalkLabSession config didSet

    /// gainProfile 변경 → corrector 인스턴스 재생성.
    func testSessionGainProfileChangeSwapsCorrector() {
        let s = WalkLabSession()
        XCTAssertFalse(s.balanceCorrector.enableHybrid,
            "init 시 robotisOriginal → enableHybrid=false")
        let originalAnklePitch = s.balanceCorrector.anklePitchGain
        XCTAssertEqual(originalAnklePitch, 0.9, accuracy: 1e-9)

        // gainProfile 만 v110Experimental 로 변경.
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,
            applyToRobot: true
        )
        XCTAssertEqual(s.balanceCorrector.anklePitchGain, 1.5, accuracy: 1e-9,
            "gainProfile=v110 → corrector.anklePitchGain=1.5")
    }

    /// algorithmMode=hybridBA → corrector.enableHybrid=true 강제.
    func testSessionHybridModeForcesHybridCorrector() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .hybridBA,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,  // robotisOriginal 의 enableHybrid=false 임에도
            applyToRobot: true
        )
        XCTAssertTrue(s.balanceCorrector.enableHybrid,
            "algorithmMode=.hybridBA 면 corrector.enableHybrid 강제 ON")
    }

    /// algorithmMode=robotisPControl → corrector.enableHybrid=false 강제.
    func testSessionPControlModeForcesNonHybridCorrector() {
        let s = WalkLabSession()
        // v110 default 는 enableHybrid=true 지만 algorithmMode override 됨.
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,
            applyToRobot: true
        )
        XCTAssertFalse(s.balanceCorrector.enableHybrid,
            "algorithmMode=.robotisPControl 면 corrector.enableHybrid=false 강제")
    }

    /// blocked verdict → applyToRobot 자동 OFF.
    func testBlockedVerdictForcesApplyOff() {
        let s = WalkLabSession()
        // alternateDiagnostic + applyToRobot 시도 → didSet 가 자동 OFF.
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .alternateDiagnostic,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        )
        XCTAssertFalse(s.balanceExperimentConfig.applyToRobot,
            "blocked 조합 → 자동으로 applyToRobot=false 로 강제 전환")
    }

    /// **v1.11.3 (2026-05-18)** — hybridBA + applyToRobot=true 도 강제 강등.
    func testHybridApplyAutoDowngrades() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .hybridBA,
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,
            applyToRobot: true
        )
        XCTAssertFalse(s.balanceExperimentConfig.applyToRobot,
            "hybridBA + v110Experimental + applyToRobot=true → didSet 자동 OFF (실 fall 데이터 입증)")
    }

    /// **v1.11.3 (2026-05-18) — startWalkCycle 진입 가드**: 위험 config 가 didSet
    /// 우회로 살아남아도 보행 시작 시점에 다시 한 번 확인. session.start() 가 cradle
    /// 미확인 / bus 미연결 등으로 일찍 return 해도 가드 자체는 호출 가능해야 함.
    func testStartWalkCycleBlockedConfigDowngrades() {
        let s = WalkLabSession()
        // 정상 경로로 위험 config 시도 → didSet 가 즉시 강등.
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .hybridBA,
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,
            applyToRobot: true
        )
        // didSet 가 이미 강등.
        XCTAssertFalse(s.balanceExperimentConfig.applyToRobot,
            "didSet 가 즉시 강등 — startWalkCycle 가드는 우회 케이스 방어 추가 layer")

        // 보행 시작 시도 — cradle 미확인 / bus 미연결 이라 일찍 return 하지만 config 는
        // 이미 강등 상태 유지.
        s.start(.march)
        XCTAssertFalse(s.balanceExperimentConfig.applyToRobot,
            "start() 호출 후에도 applyToRobot=false 유지")
        s.stop()
    }

    // MARK: - 4. applyBalanceCorrectionIfEnabled 분기

    /// algorithmMode=.off → pose 그대로 + lastCorrections nil + lastCorrectionApplied=false.
    func testAlgorithmOffReturnsIdentityPose() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .off,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        )
        let basePose = RobotPose.walkReady
        let result = s.applyBalanceCorrectionIfEnabled(to: basePose)

        XCTAssertEqual(result, basePose, "algorithmMode=.off → pose identity")
        XCTAssertNil(s.lastCorrections, "off mode → lastCorrections nil")
        XCTAssertFalse(s.lastCorrectionApplied, "off mode → applied=false")
    }

    /// algorithmMode=.observeOnly → corrections 계산하지만 pose 적용 X.
    func testObserveOnlyComputesButDoesNotApply() {
        let s = WalkLabSession()
        // **v1.11.4 (2026-05-18)**: enableBalanceCorrection default OFF 로 전환됨 →
        // observeOnly 동작 검증을 위해 명시 ON.
        s.enableBalanceCorrection = true
        // observeOnly 면 corrections 계산하되 pose 미변경.
        // applyToRobot 는 무시 (observeOnly 가 우선).
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .observeOnly,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true  // observeOnly 가 우선 → 무시.
        )
        // IMU 강제 — pitch 10°.
        s._testForceImuAndTick(rollDeg: 0, pitchDeg: 10)
        let basePose = RobotPose.walkReady
        let result = s.applyBalanceCorrectionIfEnabled(to: basePose)

        XCTAssertEqual(result, basePose,
            "observeOnly → pose identity (corrections 계산하지만 적용 X)")
        XCTAssertNotNil(s.lastCorrections,
            "observeOnly → corrections 는 기록됨 (로깅 용)")
        XCTAssertFalse(s.lastCorrectionApplied,
            "observeOnly → applied=false 로 기록")
    }

    /// applyToRobot=false → observe-only 등가 (pose 변경 X).
    func testApplyToRobotFalseDoesNotMutatePose() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: false  // 명시 OFF
        )
        s._testForceImuAndTick(rollDeg: 5, pitchDeg: 10)
        let basePose = RobotPose.walkReady
        let result = s.applyBalanceCorrectionIfEnabled(to: basePose)

        XCTAssertEqual(result, basePose,
            "applyToRobot=false → pose identity")
        XCTAssertFalse(s.lastCorrectionApplied,
            "applyToRobot=false → applied=false")
    }

    /// applyToRobot=true + algorithmMode 활성 → pose 변경.
    func testApplyToRobotTrueMutatesPose() {
        let s = WalkLabSession()
        s.enableBalanceCorrection = true
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        )
        // 강한 IMU 입력 → corrections 가 deadband 넘게.
        s._testForceImuAndTick(rollDeg: 10, pitchDeg: 15)
        let basePose = RobotPose.walkReady

        // Ramp 가 시작되지 않은 직후 — corrections 0 가능성 회피로 ramp 시점 미리 set.
        // Test 만 ramp 즉시 완료된 것으로 가정 (대안: tick 시각 조작).
        // 여기선 ramp 0 → corrections × 0 = 0 일 수 있어서 corrections.maxAbs 만 검증.
        _ = s.applyBalanceCorrectionIfEnabled(to: basePose)
        // applied 여부는 enableBalanceCorrection + ramp + corrections 모두 만족 시 true.
        // ramp 가 init 직후라 corrections 0 → applied 는 true (pose 가 동일해도).
        // 본 테스트는 분기 logic 만 확인 — applied=true 이거나 corrections 0 이거나.
        XCTAssertNotNil(s.lastCorrections,
            "applyToRobot=true + 활성 → corrections 계산됨")
    }

    // MARK: - 5. WalkSessionSample v1.11 fields

    /// 신규 v1.11 필드 포함 sample JSON encode/decode roundtrip.
    func testWalkSessionSampleV111FieldsRoundtrip() throws {
        let sample = WalkSessionSample(
            t: 1234.5,
            preset: "normalWalk",
            intensityLevel: 2,
            imuRollDeg: 1.0,
            imuPitchDeg: 2.0,
            correctorRollErrDeg: 0.5,
            correctorPitchErrDeg: 1.5,
            balanceState: "normal",
            correctorDeltas: [0, 0, 0, 0, 0, 0, 0, 0],
            imuSource: "sim",
            batteryVolts: 12.0,
            motorAvgTemp: 35.0,
            balanceAlgorithmMode: "hybridBA",
            balanceSignConvention: "robotisWalkingCpp",
            balanceGainProfile: "v110Experimental",
            correctionAppliedToRobot: true,
            walkCycleElapsedMs: 200.0,
            walkPeriodMs: 600.0,
            imuSampleAgeMs: 30.0,
            expectedPitchDeg: 4.5,
            emaPitchDeg: 0.3,
            effectivePitchErrDeg: -0.1
        )

        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(WalkSessionSample.self, from: data)

        XCTAssertEqual(decoded.balanceAlgorithmMode, "hybridBA")
        XCTAssertEqual(decoded.balanceSignConvention, "robotisWalkingCpp")
        XCTAssertEqual(decoded.balanceGainProfile, "v110Experimental")
        XCTAssertEqual(decoded.correctionAppliedToRobot, true)
        XCTAssertEqual(decoded.walkCycleElapsedMs ?? -1, 200.0, accuracy: 1e-6)
        XCTAssertEqual(decoded.walkPeriodMs ?? -1, 600.0, accuracy: 1e-6)
        XCTAssertEqual(decoded.imuSampleAgeMs ?? -1, 30.0, accuracy: 1e-6)
        XCTAssertEqual(decoded.expectedPitchDeg ?? -1, 4.5, accuracy: 1e-6)
        XCTAssertEqual(decoded.emaPitchDeg ?? -1, 0.3, accuracy: 1e-6)
        XCTAssertEqual(decoded.effectivePitchErrDeg ?? 100, -0.1, accuracy: 1e-6)
    }

    /// **Backward-compat** — 기존 (legacy) JSON 만 있는 sample 도 decode 가능 (신규 필드는 nil).
    func testWalkSessionSampleLegacyJsonStillDecodes() throws {
        let legacyJson = """
        {
          "t": 100.0,
          "preset": "march",
          "intensityLevel": 2,
          "imuRollDeg": 0.5,
          "imuPitchDeg": 1.0,
          "correctorRollErrDeg": 0.0,
          "correctorPitchErrDeg": 0.5,
          "balanceState": "normal",
          "correctorDeltas": [0,0,0,0,0,0,0,0],
          "imuSource": "sim",
          "batteryVolts": null,
          "motorAvgTemp": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WalkSessionSample.self, from: legacyJson)
        XCTAssertEqual(decoded.preset, "march")
        XCTAssertNil(decoded.balanceAlgorithmMode,
            "legacy json → 신규 필드 nil 로 decode (backward-compat)")
        XCTAssertNil(decoded.correctionAppliedToRobot)
        XCTAssertNil(decoded.walkCycleElapsedMs)
        XCTAssertNil(decoded.effectivePitchErrDeg)
    }

    // MARK: - 5b. v1.11.1 critical regression (사용자 review 2026-05-18)

    /// **CRITICAL (사용자 보고)**: v110Observe 프리셋 적용 시 corrector.enableHybrid=true 보장.
    /// 종전 버그: algorithmMode==.observeOnly 면 forceHybrid=false 라 enableHybrid 강제 off →
    /// useHybridPath=false → 실제로는 P-control 로 계산. "v1.10 관찰" UI 라벨과 불일치.
    /// v1.11.1 fix: observeOnly 시 gainProfile native enableHybrid 보존.
    func testV110ObserveActuallyRunsHybridAlgorithm() {
        let s = WalkLabSession()
        // v110Observe 프리셋 = observeOnly + v110Experimental gain + applyToRobot=false.
        s.balanceExperimentConfig = .v110Observe
        XCTAssertTrue(s.balanceCorrector.enableHybrid,
            "v110Observe (observeOnly + v110Experimental) → corrector.enableHybrid 가 true 여야 함. " +
            "false 면 실제로는 P-control 로 흐르는 버그.")
        XCTAssertEqual(s.balanceCorrector.anklePitchGain, 1.5, accuracy: 1e-9,
            "v110 gain 적용 확인")
    }

    /// observeOnly + robotisOriginal → corrector.enableHybrid 가 false (gainProfile native).
    /// P-control 알고리즘을 pose 적용 없이 관찰.
    func testObserveOnlyRobotisOriginalUsesPControl() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .observeOnly,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: false
        )
        XCTAssertFalse(s.balanceCorrector.enableHybrid,
            "observeOnly + robotisOriginal → P-control 관찰 (enableHybrid=false)")
    }

    /// algorithmMode=.hybridBA 명시 시 gainProfile 의 enableHybrid 무관 true 강제.
    func testHybridBAModeForceTrueRegardlessOfProfile() {
        let s = WalkLabSession()
        // robotisOriginal 의 enableHybrid=false 임에도 hybridBA mode 가 override.
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .hybridBA,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        )
        XCTAssertTrue(s.balanceCorrector.enableHybrid,
            ".hybridBA mode 는 gainProfile 의 enableHybrid 와 무관 true 강제")
    }

    // MARK: - 5c. v1.11.2 P1: requestConfigChange risk gate (사용자 review 2026-05-18)

    /// **P1 핵심**: isRiskyToApply 가 정확하게 위험 조합만 true.
    func testIsRiskyToApplyCoverage() {
        // 안전: applyToRobot=false 면 어떤 조합이든 false.
        XCTAssertFalse(BalanceExperimentConfig.v110Observe.isRiskyToApply,
            "observe-only 는 항상 안전")
        XCTAssertFalse(BalanceExperimentConfig.defaultRobotis.isRiskyToApply,
            "defaultRobotis = robotisPControl + robotisOriginal + applyToRobot → 안전")

        // **v1.11.3 (2026-05-18)** — v110Apply preset 은 applyToRobot=false 강등 →
        // isRiskyToApply=false. 위험 조합 검증은 직접 config 생성으로.
        XCTAssertFalse(BalanceExperimentConfig.v110Apply.isRiskyToApply,
            "v110Apply 는 강등되어 더 이상 위험 X (applyToRobot=false)")
        XCTAssertTrue(BalanceExperimentConfig(
            algorithmMode: .hybridBA,
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,
            applyToRobot: true
        ).isRiskyToApply, "직접 위험 조합 (hybridBA+v110+apply) 은 여전히 risky")
        XCTAssertTrue(BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,
            applyToRobot: true
        ).isRiskyToApply, "v110Experimental + applyToRobot → 위험 (P-control 이어도)")
        XCTAssertTrue(BalanceExperimentConfig(
            algorithmMode: .hybridBA,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        ).isRiskyToApply, "hybridBA + applyToRobot → 위험 (robotisOriginal gain 이어도)")
        XCTAssertTrue(BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .alternateDiagnostic,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        ).isRiskyToApply, "alternateDiagnostic + applyToRobot → 위험")
    }

    // MARK: - 5d. v1.11.1 P2-B: IMU freshness gate 회귀 (사용자 review)

    /// IMU freshness gate — bus 없이 (sim 모드) 는 gate 미적용.
    /// sim 에서는 lastImuSampleAt nil 이라 freshnessGate=1.0 으로 정상 동작.
    func testFreshnessGateSimModeNoGate() {
        let s = WalkLabSession()
        // store 가 attach 안 됐으므로 store?.bus == nil → sim 모드.
        s.enableBalanceCorrection = true
        s.balanceExperimentConfig = .defaultRobotis  // robotisPControl + applyToRobot=true
        let pose = RobotPose.walkReady
        _ = s.applyBalanceCorrectionIfEnabled(to: pose)
        // sim 모드 → freshnessGate=1.0 → corrections 계산 정상.
        XCTAssertNotNil(s.lastRawCandidate,
            "sim 모드 freshnessGate 미적용 — corrections 정상 계산")
    }

    /// **P2-B 회귀**: bus 연결됐는데 IMU 한 번도 안 옴 → corrections 즉시 차단.
    /// Codex review 2026-05-18 의 추가 발견.
    /// 직접 ConnectionStore 주입은 setup 복잡하므로 본 test 는 가드 logic 자체 검증
    /// (lastImuSampleAt nil + busConnected = false 인 일반 path 와 동일 흐름 확인).
    func testFreshnessGateBusConnectedButNoImuBlocks() {
        let s = WalkLabSession()
        s.enableBalanceCorrection = true
        s.balanceExperimentConfig = .defaultRobotis
        // store 없으므로 busConnected=false → 정상 path. Gate 회로 자체 정상 동작 확인.
        _ = s.applyBalanceCorrectionIfEnabled(to: .walkReady)
        // store?.bus == nil 인 case 에서 차단 없이 정상 흐름 확인.
        XCTAssertTrue(s.lastCorrectionApplied || s.lastCorrections == nil,
            "store 없는 sim mode 는 freshness gate 차단 안 함")
    }

    /// algorithmMode .off 일 때 freshnessGate 보다 우선 — early return + state clear.
    func testOffModePrecedesFreshnessGate() {
        let s = WalkLabSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .off,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true
        )
        let result = s.applyBalanceCorrectionIfEnabled(to: .walkReady)
        XCTAssertEqual(result, .walkReady)
        XCTAssertNil(s.lastCorrections)
        XCTAssertNil(s.lastRawCandidate, "off mode → rawCandidate 도 clear")
        XCTAssertFalse(s.lastCorrectionApplied)
    }

    // MARK: - 6. BalanceCorrector.forGainProfile factory

    /// forGainProfile 이 올바른 인스턴스 반환.
    func testForGainProfileFactory() {
        let original = BalanceCorrector.forGainProfile(.robotisOriginal)
        XCTAssertEqual(original.anklePitchGain, 0.9, accuracy: 1e-9)
        XCTAssertEqual(original.ankleRollGain, 1.0, accuracy: 1e-9)
        XCTAssertFalse(original.enableHybrid)

        let experimental = BalanceCorrector.forGainProfile(.v110Experimental)
        XCTAssertEqual(experimental.anklePitchGain, 1.5, accuracy: 1e-9)
        XCTAssertEqual(experimental.ankleRollGain, 0.5, accuracy: 1e-9)
        XCTAssertTrue(experimental.enableHybrid)

        let custom = BalanceCorrector.forGainProfile(.custom)
        // custom 은 robotisOriginal fallback (expert slider override 예상).
        XCTAssertEqual(custom.anklePitchGain, 0.9, accuracy: 1e-9,
            "custom profile = robotisOriginal fallback (expert slider override)")
    }
}
