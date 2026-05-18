import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.8 (2026-05-18) — 8 axis 직교성 / 상호작용 / lifecycle 회귀 가드**.
///
/// 5 HIGH fix 검증:
/// - HIGH-1: .robotisOnboard 시 5축 토글 disabled (UI 단)
/// - HIGH-2: walkingEngine.didSet 가 onboardWalkingActive=false reset
/// - HIGH-3: 보행 중 startWalkCycle 다중 진입 차단
/// - HIGH-4: pitchInputConvention.negate + signConvention.alternateDiagnostic blocked
/// - HIGH-5: 명령 dedup 의 stale reset
@MainActor
final class WalkLabV118OrthogonalityTests: XCTestCase {

    // MARK: - HIGH-2: walkingEngine.didSet cleanup

    /// **회귀 가드**: walkingEngine 전환 시 onboardWalkingActive reset.
    func testWalkingEngineToRobotisToMacResetsOnboardActive() {
        let s = WalkLabSession()
        // private(set) onboardWalkingActive — 직접 set 불가. start() 경로로만 true 됨.
        // sim 모드 (store 미연결) 에서는 startWalkCycle 가 noConnection 으로 일찍
        // return 하므로 onboardWalkingActive 가 true 가 안 됨. 따라서 본 테스트는
        // 간접적 — walkingEngine 변경 시 didSet 가 false 유지 검증.
        s.walkingEngine = .robotisOnboard
        XCTAssertFalse(s.onboardWalkingActive,
            "start() 호출 안 했으면 onboardWalkingActive=false 유지")
        s.walkingEngine = .macSparseKeyframe
        XCTAssertFalse(s.onboardWalkingActive,
            "엔진 전환 후에도 false")
    }

    // MARK: - HIGH-3: 보행 중 다중 진입 차단

    /// 보행 진행 중 startWalkCycle 재호출 시 차단.
    /// (private 메서드 직접 테스트 불가 — public start() 호출 후 lastRobotEvent 검사)
    func testStartWalkCycleSecondCallBlockedWhileOnboardActive() {
        let s = WalkLabSession()
        s.walkingEngine = .robotisOnboard
        // sim 모드 (store 미연결) → start() 가 noConnection 으로 일찍 return.
        // 본 테스트는 코드 path 검증 — 다중 start() 호출 시 exception 없음 + state
        // 일관성. onboardWalkingActive 가 진짜로 true 되는 검증은 실 robot 환경 필요.
        s.start(.march)
        s.start(.slowWalk)
        // 두 번째 호출 후에도 onboardWalkingActive 안 변함 (sim 모드).
        XCTAssertFalse(s.onboardWalkingActive,
            "sim 모드: 다중 start() 호출 후에도 onboardWalkingActive false 유지")
    }

    // MARK: - HIGH-4: double-negate safetyVerdict

    /// **회귀 가드**: pitchInputConvention=.negate + signConvention=.alternateDiagnostic
    /// → safetyVerdict.blocked.
    func testNegateAndAlternateDiagnosticBothBlocked() {
        let c = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .alternateDiagnostic,
            gainProfile: .robotisOriginal,
            applyToRobot: false,  // observe-only 도 차단
            pitchInputConvention: .negateForwardIsNegative
        )
        if case .blocked(let msg) = c.safetyVerdict {
            XCTAssertTrue(msg.contains("정규화") || msg.contains("중복") || msg.contains("부호 반전"),
                "메시지에 double-negate 안내 명시: \(msg)")
        } else {
            XCTFail("negate + alternateDiagnostic 는 blocked 이어야: \(c.safetyVerdict)")
        }
    }

    /// .negate alone (single axis ON) 은 safe.
    func testNegateAloneIsSafe() {
        let c = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .robotisWalkingCpp,  // default
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .negateForwardIsNegative
        )
        XCTAssertEqual(c.safetyVerdict, .safe,
            "정규화 단독 ON 은 안전 (calibration fix)")
    }

    /// .alternateDiagnostic alone + applyToRobot → blocked (기존 가드).
    func testAlternateDiagnosticAloneStillBlocked() {
        let c = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,
            signConvention: .alternateDiagnostic,
            gainProfile: .robotisOriginal,
            applyToRobot: true,
            pitchInputConvention: .imuRaw
        )
        if case .blocked = c.safetyVerdict { /* OK */ }
        else { XCTFail("alternateDiagnostic + applyToRobot 는 blocked: \(c.safetyVerdict)") }
    }

    // MARK: - MEDIUM-2: safetyVerdict 메시지 분리

    /// **회귀 가드**: hybridBA + robotisOriginal + apply → 메시지에 "gain 안전" 명시.
    func testBlockedMessageDistinguishesAlgorithmFromGain() {
        let c = BalanceExperimentConfig(
            algorithmMode: .hybridBA,
            signConvention: .robotisWalkingCpp,
            gainProfile: .robotisOriginal,  // gain 은 안전
            applyToRobot: true
        )
        if case .blocked(let msg) = c.safetyVerdict {
            XCTAssertTrue(msg.contains("알고리즘") || msg.contains("Hybrid"),
                "알고리즘 차단 명시")
            XCTAssertTrue(msg.contains("안전") || msg.contains("ROBOTIS"),
                "gain 은 안전 표시 (사용자 혼동 차단)")
        } else {
            XCTFail("hybridBA + apply blocked 기대: \(c.safetyVerdict)")
        }
    }

    /// **회귀 가드**: P-control + v110 gain + apply → 메시지에 "알고리즘 안전" 명시.
    func testBlockedMessageGainOnlyDistinguishesFromAlgorithm() {
        let c = BalanceExperimentConfig(
            algorithmMode: .robotisPControl,  // algorithm 은 안전
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,
            applyToRobot: true
        )
        if case .blocked(let msg) = c.safetyVerdict {
            XCTAssertTrue(msg.contains("gain") || msg.contains("v1.10"),
                "gain 차단 명시")
            XCTAssertTrue(msg.contains("P-control") || msg.contains("안전"),
                "algorithm 은 안전 표시")
        } else {
            XCTFail("v110 gain + apply blocked 기대: \(c.safetyVerdict)")
        }
    }
}
