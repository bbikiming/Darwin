import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// 사이클 160 (P0-3, gyro closed-loop review): balanceCorrectionFreshness 상태 검증.
///
/// applyBalanceCorrectionIfEnabled 가 IMU age 에 따라 .normal / .degraded / .blocked 로
/// 전환되는지 단위 테스트. UI HUD 가 본 상태를 표시해 사용자 silent 차단 인지 가능.
///
/// 주의: lastImuSampleAt 가 store-derived computed property 라 직접 inject 불가.
/// 본 테스트는 sim mode (bus nil) 의 .normal default + enum 정합성만 검증.
@MainActor
final class WalkLabBalanceFreshnessTests: XCTestCase {

    private func makeSession() -> WalkLabSession {
        let s = WalkLabSession()
        s.enableBalanceCorrection = true
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        return s
    }

    /// sim mode (bus nil + lastImuSampleAt nil) → .normal — IMU age 무관.
    func testFreshnessNormalInSimMode() {
        let s = makeSession()
        // sim 가정 — store nil 또는 store.bus nil + lastImuSuccessAt nil.
        // makeSession 는 store nil → lastImuSampleAt 는 nil → busConnected false → freshnessGate = 1.0.
        _ = s.applyBalanceCorrectionIfEnabled(to: .walkReady)
        XCTAssertEqual(s.balanceCorrectionFreshness, .normal,
                       "sim mode (store nil) 은 .normal default")
    }

    /// disable 시 freshness 는 unchanged — 호출 자체가 early return.
    func testFreshnessUnchangedWhenDisabled() {
        let s = makeSession()
        s.enableBalanceCorrection = false
        let initial = s.balanceCorrectionFreshness
        _ = s.applyBalanceCorrectionIfEnabled(to: .walkReady)
        XCTAssertEqual(s.balanceCorrectionFreshness, initial,
                       "disable 경로는 freshness 상태 무변화")
    }

    /// algorithmMode .off → identity 반환, freshness 는 normal default 유지.
    func testFreshnessNormalWhenAlgorithmOff() {
        let s = makeSession()
        s.balanceExperimentConfig = BalanceExperimentConfig(
            algorithmMode: .off,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        _ = s.applyBalanceCorrectionIfEnabled(to: .walkReady)
        // .off 는 freshness gate 분기 전에 early return — default .normal 유지.
        XCTAssertEqual(s.balanceCorrectionFreshness, .normal)
    }

    /// koreanLabel 가 3 case 모두 non-empty + 한국어.
    func testKoreanLabelsNonEmpty() {
        for state in WalkLabSession.BalanceCorrectionFreshness.allCases {
            XCTAssertFalse(state.koreanLabel.isEmpty,
                           "\(state) 의 koreanLabel 비어 있음")
        }
    }

    /// rawValue + Equatable + CaseIterable 정상.
    func testRawValueAndEquatable() {
        XCTAssertEqual(WalkLabSession.BalanceCorrectionFreshness.normal.rawValue, "normal")
        XCTAssertEqual(WalkLabSession.BalanceCorrectionFreshness.degraded.rawValue, "degraded")
        XCTAssertEqual(WalkLabSession.BalanceCorrectionFreshness.blocked.rawValue, "blocked")
        XCTAssertNotEqual(WalkLabSession.BalanceCorrectionFreshness.normal,
                          WalkLabSession.BalanceCorrectionFreshness.blocked)
        XCTAssertEqual(WalkLabSession.BalanceCorrectionFreshness.allCases.count, 3)
    }

    /// 한국어 라벨 의미상 distinct.
    func testKoreanLabelsDistinct() {
        let labels = WalkLabSession.BalanceCorrectionFreshness.allCases.map { $0.koreanLabel }
        let unique = Set(labels)
        XCTAssertEqual(labels.count, unique.count, "모든 case 의 koreanLabel 가 distinct 해야")
    }
}
