import XCTest
@testable import ForgeCore

/// WalkStabilityPredictor 의 휴리스틱 출력 회귀.
/// 점수 구간 + 메시지 트리거 + recommendedCaps coupling 검증.
final class WalkStabilityPredictorTests: XCTestCase {

    // MARK: - 0 / safe / critical 영역 회귀

    func testIdleIsZero() {
        let r = WalkStabilityPredictor.evaluate(WalkStabilityInput())
        XCTAssertEqual(r.score, 0, "기본값 (stride=0, period=600) 은 점수 0 이어야 함")
        XCTAssertEqual(r.category, .safe)
        XCTAssertTrue(r.messages.isEmpty)
    }

    func testSlowWalkIsSafe() {
        let r = WalkStabilityPredictor.evaluate(WalkStabilityInput(
            strideMm: 15, periodMs: 700, footHeightMm: 40, balanceGain: 1.0
        ))
        XCTAssertLessThan(r.score, 30, "보폭 15 mm + 주기 700 ms 은 safe")
        XCTAssertEqual(r.category, .safe)
    }

    func testFastWalkIsCaution() {
        let r = WalkStabilityPredictor.evaluate(WalkStabilityInput(
            strideMm: 25, periodMs: 550, footHeightMm: 40, balanceGain: 1.0
        ))
        XCTAssertGreaterThanOrEqual(r.score, 30, "보폭 25 + 주기 550 은 최소 caution")
        XCTAssertLessThan(r.score, 80)
        XCTAssertTrue([.caution, .highRisk].contains(r.category))
    }

    func testJogIsHighRisk() {
        let r = WalkStabilityPredictor.evaluate(WalkStabilityInput(
            strideMm: 38, periodMs: 450, footHeightMm: 40, balanceGain: 1.0
        ))
        XCTAssertGreaterThanOrEqual(r.score, 60, "보폭 38 + 주기 450 = jog 영역 — 최소 highRisk")
    }

    func testCriticalBlocksStart() {
        let r = WalkStabilityPredictor.evaluate(WalkStabilityInput(
            strideMm: 45, periodMs: 400, footHeightMm: 20, balanceGain: 0.0
        ))
        XCTAssertGreaterThanOrEqual(r.score, 80)
        XCTAssertEqual(r.category, .critical)
        XCTAssertFalse(r.messages.isEmpty, "critical 조합은 사용자 메시지가 있어야 함")
    }

    // MARK: - 카테고리 메시지 트리거

    func testLowFootHeightWarning() {
        let r = WalkStabilityPredictor.evaluate(WalkStabilityInput(
            strideMm: 15, periodMs: 700, footHeightMm: 20, balanceGain: 1.0
        ))
        XCTAssertTrue(r.messages.contains(where: { $0.contains("끌림") }),
                      "발 높이 < 25 mm 는 끌림 메시지 발화")
    }

    func testNoBalanceCompensationWarning() {
        let r = WalkStabilityPredictor.evaluate(WalkStabilityInput(
            strideMm: 30, periodMs: 600, footHeightMm: 40, balanceGain: 0.1
        ))
        XCTAssertTrue(r.messages.contains(where: { $0.contains("균형 게인") }),
                      "보폭 큰데 balanceGain < 0.3 은 메시지 발화")
    }

    func testDiagonalComboWarning() {
        let r = WalkStabilityPredictor.evaluate(WalkStabilityInput(
            strideMm: 30, sideMm: 15, periodMs: 600, footHeightMm: 40, balanceGain: 1.0
        ))
        XCTAssertTrue(r.messages.contains(where: { $0.contains("회전 모멘트") || $0.contains("측면") }),
                      "전후+측면 큰 보폭 조합 메시지")
    }

    // MARK: - effective speed 계산

    func testEffectiveSpeedCalc() {
        let r = WalkStabilityPredictor.evaluate(WalkStabilityInput(
            strideMm: 30, periodMs: 600
        ))
        // 30 mm × (1000/600) ≈ 50 mm/s
        XCTAssertEqual(r.effectiveSpeedMmPerSec, 50.0, accuracy: 0.01)
    }

    func testEffectiveSpeedTriggersWarningAt50() {
        let r = WalkStabilityPredictor.evaluate(WalkStabilityInput(
            strideMm: 35, periodMs: 500
        ))
        // 35 × 2.0 = 70 → 메시지 발화
        XCTAssertGreaterThan(r.effectiveSpeedMmPerSec, 50)
        XCTAssertTrue(r.messages.contains(where: { $0.contains("유효 속도") }))
    }

    // MARK: - recommendedCaps coupling

    func testCapShrinksWhenPeriodShort() {
        let inp = WalkStabilityInput(strideMm: 30, periodMs: 450)
        let caps = WalkStabilityPredictor.recommendedCaps(inp)
        XCTAssertLessThanOrEqual(caps.maxStrideMm, 25,
            "주기 < 500 ms 면 stride cap 이 25 mm 이하로 줄어야 함")
    }

    func testCapShrinksWhenBalanceLow() {
        let inp = WalkStabilityInput(strideMm: 30, balanceGain: 0.2)
        let caps = WalkStabilityPredictor.recommendedCaps(inp)
        XCTAssertLessThanOrEqual(caps.maxStrideMm, 22,
            "balanceGain < 0.3 면 stride cap 이 22 이하로 줄어야 함")
    }

    func testCapShrinksWhenFootHeightExtreme() {
        let low = WalkStabilityPredictor.recommendedCaps(WalkStabilityInput(footHeightMm: 25))
        let high = WalkStabilityPredictor.recommendedCaps(WalkStabilityInput(footHeightMm: 65))
        XCTAssertLessThanOrEqual(low.maxStrideMm, 25, "발 높이 < 30 → stride cap ≤ 25")
        XCTAssertLessThanOrEqual(high.maxStrideMm, 25, "발 높이 > 60 → stride cap ≤ 25")
    }

    func testSideAndTurnCapsCoupleWithStride() {
        let inp = WalkStabilityInput(strideMm: 30)
        let caps = WalkStabilityPredictor.recommendedCaps(inp)
        XCTAssertLessThanOrEqual(caps.maxSideMm, 12, "큰 보폭 → 측면 cap 축소")
        XCTAssertLessThanOrEqual(caps.maxTurnDeg, 8, "큰 보폭 → 회전 cap 축소")
    }

    // MARK: - 단조성

    func testScoreMonotonicWithStride() {
        let s1 = WalkStabilityPredictor.evaluate(WalkStabilityInput(strideMm: 10, periodMs: 600)).score
        let s2 = WalkStabilityPredictor.evaluate(WalkStabilityInput(strideMm: 20, periodMs: 600)).score
        let s3 = WalkStabilityPredictor.evaluate(WalkStabilityInput(strideMm: 30, periodMs: 600)).score
        let s4 = WalkStabilityPredictor.evaluate(WalkStabilityInput(strideMm: 40, periodMs: 600)).score
        XCTAssertLessThanOrEqual(s1, s2)
        XCTAssertLessThanOrEqual(s2, s3)
        XCTAssertLessThanOrEqual(s3, s4)
    }

    func testScoreMonotonicWithSpeedup() {
        // 같은 보폭에서 주기가 짧아질수록 (속도 ↑) 점수 증가
        let slow   = WalkStabilityPredictor.evaluate(WalkStabilityInput(strideMm: 25, periodMs: 800)).score
        let normal = WalkStabilityPredictor.evaluate(WalkStabilityInput(strideMm: 25, periodMs: 600)).score
        let fast   = WalkStabilityPredictor.evaluate(WalkStabilityInput(strideMm: 25, periodMs: 450)).score
        XCTAssertLessThanOrEqual(slow, normal)
        XCTAssertLessThanOrEqual(normal, fast)
    }
}
