import Foundation

/// 세션 데이터 품질을 평가한다. independent IMU count / duplicate ratio / stale ratio /
/// 알고리즘 필드 유무를 보고 grade A..F 와 useClass 를 산출.
///
/// 보수적 임계값 (prompt §5.1):
/// - A: 10s+ / indep IMU ≥ 100 / stale < 5% / duplicate < 20%
/// - B: 8s+ / indep IMU ≥ 60 / stale < 10% / duplicate < 40%
/// - C: 5s+ / indep IMU ≥ 25
/// - D: 2s+ 또는 중복률 높음
/// - F: < 2s / emergency / schema 불완전 / IMU stale 심함
public enum WalkSessionQualityAnalyzer {

    public struct Thresholds: Sendable {
        public let durationA: Double
        public let durationB: Double
        public let durationC: Double
        public let durationD: Double
        public let indepImuA: Int
        public let indepImuB: Int
        public let indepImuC: Int
        public let duplicateA: Double
        public let duplicateB: Double
        public let staleA: Double
        public let staleB: Double
        public let staleSevere: Double

        public init(durationA: Double = 10,
                    durationB: Double = 8,
                    durationC: Double = 5,
                    durationD: Double = 2,
                    indepImuA: Int = 100,
                    indepImuB: Int = 60,
                    indepImuC: Int = 25,
                    duplicateA: Double = 0.20,
                    duplicateB: Double = 0.40,
                    staleA: Double = 0.05,
                    staleB: Double = 0.10,
                    staleSevere: Double = 0.50) {
            self.durationA = durationA
            self.durationB = durationB
            self.durationC = durationC
            self.durationD = durationD
            self.indepImuA = indepImuA
            self.indepImuB = indepImuB
            self.indepImuC = indepImuC
            self.duplicateA = duplicateA
            self.duplicateB = duplicateB
            self.staleA = staleA
            self.staleB = staleB
            self.staleSevere = staleSevere
        }

        public static let `default` = Thresholds()
    }

    public static func analyze(session: DecodedWalkSession,
                               thresholds: Thresholds = .default) -> WalkSessionDataQuality {
        let samples = session.samples
        let sampleCount = samples.count
        let duration = computeDuration(samples)

        let imuRollPitch: [(Double, Double)] = samples.compactMap { s in
            guard let r = s.imuRollDeg, let p = s.imuPitchDeg else { return nil }
            return (r, p)
        }
        let independentImuSampleCount = Set(imuRollPitch.map { "\($0.0)|\($0.1)" }).count
        let duplicateRatio = computeDuplicateRatio(samples: samples)
        let nominalRate = duration > 0 ? Double(sampleCount) / duration : 0
        let effectiveImuRate = duration > 0 ? Double(independentImuSampleCount) / duration : 0

        let ages = samples.compactMap { $0.imuSampleAgeMs }.sorted()
        let medianAge = percentile(ages, p: 0.5)
        let p95Age = percentile(ages, p: 0.95)
        let staleRatio = computeStaleRatio(samples: samples)

        let busFailureCount = samples.compactMap { $0.busWriteFailureCount }.max() ?? 0
            + (samples.compactMap { $0.busReadFailureCount }.max() ?? 0)
        let emergencyCount = session.events.filter {
            $0.kind == WalkSessionEventKind.emergencyStop.rawValue ||
            $0.kind == WalkSessionEventKind.balanceLost.rawValue ||
            $0.kind == WalkSessionEventKind.thermalAlarm.rawValue
        }.count

        var reasons: [WalkSessionQualityReason] = []

        // F 자동 판정 — 안전 / 스키마 / 너무 짧음 / stale 심함.
        if duration < thresholds.durationD {
            reasons.append(.durationTooShort)
        }
        if emergencyCount > 0 {
            reasons.append(.emergencyStopped)
        }
        if busFailureCount > 0 {
            reasons.append(.busFailuresPresent)
        }
        if staleRatio >= thresholds.staleSevere {
            reasons.append(.staleRatioTooHigh)
        }
        if session.schemaVersion == .v1 {
            reasons.append(.legacySchemaMissingFields)
        }
        if session.header.balanceAlgorithmMode == nil {
            reasons.append(.algorithmFieldsMissing)
        }
        if session.header.supportMode == nil || session.header.supportMode == "unknown" {
            reasons.append(.supportModeUnknown)
        }
        if duplicateRatio > thresholds.duplicateB {
            reasons.append(.duplicateRatioTooHigh)
        }
        if independentImuSampleCount < thresholds.indepImuC {
            reasons.append(.independentImuTooLow)
        }
        if staleRatio > thresholds.staleB && !reasons.contains(.staleRatioTooHigh) {
            reasons.append(.staleRatioTooHigh)
        }

        let grade = computeGrade(
            duration: duration,
            indepImu: independentImuSampleCount,
            duplicateRatio: duplicateRatio,
            staleRatio: staleRatio,
            emergencyCount: emergencyCount,
            thresholds: thresholds
        )
        let useClass = computeUseClass(
            grade: grade,
            reasons: reasons,
            emergencyCount: emergencyCount,
            schemaVersion: session.schemaVersion,
            balanceAlgorithmMode: session.header.balanceAlgorithmMode
        )

        if reasons.isEmpty { reasons.append(.healthy) }

        return WalkSessionDataQuality(
            useClass: useClass,
            grade: grade,
            reasons: reasons,
            durationSec: duration,
            sampleCount: sampleCount,
            independentImuSampleCount: independentImuSampleCount,
            imuDuplicateRatio: duplicateRatio,
            nominalSampleRateHz: nominalRate,
            effectiveImuRateHz: effectiveImuRate,
            medianImuAgeMs: medianAge,
            p95ImuAgeMs: p95Age,
            staleRatio: staleRatio,
            busFailureCount: busFailureCount,
            emergencyCount: emergencyCount
        )
    }

    // MARK: - helpers

    static func computeDuration(_ samples: [WalkSessionSampleResolved]) -> Double {
        guard let first = samples.first?.tMs,
              let last = samples.last?.tMs else { return 0 }
        return max(0, (last - first) / 1000.0)
    }

    static func computeDuplicateRatio(samples: [WalkSessionSampleResolved]) -> Double {
        guard samples.count > 1 else { return 0 }
        var dup = 0
        var lastR: Double?
        var lastP: Double?
        var pairs = 0
        for s in samples {
            guard let r = s.imuRollDeg, let p = s.imuPitchDeg else { continue }
            if let lr = lastR, let lp = lastP {
                pairs += 1
                if r == lr && p == lp { dup += 1 }
            }
            lastR = r
            lastP = p
        }
        guard pairs > 0 else { return 0 }
        return Double(dup) / Double(pairs)
    }

    static func computeStaleRatio(samples: [WalkSessionSampleResolved]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let total = samples.count
        let staleCount = samples.filter { s in
            if s.imuStale { return true }
            if let age = s.imuSampleAgeMs, age > 250 { return true }
            return false
        }.count
        return Double(staleCount) / Double(total)
    }

    static func percentile(_ sorted: [Double], p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let idx = Int(Double(sorted.count - 1) * p)
        return sorted[max(0, min(sorted.count - 1, idx))]
    }

    static func computeGrade(duration: Double,
                             indepImu: Int,
                             duplicateRatio: Double,
                             staleRatio: Double,
                             emergencyCount: Int,
                             thresholds: Thresholds) -> WalkSessionGrade {
        if duration < thresholds.durationD { return .F }
        if emergencyCount > 0 { return .F }
        if staleRatio >= thresholds.staleSevere { return .F }

        if duration >= thresholds.durationA,
           indepImu >= thresholds.indepImuA,
           duplicateRatio < thresholds.duplicateA,
           staleRatio < thresholds.staleA {
            return .A
        }
        if duration >= thresholds.durationB,
           indepImu >= thresholds.indepImuB,
           duplicateRatio < thresholds.duplicateB,
           staleRatio < thresholds.staleB {
            return .B
        }
        if duration >= thresholds.durationC,
           indepImu >= thresholds.indepImuC {
            return .C
        }
        if duration >= thresholds.durationD {
            return .D
        }
        return .F
    }

    static func computeUseClass(grade: WalkSessionGrade,
                                reasons: [WalkSessionQualityReason],
                                emergencyCount: Int,
                                schemaVersion: WalkSessionSchemaVersion,
                                balanceAlgorithmMode: String?) -> WalkSessionUseClass {
        if emergencyCount > 0 {
            return .usableForSafetyReview
        }
        switch grade {
        case .A:
            // comparison 가능하려면 algorithm 필드도 있어야 함.
            if balanceAlgorithmMode == nil { return .usableForBiasOnly }
            return .usableForComparison
        case .B:
            if balanceAlgorithmMode == nil { return .usableForBiasOnly }
            return .usableForComparison
        case .C:
            return .usableForBiasOnly
        case .D:
            return .inconclusive
        case .F:
            return .rejected
        }
    }
}
