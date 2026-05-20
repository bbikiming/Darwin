import Foundation

/// v2 sample — tick 단위 보행 데이터. line type / schemaVersion / IMU freshness / 보정
/// 컨텍스트를 모두 포함한다.
///
/// 핵심 설계:
/// - `imuSampleAgeMs`, `imuDuplicate`, `imuStale` 로 IMU 신선도 추적.
/// - `candidateDeltas` (계산값) 와 `appliedDeltas` (실제 송출값) 분리. observeOnly
///   에서는 candidate 만 채우고 applied 는 0.
/// - `walkPhase01` 과 `walkCycleElapsedMs` 로 Hybrid 검증의 위상 분석 가능.
/// - raw accel/gyro 는 옵션. 가능하면 저장.
public struct WalkSessionSampleV2: Codable, Equatable, Sendable {
    public let type: String
    public let schemaVersion: Int

    public let tMs: Double
    public let wallTimeIso: String
    public let tickIndex: Int
    public let tickDtMs: Double

    public let preset: String
    public let walkPeriodMs: Double
    public let walkCycleElapsedMs: Double
    public let walkPhase01: Double
    public let plannedStepIndex: Int?

    public let imuSource: String
    public let imuSequence: UInt64?
    public let imuReadAtMs: Double?
    public let imuSampleAgeMs: Double?
    public let imuDuplicate: Bool
    public let imuStale: Bool

    public let rawAccelX: Double?
    public let rawAccelY: Double?
    public let rawAccelZ: Double?
    public let rawGyroX: Double?
    public let rawGyroY: Double?
    public let rawGyroZ: Double?
    public let imuRollDeg: Double
    public let imuPitchDeg: Double

    public let balanceAlgorithmMode: String
    public let balanceSignConvention: String
    public let balanceGainProfile: String
    public let correctionAppliedToRobot: Bool
    public let observeOnly: Bool

    public let expectedPitchDeg: Double?
    public let expectedRollDeg: Double?
    public let emaPitchDeg: Double?
    public let emaRollDeg: Double?
    public let effectivePitchErrDeg: Double
    public let effectiveRollErrDeg: Double

    public let correctorDeltas: [Double]
    public let candidateDeltas: [Double]?
    public let appliedDeltas: [Double]
    public let maxCorrectionDeg: Double

    public let targetPoseLowerBodyDeg: [String: Double]?
    public let appliedPoseLowerBodyDeg: [String: Double]?

    public let balanceState: String
    public let batteryVolts: Double?
    public let motorAvgTemp: Double?
    public let busWriteFailureCount: Int
    public let busReadFailureCount: Int
    public let intensityLevel: Int

    public init(tMs: Double,
                wallTimeIso: String,
                tickIndex: Int,
                tickDtMs: Double,
                preset: String,
                walkPeriodMs: Double,
                walkCycleElapsedMs: Double,
                walkPhase01: Double,
                plannedStepIndex: Int? = nil,
                imuSource: String,
                imuSequence: UInt64? = nil,
                imuReadAtMs: Double? = nil,
                imuSampleAgeMs: Double? = nil,
                imuDuplicate: Bool = false,
                imuStale: Bool = false,
                rawAccelX: Double? = nil,
                rawAccelY: Double? = nil,
                rawAccelZ: Double? = nil,
                rawGyroX: Double? = nil,
                rawGyroY: Double? = nil,
                rawGyroZ: Double? = nil,
                imuRollDeg: Double,
                imuPitchDeg: Double,
                balanceAlgorithmMode: String,
                balanceSignConvention: String,
                balanceGainProfile: String,
                correctionAppliedToRobot: Bool,
                observeOnly: Bool,
                expectedPitchDeg: Double? = nil,
                expectedRollDeg: Double? = nil,
                emaPitchDeg: Double? = nil,
                emaRollDeg: Double? = nil,
                effectivePitchErrDeg: Double,
                effectiveRollErrDeg: Double,
                correctorDeltas: [Double],
                candidateDeltas: [Double]? = nil,
                appliedDeltas: [Double],
                maxCorrectionDeg: Double,
                targetPoseLowerBodyDeg: [String: Double]? = nil,
                appliedPoseLowerBodyDeg: [String: Double]? = nil,
                balanceState: String,
                batteryVolts: Double? = nil,
                motorAvgTemp: Double? = nil,
                busWriteFailureCount: Int = 0,
                busReadFailureCount: Int = 0,
                intensityLevel: Int) {
        self.type = WalkSessionLineType.sample.rawValue
        self.schemaVersion = WalkSessionSchemaVersion.v2.rawValue
        self.tMs = tMs
        self.wallTimeIso = wallTimeIso
        self.tickIndex = tickIndex
        self.tickDtMs = tickDtMs
        self.preset = preset
        self.walkPeriodMs = walkPeriodMs
        self.walkCycleElapsedMs = walkCycleElapsedMs
        self.walkPhase01 = walkPhase01
        self.plannedStepIndex = plannedStepIndex
        self.imuSource = imuSource
        self.imuSequence = imuSequence
        self.imuReadAtMs = imuReadAtMs
        self.imuSampleAgeMs = imuSampleAgeMs
        self.imuDuplicate = imuDuplicate
        self.imuStale = imuStale
        self.rawAccelX = rawAccelX
        self.rawAccelY = rawAccelY
        self.rawAccelZ = rawAccelZ
        self.rawGyroX = rawGyroX
        self.rawGyroY = rawGyroY
        self.rawGyroZ = rawGyroZ
        self.imuRollDeg = imuRollDeg
        self.imuPitchDeg = imuPitchDeg
        self.balanceAlgorithmMode = balanceAlgorithmMode
        self.balanceSignConvention = balanceSignConvention
        self.balanceGainProfile = balanceGainProfile
        self.correctionAppliedToRobot = correctionAppliedToRobot
        self.observeOnly = observeOnly
        self.expectedPitchDeg = expectedPitchDeg
        self.expectedRollDeg = expectedRollDeg
        self.emaPitchDeg = emaPitchDeg
        self.emaRollDeg = emaRollDeg
        self.effectivePitchErrDeg = effectivePitchErrDeg
        self.effectiveRollErrDeg = effectiveRollErrDeg
        self.correctorDeltas = correctorDeltas
        self.candidateDeltas = candidateDeltas
        self.appliedDeltas = appliedDeltas
        self.maxCorrectionDeg = maxCorrectionDeg
        self.targetPoseLowerBodyDeg = targetPoseLowerBodyDeg
        self.appliedPoseLowerBodyDeg = appliedPoseLowerBodyDeg
        self.balanceState = balanceState
        self.batteryVolts = batteryVolts
        self.motorAvgTemp = motorAvgTemp
        self.busWriteFailureCount = busWriteFailureCount
        self.busReadFailureCount = busReadFailureCount
        self.intensityLevel = intensityLevel
    }
}

/// v1 (legacy) sample — 21 개 기존 로그가 사용하는 최소 필드.
public struct WalkSessionSampleV1: Codable, Equatable, Sendable {
    public let t: Double
    public let preset: String?
    public let intensityLevel: Int?
    public let imuRollDeg: Double?
    public let imuPitchDeg: Double?
    public let correctorRollErrDeg: Double?
    public let correctorPitchErrDeg: Double?
    public let balanceState: String?
    public let correctorDeltas: [Double]?
    public let imuSource: String?
    public let batteryVolts: Double?
    public let motorAvgTemp: Double?

    public init(t: Double,
                preset: String? = nil,
                intensityLevel: Int? = nil,
                imuRollDeg: Double? = nil,
                imuPitchDeg: Double? = nil,
                correctorRollErrDeg: Double? = nil,
                correctorPitchErrDeg: Double? = nil,
                balanceState: String? = nil,
                correctorDeltas: [Double]? = nil,
                imuSource: String? = nil,
                batteryVolts: Double? = nil,
                motorAvgTemp: Double? = nil) {
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
    }
}

/// Decoder 가 v1/v2 둘 다 받아서 만드는 공통 in-memory sample. 일부 v2 전용 필드는
/// v1 로그에서 nil 로 채워진다.
public struct WalkSessionSampleResolved: Equatable, Sendable {
    public let schemaVersion: WalkSessionSchemaVersion
    public let tMs: Double
    public let tickIndex: Int?
    public let tickDtMs: Double?

    public let preset: String?
    public let walkPeriodMs: Double?
    public let walkCycleElapsedMs: Double?
    public let walkPhase01: Double?

    public let imuSource: String?
    public let imuSampleAgeMs: Double?
    public let imuDuplicate: Bool
    public let imuStale: Bool
    public let imuRollDeg: Double?
    public let imuPitchDeg: Double?

    public let balanceAlgorithmMode: String?
    public let balanceSignConvention: String?
    public let balanceGainProfile: String?
    public let correctionAppliedToRobot: Bool?
    public let observeOnly: Bool?

    public let expectedPitchDeg: Double?
    public let expectedRollDeg: Double?
    public let emaPitchDeg: Double?
    public let emaRollDeg: Double?
    public let effectivePitchErrDeg: Double?
    public let effectiveRollErrDeg: Double?

    public let correctorDeltas: [Double]?
    public let candidateDeltas: [Double]?
    public let appliedDeltas: [Double]?

    public let balanceState: String?
    public let batteryVolts: Double?
    public let motorAvgTemp: Double?
    public let intensityLevel: Int?
    public let busWriteFailureCount: Int?
    public let busReadFailureCount: Int?

    public init(schemaVersion: WalkSessionSchemaVersion,
                tMs: Double,
                tickIndex: Int? = nil,
                tickDtMs: Double? = nil,
                preset: String? = nil,
                walkPeriodMs: Double? = nil,
                walkCycleElapsedMs: Double? = nil,
                walkPhase01: Double? = nil,
                imuSource: String? = nil,
                imuSampleAgeMs: Double? = nil,
                imuDuplicate: Bool = false,
                imuStale: Bool = false,
                imuRollDeg: Double? = nil,
                imuPitchDeg: Double? = nil,
                balanceAlgorithmMode: String? = nil,
                balanceSignConvention: String? = nil,
                balanceGainProfile: String? = nil,
                correctionAppliedToRobot: Bool? = nil,
                observeOnly: Bool? = nil,
                expectedPitchDeg: Double? = nil,
                expectedRollDeg: Double? = nil,
                emaPitchDeg: Double? = nil,
                emaRollDeg: Double? = nil,
                effectivePitchErrDeg: Double? = nil,
                effectiveRollErrDeg: Double? = nil,
                correctorDeltas: [Double]? = nil,
                candidateDeltas: [Double]? = nil,
                appliedDeltas: [Double]? = nil,
                balanceState: String? = nil,
                batteryVolts: Double? = nil,
                motorAvgTemp: Double? = nil,
                intensityLevel: Int? = nil,
                busWriteFailureCount: Int? = nil,
                busReadFailureCount: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.tMs = tMs
        self.tickIndex = tickIndex
        self.tickDtMs = tickDtMs
        self.preset = preset
        self.walkPeriodMs = walkPeriodMs
        self.walkCycleElapsedMs = walkCycleElapsedMs
        self.walkPhase01 = walkPhase01
        self.imuSource = imuSource
        self.imuSampleAgeMs = imuSampleAgeMs
        self.imuDuplicate = imuDuplicate
        self.imuStale = imuStale
        self.imuRollDeg = imuRollDeg
        self.imuPitchDeg = imuPitchDeg
        self.balanceAlgorithmMode = balanceAlgorithmMode
        self.balanceSignConvention = balanceSignConvention
        self.balanceGainProfile = balanceGainProfile
        self.correctionAppliedToRobot = correctionAppliedToRobot
        self.observeOnly = observeOnly
        self.expectedPitchDeg = expectedPitchDeg
        self.expectedRollDeg = expectedRollDeg
        self.emaPitchDeg = emaPitchDeg
        self.emaRollDeg = emaRollDeg
        self.effectivePitchErrDeg = effectivePitchErrDeg
        self.effectiveRollErrDeg = effectiveRollErrDeg
        self.correctorDeltas = correctorDeltas
        self.candidateDeltas = candidateDeltas
        self.appliedDeltas = appliedDeltas
        self.balanceState = balanceState
        self.batteryVolts = batteryVolts
        self.motorAvgTemp = motorAvgTemp
        self.intensityLevel = intensityLevel
        self.busWriteFailureCount = busWriteFailureCount
        self.busReadFailureCount = busReadFailureCount
    }
}
