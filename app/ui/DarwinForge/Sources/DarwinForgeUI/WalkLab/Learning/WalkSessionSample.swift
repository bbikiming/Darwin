import Foundation

/// **v1.11.25 (2026-05-21) — FSR (foot pressure) sample 형식**.
///
/// `ForgeCore.FsrReading` 의 compact JSON 형태. JSON key 약어 (fl/fr/rr/rl/x/y) — 60 bytes/foot.
public struct FsrSampleSnapshot: Codable, Sendable, Equatable {
    /// front-left cell pressure (0..1023).
    public let fl: UInt16
    public let fr: UInt16
    public let rr: UInt16
    public let rl: UInt16
    /// 중심점 X (-127..127). 0 = 발 중앙.
    public let x: Int8
    /// 중심점 Y (-127..127).
    public let y: Int8

    public init(fl: UInt16, fr: UInt16, rr: UInt16, rl: UInt16, x: Int8, y: Int8) {
        self.fl = fl; self.fr = fr; self.rr = rr; self.rl = rl; self.x = x; self.y = y
    }

    /// 4 cell 합 — 발 total 압력 (raw).
    public var totalPressure: UInt32 {
        UInt32(fl) + UInt32(fr) + UInt32(rr) + UInt32(rl)
    }
}

/// **v1.11.25 (2026-05-20) — 개별 관절 측정값 스냅샷**.
///
/// `ConnectionStore.lastTelemetry.joints` 의 `JointState` 를 sample 에 dump 하기 위한
/// compact 표현. JSON key 약어 (g/a/sp/l/t/v/te) — 18 관절 × 7 필드 = ~9 KB/tick 인데
/// 약어로 ~6 KB 까지 줄어듦. 매 tick 전체 저장은 size 폭증이므로 telemetry tick 도착 시
/// (≈5 Hz USB / 2 Hz network) 만 채움 — 그 외 tick 은 `WalkSessionSample.jointStates = nil`.
public struct JointStateSnapshot: Codable, Sendable, Equatable {
    /// goal position (Dynamixel raw 0..4095).
    public let g: UInt16
    /// actual present position (Dynamixel raw).
    public let a: UInt16
    /// present speed raw.
    public let sp: UInt16
    /// present load raw (UInt16).
    public let l: UInt16
    /// present temperature (°C).
    public let t: UInt8
    /// present voltage raw (0.1V units — voltageVolts = v * 0.1).
    public let v: UInt8
    /// torque enabled.
    public let te: Bool

    public init(g: UInt16, a: UInt16, sp: UInt16, l: UInt16, t: UInt8, v: UInt8, te: Bool) {
        self.g = g; self.a = a; self.sp = sp; self.l = l; self.t = t; self.v = v; self.te = te
    }

    /// tracking error 직접 계산 helper (deg = (a - g) * 360/4096).
    public var trackingErrorRawSteps: Int { Int(a) - Int(g) }
}

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

    // MARK: - v1.11.25 (2026-05-20) — 로봇 측 실측 데이터
    //
    // 종전 한계: `appendSessionSampleIfLogging` 가 `ConnectionStore.lastTelemetry.board`
    // 와 `avgTemperature` 만 dump → 개별 18 관절 / IMU raw 6축 / per-joint failure /
    // RTT / button state 모두 메모리에는 있지만 disk 휘발. 사후 tracking error / 부하
    // 비대칭 / IMU plausibility / failure-precursor 분석 불가.
    //
    // fix (audit P0 robot-A/B/C/E/F): 메모리 보유 데이터를 sparse 하게 dump.
    // - jointStates: telemetry tick 새 도착 시에만 (≈5Hz/2Hz) — main IMU tick (20Hz) 보다 적음
    // - rawGyro/Accel: 매 tick 채움 (sample-level 20Hz)
    // - jointFailuresDelta: 이전 tick 대비 변화한 joint 만 sparse
    // - busRttMs / boardButton: 매 tick 채움 (값이 같으면 reader 가 dedup 가능)

    /// 18 관절 개별 측정 — key=`JointID.rawValue` (예: `"rHipRoll"`). `nil` = telemetry
    /// tick 이 이 sample 이전엔 같은 dataset 이라 새 데이터 없음 (size 절약).
    public let jointStates: [String: JointStateSnapshot]?

    /// IMU raw — 20Hz cadence 로 모두 채움. nil = sim 또는 IMU read 실패.
    public let rawGyroXDps: Double?
    public let rawGyroYDps: Double?
    public let rawGyroZDps: Double?
    public let rawAccelXG: Double?
    public let rawAccelYG: Double?
    public let rawAccelZG: Double?

    /// 이전 sample 대비 새로 누적된 per-joint timeout count — sparse. 변화 없으면 nil.
    public let jointFailuresDelta: [String: Int]?

    /// board read round-trip latency (ms). board 는 ≈1Hz 라 4 tick stale 가능.
    public let busRttMs: Double?

    /// CM-740 board button raw byte (register 30). 0 외 값 = 사용자 버튼 입력.
    /// nil = telemetry 미수신.
    public let boardButton: UInt8?

    // v1.11.25 audit P0 robot-D — FSR (foot pressure) snapshot.
    /// 좌측 발 FSR — board ID 112. nil = board 미장착 또는 read 실패 / sparse cadence.
    public let fsrLeft: FsrSampleSnapshot?
    /// 우측 발 FSR — board ID 111.
    public let fsrRight: FsrSampleSnapshot?

    // v1.11.25 audit P1 log-H — fall predictor score 시계열.
    /// FallPredictor.Prediction.score (0..1, 1 = 임박). nil = predictor 미사용 / disabled.
    public let fallScore: Double?
    /// fall predictor 가 recommend emergency 인가.
    public let fallRecommendEmergency: Bool?

    // MARK: - Phase 1 fall-recovery telemetry fields (backward-compat optional)

    /// 현재 auto-recovery 진행 단계 rawValue 문자열.
    /// nil = 기록 없음 (legacy 또는 session 시작 전). 분석: 낙하 발생 전후 timeline.
    public let autoRecoveryPhase: String?
    /// 낙하 방향 rawValue (`"forward"` / `"backward"`). nil = 낙하 감지 안 됨.
    public let fallDirection: String?
    /// 이 tick 에 "최근 5s 내 pilot 명령" latch 가 활성 상태였는가 (M4 gate).
    /// nil = 기록 없음 (legacy).
    public let recentlyPiloting: Bool?
    /// 이 tick 의 다리 관절 presentLoad 최대값 (JointStateSnapshot.l 기준).
    /// 낙하 직전 하체 부하 특성 분석. nil = joint telemetry 미수신 또는 기록 없음.
    public let peakLegLoad: Double?

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
        emaRollDeg: Double? = nil,
        // v1.11.25 audit robot-A/B/C/E/F
        jointStates: [String: JointStateSnapshot]? = nil,
        rawGyroXDps: Double? = nil,
        rawGyroYDps: Double? = nil,
        rawGyroZDps: Double? = nil,
        rawAccelXG: Double? = nil,
        rawAccelYG: Double? = nil,
        rawAccelZG: Double? = nil,
        jointFailuresDelta: [String: Int]? = nil,
        busRttMs: Double? = nil,
        boardButton: UInt8? = nil,
        // v1.11.25 audit P0 robot-D
        fsrLeft: FsrSampleSnapshot? = nil,
        fsrRight: FsrSampleSnapshot? = nil,
        // v1.11.25 audit P1 log-H
        fallScore: Double? = nil,
        fallRecommendEmergency: Bool? = nil,
        // Phase 1 fall-recovery telemetry
        autoRecoveryPhase: String? = nil,
        fallDirection: String? = nil,
        recentlyPiloting: Bool? = nil,
        peakLegLoad: Double? = nil
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
        // v1.11.25 audit robot-A/B/C/E/F
        self.jointStates = jointStates
        self.rawGyroXDps = rawGyroXDps
        self.rawGyroYDps = rawGyroYDps
        self.rawGyroZDps = rawGyroZDps
        self.rawAccelXG = rawAccelXG
        self.rawAccelYG = rawAccelYG
        self.rawAccelZG = rawAccelZG
        self.jointFailuresDelta = jointFailuresDelta
        self.busRttMs = busRttMs
        self.boardButton = boardButton
        // v1.11.25 audit P0 robot-D
        self.fsrLeft = fsrLeft
        self.fsrRight = fsrRight
        // v1.11.25 audit P1 log-H
        self.fallScore = fallScore
        self.fallRecommendEmergency = fallRecommendEmergency
        // Phase 1 fall-recovery telemetry
        self.autoRecoveryPhase = autoRecoveryPhase
        self.fallDirection = fallDirection
        self.recentlyPiloting = recentlyPiloting
        self.peakLegLoad = peakLegLoad
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

    // MARK: - v1.11.10 (2026-05-19) — V2 schema: 8 axis 전부 + tuning + experiment context

    /// `WalkingEngine` rawValue (`macSparseKeyframe` / `robotisOnboard`).
    public let walkingEngine: String?
    /// `BalancePitchInputConvention` rawValue (`imuRaw` / `negateForwardIsNegative`).
    public let pitchInputConvention: String?
    /// `enableBalanceCorrection` 세션 시작 시점 값.
    public let enableBalanceCorrectionAtStart: Bool?
    /// `autoOnboardBrokering` 세션 시작 시점 값 (`.robotisOnboard` 일 때만 의미).
    public let autoOnboardBrokeringAtStart: Bool?
    /// `hipPitchOffsetTrimDeg` 세션 시작 시점 값 (0~20°, default 13).
    public let hipPitchOffsetTrimDegAtStart: Double?
    /// 6 tuning slider 값 (advanced ON 시 사용자 지정).
    public let tuningStrideMm: Double?
    public let tuningSideMm: Double?
    public let tuningTurnDeg: Double?
    public let tuningPeriodMs: Double?
    public let tuningFootHeightMm: Double?
    public let tuningBalanceGain: Double?
    /// Custom gain (gainProfile=.custom 일 때만).
    public let customGainHipRoll: Double?
    public let customGainKnee: Double?
    public let customGainAnklePitch: Double?
    public let customGainAnkleRoll: Double?
    /// Robot context — 재현성.
    public let robotModel: String?
    public let firmwareVersion: String?
    public let onboardPatchVersion: String?
    /// A/B 실험 — `WalkLabExperimentLoop` 에서 사용.
    public let experimentId: String?
    public let baselineSessionId: String?

    // MARK: - v1.11.24 (2026-05-20) audit P1-2 — start-state diagnostic fields
    //
    // 종전 한계: header 만 보고 "왜 이 세션이 짧게 끝났는지", "사용자가 클릭한 preset 이
    // 무엇인지" 알 수 없었음. audit §1 mixed-preset 버그를 사후 분석할 수 있도록
    // start-time snapshot 을 명시.

    /// 마지막 `start(_:)` 호출에서 사용자가 요청한 preset rawValue.
    /// `preset` 과 다르면 (예: 사용자가 fastWalk 요청했지만 preflight 차단되어 march 가 active
    /// 유지) UI 와 로그 사이의 mismatch 흔적 — 사용자/엔지니어 진단에 결정적.
    public let requestedPreset: String?

    /// preflight 차단 사유 (`WalkPreflightFailure.diagnosticCode`). nil = preflight 통과.
    public let startBlockedReason: String?

    /// session 시작 시점에 다른 walkCycleTask 가 active 였는지. true 면 audit §1 race 케이스.
    public let walkCycleTaskActiveAtStart: Bool?

    /// 첫 motor write 가 성공했는지 (적어도 한 번 setPosition 가 nominal 성공).
    /// true 이지만 sampleCount 가 적으면 cycle 중간에 끊김 — bus disconnect 의심.
    public let motorWriteStarted: Bool?

    /// 누적 motor write step 수. footer 직전에 logger 가 close 직전에 갱신.
    public let motorWriteStepCount: Int?

    /// ROBOTIS Onboard ACK 상태 (`ok` / `no_ack` / `timeout` / `error: ...`).
    /// macSparseKeyframe 모드에서는 nil.
    public let onboardAckStatus: String?

    /// session 시작 시점의 마지막 robot event 텍스트 (UI 토스트). 디버깅 용.
    public let lastRobotEventAtStart: String?

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
        comparisonTag: WalkComparisonTag? = nil,
        // v1.11.10 V2
        walkingEngine: String? = nil,
        pitchInputConvention: String? = nil,
        enableBalanceCorrectionAtStart: Bool? = nil,
        autoOnboardBrokeringAtStart: Bool? = nil,
        hipPitchOffsetTrimDegAtStart: Double? = nil,
        tuningStrideMm: Double? = nil,
        tuningSideMm: Double? = nil,
        tuningTurnDeg: Double? = nil,
        tuningPeriodMs: Double? = nil,
        tuningFootHeightMm: Double? = nil,
        tuningBalanceGain: Double? = nil,
        customGainHipRoll: Double? = nil,
        customGainKnee: Double? = nil,
        customGainAnklePitch: Double? = nil,
        customGainAnkleRoll: Double? = nil,
        robotModel: String? = nil,
        firmwareVersion: String? = nil,
        onboardPatchVersion: String? = nil,
        experimentId: String? = nil,
        baselineSessionId: String? = nil,
        // v1.11.24 audit P1-2
        requestedPreset: String? = nil,
        startBlockedReason: String? = nil,
        walkCycleTaskActiveAtStart: Bool? = nil,
        motorWriteStarted: Bool? = nil,
        motorWriteStepCount: Int? = nil,
        onboardAckStatus: String? = nil,
        lastRobotEventAtStart: String? = nil
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
        self.walkingEngine = walkingEngine
        self.pitchInputConvention = pitchInputConvention
        self.enableBalanceCorrectionAtStart = enableBalanceCorrectionAtStart
        self.autoOnboardBrokeringAtStart = autoOnboardBrokeringAtStart
        self.hipPitchOffsetTrimDegAtStart = hipPitchOffsetTrimDegAtStart
        self.tuningStrideMm = tuningStrideMm
        self.tuningSideMm = tuningSideMm
        self.tuningTurnDeg = tuningTurnDeg
        self.tuningPeriodMs = tuningPeriodMs
        self.tuningFootHeightMm = tuningFootHeightMm
        self.tuningBalanceGain = tuningBalanceGain
        self.customGainHipRoll = customGainHipRoll
        self.customGainKnee = customGainKnee
        self.customGainAnklePitch = customGainAnklePitch
        self.customGainAnkleRoll = customGainAnkleRoll
        self.robotModel = robotModel
        self.firmwareVersion = firmwareVersion
        self.onboardPatchVersion = onboardPatchVersion
        self.experimentId = experimentId
        self.baselineSessionId = baselineSessionId
        // v1.11.24 audit P1-2
        self.requestedPreset = requestedPreset
        self.startBlockedReason = startBlockedReason
        self.walkCycleTaskActiveAtStart = walkCycleTaskActiveAtStart
        self.motorWriteStarted = motorWriteStarted
        self.motorWriteStepCount = motorWriteStepCount
        self.onboardAckStatus = onboardAckStatus
        self.lastRobotEventAtStart = lastRobotEventAtStart
    }

    // MARK: - Backward-compat decode (v1.11.9 이전 jsonl 호환)
    private enum CodingKeys: String, CodingKey {
        case sessionId, startTimeIso, preset, intensityLevelAtStart, appVersion, isRealRobot
        case balanceAlgorithmMode, balanceSignConvention, balanceGainProfile, correctionApplyMode
        case imuSourceAtStart, imuScaleSuspicionAtStart, operatorNoteAtStart, comparisonTag
        case walkingEngine, pitchInputConvention, enableBalanceCorrectionAtStart
        case autoOnboardBrokeringAtStart, hipPitchOffsetTrimDegAtStart
        case tuningStrideMm, tuningSideMm, tuningTurnDeg, tuningPeriodMs
        case tuningFootHeightMm, tuningBalanceGain
        case customGainHipRoll, customGainKnee, customGainAnklePitch, customGainAnkleRoll
        case robotModel, firmwareVersion, onboardPatchVersion
        case experimentId, baselineSessionId
        // v1.11.24 audit P1-2
        case requestedPreset, startBlockedReason, walkCycleTaskActiveAtStart
        case motorWriteStarted, motorWriteStepCount, onboardAckStatus, lastRobotEventAtStart
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.startTimeIso = try c.decode(String.self, forKey: .startTimeIso)
        self.preset = try c.decode(String.self, forKey: .preset)
        self.intensityLevelAtStart = try c.decode(Int.self, forKey: .intensityLevelAtStart)
        self.appVersion = try c.decode(String.self, forKey: .appVersion)
        self.isRealRobot = try c.decode(Bool.self, forKey: .isRealRobot)
        self.balanceAlgorithmMode = try c.decodeIfPresent(String.self, forKey: .balanceAlgorithmMode)
        self.balanceSignConvention = try c.decodeIfPresent(String.self, forKey: .balanceSignConvention)
        self.balanceGainProfile = try c.decodeIfPresent(String.self, forKey: .balanceGainProfile)
        self.correctionApplyMode = try c.decodeIfPresent(String.self, forKey: .correctionApplyMode)
        self.imuSourceAtStart = try c.decodeIfPresent(String.self, forKey: .imuSourceAtStart)
        self.imuScaleSuspicionAtStart = try c.decodeIfPresent(String.self, forKey: .imuScaleSuspicionAtStart)
        self.operatorNoteAtStart = try c.decodeIfPresent(String.self, forKey: .operatorNoteAtStart)
        self.comparisonTag = try c.decodeIfPresent(WalkComparisonTag.self, forKey: .comparisonTag)
        self.walkingEngine = try c.decodeIfPresent(String.self, forKey: .walkingEngine)
        self.pitchInputConvention = try c.decodeIfPresent(String.self, forKey: .pitchInputConvention)
        self.enableBalanceCorrectionAtStart = try c.decodeIfPresent(Bool.self, forKey: .enableBalanceCorrectionAtStart)
        self.autoOnboardBrokeringAtStart = try c.decodeIfPresent(Bool.self, forKey: .autoOnboardBrokeringAtStart)
        self.hipPitchOffsetTrimDegAtStart = try c.decodeIfPresent(Double.self, forKey: .hipPitchOffsetTrimDegAtStart)
        self.tuningStrideMm = try c.decodeIfPresent(Double.self, forKey: .tuningStrideMm)
        self.tuningSideMm = try c.decodeIfPresent(Double.self, forKey: .tuningSideMm)
        self.tuningTurnDeg = try c.decodeIfPresent(Double.self, forKey: .tuningTurnDeg)
        self.tuningPeriodMs = try c.decodeIfPresent(Double.self, forKey: .tuningPeriodMs)
        self.tuningFootHeightMm = try c.decodeIfPresent(Double.self, forKey: .tuningFootHeightMm)
        self.tuningBalanceGain = try c.decodeIfPresent(Double.self, forKey: .tuningBalanceGain)
        self.customGainHipRoll = try c.decodeIfPresent(Double.self, forKey: .customGainHipRoll)
        self.customGainKnee = try c.decodeIfPresent(Double.self, forKey: .customGainKnee)
        self.customGainAnklePitch = try c.decodeIfPresent(Double.self, forKey: .customGainAnklePitch)
        self.customGainAnkleRoll = try c.decodeIfPresent(Double.self, forKey: .customGainAnkleRoll)
        self.robotModel = try c.decodeIfPresent(String.self, forKey: .robotModel)
        self.firmwareVersion = try c.decodeIfPresent(String.self, forKey: .firmwareVersion)
        self.onboardPatchVersion = try c.decodeIfPresent(String.self, forKey: .onboardPatchVersion)
        self.experimentId = try c.decodeIfPresent(String.self, forKey: .experimentId)
        self.baselineSessionId = try c.decodeIfPresent(String.self, forKey: .baselineSessionId)
        // v1.11.24 audit P1-2 — 모두 Optional + decodeIfPresent (이전 jsonl backward-compat).
        self.requestedPreset = try c.decodeIfPresent(String.self, forKey: .requestedPreset)
        self.startBlockedReason = try c.decodeIfPresent(String.self, forKey: .startBlockedReason)
        self.walkCycleTaskActiveAtStart = try c.decodeIfPresent(Bool.self, forKey: .walkCycleTaskActiveAtStart)
        self.motorWriteStarted = try c.decodeIfPresent(Bool.self, forKey: .motorWriteStarted)
        self.motorWriteStepCount = try c.decodeIfPresent(Int.self, forKey: .motorWriteStepCount)
        self.onboardAckStatus = try c.decodeIfPresent(String.self, forKey: .onboardAckStatus)
        self.lastRobotEventAtStart = try c.decodeIfPresent(String.self, forKey: .lastRobotEventAtStart)
    }
}

/// **v1.11.24 (2026-05-20) audit iter2-H** — JSONL 마지막 줄 footer.
///
/// 종전 한계: `WalkSessionHeader` 는 session 시작 시점에 한 번만 write → motorWriteStarted /
/// motorWriteStepCount / onboardAckStatus 같은 종료-시점 진단 필드를 기록할 수 없었음
/// (header 가 immutable). audit P1-2 가 요구한 이 세 필드가 실 disk 에 항상 nil 로 남는 버그.
///
/// fix: `WalkSessionLogger.close(...)` 가 footer 객체를 마지막 sample 뒤에 한 줄 append.
/// Decoder 는 마지막 줄에 `type: "footer"` 가 있으면 footer 로 처리 — 기존 v1.11.x jsonl
/// 은 footer 없이도 decode 됨 (모든 필드 Optional).
public struct WalkSessionFooter: Codable, Sendable {
    /// JSONL 줄 구분자 — `"footer"`. WalkSessionSample 과 같은 line 에 들어가지 않도록 marker.
    public let type: String
    public let closedAtIso: String
    public let totalSampleCount: Int
    public let motorWriteStarted: Bool?
    public let motorWriteStepCount: Int?
    public let onboardAckStatus: String?
    /// 종료 사유 — `userStop` / `emergencyStop` / `presetMaxDuration` / `cycleEnded` / `unknown`.
    public let endReason: String?

    public init(closedAtIso: String,
                totalSampleCount: Int,
                motorWriteStarted: Bool?,
                motorWriteStepCount: Int?,
                onboardAckStatus: String?,
                endReason: String?) {
        self.type = "footer"
        self.closedAtIso = closedAtIso
        self.totalSampleCount = totalSampleCount
        self.motorWriteStarted = motorWriteStarted
        self.motorWriteStepCount = motorWriteStepCount
        self.onboardAckStatus = onboardAckStatus
        self.endReason = endReason
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

    // MARK: - v1.11.10 (2026-05-19) — V2 분석 metric

    /// 데이터 품질 보고. nil = legacy summary (v1.11.9 이전).
    public let dataQuality: DataQualityReport?
    /// Sagittal (앞기울) 분석 metric. nil = legacy summary.
    public let sagittal: SagittalMetric?
    /// Candidate vs applied delta 분리 통계. nil = legacy summary.
    public let candidateApplied: CandidateAppliedSplit?

    // MARK: - 데이터 기반 자동 튜닝 (2026-05-30) — 균형 안정성 파라미터 권고 (tau/D항)

    /// 본 세션에서 사용된 자이로 D항(s). 권고 방향 산출 기준. nil = legacy.
    public let derivativeTimeSecUsed: Double?
    /// 권고 D항(s). used 와 다르면 변경 권고. nil = legacy/미산출.
    public let recommendedDerivativeTimeSec: Double?
    /// 본 세션에서 사용된 baseline tau(s). nil = legacy.
    public let baselineTauSecUsed: Double?
    /// 권고 baseline tau(s). nil = legacy/미산출.
    public let recommendedBaselineTauSec: Double?
    /// 안정성 권고 이유 (D항 + tau 결합 메시지). nil = legacy.
    public let stabilityRecommendationReason: String?
    /// 안정성 권고 신뢰도 (0..1). nil = legacy.
    public let stabilityConfidence: Double?
    /// caution 이상 상태 비율 (0..1) — 불안정 corroboration. nil = legacy.
    public let cautionRatio: Double?

    public init(
        id: String, preset: String, startTimeIso: String,
        durationSec: Double, sampleCount: Int, intensityLevelUsed: Int,
        meanAbsRoll: Double, meanAbsPitch: Double,
        rollStdev: Double, pitchStdev: Double,
        peakAbsRoll: Double, peakAbsPitch: Double,
        oscillationScore: Double, correctorEffectivenessScore: Double,
        recommendedIntensityLevel: Int, recommendationReason: String,
        confidence: Double,
        dataQuality: DataQualityReport? = nil,
        sagittal: SagittalMetric? = nil,
        candidateApplied: CandidateAppliedSplit? = nil,
        derivativeTimeSecUsed: Double? = nil,
        recommendedDerivativeTimeSec: Double? = nil,
        baselineTauSecUsed: Double? = nil,
        recommendedBaselineTauSec: Double? = nil,
        stabilityRecommendationReason: String? = nil,
        stabilityConfidence: Double? = nil,
        cautionRatio: Double? = nil
    ) {
        self.id = id
        self.preset = preset
        self.startTimeIso = startTimeIso
        self.durationSec = durationSec
        self.sampleCount = sampleCount
        self.intensityLevelUsed = intensityLevelUsed
        self.meanAbsRoll = meanAbsRoll
        self.meanAbsPitch = meanAbsPitch
        self.rollStdev = rollStdev
        self.pitchStdev = pitchStdev
        self.peakAbsRoll = peakAbsRoll
        self.peakAbsPitch = peakAbsPitch
        self.oscillationScore = oscillationScore
        self.correctorEffectivenessScore = correctorEffectivenessScore
        self.recommendedIntensityLevel = recommendedIntensityLevel
        self.recommendationReason = recommendationReason
        self.confidence = confidence
        self.dataQuality = dataQuality
        self.sagittal = sagittal
        self.candidateApplied = candidateApplied
        self.derivativeTimeSecUsed = derivativeTimeSecUsed
        self.recommendedDerivativeTimeSec = recommendedDerivativeTimeSec
        self.baselineTauSecUsed = baselineTauSecUsed
        self.recommendedBaselineTauSec = recommendedBaselineTauSec
        self.stabilityRecommendationReason = stabilityRecommendationReason
        self.stabilityConfidence = stabilityConfidence
        self.cautionRatio = cautionRatio
    }

    // MARK: - Backward-compat decode (v1.11.9 이전 .summary.json 호환)
    private enum CodingKeys: String, CodingKey {
        case id, preset, startTimeIso, durationSec, sampleCount, intensityLevelUsed
        case meanAbsRoll, meanAbsPitch, rollStdev, pitchStdev, peakAbsRoll, peakAbsPitch
        case oscillationScore, correctorEffectivenessScore
        case recommendedIntensityLevel, recommendationReason, confidence
        case dataQuality, sagittal, candidateApplied
        case derivativeTimeSecUsed, recommendedDerivativeTimeSec
        case baselineTauSecUsed, recommendedBaselineTauSec
        case stabilityRecommendationReason, stabilityConfidence, cautionRatio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.preset = try c.decode(String.self, forKey: .preset)
        self.startTimeIso = try c.decode(String.self, forKey: .startTimeIso)
        self.durationSec = try c.decode(Double.self, forKey: .durationSec)
        self.sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        self.intensityLevelUsed = try c.decode(Int.self, forKey: .intensityLevelUsed)
        self.meanAbsRoll = try c.decode(Double.self, forKey: .meanAbsRoll)
        self.meanAbsPitch = try c.decode(Double.self, forKey: .meanAbsPitch)
        self.rollStdev = try c.decode(Double.self, forKey: .rollStdev)
        self.pitchStdev = try c.decode(Double.self, forKey: .pitchStdev)
        self.peakAbsRoll = try c.decode(Double.self, forKey: .peakAbsRoll)
        self.peakAbsPitch = try c.decode(Double.self, forKey: .peakAbsPitch)
        self.oscillationScore = try c.decode(Double.self, forKey: .oscillationScore)
        self.correctorEffectivenessScore = try c.decode(Double.self, forKey: .correctorEffectivenessScore)
        self.recommendedIntensityLevel = try c.decode(Int.self, forKey: .recommendedIntensityLevel)
        self.recommendationReason = try c.decode(String.self, forKey: .recommendationReason)
        self.confidence = try c.decode(Double.self, forKey: .confidence)
        self.dataQuality = try c.decodeIfPresent(DataQualityReport.self, forKey: .dataQuality)
        self.sagittal = try c.decodeIfPresent(SagittalMetric.self, forKey: .sagittal)
        self.candidateApplied = try c.decodeIfPresent(CandidateAppliedSplit.self, forKey: .candidateApplied)
        self.derivativeTimeSecUsed = try c.decodeIfPresent(Double.self, forKey: .derivativeTimeSecUsed)
        self.recommendedDerivativeTimeSec = try c.decodeIfPresent(Double.self, forKey: .recommendedDerivativeTimeSec)
        self.baselineTauSecUsed = try c.decodeIfPresent(Double.self, forKey: .baselineTauSecUsed)
        self.recommendedBaselineTauSec = try c.decodeIfPresent(Double.self, forKey: .recommendedBaselineTauSec)
        self.stabilityRecommendationReason = try c.decodeIfPresent(String.self, forKey: .stabilityRecommendationReason)
        self.stabilityConfidence = try c.decodeIfPresent(Double.self, forKey: .stabilityConfidence)
        self.cautionRatio = try c.decodeIfPresent(Double.self, forKey: .cautionRatio)
    }
}
