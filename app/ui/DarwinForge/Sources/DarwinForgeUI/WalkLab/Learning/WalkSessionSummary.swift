import Foundation

/// 세션 단위 요약 v2. 평균 / 표준편차 / lagged effectiveness / phase residual /
/// 데이터 품질 / 추천 액션을 한 곳에 담는다.
public struct WalkSessionSummaryV2: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let schemaVersion: Int
    public let preset: String
    public let startTimeIso: String
    public let durationSec: Double
    public let sessionId: String

    public let dataQuality: WalkSessionDataQuality

    public let meanRollDeg: Double
    public let meanPitchDeg: Double
    public let meanAbsRollDeg: Double
    public let meanAbsPitchDeg: Double
    public let peakAbsRollDeg: Double
    public let peakAbsPitchDeg: Double
    public let rollStdevDeg: Double
    public let pitchStdevDeg: Double

    public let pitchBiasDeg: Double
    public let rollBiasDeg: Double

    public let oscillationPitchHz: Double
    public let oscillationRollHz: Double

    public let laggedPitchEffectiveness: Double?
    public let laggedRollEffectiveness: Double?
    public let bestLagMs: Double?

    public let phaseResidualPitchRms: Double?
    public let phaseResidualRollRms: Double?

    public let recommendation: WalkSessionRecommendation

    public init(id: String,
                preset: String,
                startTimeIso: String,
                durationSec: Double,
                sessionId: String,
                dataQuality: WalkSessionDataQuality,
                meanRollDeg: Double,
                meanPitchDeg: Double,
                meanAbsRollDeg: Double,
                meanAbsPitchDeg: Double,
                peakAbsRollDeg: Double,
                peakAbsPitchDeg: Double,
                rollStdevDeg: Double,
                pitchStdevDeg: Double,
                pitchBiasDeg: Double,
                rollBiasDeg: Double,
                oscillationPitchHz: Double = 0,
                oscillationRollHz: Double = 0,
                laggedPitchEffectiveness: Double? = nil,
                laggedRollEffectiveness: Double? = nil,
                bestLagMs: Double? = nil,
                phaseResidualPitchRms: Double? = nil,
                phaseResidualRollRms: Double? = nil,
                recommendation: WalkSessionRecommendation) {
        self.id = id
        self.schemaVersion = WalkSessionSchemaVersion.v2.rawValue
        self.preset = preset
        self.startTimeIso = startTimeIso
        self.durationSec = durationSec
        self.sessionId = sessionId
        self.dataQuality = dataQuality
        self.meanRollDeg = meanRollDeg
        self.meanPitchDeg = meanPitchDeg
        self.meanAbsRollDeg = meanAbsRollDeg
        self.meanAbsPitchDeg = meanAbsPitchDeg
        self.peakAbsRollDeg = peakAbsRollDeg
        self.peakAbsPitchDeg = peakAbsPitchDeg
        self.rollStdevDeg = rollStdevDeg
        self.pitchStdevDeg = pitchStdevDeg
        self.pitchBiasDeg = pitchBiasDeg
        self.rollBiasDeg = rollBiasDeg
        self.oscillationPitchHz = oscillationPitchHz
        self.oscillationRollHz = oscillationRollHz
        self.laggedPitchEffectiveness = laggedPitchEffectiveness
        self.laggedRollEffectiveness = laggedRollEffectiveness
        self.bestLagMs = bestLagMs
        self.phaseResidualPitchRms = phaseResidualPitchRms
        self.phaseResidualRollRms = phaseResidualRollRms
        self.recommendation = recommendation
    }
}
