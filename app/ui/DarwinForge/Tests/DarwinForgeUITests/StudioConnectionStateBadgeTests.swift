import XCTest
@testable import DarwinForgeUI

/// 사이클 179 (P0 #3.1 fix, cycle 177 audit): StudioConnectionStateBadge resolver
/// 검증. (bus × liveApply) 4 케이스 의 행렬 분류.
///
/// # 비유
///
/// 사용자가 "현재 슬라이더가 로봇에 즉시 영향 주는가?" 를 한 번에 식별할 수 있어야 함.
/// 신호등 — 빨강 (실시간 적용) / 초록 (시뮬레이션) / 표시없음 (수동 보내기 필요).
final class StudioConnectionStateBadgeTests: XCTestCase {

    /// **분류 검증 #1**: bus 미연결 → liveApply 무관 `.simulationOnly`.
    /// 슬라이더 움직임이 화면 only — 사용자가 sim 인지 명시 인식.
    func testNoBusAlwaysSimulationOnly() {
        XCTAssertEqual(
            StudioConnectionStateBadge.resolve(hasBus: false, liveApply: false),
            .simulationOnly,
            "bus nil + liveApply OFF → 시뮬 (button disabled, 슬라이더만 동작)"
        )
        XCTAssertEqual(
            StudioConnectionStateBadge.resolve(hasBus: false, liveApply: true),
            .simulationOnly,
            "bus nil 시 liveApply 가 true 라도 송출 없음 (button 도 disabled 되지만 가드)"
        )
    }

    /// **분류 검증 #2**: bus 연결 + liveApply ON → `.appliedToRobot`.
    /// 슬라이더 → applyToHardware → motor 즉시 송출. 빨간/주황 강조 필요.
    func testBusWithLiveApplyAppliedToRobot() {
        XCTAssertEqual(
            StudioConnectionStateBadge.resolve(hasBus: true, liveApply: true),
            .appliedToRobot,
            "bus + liveApply ON → 즉시 송출"
        )
    }

    /// **분류 검증 #3**: bus 연결 + liveApply OFF → badge 없음 (nil).
    /// "보내기" button 만 수동 사용 — 명시 action 이라 추가 badge 불필요.
    func testBusWithoutLiveApplyNoBadge() {
        XCTAssertNil(
            StudioConnectionStateBadge.resolve(hasBus: true, liveApply: false),
            "bus 연결됐지만 liveApply OFF — 보내기 button 만 사용. 추가 badge 노이즈 차단."
        )
    }

    /// **유기 검증 #4**: 4 조합 의 행렬 enumeration — 모든 조합 정확.
    func testAllFourCombinationsMatrix() {
        let cases: [(hasBus: Bool, liveApply: Bool, expected: DFStatusBadge?)] = [
            (false, false, .simulationOnly),
            (false, true, .simulationOnly),
            (true, false, nil),
            (true, true, .appliedToRobot)
        ]
        for c in cases {
            XCTAssertEqual(
                StudioConnectionStateBadge.resolve(hasBus: c.hasBus, liveApply: c.liveApply),
                c.expected,
                "hasBus=\(c.hasBus) liveApply=\(c.liveApply) → \(String(describing: c.expected))"
            )
        }
    }

    /// **유기 검증 #5**: 분류 결과 가 사용자 안전성 의 의미 반영.
    /// `.simulationOnly` 와 `.appliedToRobot` 의 `safeForRealRobot` 차이 — 사용자가 다른 결정
    /// (예: trial 적용 confirmation 으로 cycle 153 처럼) 분기 가능.
    func testResolvedBadgeSafetySemantics() {
        let simBadge = StudioConnectionStateBadge.resolve(hasBus: false, liveApply: false)!
        XCTAssertFalse(simBadge.safeForRealRobot,
                       "sim 은 실 로봇 적용 안전성 false (당연)")

        let realBadge = StudioConnectionStateBadge.resolve(hasBus: true, liveApply: true)!
        XCTAssertTrue(realBadge.safeForRealRobot,
                      "applied 는 실 로봇 신뢰 가능 true")
    }

    /// **유기 검증 #6**: 한국어 라벨 명료성 — VoiceOver / 시각 라벨 모두 사용자 의도 전달.
    func testKoreanLabelsConvey() {
        let sim = StudioConnectionStateBadge.resolve(hasBus: false, liveApply: false)!
        XCTAssertEqual(sim.koreanLabel, "시뮬레이션")
        XCTAssertTrue(sim.accessibilityLabel.contains("시뮬레이션"))

        let real = StudioConnectionStateBadge.resolve(hasBus: true, liveApply: true)!
        XCTAssertEqual(real.koreanLabel, "실 로봇 적용됨")
        XCTAssertTrue(real.accessibilityLabel.contains("적용됨"))
    }
}
