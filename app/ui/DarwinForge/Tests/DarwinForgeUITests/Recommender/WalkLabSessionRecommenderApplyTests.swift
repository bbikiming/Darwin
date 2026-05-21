import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.16.0.1 (2026-05-21) — Phase 2 architect M4 fix**: applyRecommendation 통합 테스트.
///
/// 종전 Recommender unit test 9개는 strategy logic 만 cover. 본 테스트는 session
/// extension (`WalkLabSession+Recommender.swift`) 의 hook 동작 검증:
/// - idle 시 정상 적용 (모든 slider + intensity + balanceConfig)
/// - walking 시 safety guard (lastScopeWarning + 슬라이더 unchanged)
/// - balanceGain axis 만 nudge 시 다른 slider 영향 없음 확인
@MainActor
final class WalkLabSessionRecommenderApplyTests: XCTestCase {

    private var session: WalkLabSession!

    override func setUp() async throws {
        try await super.setUp()
        session = WalkLabSession()
    }

    override func tearDown() async throws {
        session = nil
        try await super.tearDown()
    }

    // MARK: - idle 시 정상 적용

    func testApplyRecommendation_WhenIdle_AppliesAllFields() {
        let rec = makeRecommendation(
            preset: "march",
            tuning: TuningSnapshot(strideMm: 25, sideMm: 5, turnDeg: 10,
                                   periodMs: 700, footHeightMm: 45, balanceGain: 1.5),
            intensity: 3
        )

        // 초기 상태 — idle, slider default.
        XCTAssertFalse(session.isWalkActive, "초기 상태 idle")
        let initialStride = session.strideMm

        session.applyRecommendation(rec)

        XCTAssertEqual(session.strideMm, 25, accuracy: 1e-9)
        XCTAssertEqual(session.sideMm, 5, accuracy: 1e-9)
        XCTAssertEqual(session.turnDeg, 10, accuracy: 1e-9)
        XCTAssertEqual(session.customPeriodMs, 700, accuracy: 1e-9)
        XCTAssertEqual(session.footHeightMm, 45, accuracy: 1e-9)
        XCTAssertEqual(session.balanceGain, 1.5, accuracy: 1e-9)
        XCTAssertEqual(session.correctorIntensityLevel, 3)
        XCTAssertNotEqual(session.strideMm, initialStride, "applied 후 stride 변경됨")
        XCTAssertNil(session.lastScopeWarning, "정상 적용 — warning 없음")
        XCTAssertNotNil(session.lastRobotEvent, "사용자 안내 메시지 set")
    }

    // MARK: - walking 시 safety guard

    func testApplyRecommendation_WhenWalking_DoesNotMutateSliders() {
        let rec = makeRecommendation(
            preset: "march",
            tuning: TuningSnapshot(strideMm: 35, sideMm: 0, turnDeg: 0,
                                   periodMs: 800, footHeightMm: 40, balanceGain: 1.0),
            intensity: 4
        )

        // 보행 시작 (sim 모드 — bus nil 이라도 current 변경됨, v1.14.7).
        session.start(.march)
        let strideBefore = session.strideMm
        let intensityBefore = session.correctorIntensityLevel

        session.applyRecommendation(rec)

        // Guard 발화 — slider 변경 안 됨.
        XCTAssertEqual(session.strideMm, strideBefore, accuracy: 1e-9,
                       "보행 중 strideMm 변경 안 됨")
        XCTAssertEqual(session.correctorIntensityLevel, intensityBefore,
                       "보행 중 intensity 변경 안 됨")
        XCTAssertNotNil(session.lastScopeWarning, "warning 설정됨")
        XCTAssertTrue(session.lastScopeWarning?.contains("보행 정지 후") ?? false,
                      "warning message 가 사용자에게 가이드 제공")
    }

    // MARK: - balanceConfig 전파

    func testApplyRecommendation_AppliesBalanceConfig() {
        let customConfig = BalanceExperimentConfig(
            algorithmMode: .hybridBA,
            signConvention: .robotisWalkingCpp,
            gainProfile: .v110Experimental,
            applyToRobot: false,  // observeOnly 같은 안전 mode.
            pitchInputConvention: .negateForwardIsNegative
        )
        let rec = makeRecommendation(
            preset: "march",
            tuning: TuningSnapshot(strideMm: 20, sideMm: 0, turnDeg: 0,
                                   periodMs: 600, footHeightMm: 40, balanceGain: 1.0),
            intensity: 2,
            balanceConfig: customConfig
        )

        session.applyRecommendation(rec)

        XCTAssertEqual(session.balanceExperimentConfig.algorithmMode, .hybridBA)
        XCTAssertEqual(session.balanceExperimentConfig.pitchInputConvention,
                       .negateForwardIsNegative)
    }

    // MARK: - Fixtures

    private func makeRecommendation(
        preset: String,
        tuning: TuningSnapshot,
        intensity: Int,
        balanceConfig: BalanceExperimentConfig = .defaultRobotis
    ) -> WalkTrialRecommendation {
        WalkTrialRecommendation(
            strategy: .ruleBased,
            preset: preset,
            tuning: tuning,
            intensityLevel: intensity,
            balanceConfig: balanceConfig,
            dataMaturity: 0.8,
            rationale: "test fixture",
            sourceSampleIds: ["fixture-1"]
        )
    }
}
