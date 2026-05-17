import Foundation

/// **v1.9 (2026-05-17)**: 한 tick (50ms) 의 보행 데이터 스냅샷.
///
/// JSONL 라인 하나 = WalkSessionSample 하나. 사람이 읽기 쉽고 Python/pandas 분석 가능.
/// 매 50ms (20Hz) 저장 → 1초 = ~10KB, 1분 = ~600KB, 1시간 = ~36MB.
///
/// **v1.11 (2026-05-17 사용자 prompt)**: 자이로 보정 4축 logging 필드 추가.
/// 모든 신규 필드는 Optional (backward-compat: 기존 JSONL 파일 decoder 호환).
public struct WalkSessionSample: Codable, Sendable {
    /// ms since session start.
    public let t: Double
    /// preset rawValue (idle/march/slowWalk/normalWalk/fastWalk/turnLeft/turnRight).
    public let preset: String
    /// 보정 강도 (0..4).
    public let intensityLevel: Int
    /// IMU roll (deg) — complementary filter 후.
    public let imuRollDeg: Double
    /// IMU pitch (deg).
    public let imuPitchDeg: Double
    /// Corrector 가 실제로 사용한 LPF + deadband 적용 후 roll error (v1.9).
    public let correctorRollErrDeg: Double
    /// Corrector pitch error (LPF + deadband).
    public let correctorPitchErrDeg: Double
    /// balance state (normal/caution/warning/danger/emergency).
    public let balanceState: String
    /// 8 관절 corrector delta (R/L hipRoll, R/L knee, R/L anklePitch, R/L ankleRoll). 0 = corrector OFF.
    public let correctorDeltas: [Double]
    /// IMU source (sim/real/stale).
    public let imuSource: String
    /// 배터리 전압 (V). nil = 데이터 없음.
    public let batteryVolts: Double?
    /// 모터 평균 온도 (°C). nil = 데이터 없음.
    public let motorAvgTemp: Double?

    // MARK: - v1.11 (2026-05-17) 자이로 보정 4축 logging

    /// algorithmMode (off / robotisPControl / hybridBA / observeOnly). nil = legacy log.
    public let balanceAlgorithmMode: String?
    /// signConvention (robotisWalkingCpp / alternateDiagnostic). nil = legacy log.
    public let balanceSignConvention: String?
    /// gainProfile (robotisOriginal / v110Experimental / custom). nil = legacy log.
    public let balanceGainProfile: String?
    /// 이 tick 에 corrections 가 실 pose 에 적용됐는가? observeOnly 또는 applyToRobot=false 면 false.
    public let correctionAppliedToRobot: Bool?
    /// walking cycle 시작부터 elapsed (ms), 0..periodMs. Hybrid path 일 때만 값.
    public let walkCycleElapsedMs: Double?
    /// 현재 walking cycle period (ms). preset 의 defaultTuning fallback 시에도 값.
    public let walkPeriodMs: Double?
    /// IMU 샘플 age (ms) — 최근 IMU read 부터의 경과. stale 검출용. nil = 추정 불가.
    public let imuSampleAgeMs: Double?
    /// 예상 sagittal sway pitch (deg) — phase-locked component. Hybrid 일 때만 값.
    public let expectedPitchDeg: Double?
    /// EMA 기반 chronic drift pitch (deg) — slow component. Hybrid 일 때만 값.
    public let emaPitchDeg: Double?
    /// 최종 effective pitch err (slow + fast 합) — corrections 입력. Hybrid 일 때만 값.
    public let effectivePitchErrDeg: Double?

    // MARK: - v1.11 wiring (2026-05-17) — handoff §4 호환 필드
    //
    // `docs/handoff/2026-05-17-walk-data-pipeline-v2-handoff.md` §4 의 TickData
    // 와 1:1 매핑되는 추가 필드. v2 pipeline 의 quality analyzer 가 이 값들로
    // staleRatio / phase residual / candidate vs applied 분리 검증.

    /// walking cycle 안의 정규화 위상 (0..1). `walkCycleElapsedMs / walkPeriodMs`.
    /// Hybrid phase 검증에 필수. nil = idle 또는 period 무효.
    public let walkPhase01: Double?
    /// corrector 가 계산한 raw 8-joint 보정 (관찰값) — applyToRobot=false 라도 채워짐.
    /// `correctorDeltas` 와의 차이: candidate 는 항상 corrector.corrections() 결과,
    /// applied 는 pose 에 실제 들어간 값 (observeOnly 면 [0,...]).
    public let candidateDeltas: [Double]?
    /// pose 에 실제 들어간 8-joint delta. observeOnly / applyToRobot=false → [0,...].
    public let appliedDeltas: [Double]?
    /// **Mac-side IMU read counter** (Codex review 2026-05-18 MEDIUM-3 명시).
    /// firmware sequence 가 아니라 ConnectionStore.imuSequenceCount (성공 read 마다 ++).
    /// 같은 tick 안에서 값이 같으면 "새 IMU read 없음" → corrector 가 stale 데이터 사용.
    /// packet-level duplicate (같은 hardware sample 중복) 검출은 불가 (firmware 노출 필요).
    /// nil = sim 또는 store 미연결.
    public let imuSequence: UInt32?
    /// 누적 bus write 실패 count — 모터 송출 신뢰성 지표.
    public let busWriteFailureCount: Int?
    /// 누적 bus read 실패 count — telemetry 신뢰성 지표.
    public let busReadFailureCount: Int?
    /// LPF + deadband 적용 후 corrector 가 본 effective roll err.
    public let effectiveRollErrDeg: Double?
    /// Hybrid 의 sin model 예측 roll (deg). Hybrid + lateral sway > 0 일 때만.
    public let expectedRollDeg: Double?
    /// EMA chronic roll drift (deg). Hybrid 일 때만.
    public let emaRollDeg: Double?

    public init(
        t: Double,
        preset: String,
        intensityLevel: Int,
        imuRollDeg: Double,
        imuPitchDeg: Double,
        correctorRollErrDeg: Double,
        correctorPitchErrDeg: Double,
        balanceState: String,
        correctorDeltas: [Double],
        imuSource: String,
        batteryVolts: Double?,
        motorAvgTemp: Double?,
        balanceAlgorithmMode: String? = nil,
        balanceSignConvention: String? = nil,
        balanceGainProfile: String? = nil,
        correctionAppliedToRobot: Bool? = nil,
        walkCycleElapsedMs: Double? = nil,
        walkPeriodMs: Double? = nil,
        imuSampleAgeMs: Double? = nil,
        expectedPitchDeg: Double? = nil,
        emaPitchDeg: Double? = nil,
        effectivePitchErrDeg: Double? = nil,
        walkPhase01: Double? = nil,
        candidateDeltas: [Double]? = nil,
        appliedDeltas: [Double]? = nil,
        imuSequence: UInt32? = nil,
        busWriteFailureCount: Int? = nil,
        busReadFailureCount: Int? = nil,
        effectiveRollErrDeg: Double? = nil,
        expectedRollDeg: Double? = nil,
        emaRollDeg: Double? = nil
    ) {
        self.t = t
        self.preset = preset
        self.intensityLevel = intensityLevel
        self.imuRollDeg = imuRollDeg
        self.imuPitchDeg = imuPitchDeg
        self.correctorRollErrDeg = correctorRollErrDeg
        self.correctorPitchErrDeg = correctorPitchErrDeg
        self.balanceState = balanceState
        self.correctorDeltas = correctorDeltas
        self.imuSource = imuSource
        self.batteryVolts = batteryVolts
        self.motorAvgTemp = motorAvgTemp
        self.balanceAlgorithmMode = balanceAlgorithmMode
        self.balanceSignConvention = balanceSignConvention
        self.balanceGainProfile = balanceGainProfile
        self.correctionAppliedToRobot = correctionAppliedToRobot
        self.walkCycleElapsedMs = walkCycleElapsedMs
        self.walkPeriodMs = walkPeriodMs
        self.imuSampleAgeMs = imuSampleAgeMs
        self.expectedPitchDeg = expectedPitchDeg
        self.emaPitchDeg = emaPitchDeg
        self.effectivePitchErrDeg = effectivePitchErrDeg
        self.walkPhase01 = walkPhase01
        self.candidateDeltas = candidateDeltas
        self.appliedDeltas = appliedDeltas
        self.imuSequence = imuSequence
        self.busWriteFailureCount = busWriteFailureCount
        self.busReadFailureCount = busReadFailureCount
        self.effectiveRollErrDeg = effectiveRollErrDeg
        self.expectedRollDeg = expectedRollDeg
        self.emaRollDeg = emaRollDeg
    }
}

/// **세션 메타데이터** — 파일 첫 줄 (header).
///
/// **v1.11 (Codex review 2026-05-18 HIGH-2 fix)**: handoff §3 5필드 (algorithm/sign/
/// gain/applyMode + imuSource/scale snapshot + operatorNote/comparisonTag) 도 헤더에
/// 직접 기록. 종전에는 WalkLabSession 에만 mirror 되어 JSONL header 에 안 들어감 →
/// 분석 시 어떤 corrector 설정으로 기록된 session 인지 불명. 이 fix 로 v2 pipeline
/// quality analyzer 가 header 만 보고 정확한 algorithm/sign/gain context 인식.
/// 모든 신규 필드는 Optional (v1 backward-compat).
public struct WalkSessionHeader: Codable, Sendable {
    public let sessionId: String
    public let startTimeIso: String
    public let preset: String
    public let intensityLevelAtStart: Int
    public let appVersion: String
    public let isRealRobot: Bool

    // MARK: - v1.11 (Codex 2026-05-18 HIGH-2) — handoff §3 5필드

    /// algorithmMode rawValue (`off`/`robotisPControl`/`hybridBA`/`observeOnly`).
    public let balanceAlgorithmMode: String?
    /// signConvention rawValue (`robotisWalkingCpp`/`alternateDiagnostic`).
    public let balanceSignConvention: String?
    /// gainProfile rawValue (`robotisOriginal`/`v110Experimental`/`custom`).
    public let balanceGainProfile: String?
    /// 4-state apply mode (`off`/`observeOnly`/`simOnly`/`robotApplied`).
    public let correctionApplyMode: String?
    /// session start 시점 IMU 출처 (`sim`/`real`/`stale`).
    public let imuSourceAtStart: String?
    /// session start 시점 IMU scale 의심 (`normal`/`unknown`/...).
    public let imuScaleSuspicionAtStart: String?
    /// 운영자 메모 (start 시점 snapshot).
    public let operatorNoteAtStart: String?
    /// A/B 비교 tag — `WalkComparisonTag.arm` "A"/"B" 식별.
    public let comparisonTag: WalkComparisonTag?

    public init(
        sessionId: String,
        startTimeIso: String,
        preset: String,
        intensityLevelAtStart: Int,
        appVersion: String,
        isRealRobot: Bool,
        balanceAlgorithmMode: String? = nil,
        balanceSignConvention: String? = nil,
        balanceGainProfile: String? = nil,
        correctionApplyMode: String? = nil,
        imuSourceAtStart: String? = nil,
        imuScaleSuspicionAtStart: String? = nil,
        operatorNoteAtStart: String? = nil,
        comparisonTag: WalkComparisonTag? = nil
    ) {
        self.sessionId = sessionId
        self.startTimeIso = startTimeIso
        self.preset = preset
        self.intensityLevelAtStart = intensityLevelAtStart
        self.appVersion = appVersion
        self.isRealRobot = isRealRobot
        self.balanceAlgorithmMode = balanceAlgorithmMode
        self.balanceSignConvention = balanceSignConvention
        self.balanceGainProfile = balanceGainProfile
        self.correctionApplyMode = correctionApplyMode
        self.imuSourceAtStart = imuSourceAtStart
        self.imuScaleSuspicionAtStart = imuScaleSuspicionAtStart
        self.operatorNoteAtStart = operatorNoteAtStart
        self.comparisonTag = comparisonTag
    }
}

/// **세션 종료 후 분석 결과** — 별도 .summary.json 파일.
public struct WalkSessionSummary: Codable, Sendable, Identifiable {
    public let id: String  // sessionId
    public let preset: String
    public let startTimeIso: String
    public let durationSec: Double
    public let sampleCount: Int
    public let intensityLevelUsed: Int

    /// 평균 |roll| (deg) — 작을수록 안정.
    public let meanAbsRoll: Double
    public let meanAbsPitch: Double
    /// roll 의 standard deviation.
    public let rollStdev: Double
    public let pitchStdev: Double
    /// peak |roll| (deg).
    public let peakAbsRoll: Double
    public let peakAbsPitch: Double

    /// **Oscillation score** — corrector delta 의 zero-crossing rate / sec.
    /// 높을수록 진동 (corrector 가 oscillation 유발 가능성).
    public let oscillationScore: Double

    /// **Corrector 효과 score** — corrector delta vs IMU tilt 의 음의 상관계수.
    /// +1 = 완벽 회복, 0 = 무관, -1 = fall 가속 (반대 부호).
    public let correctorEffectivenessScore: Double

    /// 자동 튜닝 권고 level (0..4). 현재 level 과 같으면 유지.
    public let recommendedIntensityLevel: Int
    /// 권고 이유 (사용자 친화 메시지).
    public let recommendationReason: String

    /// 권고의 신뢰도 (0..1). 낮으면 sample 부족 / 불확실.
    public let confidence: Double
}
