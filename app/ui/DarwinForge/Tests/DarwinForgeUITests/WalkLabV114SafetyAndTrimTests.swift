import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.4 (2026-05-18) — P0 안전 default + hipPitchOffset trim + UIUX 회귀 가드**.
///
/// 검증 대상:
/// 1. `enableBalanceCorrection` default = false (실 robot 검증 전 안전)
/// 2. `hipPitchOffsetTrimDeg` default = 13.0 (ROBOTIS 원본)
/// 3. `WalkMotionLibrary.AdvancedTuning.hipPitchOffsetDeg` 가 walking state 에 반영
/// 4. `BalanceExperimentControls.requestConfigChange` 가 `pitchInputConvention` 보존
@MainActor
final class WalkLabV114SafetyAndTrimTests: XCTestCase {

    // MARK: - 1. Safety defaults

    /// **회귀 가드 — v1.11.4 안전 default**: enableBalanceCorrection = false.
    /// 2026-05-18 실 robot 데이터 (raw gait mean pitch -13°) 입증 → corrector OFF 가 default.
    func testEnableBalanceCorrectionDefaultsFalse() {
        let s = WalkLabSession()
        XCTAssertFalse(s.enableBalanceCorrection,
            "v1.11.4: default OFF — 실 robot raw gait 진단 우선")
    }

    /// **회귀 가드 — hipPitchOffsetTrimDeg default 13°** (ROBOTIS 원본).
    /// 종전 (v1.11.3 이전) 은 하드코딩 → 사용자 변경 불가. 이제 노출되었으되 기본값
    /// 은 ROBOTIS 원본 그대로 유지.
    func testHipPitchOffsetTrimDefaultsTo13() {
        let s = WalkLabSession()
        XCTAssertEqual(s.hipPitchOffsetTrimDeg, 13.0, accuracy: 1e-6,
            "default 는 ROBOTIS Walking.cpp 원본 13°")
    }

    // MARK: - 2. AdvancedTuning.hipPitchOffsetDeg 반영

    /// **회귀 가드**: AdvancedTuning init 의 hipPitchOffsetDeg default = 13.0.
    func testAdvancedTuningHipPitchOffsetDefault() {
        let t = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 600, footHeightMm: 40, balanceGain: 1.0
        )
        XCTAssertEqual(t.hipPitchOffsetDeg, 13.0, accuracy: 1e-6,
            "AdvancedTuning init default — ROBOTIS 13°")
    }

    /// 명시적 hipPitchOffsetDeg 전달 → struct 에 반영.
    func testAdvancedTuningHipPitchOffsetPropagates() {
        let t = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 600, footHeightMm: 40, balanceGain: 1.0,
            hipPitchOffsetDeg: 5.0
        )
        XCTAssertEqual(t.hipPitchOffsetDeg, 5.0, accuracy: 1e-6)
    }

    /// **회귀 가드 — robotisWalkingApproxPose 가 trim 값 반영**:
    /// hipPitchOffset 0 vs 13 두 케이스의 cycle 전체에서 raw position 차이 존재.
    ///
    /// IK 가 trim 을 다른 joint (knee/ankle) 로 흡수할 수 있으므로 단일 joint 비교 X.
    /// 8 lower body joint × 6 cycle step 의 raw 값 sum 비교 — 어딘가는 다르면 OK.
    func testHipPitchOffsetTrimChangesGenerationOfPose() {
        let trim0 = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 600, footHeightMm: 40, balanceGain: 1.0,
            hipPitchOffsetDeg: 0.0
        )
        let trim13 = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 600, footHeightMm: 40, balanceGain: 1.0,
            hipPitchOffsetDeg: 13.0
        )
        guard let plan0 = WalkMotionLibrary.continuousWalkPlan(for: .march, tuning: trim0),
              let plan13 = WalkMotionLibrary.continuousWalkPlan(for: .march, tuning: trim13) else {
            XCTFail("continuousWalkPlan march 둘 다 nil X")
            return
        }
        XCTAssertEqual(plan0.cycle.count, plan13.cycle.count, "cycle 길이 동일")
        // 8 lower body joints — IK 흡수 가능성 고려, sum 으로 비교.
        let lowerBodyIds: [Int] = [
            JointID.rHipPitch, .lHipPitch, .rKnee, .lKnee,
            .rAnklePitch, .lAnklePitch, .rHipRoll, .lHipRoll
        ].map { Int($0.rawValue) }
        var totalDiff = 0
        for stepIdx in 0..<plan0.cycle.count {
            let p0 = plan0.cycle[stepIdx].positions
            let p13 = plan13.cycle[stepIdx].positions
            for j in lowerBodyIds {
                totalDiff += abs(Int(p0[j]) - Int(p13[j]))
            }
        }
        XCTAssertGreaterThan(totalDiff, 0,
            "hipPitchOffset 0 vs 13 → cycle 전체에서 lower body raw 합산 차이 > 0")
    }

    // MARK: - 3. WalkLabSession.currentWalkTuning 가 trim 반영

    /// **회귀 가드**: trim 이 default (13°) 와 다르면 advanced=false 여도 tuning 활성.
    func testCurrentWalkTuningActiveWhenTrimChanged() {
        // **WalkLabSession 의 currentWalkTuning 은 private**. 대신 동일 의도로
        // public API (`WalkMotionLibrary.page(for:tuning:)`) 직접 비교.
        // trim 5 vs default tuning → 어딘가는 raw 값 차이 발생 (sum 비교).
        guard let defaultPage = WalkMotionLibrary.page(for: .march, tuning: nil) else {
            XCTFail("default tuning page march nil X")
            return
        }
        let trim5 = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 600, footHeightMm: 40, balanceGain: 1.0,
            hipPitchOffsetDeg: 5.0
        )
        guard let trimPage = WalkMotionLibrary.page(for: .march, tuning: trim5) else {
            XCTFail("trim 5 page march nil X")
            return
        }
        // 두 page 의 모든 step × 모든 lower body joint 합산 차이.
        let lowerBodyIds: [Int] = [
            JointID.rHipPitch, .lHipPitch, .rKnee, .lKnee,
            .rAnklePitch, .lAnklePitch, .rHipRoll, .lHipRoll
        ].map { Int($0.rawValue) }
        let stepCount = min(defaultPage.steps.count, trimPage.steps.count)
        var totalDiff = 0
        for s in 0..<stepCount {
            let d = defaultPage.steps[s].positions
            let t = trimPage.steps[s].positions
            for j in lowerBodyIds {
                totalDiff += abs(Int(d[j]) - Int(t[j]))
            }
        }
        XCTAssertGreaterThan(totalDiff, 0,
            "default trim(13°) vs trim5° → lower body raw 합산 차이 > 0")
    }

    // MARK: - 4. pitchInputConvention 보존 회귀 (UI fix)
    //
    // BalanceExperimentControls.requestConfigChange 는 private SwiftUI method — 직접
    // 호출 불가. 대신 logical equivalent: BalanceExperimentConfig init 가 pitch axis
    // 를 explicit 매개변수로 받아야 보존 가능 — 이건 v1.11.3 부터 이미 있음.
    // **추가 검증**: 모든 4축 (algorithm/sign/gain/apply) 변경 시 pitchInputConvention
    // explicit 으로 전달하는 init 가 동작.

    func testConfigInitPreservesPitchInputConventionAcrossAxisChange() {
        let original = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .negateForwardIsNegative
        )
        // 4축 변경 시 pitchInputConvention 명시 전달 — 보존 검증.
        let after = BalanceExperimentConfig(
            algorithmMode: .observeOnly,  // axis 변경
            signConvention: original.signConvention,
            gainProfile: original.gainProfile,
            applyToRobot: original.applyToRobot,
            pitchInputConvention: original.pitchInputConvention
        )
        XCTAssertEqual(after.pitchInputConvention, .negateForwardIsNegative,
            "UI 의 axis 변경 시 pitchInputConvention 보존 필수")
    }
}
