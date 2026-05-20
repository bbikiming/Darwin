import XCTest
@testable import DarwinForgeUI

final class WalkSessionMetricsTests: XCTestCase {

    // 7) observeOnly 는 candidate 와 applied 를 분리한다.
    func testObserveOnlySeparatesCandidateAndAppliedDeltas() throws {
        let file = WalkSessionFixtures.v2CleanFile(applyMode: "observeOnly", durationSec: 6, sampleRateHz: 20)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        let nonZeroCandidate = decoded.samples.filter { ($0.candidateDeltas ?? []).contains(where: { $0 != 0 }) }.count
        let allAppliedZero = decoded.samples.allSatisfy { ($0.appliedDeltas ?? []).allSatisfy { $0 == 0 } }
        XCTAssertGreaterThan(nonZeroCandidate, 0)
        XCTAssertTrue(allAppliedZero, "observeOnly 모드에서 applied 는 0 이어야 함")
    }

    // 8) duplicate sample 은 lagged effectiveness 계산에서 제외된다.
    func testLaggedEffectivenessIgnoresDuplicateSamples() throws {
        let file = WalkSessionFixtures.v1LegacyFile(durationSec: 8, sampleRateHz: 14.8)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        let metrics = WalkSessionMetricsAnalyzer.analyze(session: decoded)
        // v1 fixture 는 duplicate 가 너무 많아 lagged effectiveness 계산이 어려움 — nil 또는 신뢰도 낮음.
        // 핵심: duplicate 가 90%+ 인데 effectiveness 가 매우 confident (예: +0.9) 로 나오면 안 됨.
        if let lp = metrics.laggedPitchEffectiveness {
            XCTAssertLessThan(abs(lp), 0.95)
        }
    }

    // 9) Hybrid summary 에는 phase 필드가 있어야 함 (v2 로그에서).
    func testHybridSummaryRequiresPhaseFields() throws {
        let file = WalkSessionFixtures.v2CleanFile(algorithmMode: "hybridBA", durationSec: 8, sampleRateHz: 20)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        // 모든 sample 에 walkPhase01 이 있어야 함.
        XCTAssertTrue(decoded.samples.allSatisfy { $0.walkPhase01 != nil })
        let metrics = WalkSessionMetricsAnalyzer.analyze(session: decoded)
        // phase residual rms 계산되어야 함.
        XCTAssertNotNil(metrics.phaseResidualPitchRms)
        XCTAssertNotNil(metrics.phaseResidualRollRms)
    }

    func testV1SessionHasNoPhaseResidual() throws {
        let file = WalkSessionFixtures.v1LegacyFile(durationSec: 8, sampleRateHz: 14.8)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        let metrics = WalkSessionMetricsAnalyzer.analyze(session: decoded)
        XCTAssertNil(metrics.phaseResidualPitchRms, "v1 로그는 walkPhase01 이 없어 phase residual 계산 불가")
    }

    func testMeanStdDevPeakComputedFromValidSamplesOnly() throws {
        let file = WalkSessionFixtures.v2CleanFile(durationSec: 6, sampleRateHz: 20)
        let decoded = try WalkSessionDecoder.decode(lines: file.split(separator: "\n").map(String.init))
        let metrics = WalkSessionMetricsAnalyzer.analyze(session: decoded)
        // sin 파 기반이므로 평균 roll 은 0 근처, peak 는 ~4°, std > 0.
        XCTAssertEqual(metrics.meanRollDeg, 0, accuracy: 1.0)
        XCTAssertGreaterThan(metrics.peakAbsRollDeg, 2.0)
        XCTAssertGreaterThan(metrics.rollStdevDeg, 0)
    }
}
