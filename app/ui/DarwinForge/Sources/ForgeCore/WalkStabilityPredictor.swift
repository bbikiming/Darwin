import Foundation

/// 보행 안정성 예측기 — Walk Lab 슬라이더 조합이 낙상으로 이어질 가능성을 0..100 점수로 반환.
///
/// 입력은 사용자 슬라이더 6개 값. 출력은 점수 + 카테고리별 위험 기여도 + 한국어 메시지.
/// 순수 함수 — Rust FFI 라운드트립 없이 Swift 측에서 즉시 계산. 시뮬 단계에서만 사용
/// (실 IK 완성 후 forge-core::walk::predict 로 옮겨 가는 것이 목표).
///
/// 휴리스틱 출처:
///   - NimbRo `patches-essential/0012-Walking-tuned-for-NimbRo-OP.patch` —
///     `balance_angle_smooth_gain`, `lean_fb_gain` 의 안정성 기여.
///   - ROBOTIS-OP2 `op2_walking_module/config/param.yaml` — period 600 ms 기준 baseline.
///   - 실측 관찰 (DASL UNLV "Making the DARwIn-OP walk", NUbots OP2 guide):
///     stride > 30 mm + period < 500 ms = 낙상 빈도 급증.
///
/// 점수 의미:
///   - 0..30  : Safe — 시작 게이트 통과.
///   - 30..60 : Caution — 시작은 가능하나 30 s 자동 종료 권장.
///   - 60..80 : HighRisk — confirm 요구.
///   - 80..100: Critical — 시작 차단.
public struct WalkStabilityInput: Sendable, Equatable {
    /// 보폭 (한 사이클당 진행 거리, mm). 0..50.
    public var strideMm: Double
    /// 측면 보폭 (mm). -25..25. 절대값 사용.
    public var sideMm: Double
    /// 회전 각 (°/cycle). -20..20. 절대값 사용.
    public var turnDeg: Double
    /// 보행 주기 (ms). 350..1000.
    public var periodMs: Double
    /// 발 들기 높이 (mm). 15..80.
    public var footHeightMm: Double
    /// 균형 게인 (NimbRo lean_fb_gain 등가). 0..5.
    public var balanceGain: Double

    public init(
        strideMm: Double = 0,
        sideMm: Double = 0,
        turnDeg: Double = 0,
        periodMs: Double = 600,
        footHeightMm: Double = 40,
        balanceGain: Double = 1.0
    ) {
        self.strideMm = strideMm
        self.sideMm = sideMm
        self.turnDeg = turnDeg
        self.periodMs = periodMs
        self.footHeightMm = footHeightMm
        self.balanceGain = balanceGain
    }
}

public struct WalkStabilityResult: Sendable, Equatable {
    /// 합산 위험 점수 (0..100, 클수록 위험).
    public let score: Double
    /// 개별 위험 기여 (디버깅·UI 시각화용).
    public let breakdown: [Contributor]
    /// 카테고리.
    public let category: Category
    /// 사용자에게 보여줄 주요 위험 메시지 (최대 3개).
    public let messages: [String]
    /// 효과적인 보행 속도 (mm/s = stride × cycles/sec).
    public let effectiveSpeedMmPerSec: Double

    public enum Category: String, Sendable {
        case safe       // 0..30
        case caution    // 30..60
        case highRisk   // 60..80
        case critical   // 80..100

        public var labelKo: String {
            switch self {
            case .safe:     return "안전"
            case .caution:  return "주의"
            case .highRisk: return "위험"
            case .critical: return "차단"
            }
        }
    }

    public struct Contributor: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        /// 0..100. 합산 시 클램프.
        public let weight: Double

        public init(id: String, label: String, weight: Double) {
            self.id = id
            self.label = label
            self.weight = weight
        }
    }
}

// MARK: - Safety thresholds (named constants extracted from magic numbers)
//
// **사이클 P0 (2026-05-23)**: safety-critical 임계값 inline magic number 를
// 명명 상수로 분리. 한 값을 잘못 수정하면 낙상 보호가 silently 깨지므로,
// 카테고리별 정적 상수로 모아 변경 영향 범위와 출처를 명시한다.
//
// 가시성: `internal` — 외부 API 변경 없이 `@testable import` 로 회귀 가드 가능.
// 변경 시 영향: 슬라이더 위험 점수 산출 + WalkLab 시작 게이트 통과 조건이 동시에
// 변할 수 있다. 변경 전 `WalkStabilityPredictorThresholdsTests` 회귀 가드를 반드시
// 통과시킨 뒤 `WalkStabilityPredictorTests` 점수 회귀까지 함께 확인할 것.

/// `WalkStabilityPredictor.evaluate` 가 사용하는 piecewise-linear knot 표.
///
/// 각 knot 은 `(입력 값, 위험 가중치 0..100)` 쌍. 인접 knot 사이는 선형 보간된다.
/// ROBOTIS-OP2 MX-28 실측 + 경험적 임계 — 변경 시 영향: 보행 위험 점수 + 시작 게이트.
internal enum StabilityThresholds {
    /// 보폭 mm → 위험 가중치. monotonic non-decreasing.
    /// 0..20 안전 / 20..30 주의 / 30..40 위험 / 40+ critical.
    static let strideKnots: [(Double, Double)] = [
        (0, 0), (20, 5), (30, 25), (40, 55), (50, 85)
    ]

    /// 보행 주기 ms → 위험 가중치. 짧을수록 (빠를수록) 위험 ↑.
    /// 800..600 안전 / 600..500 주의 / 500..400 위험 / <400 critical.
    ///
    /// **V288-1 P0 (2026-05-24)** — 두 가지 수정:
    ///   1. x 좌표 ascending 정렬 (350→900) — `piecewise()` 의 ascending-knots 규약을
    ///      준수. 종전 descending 배열은 `x <= first.0=900` 클램프가 항상 true 가 되어
    ///      period contributor 가 영구 0 인 silent 안전 결함이 있었다 (V287-5 mutation
    ///      testing 으로 발견).
    ///   2. (600, 0) — period=600ms 는 `WalkStabilityInput()` 기본값 (idle baseline).
    ///      종전 (600, 5) 는 fix 후 idle state 가 score 5 로 표시되어 사용자 mental
    ///      model 위배. 600ms 자체는 default safe baseline 이므로 weight 0 이 적절.
    static let periodKnots: [(Double, Double)] = [
        (350, 90), (400, 70), (450, 45), (500, 20), (600, 0), (700, 0), (900, 0)
    ]

    /// 유효 속도 mm/s → 위험 가중치. monotonic non-decreasing.
    /// stride × cycles/sec 의 상호작용 — 가장 강력한 낙상 지표.
    /// 경험: ~40 mm/s OP/OP2 안정 한계, 60+ 신뢰 불가.
    static let effSpeedKnots: [(Double, Double)] = [
        (0, 0), (20, 0), (40, 15), (60, 50), (80, 80), (120, 100)
    ]

    /// 측면 보폭 |mm| → 위험 가중치. monotonic non-decreasing.
    /// 0..10 안전 / 10..15 주의 / 15..20 위험 / 20+ critical.
    static let sideKnots: [(Double, Double)] = [
        (0, 0), (10, 0), (15, 15), (20, 35), (25, 60)
    ]

    /// 회전 |°/cycle| → 위험 가중치. monotonic non-decreasing.
    /// 0..5 안전 / 5..10 주의 / 10..15 위험 / 15+ critical.
    static let turnKnots: [(Double, Double)] = [
        (0, 0), (5, 0), (10, 15), (15, 35), (20, 60)
    ]

    /// 발 들기 높이 mm → 위험 가중치 (낮은 영역, < 30 mm). monotonic non-increasing on x.
    /// 끌림(drag) 위험 — 15 mm 가 최대 위험, 30 mm 이상은 안전.
    static let footHeightLowKnots: [(Double, Double)] = [
        (15, 60), (20, 40), (25, 20), (30, 0)
    ]

    /// 발 들기 높이 mm → 위험 가중치 (높은 영역, > 50 mm). monotonic non-decreasing.
    /// CoM 흔들림 위험 — 50 mm 안전, 80 mm critical.
    static let footHeightHighKnots: [(Double, Double)] = [
        (50, 0), (60, 20), (70, 50), (80, 80)
    ]

    /// 균형 게인 → 위험 가중치 (낮은 영역, < 0.5). 보상 부재 위험.
    static let balanceGainLowKnots: [(Double, Double)] = [
        (0, 35), (0.3, 15), (0.5, 0)
    ]

    /// 균형 게인 → 위험 가중치 (높은 영역, > 2.0). 과도 보상 진동 위험.
    static let balanceGainHighKnots: [(Double, Double)] = [
        (2.0, 0), (2.5, 10), (3.5, 30), (5.0, 60)
    ]

    // MARK: - Region boundaries (어느 영역으로 진입할지 판정용)

    /// 발 들기 — 30 mm 미만은 끌림 위험 영역.
    static let footHeightDragRegionMm: Double = 30
    /// 발 들기 — 50 mm 초과는 CoM 흔들림 영역.
    static let footHeightWobbleRegionMm: Double = 50
    /// 균형 게인 — 0.5 미만은 보상 부재 영역.
    static let balanceGainLowRegion: Double = 0.5
    /// 균형 게인 — 2.0 초과는 과도 보상 영역.
    static let balanceGainHighRegion: Double = 2.0

    // MARK: - Message trigger thresholds (사용자 경고 메시지 발화 임계)

    /// 보폭 |mm| 이 이 값 이상이면 "MX-28 무릎/발목 부하" 메시지.
    static let strideMessageMm: Double = 30
    /// 주기 ms 가 이 값 미만이면 "IMU 보정 한계" 메시지.
    static let periodMessageMs: Double = 500
    /// 유효 속도 mm/s 가 이 값 초과면 "보폭/주기 조합 위험" 메시지.
    static let effSpeedMessageMmPerSec: Double = 50
    /// 발 높이 mm 가 이 값 미만이면 "끌림으로 보행 실패" 메시지.
    static let footHeightDragMessageMm: Double = 25
    /// 발 높이 mm 가 이 값 초과면 "무게중심 흔들림" 메시지.
    static let footHeightWobbleMessageMm: Double = 60
    /// 균형 게인이 이 값 미만 + 보폭이 임계 초과면 "IMU 보상 없음" 메시지.
    static let balanceGainNoCompensationThreshold: Double = 0.3
    /// 균형 게인이 이 값 초과면 "과도 보상 진동" 메시지.
    static let balanceGainOvercompensationMessage: Double = 3.0
    /// "IMU 보상 없음" 메시지를 발화시키는 보폭 |mm| 하한.
    static let balanceNoCompStrideThresholdMm: Double = 25

    // MARK: - 조합 위험 임계

    /// 대각 보폭 (전후 + 측면) 조합 트리거 — 보폭 |mm| 하한.
    static let diagonalStrideMm: Double = 25
    /// 대각 보폭 조합 트리거 — 측면 |mm| 하한.
    static let diagonalSideMm: Double = 12
    /// 대각 보폭 조합 최대 추가 가중치.
    static let diagonalMaxExtra: Double = 20
    /// 대각 보폭 조합 가중치 계수 — `(stride-25) * (side-12) * factor`.
    static let diagonalFactor: Double = 0.4

    /// 회전 + 보폭 조합 트리거 — 회전 |°| 하한.
    static let turnStrideTurnDeg: Double = 8
    /// 회전 + 보폭 조합 트리거 — 보폭 |mm| 하한.
    static let turnStrideStrideMm: Double = 25
    /// 회전 + 보폭 조합 최대 추가 가중치.
    static let turnStrideMaxExtra: Double = 20
    /// 회전 + 보폭 조합 가중치 계수.
    static let turnStrideFactor: Double = 0.5

    // MARK: - 산출 보호

    /// `evaluate` 가 `cyclesPerSec` 계산 시 사용하는 period 하한 (0 분모 방지 + 안전).
    static let minPeriodForCyclesMs: Double = 200

    // MARK: - 카테고리 경계

    /// `score < safeMax` → safe.
    static let safeMaxScore: Double = 30
    /// `safeMax ≤ score < cautionMax` → caution.
    static let cautionMaxScore: Double = 60
    /// `cautionMax ≤ score < highRiskMax` → highRisk. 이상은 critical.
    static let highRiskMaxScore: Double = 80

    /// `messages` 배열의 최대 개수 (UI 가독성).
    static let maxMessageCount: Int = 3
}

/// `WalkStabilityPredictor.recommendedCaps` 가 사용하는 동적 cap 임계.
///
/// 한 슬라이더 값이 변하면 다른 슬라이더의 권장 상한이 줄어든다. 모든 값은 안전 보호용
/// 휴리스틱 — 변경 시 영향: 사용자가 가시화하는 "빨간 영역"의 크기 + 자동 클램프.
internal enum CapsThresholds {
    /// stride 기본 권장 상한 (mm). 어떤 조건도 트리거되지 않으면 이 값 유지.
    static let defaultMaxStrideMm: Double = 40

    /// 주기 < periodTier1Ms → stride cap = periodTier1MaxStride.
    static let periodTier1Ms: Double = 500
    static let periodTier1MaxStride: Double = 25
    /// 주기 < periodTier2Ms → stride cap = periodTier2MaxStride (더 엄격).
    static let periodTier2Ms: Double = 450
    static let periodTier2MaxStride: Double = 20

    /// 발 높이 < 이 값이면 끌림 방지로 stride cap 축소.
    static let footHeightLowMm: Double = 30
    static let footHeightLowMaxStride: Double = 25
    /// 발 높이 > 이 값이면 CoM 보호로 stride cap 축소.
    static let footHeightHighMm: Double = 60
    static let footHeightHighMaxStride: Double = 25

    /// balanceGain < 이 값이면 보상 부재로 stride cap 축소.
    static let balanceGainLow: Double = 0.3
    static let balanceGainLowMaxStride: Double = 22

    /// side 기본 권장 상한 (mm).
    static let defaultMaxSideMm: Double = 20
    /// |stride| > 이 값이면 회전 모멘트 보호로 side cap 축소.
    static let sideStrideCouplingMm: Double = 25
    static let sideStrideCouplingMaxSide: Double = 12
    /// 주기 < 이 값이면 side cap 추가 축소.
    static let sidePeriodMs: Double = 500
    static let sidePeriodMaxSide: Double = 10

    /// turn 기본 권장 상한 (°/cycle).
    static let defaultMaxTurnDeg: Double = 15
    /// |stride| > 이 값이면 turn cap 축소.
    static let turnStrideCouplingMm: Double = 25
    static let turnStrideCouplingMaxTurn: Double = 8
}

public enum WalkStabilityPredictor {

    /// 점수 산출 — 순수 함수. 임계는 휴리스틱.
    public static func evaluate(_ inp: WalkStabilityInput) -> WalkStabilityResult {
        var contribs: [WalkStabilityResult.Contributor] = []
        var messages: [String] = []

        let strideAbs = abs(inp.strideMm)
        let sideAbs   = abs(inp.sideMm)
        let turnAbs   = abs(inp.turnDeg)

        // 효과 속도 = stride / (period/1000) mm/s. 0~150+ 까지 범위.
        let cyclesPerSec = 1000.0 / max(inp.periodMs, StabilityThresholds.minPeriodForCyclesMs)
        let effSpeed = strideAbs * cyclesPerSec

        // 1. 보폭 자체 — 0..20 안전 / 20..30 주의 / 30..40 위험 / 40+ critical.
        do {
            let w = piecewise(strideAbs, knots: StabilityThresholds.strideKnots)
            if w > 0 { contribs.append(.init(id: "stride", label: "보폭", weight: w)) }
            if strideAbs >= StabilityThresholds.strideMessageMm {
                messages.append("보폭 \(Int(strideAbs)) mm — MX-28 무릎/발목 부하 가중")
            }
        }

        // 2. 주기 (빠를수록 위험). 800..600 안전 / 600..500 주의 / 500..400 위험 / <400 critical.
        do {
            let w = piecewise(inp.periodMs, knots: StabilityThresholds.periodKnots)
            if w > 0 { contribs.append(.init(id: "period", label: "주기", weight: w)) }
            if inp.periodMs < StabilityThresholds.periodMessageMs {
                messages.append("주기 \(Int(inp.periodMs)) ms — IMU 보정 한계 초과 가능")
            }
        }

        // 3. 효과 속도 (stride × cycles). 보폭과 주기의 상호작용 — 가장 강력한 낙상 지표.
        //    경험: ~40 mm/s 가 OP/OP2 의 안정 한계. 60+ 는 신뢰 불가.
        do {
            let w = piecewise(effSpeed, knots: StabilityThresholds.effSpeedKnots)
            if w > 0 { contribs.append(.init(id: "effSpeed", label: "유효 속도", weight: w)) }
            if effSpeed > StabilityThresholds.effSpeedMessageMmPerSec {
                messages.append("유효 속도 \(Int(effSpeed)) mm/s — 보폭/주기 조합 위험")
            }
        }

        // 4. 측면 보폭. 0..10 안전 / 10..15 주의 / 15..20 위험 / 20+ critical.
        do {
            let w = piecewise(sideAbs, knots: StabilityThresholds.sideKnots)
            if w > 0 { contribs.append(.init(id: "side", label: "측면", weight: w)) }
        }

        // 5. 회전. 0..5 안전 / 5..10 주의 / 10..15 위험 / 15+ critical.
        do {
            let w = piecewise(turnAbs, knots: StabilityThresholds.turnKnots)
            if w > 0 { contribs.append(.init(id: "turn", label: "회전", weight: w)) }
        }

        // 6. 발 들기 — 너무 낮으면 끌림, 너무 높으면 무게중심 흔들림.
        //    25 미만 끌림 / 25..30 주의 / 30..50 안전 / 50..60 주의 / 60..70 위험 / 70+ critical.
        do {
            let h = inp.footHeightMm
            let w: Double
            if h < StabilityThresholds.footHeightDragRegionMm {
                w = piecewise(h, knots: StabilityThresholds.footHeightLowKnots)
                if h < StabilityThresholds.footHeightDragMessageMm {
                    messages.append("발 들기 \(Int(h)) mm — 끌림으로 보행 실패 가능")
                }
            } else if h > StabilityThresholds.footHeightWobbleRegionMm {
                w = piecewise(h, knots: StabilityThresholds.footHeightHighKnots)
                if h > StabilityThresholds.footHeightWobbleMessageMm {
                    messages.append("발 들기 \(Int(h)) mm — 무게중심 흔들림 증가")
                }
            } else {
                w = 0
            }
            if w > 0 { contribs.append(.init(id: "footHeight", label: "발 들기", weight: w)) }
        }

        // 7. 균형 게인 — 0 부근이면 보상 없음, 너무 크면 진동.
        //    0.5..2.0 안전 / 0..0.5 주의 / 2.0..3.5 주의 / 3.5+ 위험.
        do {
            let g = inp.balanceGain
            let w: Double
            if g < StabilityThresholds.balanceGainLowRegion {
                w = piecewise(g, knots: StabilityThresholds.balanceGainLowKnots)
                if g < StabilityThresholds.balanceGainNoCompensationThreshold
                    && strideAbs > StabilityThresholds.balanceNoCompStrideThresholdMm {
                    messages.append("균형 게인 \(String(format: "%.1f", g)) — 보폭 큰 상태에서 IMU 보상 없음")
                }
            } else if g > StabilityThresholds.balanceGainHighRegion {
                w = piecewise(g, knots: StabilityThresholds.balanceGainHighKnots)
                if g > StabilityThresholds.balanceGainOvercompensationMessage {
                    messages.append("균형 게인 \(String(format: "%.1f", g)) — 과도 보상으로 진동 가능")
                }
            } else {
                w = 0
            }
            if w > 0 { contribs.append(.init(id: "balance", label: "균형 게인", weight: w)) }
        }

        // 8. 조합 위험 — diagonal 보폭 (앞+측면) 큰 경우.
        //    경험: stride 25+ + side 12+ → 회전 모멘트로 균형 흔들림.
        if strideAbs > StabilityThresholds.diagonalStrideMm
            && sideAbs > StabilityThresholds.diagonalSideMm {
            let extra = min(
                StabilityThresholds.diagonalMaxExtra,
                (strideAbs - StabilityThresholds.diagonalStrideMm)
                    * (sideAbs - StabilityThresholds.diagonalSideMm)
                    * StabilityThresholds.diagonalFactor
            )
            contribs.append(.init(id: "diagonal", label: "전후+측면 조합", weight: extra))
            messages.append("전후+측면 동시 큰 보폭 — 회전 모멘트로 낙상 가능")
        }

        // 9. 빠른 회전 + 큰 보폭 조합.
        if turnAbs > StabilityThresholds.turnStrideTurnDeg
            && strideAbs > StabilityThresholds.turnStrideStrideMm {
            let extra = min(
                StabilityThresholds.turnStrideMaxExtra,
                (turnAbs - StabilityThresholds.turnStrideTurnDeg)
                    * (strideAbs - StabilityThresholds.turnStrideStrideMm)
                    * StabilityThresholds.turnStrideFactor
            )
            contribs.append(.init(id: "turnStride", label: "회전+보폭 조합", weight: extra))
        }

        // 합산 — 단순 sum 후 100 으로 클램프. 큰 위험은 자연스럽게 100 으로 포화.
        let total = min(100.0, max(0.0, contribs.reduce(0.0) { $0 + $1.weight }))

        // 메시지는 최대 3개로 우선순위 트리밍.
        let trimmed = Array(messages.prefix(StabilityThresholds.maxMessageCount))

        let cat: WalkStabilityResult.Category
        switch total {
        case ..<StabilityThresholds.safeMaxScore:     cat = .safe
        case ..<StabilityThresholds.cautionMaxScore:  cat = .caution
        case ..<StabilityThresholds.highRiskMaxScore: cat = .highRisk
        default:                                      cat = .critical
        }

        return WalkStabilityResult(
            score: total,
            breakdown: contribs.sorted(by: { $0.weight > $1.weight }),
            category: cat,
            messages: trimmed,
            effectiveSpeedMmPerSec: effSpeed
        )
    }

    /// Smart clamp — 사용자가 한 슬라이더를 움직였을 때, 다른 파라미터의 안전 상한을 동적으로 줄임.
    ///
    /// 반환: 각 파라미터의 "권장 최대" 값. UI 가 슬라이더 max 를 이 값으로 가시화 (빨간 영역).
    ///
    /// 룰:
    ///   - period < 500 ms → max stride = 25 mm (속도 보호)
    ///   - period < 450 ms → max stride = 20 mm
    ///   - foot_height < 30 → max stride = 25 mm (끌림 방지)
    ///   - foot_height > 60 → max stride = 25 mm (CoM 흔들림)
    ///   - balance_gain < 0.3 → max stride = 22 mm (보상 없음 보호)
    public static func recommendedCaps(_ inp: WalkStabilityInput) -> Caps {
        var maxStride: Double = CapsThresholds.defaultMaxStrideMm
        if inp.periodMs < CapsThresholds.periodTier1Ms {
            maxStride = min(maxStride, CapsThresholds.periodTier1MaxStride)
        }
        if inp.periodMs < CapsThresholds.periodTier2Ms {
            maxStride = min(maxStride, CapsThresholds.periodTier2MaxStride)
        }
        if inp.footHeightMm < CapsThresholds.footHeightLowMm {
            maxStride = min(maxStride, CapsThresholds.footHeightLowMaxStride)
        }
        if inp.footHeightMm > CapsThresholds.footHeightHighMm {
            maxStride = min(maxStride, CapsThresholds.footHeightHighMaxStride)
        }
        if inp.balanceGain < CapsThresholds.balanceGainLow {
            maxStride = min(maxStride, CapsThresholds.balanceGainLowMaxStride)
        }

        var maxSide: Double = CapsThresholds.defaultMaxSideMm
        if abs(inp.strideMm) > CapsThresholds.sideStrideCouplingMm {
            maxSide = min(maxSide, CapsThresholds.sideStrideCouplingMaxSide)
        }
        if inp.periodMs < CapsThresholds.sidePeriodMs {
            maxSide = min(maxSide, CapsThresholds.sidePeriodMaxSide)
        }

        var maxTurn: Double = CapsThresholds.defaultMaxTurnDeg
        if abs(inp.strideMm) > CapsThresholds.turnStrideCouplingMm {
            maxTurn = min(maxTurn, CapsThresholds.turnStrideCouplingMaxTurn)
        }

        return Caps(maxStrideMm: maxStride, maxSideMm: maxSide, maxTurnDeg: maxTurn)
    }

    public struct Caps: Sendable, Equatable {
        public let maxStrideMm: Double
        public let maxSideMm: Double
        public let maxTurnDeg: Double
    }

    // MARK: - Helpers

    /// 구간별 linear 보간. knots 은 (입력, 가중치) 순서로 정렬되어 있다고 가정.
    ///
    /// # V288-1 (2026-05-24, V287-5 mutation testing 발견 latent bug fix)
    ///
    /// 종전: 오름차순 가정 — `periodKnots` 는 역순 (900→350 ms) 으로 정의되어
    /// `x <= first.0(=900)` 이 항상 true → period contributor 가 영구 0 반환.
    /// → period=350ms (최대 위험) 에서 score 과소 추정 → 사용자에게 잘못된 안전 신호.
    /// 신규: monotonicity 자동 감지 + 내림차순 knots 도 정상 처리 (ascending sort 우선).
    internal static func piecewise(_ x: Double, knots: [(Double, Double)]) -> Double {
        guard let first = knots.first, let last = knots.last else { return 0 }
        // V288-1: 역순 detection → ascending 정렬 후 처리 (단일 호출 비용 ≤ 10 knot 무시 가능).
        let sortedKnots: [(Double, Double)] = (first.0 <= last.0) ? knots
            : knots.sorted { $0.0 < $1.0 }
        guard let fst = sortedKnots.first, let lst = sortedKnots.last else { return 0 }
        if x <= fst.0 { return fst.1 }
        if x >= lst.0 { return lst.1 }
        for i in 0..<(sortedKnots.count - 1) {
            let a = sortedKnots[i]
            let b = sortedKnots[i + 1]
            if x >= a.0 && x <= b.0 {
                let t = (x - a.0) / (b.0 - a.0)
                return a.1 + (b.1 - a.1) * t
            }
        }
        return 0
    }
}
