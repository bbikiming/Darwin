import XCTest
@testable import ForgeCore

/// **사이클 P0 (2026-05-23)** — `WalkStabilityPredictor` 의 magic number 를
/// `StabilityThresholds` / `CapsThresholds` 명명 상수로 분리한 회귀 가드.
///
/// 검증 목표:
///   1. 각 knot 배열이 monotonic (낮은 입력 → 낮은 가중치) — piecewise 보간의 수학적
///      불변 조건. 깨지면 점수 산출이 비단조가 되어 슬라이더 조작 시 직관과 어긋난다.
///   2. region 경계가 일관 (예: `footHeightDragRegionMm` < `footHeightWobbleRegionMm`).
///   3. `CapsThresholds` 의 tier 임계가 단조 (tier1 > tier2 → 더 엄격한 제한).
///   4. 카테고리 경계가 단조 (safe < caution < highRisk < 100).
///   5. piecewise 보간 자체가 monotonic knot 에서 monotonic 출력을 내는지.
///
/// **변경 시 영향**: 한 임계값을 잘못 수정하면 낙상 보호가 silently 깨진다.
/// 이 회귀 가드를 통과한 뒤에야 `WalkStabilityPredictorTests` 점수 회귀를 신뢰할 수 있다.
final class WalkStabilityPredictorThresholdsTests: XCTestCase {

    // MARK: - knot 배열의 단조성 (monotonic non-decreasing on weight)

    /// 단조 non-decreasing 헬퍼 — knot[i+1].weight >= knot[i].weight.
    private func assertWeightMonotonicNonDecreasing(
        _ knots: [(Double, Double)],
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for i in 0..<(knots.count - 1) {
            XCTAssertLessThanOrEqual(
                knots[i].1, knots[i + 1].1,
                "\(label): knot[\(i)].weight (\(knots[i].1)) > knot[\(i+1)].weight (\(knots[i+1].1)) — 단조 깨짐",
                file: file, line: line
            )
        }
    }

    /// 단조 non-increasing on weight (x 가 증가하면 weight 가 감소).
    private func assertWeightMonotonicNonIncreasing(
        _ knots: [(Double, Double)],
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for i in 0..<(knots.count - 1) {
            XCTAssertGreaterThanOrEqual(
                knots[i].1, knots[i + 1].1,
                "\(label): knot[\(i)].weight (\(knots[i].1)) < knot[\(i+1)].weight (\(knots[i+1].1)) — 단조 깨짐",
                file: file, line: line
            )
        }
    }

    /// x 좌표가 strictly increasing 인지 — piecewise 보간이 항상 유일한 구간을 찾도록 보장.
    private func assertXStrictlyIncreasing(
        _ knots: [(Double, Double)],
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for i in 0..<(knots.count - 1) {
            XCTAssertLessThan(
                knots[i].0, knots[i + 1].0,
                "\(label): knot x 좌표가 단조 증가하지 않음 (\(knots[i].0) >= \(knots[i+1].0))",
                file: file, line: line
            )
        }
    }

    func testStrideKnotsAreMonotonic() {
        let knots = StabilityThresholds.strideKnots
        assertXStrictlyIncreasing(knots, label: "strideKnots")
        assertWeightMonotonicNonDecreasing(knots, label: "strideKnots")
        // 사후 조건: 0 mm 에서 0 weight (안전), 50 mm 에서 매우 높은 weight.
        XCTAssertEqual(knots.first?.1, 0, "strideKnots: 0 mm 에서 위험 0 이어야 함")
        XCTAssertGreaterThanOrEqual(knots.last?.1 ?? 0, 80, "strideKnots: 최대 stride 에서 critical 영역")
    }

    /// x 좌표가 strictly decreasing 인지 — periodKnots 처럼 첫 knot 이 안전 구간 (큰 x),
    /// 마지막 knot 이 위험 구간 (작은 x) 인 패턴 검증.
    private func assertXStrictlyDecreasing(
        _ knots: [(Double, Double)],
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for i in 0..<(knots.count - 1) {
            XCTAssertGreaterThan(
                knots[i].0, knots[i + 1].0,
                "\(label): knot x 좌표가 단조 감소하지 않음 (\(knots[i].0) <= \(knots[i+1].0))",
                file: file, line: line
            )
        }
    }

    func testPeriodKnotsAreMonotonic() {
        // periodKnots 의 실제 구조:
        //   x (period ms): 900 -> 350 (decreasing) — first.x 가 안전, last.x 가 위험.
        //   weight: 0 -> 90 (increasing) — 짧은 주기일수록 위험 ↑.
        // 의미적으로 단조 — period 가 감소함에 따라 weight 가 증가.
        let knots = StabilityThresholds.periodKnots
        assertXStrictlyDecreasing(knots, label: "periodKnots")
        assertWeightMonotonicNonDecreasing(knots, label: "periodKnots")
        // 사후 조건: 첫 knot (900 ms) 안전, 마지막 knot (350 ms) critical.
        XCTAssertEqual(knots.first?.1, 0, "periodKnots: 가장 긴 주기 (900 ms) 에서 위험 0")
        XCTAssertGreaterThanOrEqual(knots.last?.1 ?? 0, 80, "periodKnots: 가장 짧은 주기에서 critical")
    }

    func testEffSpeedKnotsAreMonotonic() {
        let knots = StabilityThresholds.effSpeedKnots
        assertXStrictlyIncreasing(knots, label: "effSpeedKnots")
        assertWeightMonotonicNonDecreasing(knots, label: "effSpeedKnots")
        XCTAssertEqual(knots.first?.1, 0, "effSpeedKnots: 0 mm/s 위험 0")
        XCTAssertEqual(knots.last?.1, 100, "effSpeedKnots: 최대 속도에서 100 (포화)")
    }

    func testSideKnotsAreMonotonic() {
        let knots = StabilityThresholds.sideKnots
        assertXStrictlyIncreasing(knots, label: "sideKnots")
        assertWeightMonotonicNonDecreasing(knots, label: "sideKnots")
        XCTAssertEqual(knots.first?.1, 0, "sideKnots: 0 mm 위험 0")
    }

    func testTurnKnotsAreMonotonic() {
        let knots = StabilityThresholds.turnKnots
        assertXStrictlyIncreasing(knots, label: "turnKnots")
        assertWeightMonotonicNonDecreasing(knots, label: "turnKnots")
        XCTAssertEqual(knots.first?.1, 0, "turnKnots: 0° 위험 0")
    }

    func testFootHeightLowKnotsAreMonotonic() {
        // 발 높이 낮은 영역: x 증가 → weight 감소 (높을수록 안전).
        let knots = StabilityThresholds.footHeightLowKnots
        assertXStrictlyIncreasing(knots, label: "footHeightLowKnots")
        assertWeightMonotonicNonIncreasing(knots, label: "footHeightLowKnots")
        XCTAssertEqual(knots.last?.1, 0, "footHeightLowKnots: 30 mm 에서 위험 0 (안전 영역 시작)")
    }

    func testFootHeightHighKnotsAreMonotonic() {
        // 발 높이 높은 영역: x 증가 → weight 증가 (너무 높으면 CoM 흔들림).
        let knots = StabilityThresholds.footHeightHighKnots
        assertXStrictlyIncreasing(knots, label: "footHeightHighKnots")
        assertWeightMonotonicNonDecreasing(knots, label: "footHeightHighKnots")
        XCTAssertEqual(knots.first?.1, 0, "footHeightHighKnots: 50 mm 에서 위험 0 (안전 영역 끝)")
    }

    func testBalanceGainLowKnotsAreMonotonic() {
        // 균형 게인 낮은 영역: x 증가 → weight 감소 (게인 ↑ = 보상 강함).
        let knots = StabilityThresholds.balanceGainLowKnots
        assertXStrictlyIncreasing(knots, label: "balanceGainLowKnots")
        assertWeightMonotonicNonIncreasing(knots, label: "balanceGainLowKnots")
        XCTAssertEqual(knots.last?.1, 0, "balanceGainLowKnots: 0.5 게인에서 위험 0 (안전 영역 시작)")
    }

    func testBalanceGainHighKnotsAreMonotonic() {
        // 균형 게인 높은 영역: x 증가 → weight 증가 (너무 강하면 진동).
        let knots = StabilityThresholds.balanceGainHighKnots
        assertXStrictlyIncreasing(knots, label: "balanceGainHighKnots")
        assertWeightMonotonicNonDecreasing(knots, label: "balanceGainHighKnots")
        XCTAssertEqual(knots.first?.1, 0, "balanceGainHighKnots: 2.0 게인에서 위험 0 (안전 영역 끝)")
    }

    // MARK: - region 경계의 일관성

    func testFootHeightRegionsAreOrdered() {
        XCTAssertLessThan(
            StabilityThresholds.footHeightDragRegionMm,
            StabilityThresholds.footHeightWobbleRegionMm,
            "끌림 영역 상한이 흔들림 영역 하한보다 작아야 함 (가운데에 안전 영역)"
        )
        // 끌림 메시지 임계 < 끌림 region 상한 — 메시지가 region 안에서만 발화.
        XCTAssertLessThanOrEqual(
            StabilityThresholds.footHeightDragMessageMm,
            StabilityThresholds.footHeightDragRegionMm,
            "끌림 메시지 임계는 끌림 region 안에 있어야 함"
        )
        // 흔들림 메시지 임계 > 흔들림 region 하한.
        XCTAssertGreaterThanOrEqual(
            StabilityThresholds.footHeightWobbleMessageMm,
            StabilityThresholds.footHeightWobbleRegionMm,
            "흔들림 메시지 임계는 흔들림 region 안에 있어야 함"
        )
    }

    func testBalanceGainRegionsAreOrdered() {
        XCTAssertLessThan(
            StabilityThresholds.balanceGainLowRegion,
            StabilityThresholds.balanceGainHighRegion,
            "낮은 게인 영역 상한이 높은 게인 영역 하한보다 작아야 함"
        )
        XCTAssertLessThanOrEqual(
            StabilityThresholds.balanceGainNoCompensationThreshold,
            StabilityThresholds.balanceGainLowRegion,
            "보상 없음 메시지 임계는 낮은 게인 region 안에 있어야 함"
        )
        XCTAssertGreaterThanOrEqual(
            StabilityThresholds.balanceGainOvercompensationMessage,
            StabilityThresholds.balanceGainHighRegion,
            "과도 보상 메시지 임계는 높은 게인 region 안에 있어야 함"
        )
    }

    // MARK: - 카테고리 경계 단조성

    func testCategoryBoundariesAreOrdered() {
        XCTAssertLessThan(StabilityThresholds.safeMaxScore, StabilityThresholds.cautionMaxScore,
                          "safe 경계 < caution 경계")
        XCTAssertLessThan(StabilityThresholds.cautionMaxScore, StabilityThresholds.highRiskMaxScore,
                          "caution 경계 < highRisk 경계")
        XCTAssertLessThan(StabilityThresholds.highRiskMaxScore, 100,
                          "highRisk 경계 < 100 (critical 까지 여유)")
        XCTAssertGreaterThan(StabilityThresholds.safeMaxScore, 0,
                             "safe 경계 > 0")
    }

    // MARK: - CapsThresholds tier 단조성

    func testCapsTierThresholdsAreOrdered() {
        // periodTier1 (덜 엄격) > periodTier2 (더 엄격) — 짧은 주기일수록 더 작은 cap.
        XCTAssertGreaterThan(
            CapsThresholds.periodTier1Ms, CapsThresholds.periodTier2Ms,
            "periodTier1Ms (\(CapsThresholds.periodTier1Ms)) 는 periodTier2Ms (\(CapsThresholds.periodTier2Ms)) 보다 커야 함"
        )
        // tier1 의 maxStride > tier2 의 maxStride — 더 엄격한 tier 는 더 작은 cap.
        XCTAssertGreaterThanOrEqual(
            CapsThresholds.periodTier1MaxStride, CapsThresholds.periodTier2MaxStride,
            "periodTier1MaxStride 는 periodTier2MaxStride 이상이어야 함 (엄격할수록 cap 축소)"
        )
    }

    func testCapsFootHeightThresholdsAreOrdered() {
        XCTAssertLessThan(
            CapsThresholds.footHeightLowMm, CapsThresholds.footHeightHighMm,
            "footHeightLowMm 는 footHeightHighMm 보다 작아야 함 (가운데에 안전 영역)"
        )
    }

    func testCapsDefaultsExceedAllTierCaps() {
        // 기본 cap 은 모든 tier 의 결과보다 같거나 커야 함 — 트리거되지 않은 슬라이더가
        // 트리거된 슬라이더보다 작은 cap 을 갖는 것은 부자연스러움.
        XCTAssertGreaterThanOrEqual(
            CapsThresholds.defaultMaxStrideMm, CapsThresholds.periodTier1MaxStride
        )
        XCTAssertGreaterThanOrEqual(
            CapsThresholds.defaultMaxStrideMm, CapsThresholds.periodTier2MaxStride
        )
        XCTAssertGreaterThanOrEqual(
            CapsThresholds.defaultMaxStrideMm, CapsThresholds.footHeightLowMaxStride
        )
        XCTAssertGreaterThanOrEqual(
            CapsThresholds.defaultMaxStrideMm, CapsThresholds.footHeightHighMaxStride
        )
        XCTAssertGreaterThanOrEqual(
            CapsThresholds.defaultMaxStrideMm, CapsThresholds.balanceGainLowMaxStride
        )
        XCTAssertGreaterThanOrEqual(
            CapsThresholds.defaultMaxSideMm, CapsThresholds.sideStrideCouplingMaxSide
        )
        XCTAssertGreaterThanOrEqual(
            CapsThresholds.defaultMaxSideMm, CapsThresholds.sidePeriodMaxSide
        )
        XCTAssertGreaterThanOrEqual(
            CapsThresholds.defaultMaxTurnDeg, CapsThresholds.turnStrideCouplingMaxTurn
        )
    }

    // MARK: - 회귀 가드 (값 변경 감지)
    //
    // 이 테스트는 의도적으로 정확한 값을 검증한다. 임계값을 바꿔야 한다면 이 테스트도
    // 함께 갱신해야 한다 — refactor 가 silently 값을 바꾸는 사고를 막는 트립와이어.

    func testStrideKnotsExactValuesAreUnchanged() {
        let knots = StabilityThresholds.strideKnots
        XCTAssertEqual(knots.count, 5)
        XCTAssertEqual(knots[0].0, 0);  XCTAssertEqual(knots[0].1, 0)
        XCTAssertEqual(knots[1].0, 20); XCTAssertEqual(knots[1].1, 5)
        XCTAssertEqual(knots[2].0, 30); XCTAssertEqual(knots[2].1, 25)
        XCTAssertEqual(knots[3].0, 40); XCTAssertEqual(knots[3].1, 55)
        XCTAssertEqual(knots[4].0, 50); XCTAssertEqual(knots[4].1, 85)
    }

    func testPeriodKnotsExactValuesAreUnchanged() {
        let knots = StabilityThresholds.periodKnots
        XCTAssertEqual(knots.count, 7)
        XCTAssertEqual(knots[0].0, 900); XCTAssertEqual(knots[0].1, 0)
        XCTAssertEqual(knots[1].0, 700); XCTAssertEqual(knots[1].1, 0)
        XCTAssertEqual(knots[2].0, 600); XCTAssertEqual(knots[2].1, 5)
        XCTAssertEqual(knots[3].0, 500); XCTAssertEqual(knots[3].1, 20)
        XCTAssertEqual(knots[4].0, 450); XCTAssertEqual(knots[4].1, 45)
        XCTAssertEqual(knots[5].0, 400); XCTAssertEqual(knots[5].1, 70)
        XCTAssertEqual(knots[6].0, 350); XCTAssertEqual(knots[6].1, 90)
    }

    func testCapThresholdsExactValuesAreUnchanged() {
        XCTAssertEqual(CapsThresholds.defaultMaxStrideMm, 40)
        XCTAssertEqual(CapsThresholds.periodTier1Ms, 500)
        XCTAssertEqual(CapsThresholds.periodTier1MaxStride, 25)
        XCTAssertEqual(CapsThresholds.periodTier2Ms, 450)
        XCTAssertEqual(CapsThresholds.periodTier2MaxStride, 20)
        XCTAssertEqual(CapsThresholds.footHeightLowMm, 30)
        XCTAssertEqual(CapsThresholds.footHeightHighMm, 60)
        XCTAssertEqual(CapsThresholds.balanceGainLow, 0.3)
        XCTAssertEqual(CapsThresholds.balanceGainLowMaxStride, 22)
    }

    // MARK: - piecewise 보간 자체의 monotonic 보장

    func testPiecewiseInterpolationIsMonotonicOnStrideKnots() {
        // 0 mm 부터 50 mm 까지 1 mm 간격으로 piecewise 가 단조인지 검증.
        let knots = StabilityThresholds.strideKnots
        var prev = WalkStabilityPredictor.piecewise(0, knots: knots)
        for x in stride(from: 1.0, through: 60.0, by: 1.0) {
            let w = WalkStabilityPredictor.piecewise(x, knots: knots)
            XCTAssertGreaterThanOrEqual(
                w, prev,
                "piecewise(\(x)) = \(w) < piecewise(이전) = \(prev) — strideKnots 단조 깨짐"
            )
            prev = w
        }
    }

    func testPiecewiseClampingBelowFirstKnot() {
        let knots = StabilityThresholds.strideKnots
        XCTAssertEqual(WalkStabilityPredictor.piecewise(-100, knots: knots), knots.first?.1,
                       "first knot 이하 입력은 first.weight 클램프")
    }

    func testPiecewiseClampingAboveLastKnot() {
        let knots = StabilityThresholds.strideKnots
        XCTAssertEqual(WalkStabilityPredictor.piecewise(9999, knots: knots), knots.last?.1,
                       "last knot 이상 입력은 last.weight 클램프")
    }

    // MARK: - 메시지 트리거 임계의 sanity

    func testMessageThresholdsAreWithinSliderRanges() {
        // 모든 메시지 임계는 사용자가 도달 가능한 슬라이더 범위 안에 있어야 함.
        XCTAssertGreaterThan(StabilityThresholds.strideMessageMm, 0)
        XCTAssertLessThanOrEqual(StabilityThresholds.strideMessageMm, 50)
        XCTAssertGreaterThan(StabilityThresholds.periodMessageMs, 200)
        XCTAssertLessThanOrEqual(StabilityThresholds.periodMessageMs, 1000)
        XCTAssertGreaterThan(StabilityThresholds.effSpeedMessageMmPerSec, 0)
        XCTAssertGreaterThan(StabilityThresholds.footHeightDragMessageMm, 0)
        XCTAssertLessThan(
            StabilityThresholds.footHeightDragMessageMm,
            StabilityThresholds.footHeightWobbleMessageMm,
            "끌림 메시지 임계 < 흔들림 메시지 임계"
        )
    }

    // MARK: - 행위 보존 (refactor 가 evaluate 결과를 바꾸지 않는지)

    func testEvaluateBehaviorIsUnchangedAfterRefactor() {
        // 여러 대표 시나리오에서 점수가 동일하게 산출되는지 확인.
        // 값이 깨지면 refactor 가 silently 동작을 바꾼 것.
        let cases: [(WalkStabilityInput, ClosedRange<Double>, WalkStabilityResult.Category)] = [
            // (입력, 기대 점수 범위, 기대 카테고리)
            (WalkStabilityInput(), 0...0, .safe),
            (WalkStabilityInput(strideMm: 15, periodMs: 700), 0...30, .safe),
            (WalkStabilityInput(strideMm: 45, periodMs: 400, footHeightMm: 20, balanceGain: 0),
                80...100, .critical),
        ]
        for (inp, expectedRange, expectedCat) in cases {
            let r = WalkStabilityPredictor.evaluate(inp)
            XCTAssertTrue(
                expectedRange.contains(r.score),
                "evaluate(\(inp)) = \(r.score), 기대 범위 \(expectedRange) 벗어남"
            )
            XCTAssertEqual(r.category, expectedCat, "카테고리 회귀: \(inp)")
        }
    }
}
