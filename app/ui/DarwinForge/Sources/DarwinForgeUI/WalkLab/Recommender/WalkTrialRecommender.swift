import Foundation

/// **v1.16.0 (2026-05-21) — Phase 2: WalkTrial Recommender**.
///
/// 사용자가 워크랩에서 다양한 trial 을 저장 + 라벨링한 결과를 활용해 **다음에 시도할 config**
/// 를 추천. Phase 1 의 `WalkTrialStore` 가 토대 — 정량 outcome + 정성 라벨 모두 학습 신호.
///
/// # 3 Strategy (architect 권고 — strategy pattern)
///
/// 1. **Rule-based** (즉시 가치, 30분 구현)
///    - `stabilityScore ≥ 0.9 AND fallEventCount == 0 AND overallScore ≥ 0.8` → "good trial"
///    - 같은 preset 의 good trial 들의 config 평균 추천
///
/// 2. **1-D Coordinate Descent** (locomotion 연구 권고 — Bayesian opt 보다 실 robot 적합)
///    - 4-D config space 에서 한 axis 만 ±10% 탐색
///    - 5~10 trial 누적 후 활성화
///    - 매 epoch 한 축씩 — period → strideMm → intensity → balanceGain
///
/// 3. **Claude critic** (정성 분석, 이미 ExperimentLoopController 에 인프라 있음)
///    - 본 Recommender 가 직접 호출하지 않고 ExperimentLoopController 와 연계
///    - Phase 2 에선 placeholder — 미래 통합 hook
///
/// # 비유
///
/// 운동 코치 — 선수의 지난 시도들을 보고 "지난 5번 중 6보 보폭 + 600ms 주기 일 때 가장
/// 안정적이었다" 같은 정량 추천. 코치가 직접 실행은 안 시키고 (사용자가 적용 여부 결정) — UI
/// 가 "이 추천 적용" 버튼만 노출.
@MainActor
public final class WalkTrialRecommender {

    public static let shared = WalkTrialRecommender()

    private let store: WalkTrialStore

    public init(store: WalkTrialStore = .shared) {
        self.store = store
    }

    // MARK: - Public entry — 통합 추천

    /// 현재 시도 중인 preset 에 대해 N개 strategy 의 추천을 모두 받고 voting (가중치 기반).
    public func recommend(for preset: String) -> [WalkTrialRecommendation] {
        var results: [WalkTrialRecommendation] = []

        if let rule = ruleBased(for: preset) {
            results.append(rule)
        }
        if let coord = coordinateDescent(for: preset) {
            results.append(coord)
        }
        if let pilot = pilotBiased(for: preset) {
            results.append(pilot)
        }
        // Claude strategy 는 Phase 2 에선 placeholder. ExperimentLoopController 와 통합 후 별도.

        return results
    }

    // MARK: - Strategy 1: Rule-based

    /// preset 에 대한 good trial 들의 config 평균. trial 부족 (< 3 개) 시 nil.
    /// **v1.16.0.1 fix (critic MAJOR #1)**: 종전 filter 가 overallScore + noFallsOnly 만
    /// → unstable trial (예: stabilityScore=0.4 + smoothnessScore=0.9 = overall 0.65 → 0.8↓
    /// 라 자동 제외) 인데, 실제로는 stabilityScore=0.5 + smoothness=1.0 + energy=0.95
    /// 같은 case 도 overall=0.755 라 제외 → OK 이지만, 가중치 (0.5/0.3/0.2) 로 stability
    /// 절반 가중이 약함. **명시 minStabilityScore=0.7 추가** — 실 robot fall 차단.
    public func ruleBased(for preset: String) -> WalkTrialRecommendation? {
        return ruleBased(for: preset, realRobotOnly: false)
    }

    /// **사이클 119 (audit #31, P0)**: realRobotOnly 명시 overload.
    /// sim/real trial 구분 — 추천 카드 rationale 에 비율 표시 + 실 로봇 데이터만으로
    /// 추천 받고 싶을 때 `realRobotOnly: true`.
    public func ruleBased(for preset: String, realRobotOnly: Bool) -> WalkTrialRecommendation? {
        let filter = TrialFilter(
            preset: preset,
            minOverallScore: 0.8,
            minStabilityScore: 0.7,   // critic MAJOR #1 fix — fall 위험 차단.
            noFallsOnly: true,
            realRobotOnly: realRobotOnly  // 사이클 119 audit #31.
        )
        let goodEntries = store.query(filter: filter, sort: .overallDesc)
        guard goodEntries.count >= 3 else { return nil }

        // 상위 5개 trial 로드 — index entry 만으론 config 부족.
        let topIds = goodEntries.prefix(5).map { $0.id }
        let topTrials: [WalkTrial] = topIds.compactMap { store.load(id: $0) }
        guard topTrials.count >= 3 else { return nil }

        let avgTuning = averageTuning(topTrials.map { $0.config.tuning })
        // **v1.16.0.1 fix (critic MAJOR #2)**: 종전 정수 나눗셈 `(sum) / count` 는 truncate
        // (예: [1,1,3] 평균 = 5/3 = 1, 기대 2 round). Double cast + round 으로 정확.
        let intensitySum = topTrials.map { $0.config.intensityLevel }.reduce(0, +)
        let avgIntensity = Int((Double(intensitySum) / Double(topTrials.count)).rounded())
        let avgOverall = topTrials.map { $0.outcome.overallScore }.reduce(0, +) / Double(topTrials.count)

        // **사이클 119 (audit #31)**: sim/real 비율 명시. 호출자/UI 가 "데이터 출처 신뢰" 판정.
        let realCount = topTrials.filter { $0.config.isRealRobot }.count
        let simCount = topTrials.count - realCount
        let breakdown = realRobotOnly
            ? "실로봇 \(realCount)개 (sim 제외)"
            : "실로봇 \(realCount)개 / 시뮬 \(simCount)개"

        return WalkTrialRecommendation(
            strategy: .ruleBased,
            preset: preset,
            tuning: avgTuning,
            intensityLevel: avgIntensity,
            balanceConfig: topTrials.first?.config.balanceConfig ?? .defaultRobotis,
            dataMaturity: min(1.0, Double(topTrials.count) / 5.0),
            rationale: "상위 \(topTrials.count) good trial 평균 (avg score \(Int(avgOverall * 100))/100, \(breakdown))",
            sourceSampleIds: topIds
        )
    }

    // MARK: - Strategy 2: 1-D Coordinate Descent

    /// 4-D config space (period × stride × intensity × balanceGain) 의 한 axis 를 +10% 또는 -10%
    /// 탐색. baseline = 같은 preset 의 best trial. trial < 5 일 때 nil.
    public func coordinateDescent(for preset: String) -> WalkTrialRecommendation? {
        let filter = TrialFilter(preset: preset)
        let allEntries = store.query(filter: filter, sort: .overallDesc)
        guard allEntries.count >= 5 else { return nil }

        // Baseline = best trial.
        guard let bestId = allEntries.first?.id,
              let best = store.load(id: bestId)
        else { return nil }

        // 다음 탐색 axis 결정 — round-robin (trial 수 % 4).
        let axisIndex = allEntries.count % 4
        let axes: [CoordAxis] = [.period, .stride, .intensity, .balanceGain]
        let axis = axes[axisIndex]

        // ±10% sign 결정 — 같은 axis 의 마지막 변화 방향 반전 또는 무변화면 +.
        let sign: Double = allEntries.count % 2 == 0 ? 1.0 : -1.0
        let nudge = 0.10 * sign

        var newTuning = best.config.tuning
        var newIntensity = best.config.intensityLevel
        let rationale: String

        switch axis {
        case .period:
            let newVal = max(350, min(1000, best.config.tuning.periodMs * (1.0 + nudge)))
            newTuning = TuningSnapshot(
                strideMm: best.config.tuning.strideMm,
                sideMm: best.config.tuning.sideMm,
                turnDeg: best.config.tuning.turnDeg,
                periodMs: newVal,
                footHeightMm: best.config.tuning.footHeightMm,
                balanceGain: best.config.tuning.balanceGain
            )
            rationale = "주기 \(Int(best.config.tuning.periodMs))ms → \(Int(newVal))ms (\(sign > 0 ? "+" : "")10%)"

        case .stride:
            let newVal = max(0, min(50, best.config.tuning.strideMm * (1.0 + nudge)))
            newTuning = TuningSnapshot(
                strideMm: newVal,
                sideMm: best.config.tuning.sideMm,
                turnDeg: best.config.tuning.turnDeg,
                periodMs: best.config.tuning.periodMs,
                footHeightMm: best.config.tuning.footHeightMm,
                balanceGain: best.config.tuning.balanceGain
            )
            rationale = "보폭 \(Int(best.config.tuning.strideMm))mm → \(Int(newVal))mm (\(sign > 0 ? "+" : "")10%)"

        case .intensity:
            // intensity 는 정수 0..4, ±1 step.
            let delta = sign > 0 ? 1 : -1
            newIntensity = max(0, min(4, best.config.intensityLevel + delta))
            rationale = "보정 강도 \(best.config.intensityLevel) → \(newIntensity)"

        case .balanceGain:
            let newVal = max(0, min(5, best.config.tuning.balanceGain * (1.0 + nudge)))
            newTuning = TuningSnapshot(
                strideMm: best.config.tuning.strideMm,
                sideMm: best.config.tuning.sideMm,
                turnDeg: best.config.tuning.turnDeg,
                periodMs: best.config.tuning.periodMs,
                footHeightMm: best.config.tuning.footHeightMm,
                balanceGain: newVal
            )
            rationale = "균형 게인 \(String(format: "%.2f", best.config.tuning.balanceGain)) → \(String(format: "%.2f", newVal)) (\(sign > 0 ? "+" : "")10%)"
        }

        return WalkTrialRecommendation(
            strategy: .coordinateDescent,
            preset: preset,
            tuning: newTuning,
            intensityLevel: newIntensity,
            balanceConfig: best.config.balanceConfig,
            dataMaturity: min(1.0, Double(allEntries.count) / 10.0),
            rationale: "좌표 하강: \(rationale). 베이스라인 score \(Int(best.outcome.overallScore * 100))/100",
            sourceSampleIds: [bestId]
        )
    }

    // MARK: - Strategy 3: Pilot-biased (Cycle 16)

    /// **v1.20.9 (2026-05-22) 사이클 16 + 사이클 16-fix (코덱스)** — pilot stick 입력의 peak abs
    /// amplitude 를 사용자 comfort zone 으로 해석. trial.config.pilotInputs (Cycle 7) + advanced
    /// 모드에서만 신뢰 가능 (CRITICAL fix).
    ///
    /// # 비유
    ///
    /// 사용자가 자전거 타며 "이 정도 속도가 편하다" 라고 결정하는 것과 같음. 단, 자전거 페달과
    /// 바퀴 연결이 풀려있으면 (advanced=false) 페달 밟은 양은 속도 신뢰 신호 못 됨 → 제외.
    ///
    /// # 필터 (사이클 16-fix 코덱스 검수 반영)
    ///
    /// - preset 일치
    /// - pilotInputs != nil (Cycle 7 이후 trial)
    /// - **wasAdvancedMode == true** (CRITICAL — slider/pilot 이 실제 walking 에 반영된 trial 만)
    /// - **moveEventCount >= 10** (HIGH 1 — stop/emergency 제외 실 move 입력)
    /// - **!emergencyTriggered** (HIGH 1 — 비상 정지 trial 제외)
    /// - overall >= 0.75 (상향 — 0.7 → 0.75, noise 차단)
    /// - minStability >= 0.7
    /// - falls == 0
    ///
    /// trial 부족 (< 3 개) 시 nil (상향 — 2 → 3).
    public func pilotBiased(for preset: String) -> WalkTrialRecommendation? {
        let filter = TrialFilter(preset: preset, minOverallScore: 0.75,
                                  minStabilityScore: 0.7, noFallsOnly: true)
        let allEntries = store.query(filter: filter, sort: .overallDesc)
        // **MEDIUM 1 fix**: filter 먼저, prefix 나중 — non-pilot trial 이 top 10 점유 시 손실 차단.
        // **LOW 2 fix**: tuple (trial, pilot) 으로 force unwrap 제거.
        let candidates: [(trial: WalkTrial, pilot: PilotInputSummary)] = allEntries.compactMap { entry in
            guard let trial = store.load(id: entry.id),
                  let pilot = trial.config.pilotInputs,
                  trial.config.wasAdvancedMode,                  // CRITICAL fix
                  pilot.moveEventCount >= 10,                    // HIGH 1
                  !pilot.emergencyTriggered                      // HIGH 1
            else { return nil }
            return (trial, pilot)
        }
        let topPiloted = Array(candidates.prefix(10))
        guard topPiloted.count >= 3 else { return nil }          // 상향 2→3

        let n = Double(topPiloted.count)
        // **HIGH 2 fix**: peakAbs* — 음수 방향 입력도 신뢰 (왼쪽/시계/후진).
        let avgAbsPeakStride = topPiloted.map { $0.pilot.peakAbsStrideMm }.reduce(0, +) / n
        let avgAbsPeakSide   = topPiloted.map { $0.pilot.peakAbsSideMm   }.reduce(0, +) / n
        let avgAbsPeakTurn   = topPiloted.map { $0.pilot.peakAbsTurnDeg  }.reduce(0, +) / n
        // 다른 tuning 축은 trial 의 평균 (slider 가 결정).
        let baseTuning = averageTuning(topPiloted.map { $0.trial.config.tuning })
        let pilotTuning = TuningSnapshot(
            strideMm: avgAbsPeakStride,
            sideMm: avgAbsPeakSide,
            turnDeg: avgAbsPeakTurn,
            periodMs: baseTuning.periodMs,
            footHeightMm: baseTuning.footHeightMm,
            balanceGain: baseTuning.balanceGain
        )
        let intensitySum = topPiloted.map { $0.trial.config.intensityLevel }.reduce(0, +)
        let avgIntensity = Int((Double(intensitySum) / n).rounded())
        let totalMoveSum = topPiloted.map { $0.pilot.moveEventCount }.reduce(0, +)

        return WalkTrialRecommendation(
            strategy: .pilotBiased,
            preset: preset,
            tuning: pilotTuning,
            intensityLevel: avgIntensity,
            // **LOW 1 partial fix**: top-score piloted trial 의 config — 향후 group-by 가능.
            balanceConfig: topPiloted.first?.trial.config.balanceConfig ?? .defaultRobotis,
            // **MEDIUM 2 fix**: dataMaturity cap 상향 (5→10), pilot noisy 라 더 보수적.
            dataMaturity: min(1.0, n / 10.0),
            rationale: "\(Int(n))개 advanced+piloted trial — abs peak avg: stride \(Int(avgAbsPeakStride))mm / side \(Int(avgAbsPeakSide))mm / turn \(Int(avgAbsPeakTurn))° (총 \(totalMoveSum) move events)",
            sourceSampleIds: topPiloted.map { $0.trial.id }
        )
    }

    // MARK: - Helpers

    private func averageTuning(_ tunings: [TuningSnapshot]) -> TuningSnapshot {
        let n = Double(tunings.count)
        return TuningSnapshot(
            strideMm: tunings.map { $0.strideMm }.reduce(0, +) / n,
            sideMm: tunings.map { $0.sideMm }.reduce(0, +) / n,
            turnDeg: tunings.map { $0.turnDeg }.reduce(0, +) / n,
            periodMs: tunings.map { $0.periodMs }.reduce(0, +) / n,
            footHeightMm: tunings.map { $0.footHeightMm }.reduce(0, +) / n,
            balanceGain: tunings.map { $0.balanceGain }.reduce(0, +) / n
        )
    }
}

// MARK: - Recommendation 데이터

/// Recommender 가 산출하는 한 건의 추천.
public struct WalkTrialRecommendation: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let strategy: Strategy
    public let preset: String
    public let tuning: TuningSnapshot
    public let intensityLevel: Int
    public let balanceConfig: BalanceExperimentConfig
    /// 0..1 — 데이터 sample 수 기반 (5+ 가 만점).
    /// **v1.16.0.1 fix (architect)**: 종전 `confidence` 는 statistical confidence 가 아니라
    /// sample-size proxy (`min(1.0, count/5)`). 사용자/외부 LLM 이 "통계 신뢰도" 로 오해 가능
    /// → `dataMaturity` 로 rename. 의미: "이 추천이 충분한 데이터에 기반하는가" (0..1).
    public let dataMaturity: Double
    public let rationale: String
    /// 추천 근거가 된 trial ID 목록 — 사용자가 클릭 시 원본 trial 로 이동.
    public let sourceSampleIds: [String]

    public enum Strategy: String, Sendable, Equatable, CaseIterable {
        case ruleBased
        case coordinateDescent
        /// **v1.16.0.1 (2026-05-21) — critic Minor #4**: 본 case 는 ExperimentLoopController
        /// + WalkSessionClaudeCritic 와 미래 통합 path 의 placeholder. Phase 2 에선 미사용
        /// (Recommender 가 직접 instantiate 안 함). 추후 ClaudeCriticResponse 를 본 Recommendation
        /// 으로 wrap 하는 adapter 추가 시 사용. 현재는 enum exhaustive 완전성을 위해 보존.
        case claudeCritic
        /// **v1.20.9 (2026-05-22) 사이클 16** — pilot stick 입력 평균 기반.
        /// trial.config.pilotInputs.peak* 값들의 평균을 사용자 comfort zone 으로 해석.
        case pilotBiased

        public var label: String {
            switch self {
            case .ruleBased:          return "규칙 기반 (good trial 평균)"
            case .coordinateDescent:  return "좌표 하강 (1축 ±10%)"
            case .claudeCritic:       return "Claude 분석 (추후 통합)"
            case .pilotBiased:        return "조종 기반 (사용자 comfort)"
            }
        }

        public var icon: String {
            switch self {
            case .ruleBased:          return "chart.bar.fill"
            case .coordinateDescent:  return "arrow.up.and.down.righttriangle.up.righttriangle.down"
            case .claudeCritic:       return "brain"
            case .pilotBiased:        return "gamecontroller.fill"
            }
        }
    }

    public init(
        id: UUID = UUID(),
        strategy: Strategy,
        preset: String,
        tuning: TuningSnapshot,
        intensityLevel: Int,
        balanceConfig: BalanceExperimentConfig,
        dataMaturity: Double,
        rationale: String,
        sourceSampleIds: [String]
    ) {
        self.id = id
        self.strategy = strategy
        self.preset = preset
        self.tuning = tuning
        self.intensityLevel = intensityLevel
        self.balanceConfig = balanceConfig
        self.dataMaturity = dataMaturity
        self.rationale = rationale
        self.sourceSampleIds = sourceSampleIds
    }
}

// MARK: - Internal types

private enum CoordAxis {
    case period, stride, intensity, balanceGain
}
