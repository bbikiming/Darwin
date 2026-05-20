import Foundation

/// 실행 중인 보행 세션 → v2 JSONL 로 기록하는 facade.
///
/// WalkLabSession 의 tick 에서 호출되며, 다음을 일관되게 처리한다:
/// - 보정 컨텍스트 (algorithm / sign / gain / apply mode) 를 sample 마다 동봉.
/// - IMU duplicate flag 자동 계산 (이전 tick 의 roll/pitch 와 비교).
/// - IMU sample age (호출자가 알면 전달, 모르면 nil).
/// - tick index 자동 증가.
@MainActor
public final class WalkSessionRecorder {
    public struct Context: Sendable {
        public let preset: String
        public let isRealRobot: Bool
        public let supportMode: String?
        public let walkTuning: WalkTuningSnapshot
        public let balanceAlgorithmMode: String
        public let balanceSignConvention: String
        public let balanceGainProfile: String
        public let correctorIntensityLevelAtStart: Int
        public let correctionApplyMode: String
        public let imuSourceAtStart: String
        public let imuScaleSuspicionAtStart: String
        public let safetyPolicy: SafetyPolicySnapshot
        public let appVersion: String
        public let gitCommit: String?
        public let operatorNote: String?
        public let comparisonTag: WalkComparisonTag?

        public init(preset: String,
                    isRealRobot: Bool,
                    supportMode: String? = nil,
                    walkTuning: WalkTuningSnapshot,
                    balanceAlgorithmMode: String,
                    balanceSignConvention: String,
                    balanceGainProfile: String,
                    correctorIntensityLevelAtStart: Int,
                    correctionApplyMode: String,
                    imuSourceAtStart: String,
                    imuScaleSuspicionAtStart: String = "normal",
                    safetyPolicy: SafetyPolicySnapshot = .init(),
                    appVersion: String,
                    gitCommit: String? = nil,
                    operatorNote: String? = nil,
                    comparisonTag: WalkComparisonTag? = nil) {
            self.preset = preset
            self.isRealRobot = isRealRobot
            self.supportMode = supportMode
            self.walkTuning = walkTuning
            self.balanceAlgorithmMode = balanceAlgorithmMode
            self.balanceSignConvention = balanceSignConvention
            self.balanceGainProfile = balanceGainProfile
            self.correctorIntensityLevelAtStart = correctorIntensityLevelAtStart
            self.correctionApplyMode = correctionApplyMode
            self.imuSourceAtStart = imuSourceAtStart
            self.imuScaleSuspicionAtStart = imuScaleSuspicionAtStart
            self.safetyPolicy = safetyPolicy
            self.appVersion = appVersion
            self.gitCommit = gitCommit
            self.operatorNote = operatorNote
            self.comparisonTag = comparisonTag
        }
    }

    public struct TickData: Sendable {
        public let tMs: Double
        public let walkCycleElapsedMs: Double
        public let walkPhase01: Double
        public let imuRollDeg: Double
        public let imuPitchDeg: Double
        public let imuSampleAgeMs: Double?
        public let imuSequence: UInt64?
        public let effectivePitchErrDeg: Double
        public let effectiveRollErrDeg: Double
        public let candidateDeltas: [Double]?
        public let appliedDeltas: [Double]
        public let correctionAppliedToRobot: Bool
        public let observeOnly: Bool
        public let balanceState: String
        public let batteryVolts: Double?
        public let motorAvgTemp: Double?
        public let busWriteFailureCount: Int
        public let busReadFailureCount: Int
        public let intensityLevel: Int
        public let expectedPitchDeg: Double?
        public let expectedRollDeg: Double?
        public let emaPitchDeg: Double?
        public let emaRollDeg: Double?

        public init(tMs: Double,
                    walkCycleElapsedMs: Double,
                    walkPhase01: Double,
                    imuRollDeg: Double,
                    imuPitchDeg: Double,
                    imuSampleAgeMs: Double? = nil,
                    imuSequence: UInt64? = nil,
                    effectivePitchErrDeg: Double,
                    effectiveRollErrDeg: Double,
                    candidateDeltas: [Double]? = nil,
                    appliedDeltas: [Double],
                    correctionAppliedToRobot: Bool,
                    observeOnly: Bool,
                    balanceState: String,
                    batteryVolts: Double? = nil,
                    motorAvgTemp: Double? = nil,
                    busWriteFailureCount: Int = 0,
                    busReadFailureCount: Int = 0,
                    intensityLevel: Int,
                    expectedPitchDeg: Double? = nil,
                    expectedRollDeg: Double? = nil,
                    emaPitchDeg: Double? = nil,
                    emaRollDeg: Double? = nil) {
            self.tMs = tMs
            self.walkCycleElapsedMs = walkCycleElapsedMs
            self.walkPhase01 = walkPhase01
            self.imuRollDeg = imuRollDeg
            self.imuPitchDeg = imuPitchDeg
            self.imuSampleAgeMs = imuSampleAgeMs
            self.imuSequence = imuSequence
            self.effectivePitchErrDeg = effectivePitchErrDeg
            self.effectiveRollErrDeg = effectiveRollErrDeg
            self.candidateDeltas = candidateDeltas
            self.appliedDeltas = appliedDeltas
            self.correctionAppliedToRobot = correctionAppliedToRobot
            self.observeOnly = observeOnly
            self.balanceState = balanceState
            self.batteryVolts = batteryVolts
            self.motorAvgTemp = motorAvgTemp
            self.busWriteFailureCount = busWriteFailureCount
            self.busReadFailureCount = busReadFailureCount
            self.intensityLevel = intensityLevel
            self.expectedPitchDeg = expectedPitchDeg
            self.expectedRollDeg = expectedRollDeg
            self.emaPitchDeg = emaPitchDeg
            self.emaRollDeg = emaRollDeg
        }
    }

    private let logger: WalkSessionLogger
    private var context: Context?
    private var sessionId: String?
    private var startDate: Date?
    private var tickIndex: Int = 0
    private var lastRoll: Double?
    private var lastPitch: Double?

    public init(logger: WalkSessionLogger = WalkSessionLogger()) {
        self.logger = logger
    }

    @discardableResult
    public func startSession(context: Context) -> URL? {
        let now = Date()
        let sid = WalkSessionClock.sessionId(now)
        let header = WalkSessionHeaderV2(
            sessionId: sid,
            startTimeIso: WalkSessionClock.iso8601(now),
            appVersion: context.appVersion,
            gitCommit: context.gitCommit,
            isRealRobot: context.isRealRobot,
            operatorNote: context.operatorNote,
            supportMode: context.supportMode,
            preset: context.preset,
            walkTuning: context.walkTuning,
            balanceAlgorithmMode: context.balanceAlgorithmMode,
            balanceSignConvention: context.balanceSignConvention,
            balanceGainProfile: context.balanceGainProfile,
            correctorIntensityLevelAtStart: context.correctorIntensityLevelAtStart,
            correctionApplyMode: context.correctionApplyMode,
            imuSourceAtStart: context.imuSourceAtStart,
            imuScaleSuspicionAtStart: context.imuScaleSuspicionAtStart,
            safetyPolicy: context.safetyPolicy,
            comparisonTag: context.comparisonTag
        )
        self.context = context
        self.sessionId = sid
        self.startDate = now
        self.tickIndex = 0
        self.lastRoll = nil
        self.lastPitch = nil
        return try? logger.open(header: header)
    }

    public func recordTick(_ data: TickData) {
        guard let ctx = context else { return }
        let duplicate = (lastRoll == data.imuRollDeg && lastPitch == data.imuPitchDeg)
        let stale = (data.imuSampleAgeMs ?? 0) > 250
        let sample = WalkSessionSampleV2(
            tMs: data.tMs,
            wallTimeIso: WalkSessionClock.iso8601(Date()),
            tickIndex: tickIndex,
            tickDtMs: 50,
            preset: ctx.preset,
            walkPeriodMs: ctx.walkTuning.periodMs,
            walkCycleElapsedMs: data.walkCycleElapsedMs,
            walkPhase01: data.walkPhase01,
            imuSource: ctx.imuSourceAtStart,
            imuSequence: data.imuSequence,
            imuReadAtMs: data.imuSampleAgeMs.map { _ in data.tMs },
            imuSampleAgeMs: data.imuSampleAgeMs,
            imuDuplicate: duplicate,
            imuStale: stale,
            imuRollDeg: data.imuRollDeg,
            imuPitchDeg: data.imuPitchDeg,
            balanceAlgorithmMode: ctx.balanceAlgorithmMode,
            balanceSignConvention: ctx.balanceSignConvention,
            balanceGainProfile: ctx.balanceGainProfile,
            correctionAppliedToRobot: data.correctionAppliedToRobot,
            observeOnly: data.observeOnly,
            expectedPitchDeg: data.expectedPitchDeg,
            expectedRollDeg: data.expectedRollDeg,
            emaPitchDeg: data.emaPitchDeg,
            emaRollDeg: data.emaRollDeg,
            effectivePitchErrDeg: data.effectivePitchErrDeg,
            effectiveRollErrDeg: data.effectiveRollErrDeg,
            correctorDeltas: data.appliedDeltas,
            candidateDeltas: data.candidateDeltas,
            appliedDeltas: data.appliedDeltas,
            maxCorrectionDeg: 15,
            balanceState: data.balanceState,
            batteryVolts: data.batteryVolts,
            motorAvgTemp: data.motorAvgTemp,
            busWriteFailureCount: data.busWriteFailureCount,
            busReadFailureCount: data.busReadFailureCount,
            intensityLevel: data.intensityLevel
        )
        logger.write(sample)
        tickIndex += 1
        lastRoll = data.imuRollDeg
        lastPitch = data.imuPitchDeg
    }

    public func recordEvent(kind: WalkSessionEventKind,
                            severity: WalkSessionEventSeverity = .info,
                            message: String,
                            payload: [String: String] = [:]) {
        let event = WalkSessionEventV2(
            tMs: elapsedMs(),
            wallTimeIso: WalkSessionClock.iso8601(Date()),
            kind: kind.rawValue,
            severity: severity.rawValue,
            message: message,
            payload: payload
        )
        logger.write(event)
    }

    @discardableResult
    public func stopSession(endReason: String = "userStop",
                            endedNormally: Bool = true) -> URL? {
        let url = logger.fileURL
        logger.close(reason: endReason, endedNormally: endedNormally)
        context = nil
        sessionId = nil
        startDate = nil
        return url
    }

    /// 외부에서 sessionId 가 필요할 때 — UI 표시 등.
    public var currentSessionId: String? { sessionId }

    public var fileURL: URL? { logger.fileURL }

    private func elapsedMs() -> Double {
        guard let start = startDate else { return 0 }
        return Date().timeIntervalSince(start) * 1000.0
    }
}
