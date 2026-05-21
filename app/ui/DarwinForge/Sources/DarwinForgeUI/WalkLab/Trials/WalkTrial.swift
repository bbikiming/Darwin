import Foundation

/// **v1.15.0 (2026-05-21) — Phase 1 데이터 모델**.
///
/// `WalkTrial` 은 "한 번의 보행 시도" 의 **atomic 단위** 입니다. 사용자 목표 ("워크랩에서
/// 다양한 테스트 → 좋은 모션 자동 추출 → 원격 조종에 적용") 의 토대 — 학습/추천/blending
/// 모두 "어떤 config 가 좋은 결과를 냈는가" 라는 정량 질의에 답해야 하고, 이를 위해
/// config + outcome + label 이 한 묶음으로 영구 저장되어야 합니다.
///
/// # 기존 시스템과의 관계
///
/// - `WalkSessionLogger` 가 매 50ms tick 마다 `WalkSessionSample` 을 jsonl 에 append.
/// - `WalkSessionAnalyzer` 가 종료 후 `WalkSessionSummary` (mean/peak/oscillation/effectiveness) 계산.
/// - **신규 WalkTrial 은 이 둘을 high-level abstraction 으로 통합** — Summary 의 metric +
///   사용자 라벨 + 검색 가능 metadata. timeseries 는 jsonl path 만 ref 로 보관 (re-encoding X).
///
/// # 비유
///
/// 과학 실험의 "한 번의 실험 run" 과 같습니다 — 조건 (config), 측정 (outcome), 평가 (label)
/// 가 한 묶음. 한 trial 만으로는 의미 없지만, 100 trials 가 모이면 "어떤 조건이 어떤 결과를
/// 일관 산출하는가" 의 패턴 분석 가능.
///
/// # Codable + Sendable + Identifiable
///
/// - `Codable`: JSON 파일 저장.
/// - `Sendable`: cross-actor 안전 (background queue 에서 analyzer 가 계산해서 main 으로 전달).
/// - `Identifiable`: SwiftUI ForEach 에서 row 식별.
public struct WalkTrial: Codable, Sendable, Identifiable, Equatable, Hashable {
    /// Hashable 은 `id` 만으로 충분 — SwiftUI List/ForEach 의 selection 식별 용.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: WalkTrial, rhs: WalkTrial) -> Bool {
        // Equatable + Hashable invariant — 같은 id = 같은 trial.
        lhs.id == rhs.id
    }

    /// trial 고유 ID. WalkSessionLogger 의 sessionId 와 동일 (1:1 매핑).
    public let id: String
    /// trial 시작 시각 (ISO 8601).
    public let startedAtIso: String
    /// trial 종료 시각 (ISO 8601). nil = 진행 중 또는 비정상 종료.
    public let endedAtIso: String?
    /// trial 지속 시간 (초).
    public let durationSec: Double
    /// 종료 사유.
    public let endReason: EndReason

    /// trial 의 입력 조건 — preset + balance config + sliders.
    public let config: TrialConfig
    /// trial 의 결과 — Analyzer 가 계산한 metrics.
    public let outcome: TrialOutcome
    /// 사용자 평가. nil = 사용자가 라벨링 안 함 (자동 metric 만으로 분석 가능).
    public let label: UserLabel?
    /// 시계열 데이터 참조. nil = timeseries 파일 없음 (sim mode 또는 logger 비활성).
    public let timeseries: TimeseriesRef?

    public init(
        id: String,
        startedAtIso: String,
        endedAtIso: String?,
        durationSec: Double,
        endReason: EndReason,
        config: TrialConfig,
        outcome: TrialOutcome,
        label: UserLabel? = nil,
        timeseries: TimeseriesRef? = nil
    ) {
        self.id = id
        self.startedAtIso = startedAtIso
        self.endedAtIso = endedAtIso
        self.durationSec = durationSec
        self.endReason = endReason
        self.config = config
        self.outcome = outcome
        self.label = label
        self.timeseries = timeseries
    }

    // MARK: - Backward-compat 위한 decode (미래 필드 추가 대비)

    private enum CodingKeys: String, CodingKey {
        case id, startedAtIso, endedAtIso, durationSec, endReason
        case config, outcome, label, timeseries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.startedAtIso = try c.decode(String.self, forKey: .startedAtIso)
        self.endedAtIso = try c.decodeIfPresent(String.self, forKey: .endedAtIso)
        self.durationSec = try c.decode(Double.self, forKey: .durationSec)
        self.endReason = try c.decode(EndReason.self, forKey: .endReason)
        self.config = try c.decode(TrialConfig.self, forKey: .config)
        self.outcome = try c.decode(TrialOutcome.self, forKey: .outcome)
        self.label = try c.decodeIfPresent(UserLabel.self, forKey: .label)
        self.timeseries = try c.decodeIfPresent(TimeseriesRef.self, forKey: .timeseries)
    }
}

// MARK: - EndReason

/// trial 이 어떻게 종료됐는가. 비교 분석 시 "정상 완료 trial 만" filter 가능.
public enum EndReason: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 사용자가 stop 버튼 (또는 단축키) 으로 정상 종료.
    case userStop
    /// preset 의 maxDurationSec 도달로 자동 종료 (정상).
    case maxDuration
    /// emergencyStop (사용자 또는 자동 fall prevention).
    case emergencyStop
    /// fall predictor 가 recommend emergency.
    case fallPredictorTriggered
    /// preflight failure (cradle / risk 미동의 등).
    case preflightFailed
    /// bus disconnect / write 실패 누적.
    case busFailure
    /// 알 수 없음 / 비정상 종료 (앱 crash, deinit 등).
    case unknown

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .userStop:               return "사용자 정지"
        case .maxDuration:            return "최대 시간 도달"
        case .emergencyStop:          return "긴급 정지"
        case .fallPredictorTriggered: return "낙상 예측 발동"
        case .preflightFailed:        return "사전 검증 실패"
        case .busFailure:             return "통신 실패"
        case .unknown:                return "알 수 없음"
        }
    }

    /// 이 종료 사유가 "성공" 으로 간주되는가? — Analyzer 의 stability 계산에 사용.
    public var isSuccess: Bool {
        switch self {
        case .userStop, .maxDuration:                             return true
        case .emergencyStop, .fallPredictorTriggered,
             .preflightFailed, .busFailure, .unknown:             return false
        }
    }
}

// MARK: - TrialConfig

/// trial 시작 시점의 모든 입력 조건 — 재현 가능한 unit.
///
/// `WalkSessionHeader` 의 핵심 필드를 추출 + 정규화. 미래에 신규 조건 (예: motion blending
/// settings) 추가 시 Optional 로 backward-compat.
public struct TrialConfig: Codable, Sendable, Equatable {
    public let preset: String
    /// preset 의 안전 등급 — `WalkLabPreset.safety.rawValue` (safe / caution / highRisk).
    public let presetSafety: String
    /// 보정 강도 level (0..4).
    public let intensityLevel: Int
    /// balance config 4축 + pitchConvention.
    public let balanceConfig: BalanceExperimentConfig
    /// `enableBalanceCorrection` master toggle.
    public let enableBalanceCorrection: Bool
    /// 6 tuning sliders. advanced 모드 OFF 시 모두 default (slider 미사용).
    public let tuning: TuningSnapshot
    /// custom gain (gainProfile=.custom 일 때만 의미).
    public let customGain: CustomGainSnapshot?
    /// `walkingEngine` rawValue (macSparseKeyframe / robotisOnboard).
    public let walkingEngine: String
    /// 실 robot 송출 여부.
    public let isRealRobot: Bool

    public init(
        preset: String,
        presetSafety: String,
        intensityLevel: Int,
        balanceConfig: BalanceExperimentConfig,
        enableBalanceCorrection: Bool,
        tuning: TuningSnapshot,
        customGain: CustomGainSnapshot? = nil,
        walkingEngine: String,
        isRealRobot: Bool
    ) {
        self.preset = preset
        self.presetSafety = presetSafety
        self.intensityLevel = intensityLevel
        self.balanceConfig = balanceConfig
        self.enableBalanceCorrection = enableBalanceCorrection
        self.tuning = tuning
        self.customGain = customGain
        self.walkingEngine = walkingEngine
        self.isRealRobot = isRealRobot
    }
}

/// 6 advanced slider 값. tick rate 와 무관 (start 시점 snapshot).
public struct TuningSnapshot: Codable, Sendable, Equatable {
    public let strideMm: Double
    public let sideMm: Double
    public let turnDeg: Double
    public let periodMs: Double
    public let footHeightMm: Double
    public let balanceGain: Double

    public init(
        strideMm: Double, sideMm: Double, turnDeg: Double,
        periodMs: Double, footHeightMm: Double, balanceGain: Double
    ) {
        self.strideMm = strideMm
        self.sideMm = sideMm
        self.turnDeg = turnDeg
        self.periodMs = periodMs
        self.footHeightMm = footHeightMm
        self.balanceGain = balanceGain
    }

    /// 모든 slider 가 default 값인가 (사용자가 advanced 모드 안 썼는가).
    public var isDefault: Bool {
        strideMm == 0 && sideMm == 0 && turnDeg == 0
            && periodMs == 600 && footHeightMm == 40 && balanceGain == 1.0
    }
}

/// custom gain 4개. gainProfile=.custom 일 때만 의미 있음.
public struct CustomGainSnapshot: Codable, Sendable, Equatable {
    public let hipRoll: Double
    public let knee: Double
    public let anklePitch: Double
    public let ankleRoll: Double

    public init(hipRoll: Double, knee: Double, anklePitch: Double, ankleRoll: Double) {
        self.hipRoll = hipRoll
        self.knee = knee
        self.anklePitch = anklePitch
        self.ankleRoll = ankleRoll
    }
}

// MARK: - TrialOutcome

/// Analyzer 가 계산한 정량 outcome. 비교/추천/순위 매기기 모두 이 구조체 기반.
///
/// **3 핵심 metric** (모두 0..1, 1 이 best):
/// - `stabilityScore` — 안정성 (BalanceState 분포 + fall events 반영)
/// - `smoothnessScore` — 부드러움 (IMU 가속도 std-dev 역수)
/// - `energyScore` — 에너지 효율 (motor temp rise / step 수)
///
/// 4번째 derived: `overallScore` — 3 metric 의 가중 평균.
public struct TrialOutcome: Codable, Sendable, Equatable {
    public let stabilityScore: Double
    public let smoothnessScore: Double
    public let energyScore: Double
    /// 가중 평균 — stability 50%, smoothness 30%, energy 20%. 사용자 ranking 기본 keys.
    public let overallScore: Double

    /// BalanceState 분포 (normal/caution/warning/danger/emergency 각 비율, 합=1.0).
    public let stateDistribution: [String: Double]
    /// fall event 수 (recommend emergency 발동).
    public let fallEventCount: Int
    /// fall event 사이 평균 시간 (초). 0 = fall 없음 (좋음).
    public let meanTimeBetweenFallsSec: Double?
    /// 최대 |roll| (deg).
    public let peakAbsRollDeg: Double
    /// 최대 |pitch| (deg).
    public let peakAbsPitchDeg: Double
    /// 평균 |roll| (deg).
    public let meanAbsRollDeg: Double
    /// 평균 |pitch| (deg).
    public let meanAbsPitchDeg: Double
    /// peak motor temp (°C).
    public let peakMotorTempC: Double
    /// 누적 bus write 실패.
    public let busWriteFailures: Int
    /// 실행된 step 수 (motor write step count).
    public let stepsExecuted: Int
    /// sample 수 (timeseries 길이).
    public let sampleCount: Int

    public init(
        stabilityScore: Double,
        smoothnessScore: Double,
        energyScore: Double,
        overallScore: Double,
        stateDistribution: [String: Double],
        fallEventCount: Int,
        meanTimeBetweenFallsSec: Double?,
        peakAbsRollDeg: Double,
        peakAbsPitchDeg: Double,
        meanAbsRollDeg: Double,
        meanAbsPitchDeg: Double,
        peakMotorTempC: Double,
        busWriteFailures: Int,
        stepsExecuted: Int,
        sampleCount: Int
    ) {
        self.stabilityScore = stabilityScore
        self.smoothnessScore = smoothnessScore
        self.energyScore = energyScore
        self.overallScore = overallScore
        self.stateDistribution = stateDistribution
        self.fallEventCount = fallEventCount
        self.meanTimeBetweenFallsSec = meanTimeBetweenFallsSec
        self.peakAbsRollDeg = peakAbsRollDeg
        self.peakAbsPitchDeg = peakAbsPitchDeg
        self.meanAbsRollDeg = meanAbsRollDeg
        self.meanAbsPitchDeg = meanAbsPitchDeg
        self.peakMotorTempC = peakMotorTempC
        self.busWriteFailures = busWriteFailures
        self.stepsExecuted = stepsExecuted
        self.sampleCount = sampleCount
    }

    /// "good trial" 판정 — rule-based recommender 의 baseline.
    /// stabilityScore ≥ 0.9 AND fallEventCount = 0 AND overallScore ≥ 0.8.
    public var isGoodTrial: Bool {
        stabilityScore >= 0.9 && fallEventCount == 0 && overallScore >= 0.8
    }
}

// MARK: - UserLabel

/// 사용자 평가 — 별점 + 자유 텍스트 + 태그. Claude critic 의 정성 학습 신호.
///
/// 사용자가 라벨링 안 해도 trial 은 outcome metric 만으로 학습 가능 (라벨 없으면 자동 분석만).
public struct UserLabel: Codable, Sendable, Equatable {
    /// 1..5 별점. 0 = 미평가 (default).
    public let rating: Int
    /// 자유 텍스트 피드백. 비어있을 수 있음.
    public let freeText: String
    /// 사용자/자동 추천 태그 (예: "smooth", "turn-unstable", "too-fast").
    public let tags: [String]
    /// 라벨링 시각 (ISO 8601).
    public let labeledAtIso: String

    public init(rating: Int, freeText: String, tags: [String], labeledAtIso: String) {
        // rating clamp 1..5 — 0 은 의미상 미평가지만 init 으로 들어오면 1 로 보정.
        self.rating = max(1, min(5, rating))
        self.freeText = freeText
        self.tags = tags
        self.labeledAtIso = labeledAtIso
    }
}

// MARK: - TimeseriesRef

/// timeseries 파일 참조. 새로 encoding 하지 않고 기존 `WalkSessionLogger` 가 만든 jsonl 가리킴.
///
/// jsonl 파일은 별도 retention 정책 (30일 cap). trial 요약은 영구.
public struct TimeseriesRef: Codable, Sendable, Equatable {
    /// jsonl 파일 path. App Sandbox container 안의 상대 경로 (예: "sessions/2026-05-21-...-march.jsonl").
    public let jsonlRelativePath: String
    /// sample 수 (sanity check).
    public let sampleCount: Int
    /// sample rate (Hz). 10Hz (v1.14.8+) 또는 20Hz (legacy).
    public let sampleRateHz: Double

    public init(jsonlRelativePath: String, sampleCount: Int, sampleRateHz: Double) {
        self.jsonlRelativePath = jsonlRelativePath
        self.sampleCount = sampleCount
        self.sampleRateHz = sampleRateHz
    }
}

// MARK: - Trial Index Entry

/// `index.json` 의 한 항목 — 모든 trial 의 lightweight 요약 (검색/필터 가속).
///
/// 전체 WalkTrial 을 로드하지 않고 index 만으로 카드 리스트 표시 가능.
public struct TrialIndexEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let startedAtIso: String
    public let preset: String
    public let durationSec: Double
    public let endReason: EndReason
    public let overallScore: Double
    public let stabilityScore: Double
    public let fallEventCount: Int
    public let rating: Int  // 0 = unrated
    public let tagsCount: Int
    public let isRealRobot: Bool

    public init(
        id: String, startedAtIso: String, preset: String,
        durationSec: Double, endReason: EndReason,
        overallScore: Double, stabilityScore: Double,
        fallEventCount: Int, rating: Int, tagsCount: Int,
        isRealRobot: Bool
    ) {
        self.id = id
        self.startedAtIso = startedAtIso
        self.preset = preset
        self.durationSec = durationSec
        self.endReason = endReason
        self.overallScore = overallScore
        self.stabilityScore = stabilityScore
        self.fallEventCount = fallEventCount
        self.rating = rating
        self.tagsCount = tagsCount
        self.isRealRobot = isRealRobot
    }

    /// WalkTrial 에서 index entry 생성.
    public static func from(_ trial: WalkTrial) -> TrialIndexEntry {
        TrialIndexEntry(
            id: trial.id,
            startedAtIso: trial.startedAtIso,
            preset: trial.config.preset,
            durationSec: trial.durationSec,
            endReason: trial.endReason,
            overallScore: trial.outcome.overallScore,
            stabilityScore: trial.outcome.stabilityScore,
            fallEventCount: trial.outcome.fallEventCount,
            rating: trial.label?.rating ?? 0,
            tagsCount: trial.label?.tags.count ?? 0,
            isRealRobot: trial.config.isRealRobot
        )
    }
}

// MARK: - Common tags 추천

/// 자동 태그 추천 — outcome metric 기반.
///
/// 사용자가 라벨링 시 시작 자동 채워주는 chip 후보 (사용자가 선택/해제).
public enum WalkTrialAutoTag {
    /// outcome 기반 추천 태그 list (preset + metric pattern 보고).
    public static func suggest(for trial: WalkTrial) -> [String] {
        var tags: [String] = []
        let o = trial.outcome
        let c = trial.config
        // stability 기반
        if o.stabilityScore >= 0.95 { tags.append("stable") }
        if o.stabilityScore < 0.7 { tags.append("unstable") }
        if o.fallEventCount > 0 { tags.append("fall-\(o.fallEventCount)") }
        // smoothness
        if o.smoothnessScore >= 0.9 { tags.append("smooth") }
        if o.smoothnessScore < 0.5 { tags.append("jerky") }
        // preset-specific
        if c.preset.contains("turn") && o.stabilityScore < 0.8 { tags.append("turn-unstable") }
        if c.preset.contains("fast") || c.preset == "jog" { tags.append("high-speed") }
        // duration
        if trial.durationSec < 3 { tags.append("short-trial") }
        if trial.durationSec > 30 { tags.append("long-trial") }
        // outcome by endReason
        if trial.endReason == .emergencyStop || trial.endReason == .fallPredictorTriggered {
            tags.append("aborted-by-safety")
        }
        return tags
    }
}
