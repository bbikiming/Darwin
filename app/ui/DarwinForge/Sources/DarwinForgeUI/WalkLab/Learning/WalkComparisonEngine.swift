import Foundation

/// 두 세션이 A/B 비교에 적합한지 판단 + 결과 산출. "한 번에 하나의 변수만 바꾸기"
/// 규칙을 강제한다.
public enum WalkComparisonEngine {

    public enum Verdict: String, Sendable {
        case improved
        case worsened
        case inconclusive
        case incomparable
    }

    public struct Eligibility: Sendable {
        public let isEligible: Bool
        public let reasons: [String]

        public init(isEligible: Bool, reasons: [String]) {
            self.isEligible = isEligible
            self.reasons = reasons
        }
    }

    public struct Result: Sendable {
        public let baselineSessionId: String
        public let experimentSessionId: String
        public let verdict: Verdict
        public let variableChanged: WalkComparisonVariable
        public let deltaMeanAbsPitch: Double
        public let deltaMeanAbsRoll: Double
        public let deltaPitchStdev: Double
        public let deltaRollStdev: Double
        public let deltaOscillationPitch: Double
        public let deltaOscillationRoll: Double
        public let reasons: [String]

        public init(baselineSessionId: String,
                    experimentSessionId: String,
                    verdict: Verdict,
                    variableChanged: WalkComparisonVariable,
                    deltaMeanAbsPitch: Double,
                    deltaMeanAbsRoll: Double,
                    deltaPitchStdev: Double,
                    deltaRollStdev: Double,
                    deltaOscillationPitch: Double,
                    deltaOscillationRoll: Double,
                    reasons: [String]) {
            self.baselineSessionId = baselineSessionId
            self.experimentSessionId = experimentSessionId
            self.verdict = verdict
            self.variableChanged = variableChanged
            self.deltaMeanAbsPitch = deltaMeanAbsPitch
            self.deltaMeanAbsRoll = deltaMeanAbsRoll
            self.deltaPitchStdev = deltaPitchStdev
            self.deltaRollStdev = deltaRollStdev
            self.deltaOscillationPitch = deltaOscillationPitch
            self.deltaOscillationRoll = deltaOscillationRoll
            self.reasons = reasons
        }
    }

    /// 두 세션이 비교 가능한지 검사. preset / support mode / surface 같은 컨트롤 변수가
    /// 다르면 incomparable.
    public static func eligibility(baseline: DecodedWalkSession,
                                   experiment: DecodedWalkSession) -> Eligibility {
        var reasons: [String] = []

        // 1) 둘 다 비교 가능한 grade 여야 함.
        let bq = WalkSessionQualityAnalyzer.analyze(session: baseline)
        let eq = WalkSessionQualityAnalyzer.analyze(session: experiment)
        if bq.useClass != .usableForComparison {
            reasons.append("A 측 데이터 품질 부족 (\(bq.grade.rawValue)/\(WalkSessionLabels.useClassLabel(bq.useClass)))")
        }
        if eq.useClass != .usableForComparison {
            reasons.append("B 측 데이터 품질 부족 (\(eq.grade.rawValue)/\(WalkSessionLabels.useClassLabel(eq.useClass)))")
        }

        // 2) preset 이 같아야 함.
        if baseline.header.preset != experiment.header.preset {
            reasons.append("preset 이 다름 (\(baseline.header.preset) vs \(experiment.header.preset))")
        }

        // 3) support mode 가 같아야 함 (둘 다 unknown 이어도 경고).
        let bSupport = baseline.header.supportMode ?? "unknown"
        let eSupport = experiment.header.supportMode ?? "unknown"
        if bSupport != eSupport {
            reasons.append("지지 조건 다름 (\(bSupport) vs \(eSupport))")
        }
        if bSupport == "unknown" || eSupport == "unknown" {
            reasons.append("지지 조건 불명 — 비교 신뢰도 낮음")
        }

        // 4) 한 번에 하나의 변수만.
        let diffs = diffVariables(baseline: baseline.header, experiment: experiment.header)
        if diffs.count > 1 {
            reasons.append("동시에 \(diffs.count)개 변수가 변경됨 (\(diffs.map { $0.rawValue }.joined(separator: ", "))). A/B 는 한 번에 한 변수만 바꿔야 합니다.")
        }
        if diffs.isEmpty {
            reasons.append("두 세션이 동일한 설정 — 비교 의미 없음")
        }

        return Eligibility(isEligible: reasons.isEmpty, reasons: reasons)
    }

    /// 두 세션을 비교. eligibility 가 부적격이면 verdict 는 `.incomparable`.
    public static func compare(baseline: DecodedWalkSession,
                               experiment: DecodedWalkSession) -> Result {
        let elig = eligibility(baseline: baseline, experiment: experiment)
        let bm = WalkSessionMetricsAnalyzer.analyze(session: baseline)
        let em = WalkSessionMetricsAnalyzer.analyze(session: experiment)
        let bq = WalkSessionQualityAnalyzer.analyze(session: baseline)
        let eq = WalkSessionQualityAnalyzer.analyze(session: experiment)

        let dPitch = em.meanAbsPitchDeg - bm.meanAbsPitchDeg
        let dRoll = em.meanAbsRollDeg - bm.meanAbsRollDeg
        let dPitchStd = em.pitchStdevDeg - bm.pitchStdevDeg
        let dRollStd = em.rollStdevDeg - bm.rollStdevDeg
        let dOscP = em.oscillationPitchHz - bm.oscillationPitchHz
        let dOscR = em.oscillationRollHz - bm.oscillationRollHz

        let diffs = diffVariables(baseline: baseline.header, experiment: experiment.header)
        let variable = diffs.first ?? .none

        var verdict: Verdict
        var reasons = elig.reasons
        if !elig.isEligible {
            verdict = .incomparable
        } else {
            // 안전 우선: stale / duplicate 가 심해지면 평균 tilt 가 낮아져도 개선이라 부르지 않는다.
            if eq.staleRatio > bq.staleRatio * 1.5 || eq.imuDuplicateRatio > bq.imuDuplicateRatio * 1.5 {
                verdict = .inconclusive
                reasons.append("실험 측 IMU 신선도가 떨어짐 — 평균 비교 의미 약함")
            } else {
                let improved = dPitch < -1.0 || dRoll < -1.0
                let worsened = dPitch > 1.0 || dRoll > 1.0
                if improved && !worsened { verdict = .improved }
                else if worsened && !improved { verdict = .worsened }
                else { verdict = .inconclusive }
            }
        }

        return Result(
            baselineSessionId: baseline.header.sessionId,
            experimentSessionId: experiment.header.sessionId,
            verdict: verdict,
            variableChanged: variable,
            deltaMeanAbsPitch: dPitch,
            deltaMeanAbsRoll: dRoll,
            deltaPitchStdev: dPitchStd,
            deltaRollStdev: dRollStd,
            deltaOscillationPitch: dOscP,
            deltaOscillationRoll: dOscR,
            reasons: reasons
        )
    }

    /// header 끼리 비교해서 어떤 변수가 다른지 반환. preset / supportMode 같은
    /// 컨트롤 변수는 제외 — eligibility 가 이미 거른다.
    static func diffVariables(baseline: WalkSessionHeaderResolved,
                              experiment: WalkSessionHeaderResolved) -> [WalkComparisonVariable] {
        var diffs: [WalkComparisonVariable] = []
        if baseline.balanceAlgorithmMode != experiment.balanceAlgorithmMode {
            diffs.append(.algorithm)
        }
        if baseline.balanceSignConvention != experiment.balanceSignConvention {
            diffs.append(.sign)
        }
        if baseline.balanceGainProfile != experiment.balanceGainProfile {
            diffs.append(.gain)
        }
        if baseline.intensityLevelAtStart != experiment.intensityLevelAtStart {
            diffs.append(.intensity)
        }
        return diffs
    }
}
