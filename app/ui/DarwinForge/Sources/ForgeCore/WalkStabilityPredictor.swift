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

public enum WalkStabilityPredictor {

    /// 점수 산출 — 순수 함수. 임계는 휴리스틱.
    public static func evaluate(_ inp: WalkStabilityInput) -> WalkStabilityResult {
        var contribs: [WalkStabilityResult.Contributor] = []
        var messages: [String] = []

        let strideAbs = abs(inp.strideMm)
        let sideAbs   = abs(inp.sideMm)
        let turnAbs   = abs(inp.turnDeg)

        // 효과 속도 = stride / (period/1000) mm/s. 0~150+ 까지 범위.
        let cyclesPerSec = 1000.0 / max(inp.periodMs, 200.0)
        let effSpeed = strideAbs * cyclesPerSec

        // 1. 보폭 자체 — 0..20 안전 / 20..30 주의 / 30..40 위험 / 40+ critical.
        do {
            let w = piecewise(strideAbs, knots: [(0, 0), (20, 5), (30, 25), (40, 55), (50, 85)])
            if w > 0 { contribs.append(.init(id: "stride", label: "보폭", weight: w)) }
            if strideAbs >= 30 { messages.append("보폭 \(Int(strideAbs)) mm — MX-28 무릎/발목 부하 가중") }
        }

        // 2. 주기 (빠를수록 위험). 800..600 안전 / 600..500 주의 / 500..400 위험 / <400 critical.
        do {
            let w = piecewise(inp.periodMs, knots: [(900, 0), (700, 0), (600, 5), (500, 20), (450, 45), (400, 70), (350, 90)])
            if w > 0 { contribs.append(.init(id: "period", label: "주기", weight: w)) }
            if inp.periodMs < 500 { messages.append("주기 \(Int(inp.periodMs)) ms — IMU 보정 한계 초과 가능") }
        }

        // 3. 효과 속도 (stride × cycles). 보폭과 주기의 상호작용 — 가장 강력한 낙상 지표.
        //    경험: ~40 mm/s 가 OP/OP2 의 안정 한계. 60+ 는 신뢰 불가.
        do {
            let w = piecewise(effSpeed, knots: [(0, 0), (20, 0), (40, 15), (60, 50), (80, 80), (120, 100)])
            if w > 0 { contribs.append(.init(id: "effSpeed", label: "유효 속도", weight: w)) }
            if effSpeed > 50 { messages.append("유효 속도 \(Int(effSpeed)) mm/s — 보폭/주기 조합 위험") }
        }

        // 4. 측면 보폭. 0..10 안전 / 10..15 주의 / 15..20 위험 / 20+ critical.
        do {
            let w = piecewise(sideAbs, knots: [(0, 0), (10, 0), (15, 15), (20, 35), (25, 60)])
            if w > 0 { contribs.append(.init(id: "side", label: "측면", weight: w)) }
        }

        // 5. 회전. 0..5 안전 / 5..10 주의 / 10..15 위험 / 15+ critical.
        do {
            let w = piecewise(turnAbs, knots: [(0, 0), (5, 0), (10, 15), (15, 35), (20, 60)])
            if w > 0 { contribs.append(.init(id: "turn", label: "회전", weight: w)) }
        }

        // 6. 발 들기 — 너무 낮으면 끌림, 너무 높으면 무게중심 흔들림.
        //    25 미만 끌림 / 25..30 주의 / 30..50 안전 / 50..60 주의 / 60..70 위험 / 70+ critical.
        do {
            let h = inp.footHeightMm
            let w: Double
            if h < 30 {
                w = piecewise(h, knots: [(15, 60), (20, 40), (25, 20), (30, 0)])
                if h < 25 { messages.append("발 들기 \(Int(h)) mm — 끌림으로 보행 실패 가능") }
            } else if h > 50 {
                w = piecewise(h, knots: [(50, 0), (60, 20), (70, 50), (80, 80)])
                if h > 60 { messages.append("발 들기 \(Int(h)) mm — 무게중심 흔들림 증가") }
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
            if g < 0.5 {
                w = piecewise(g, knots: [(0, 35), (0.3, 15), (0.5, 0)])
                if g < 0.3 && strideAbs > 25 {
                    messages.append("균형 게인 \(String(format: "%.1f", g)) — 보폭 큰 상태에서 IMU 보상 없음")
                }
            } else if g > 2.0 {
                w = piecewise(g, knots: [(2.0, 0), (2.5, 10), (3.5, 30), (5.0, 60)])
                if g > 3.0 { messages.append("균형 게인 \(String(format: "%.1f", g)) — 과도 보상으로 진동 가능") }
            } else {
                w = 0
            }
            if w > 0 { contribs.append(.init(id: "balance", label: "균형 게인", weight: w)) }
        }

        // 8. 조합 위험 — diagonal 보폭 (앞+측면) 큰 경우.
        //    경험: stride 25+ + side 12+ → 회전 모멘트로 균형 흔들림.
        if strideAbs > 25 && sideAbs > 12 {
            let extra = min(20, (strideAbs - 25) * (sideAbs - 12) * 0.4)
            contribs.append(.init(id: "diagonal", label: "전후+측면 조합", weight: extra))
            messages.append("전후+측면 동시 큰 보폭 — 회전 모멘트로 낙상 가능")
        }

        // 9. 빠른 회전 + 큰 보폭 조합.
        if turnAbs > 8 && strideAbs > 25 {
            let extra = min(20, (turnAbs - 8) * (strideAbs - 25) * 0.5)
            contribs.append(.init(id: "turnStride", label: "회전+보폭 조합", weight: extra))
        }

        // 합산 — 단순 sum 후 100 으로 클램프. 큰 위험은 자연스럽게 100 으로 포화.
        let total = min(100.0, max(0.0, contribs.reduce(0.0) { $0 + $1.weight }))

        // 메시지는 최대 3개로 우선순위 트리밍.
        let trimmed = Array(messages.prefix(3))

        let cat: WalkStabilityResult.Category
        switch total {
        case ..<30:  cat = .safe
        case ..<60:  cat = .caution
        case ..<80:  cat = .highRisk
        default:     cat = .critical
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
        var maxStride: Double = 40
        if inp.periodMs < 500 { maxStride = min(maxStride, 25) }
        if inp.periodMs < 450 { maxStride = min(maxStride, 20) }
        if inp.footHeightMm < 30 { maxStride = min(maxStride, 25) }
        if inp.footHeightMm > 60 { maxStride = min(maxStride, 25) }
        if inp.balanceGain < 0.3 { maxStride = min(maxStride, 22) }

        var maxSide: Double = 20
        if abs(inp.strideMm) > 25 { maxSide = min(maxSide, 12) }
        if inp.periodMs < 500 { maxSide = min(maxSide, 10) }

        var maxTurn: Double = 15
        if abs(inp.strideMm) > 25 { maxTurn = min(maxTurn, 8) }

        return Caps(maxStrideMm: maxStride, maxSideMm: maxSide, maxTurnDeg: maxTurn)
    }

    public struct Caps: Sendable, Equatable {
        public let maxStrideMm: Double
        public let maxSideMm: Double
        public let maxTurnDeg: Double
    }

    // MARK: - Helpers

    /// 구간별 linear 보간. knots 은 (입력, 가중치) 순서로 정렬되어 있다고 가정.
    private static func piecewise(_ x: Double, knots: [(Double, Double)]) -> Double {
        guard let first = knots.first, let last = knots.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0  { return last.1 }
        for i in 0..<(knots.count - 1) {
            let a = knots[i]
            let b = knots[i + 1]
            if x >= a.0 && x <= b.0 {
                let t = (x - a.0) / (b.0 - a.0)
                return a.1 + (b.1 - a.1) * t
            }
        }
        return 0
    }
}
