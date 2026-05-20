import Foundation

/// 워크 튜닝 스냅샷 — 세션 시작 시점의 walking parameters.
public struct WalkTuningSnapshot: Codable, Equatable, Sendable {
    public let periodMs: Double
    public let xStrideM: Double
    public let yStrideM: Double
    public let aTurnRad: Double
    public let footHeightMm: Double?
    public let balanceGain: Double?

    public init(periodMs: Double,
                xStrideM: Double,
                yStrideM: Double,
                aTurnRad: Double,
                footHeightMm: Double? = nil,
                balanceGain: Double? = nil) {
        self.periodMs = periodMs
        self.xStrideM = xStrideM
        self.yStrideM = yStrideM
        self.aTurnRad = aTurnRad
        self.footHeightMm = footHeightMm
        self.balanceGain = balanceGain
    }
}

/// 안전 정책 스냅샷 — emergency thresholds, 자동 정지 조건.
public struct SafetyPolicySnapshot: Codable, Equatable, Sendable {
    public let maxTiltDeg: Double
    public let maxMotorTempC: Double
    public let cradleRequired: Bool
    public let highRiskAcknowledged: Bool

    public init(maxTiltDeg: Double = 30,
                maxMotorTempC: Double = 60,
                cradleRequired: Bool = true,
                highRiskAcknowledged: Bool = false) {
        self.maxTiltDeg = maxTiltDeg
        self.maxMotorTempC = maxMotorTempC
        self.cradleRequired = cradleRequired
        self.highRiskAcknowledged = highRiskAcknowledged
    }
}

/// Walk session header — v2.
///
/// v2 는 line type 과 schemaVersion 을 명시한다. 알고리즘/부호/gain 등 보정 컨텍스트
/// 와 함께 저장되므로 한 파일만 봐도 "어떤 조건에서 걸었는지" 알 수 있다.
public struct WalkSessionHeaderV2: Codable, Equatable, Sendable {
    public let type: String
    public let schemaVersion: Int

    public let sessionId: String
    public let startTimeIso: String
    public let appVersion: String
    public let gitCommit: String?

    public let isRealRobot: Bool
    public let robotProfileId: String?
    public let operatorNote: String?
    public let surfaceType: String?
    /// cradle, handSupport, floor, unknown
    public let supportMode: String?

    public let preset: String
    public let walkTuning: WalkTuningSnapshot

    public let balanceAlgorithmMode: String
    public let balanceSignConvention: String
    public let balanceGainProfile: String
    public let correctorIntensityLevelAtStart: Int
    /// off, observeOnly, simOnly, robotApplied
    public let correctionApplyMode: String

    public let imuSourceAtStart: String
    public let imuCalibrationId: String?
    public let imuScaleSuspicionAtStart: String

    public let safetyPolicy: SafetyPolicySnapshot

    public let comparisonTag: WalkComparisonTag?

    public init(sessionId: String,
                startTimeIso: String,
                appVersion: String,
                gitCommit: String? = nil,
                isRealRobot: Bool,
                robotProfileId: String? = nil,
                operatorNote: String? = nil,
                surfaceType: String? = nil,
                supportMode: String? = nil,
                preset: String,
                walkTuning: WalkTuningSnapshot,
                balanceAlgorithmMode: String,
                balanceSignConvention: String,
                balanceGainProfile: String,
                correctorIntensityLevelAtStart: Int,
                correctionApplyMode: String,
                imuSourceAtStart: String,
                imuCalibrationId: String? = nil,
                imuScaleSuspicionAtStart: String = "normal",
                safetyPolicy: SafetyPolicySnapshot = SafetyPolicySnapshot(),
                comparisonTag: WalkComparisonTag? = nil) {
        self.type = WalkSessionLineType.header.rawValue
        self.schemaVersion = WalkSessionSchemaVersion.v2.rawValue
        self.sessionId = sessionId
        self.startTimeIso = startTimeIso
        self.appVersion = appVersion
        self.gitCommit = gitCommit
        self.isRealRobot = isRealRobot
        self.robotProfileId = robotProfileId
        self.operatorNote = operatorNote
        self.surfaceType = surfaceType
        self.supportMode = supportMode
        self.preset = preset
        self.walkTuning = walkTuning
        self.balanceAlgorithmMode = balanceAlgorithmMode
        self.balanceSignConvention = balanceSignConvention
        self.balanceGainProfile = balanceGainProfile
        self.correctorIntensityLevelAtStart = correctorIntensityLevelAtStart
        self.correctionApplyMode = correctionApplyMode
        self.imuSourceAtStart = imuSourceAtStart
        self.imuCalibrationId = imuCalibrationId
        self.imuScaleSuspicionAtStart = imuScaleSuspicionAtStart
        self.safetyPolicy = safetyPolicy
        self.comparisonTag = comparisonTag
    }
}

/// v1 (legacy) header — 21 개 기존 로그가 사용하는 최소 필드.
///
/// 새 코드는 v1 을 직접 쓰지 않는다. decoder 가 v1 → 공통 in-memory model 로 변환할 때만 사용.
public struct WalkSessionHeaderV1: Codable, Equatable, Sendable {
    public let sessionId: String
    public let startTimeIso: String
    public let appVersion: String?
    public let preset: String
    public let isRealRobot: Bool?
    public let intensityLevelAtStart: Int?

    public init(sessionId: String,
                startTimeIso: String,
                appVersion: String? = nil,
                preset: String,
                isRealRobot: Bool? = nil,
                intensityLevelAtStart: Int? = nil) {
        self.sessionId = sessionId
        self.startTimeIso = startTimeIso
        self.appVersion = appVersion
        self.preset = preset
        self.isRealRobot = isRealRobot
        self.intensityLevelAtStart = intensityLevelAtStart
    }
}

/// Decoder 가 v1/v2 어느 쪽이든 받아 공통 in-memory 표현으로 변환한 결과.
public struct WalkSessionHeaderResolved: Equatable, Sendable {
    public let schemaVersion: WalkSessionSchemaVersion
    public let sessionId: String
    public let startTimeIso: String
    public let appVersion: String?
    public let gitCommit: String?
    public let preset: String
    public let isRealRobot: Bool?
    public let intensityLevelAtStart: Int?
    public let supportMode: String?
    public let walkTuning: WalkTuningSnapshot?
    public let balanceAlgorithmMode: String?
    public let balanceSignConvention: String?
    public let balanceGainProfile: String?
    public let correctionApplyMode: String?
    public let imuSourceAtStart: String?
    public let imuScaleSuspicionAtStart: String?
    public let safetyPolicy: SafetyPolicySnapshot?
    public let comparisonTag: WalkComparisonTag?

    public init(schemaVersion: WalkSessionSchemaVersion,
                sessionId: String,
                startTimeIso: String,
                appVersion: String?,
                gitCommit: String?,
                preset: String,
                isRealRobot: Bool?,
                intensityLevelAtStart: Int?,
                supportMode: String?,
                walkTuning: WalkTuningSnapshot?,
                balanceAlgorithmMode: String?,
                balanceSignConvention: String?,
                balanceGainProfile: String?,
                correctionApplyMode: String?,
                imuSourceAtStart: String?,
                imuScaleSuspicionAtStart: String?,
                safetyPolicy: SafetyPolicySnapshot?,
                comparisonTag: WalkComparisonTag? = nil) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.startTimeIso = startTimeIso
        self.appVersion = appVersion
        self.gitCommit = gitCommit
        self.preset = preset
        self.isRealRobot = isRealRobot
        self.intensityLevelAtStart = intensityLevelAtStart
        self.supportMode = supportMode
        self.walkTuning = walkTuning
        self.balanceAlgorithmMode = balanceAlgorithmMode
        self.balanceSignConvention = balanceSignConvention
        self.balanceGainProfile = balanceGainProfile
        self.correctionApplyMode = correctionApplyMode
        self.imuSourceAtStart = imuSourceAtStart
        self.imuScaleSuspicionAtStart = imuScaleSuspicionAtStart
        self.safetyPolicy = safetyPolicy
        self.comparisonTag = comparisonTag
    }
}
