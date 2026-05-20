import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.11.10 (2026-05-19) — Context V2 + DataQualityReport + Critic JSON 회귀 가드**.
///
/// 검증:
/// - V2 Header / Summary decode (legacy v1.11.9 jsonl backward-compat)
/// - DataQualityReport compute (실 데이터 threshold 기반)
/// - SagittalMetric + CandidateAppliedSplit 계산
/// - ClaudeCriticResponse Codable + validation
/// - WalkSessionClaudePromptV2 7 section 구조
/// - Analyst.stripMarkdownFence + JSON parse
@MainActor
final class WalkLabV1110ContextV2Tests: XCTestCase {

    // MARK: - 1. Header V2 decode backward-compat

    /// v1.11.9 legacy jsonl 의 header decode 성공 + V2 필드 nil.
    func testLegacyHeaderDecode() throws {
        let legacy = #"""
        {
          "sessionId": "2026-05-18T10-30-02.978Z",
          "startTimeIso": "2026-05-18T10:30:02.978Z",
          "preset": "march",
          "intensityLevelAtStart": 2,
          "appVersion": "1.11.9",
          "isRealRobot": true,
          "balanceAlgorithmMode": "robotisPControl",
          "balanceSignConvention": "robotisWalkingCpp",
          "balanceGainProfile": "robotisOriginal",
          "correctionApplyMode": "robotApplied"
        }
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WalkSessionHeader.self, from: legacy)
        XCTAssertEqual(decoded.sessionId, "2026-05-18T10-30-02.978Z")
        XCTAssertEqual(decoded.balanceAlgorithmMode, "robotisPControl")
        // V2 필드는 nil (legacy 없음).
        XCTAssertNil(decoded.walkingEngine)
        XCTAssertNil(decoded.hipPitchOffsetTrimDegAtStart)
        XCTAssertNil(decoded.tuningStrideMm)
    }

    /// V2 full header roundtrip.
    func testV2HeaderRoundtrip() throws {
        let h = WalkSessionHeader(
            sessionId: "test", startTimeIso: "2026-05-19T00:00:00Z",
            preset: "march", intensityLevelAtStart: 2,
            appVersion: "1.11.10", isRealRobot: true,
            balanceAlgorithmMode: "hybridBA",
            walkingEngine: "macSparseKeyframe",
            pitchInputConvention: "negateForwardIsNegative",
            enableBalanceCorrectionAtStart: true,
            hipPitchOffsetTrimDegAtStart: 5.0,
            tuningStrideMm: 28, tuningPeriodMs: 600, tuningFootHeightMm: 40,
            experimentId: "exp-001", baselineSessionId: "baseline-007"
        )
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(WalkSessionHeader.self, from: data)
        XCTAssertEqual(decoded.walkingEngine, "macSparseKeyframe")
        XCTAssertEqual(decoded.pitchInputConvention, "negateForwardIsNegative")
        XCTAssertEqual(decoded.hipPitchOffsetTrimDegAtStart, 5.0)
        XCTAssertEqual(decoded.experimentId, "exp-001")
    }

    // MARK: - 2. Summary V2 decode

    /// v1.11.9 legacy summary decode 성공 + V2 metric nil.
    func testLegacySummaryDecode() throws {
        let legacy = #"""
        {
          "id": "test", "preset": "march", "startTimeIso": "x", "durationSec": 10,
          "sampleCount": 200, "intensityLevelUsed": 2,
          "meanAbsRoll": 5.0, "meanAbsPitch": 13.0, "rollStdev": 3.0, "pitchStdev": 4.0,
          "peakAbsRoll": 18.0, "peakAbsPitch": 25.0,
          "oscillationScore": 1.5, "correctorEffectivenessScore": 0.3,
          "recommendedIntensityLevel": 3, "recommendationReason": "test", "confidence": 0.7
        }
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WalkSessionSummary.self, from: legacy)
        XCTAssertEqual(decoded.id, "test")
        XCTAssertEqual(decoded.meanAbsPitch, 13.0, accuracy: 0.01)
        // V2 nil
        XCTAssertNil(decoded.dataQuality)
        XCTAssertNil(decoded.sagittal)
        XCTAssertNil(decoded.candidateApplied)
    }

    // MARK: - 3. DataQualityReport

    /// 빈 sample → fail.
    func testQualityEmpty() {
        let h = mockHeader()
        let q = DataQualityReport.compute(samples: [], header: h, durationSec: 0)
        XCTAssertEqual(q.verdict, .fail)
        XCTAssertFalse(q.reasons.isEmpty)
    }

    /// 정상 데이터 → pass.
    func testQualityPass() {
        let h = mockHeader(isReal: true)
        let samples = (0..<200).map { i -> WalkSessionSample in
            mockSample(t: Double(i) * 50,
                       walkPhase: [0.03, 0.18, 0.42, 0.52, 0.68, 0.92][i % 6],
                       pitch: -10 + Double.random(in: -1...1),
                       roll: Double.random(in: -1...1),
                       imuSeq: UInt32(i),
                       ageMs: 50,
                       applied: [0.1, 0.1, 0.2, 0.2, 0.3, -0.3, 0.1, 0.1])
        }
        let q = DataQualityReport.compute(samples: samples, header: h, durationSec: 10.0)
        XCTAssertEqual(q.verdict, .pass, "정상 데이터 → pass. reasons: \(q.reasons)")
    }

    /// duplicate IMU 70% → weak (60% 초과).
    func testQualityWeakDueToDuplicate() {
        let h = mockHeader(isReal: true)
        let samples = (0..<200).map { i -> WalkSessionSample in
            mockSample(t: Double(i) * 50,
                       walkPhase: [0.03, 0.18, 0.42, 0.52, 0.68, 0.92][i % 6],
                       pitch: -10, roll: 0,
                       imuSeq: UInt32(i / 4),  // 4 sample 마다 sequence 동일 → 75% dup
                       ageMs: 50,
                       applied: [0.1, 0.1, 0.2, 0.2, 0.3, -0.3, 0.1, 0.1])
        }
        let q = DataQualityReport.compute(samples: samples, header: h, durationSec: 10.0)
        XCTAssertNotEqual(q.verdict, .pass, "75% duplicate → not pass (verdict=\(q.verdict.rawValue))")
        XCTAssertGreaterThan(q.duplicateImuRatio, 0.60)
        XCTAssertFalse(q.duplicateOK)
    }

    /// duration < 1s → fail.
    func testQualityFailShortDuration() {
        let h = mockHeader(isReal: true)
        let samples = (0..<5).map { mockSample(t: Double($0) * 50, walkPhase: 0.03, pitch: -10, roll: 0) }
        let q = DataQualityReport.compute(samples: samples, header: h, durationSec: 0.3)
        XCTAssertEqual(q.verdict, .fail, "0.3s → fail")
    }

    /// observeOnly + applied 모두 0 → applied gate 통과 (정상).
    func testQualityObserveOnlyAllowsZeroApplied() {
        let h = mockHeader(isReal: true, applyMode: "observeOnly")
        let samples = (0..<150).map { i -> WalkSessionSample in
            mockSample(t: Double(i) * 50,
                       walkPhase: [0.03, 0.18, 0.42, 0.52, 0.68, 0.92][i % 6],
                       pitch: -10, roll: 0,
                       imuSeq: UInt32(i), ageMs: 50,
                       applied: [0, 0, 0, 0, 0, 0, 0, 0])  // observeOnly = all zero
        }
        let q = DataQualityReport.compute(samples: samples, header: h, durationSec: 7.5)
        XCTAssertTrue(q.appliedZeroOK, "observeOnly 면 applied=0 정상")
        XCTAssertTrue(q.isObserveOnly)
    }

    // MARK: - 4. SagittalMetric

    /// 합성 데이터: pitch 가 -5 → +5 linear → drift +1°/s 기대 (10초).
    func testSagittalDrift() {
        let samples = (0..<100).map { i -> WalkSessionSample in
            let t = Double(i) * 100
            let pitch = -5.0 + Double(i) * 0.1  // 0 → 10 over 100 samples
            return mockSample(t: t, walkPhase: 0.5, pitch: pitch, roll: 0)
        }
        let sag = SagittalMetric.compute(samples: samples, durationSec: 10.0)
        XCTAssertGreaterThan(sag.pitchDriftPerSec, 0.5, "양의 drift 검출")
        XCTAssertEqual(sag.meanSignedPitch, 0.0, accuracy: 1.0)
    }

    // MARK: - 5. CandidateAppliedSplit

    /// candidate / applied 분리 정확성.
    func testCandidateAppliedSplit() {
        // candidate = +2.0, applied = +0.5 (R ankle pitch, idx 4)
        let samples = (0..<50).map { _ in
            WalkSessionSample(
                t: 0, preset: "march", intensityLevel: 2,
                imuRollDeg: 0, imuPitchDeg: -10,
                correctorRollErrDeg: 0, correctorPitchErrDeg: 0,
                balanceState: "normal",
                correctorDeltas: Array(repeating: 0.0, count: 8),
                imuSource: "real", batteryVolts: nil, motorAvgTemp: nil,
                candidateDeltas: [0, 0, 0, 0, 2.0, -2.0, 0, 0],
                appliedDeltas: [0, 0, 0, 0, 0.5, -0.5, 0, 0]
            )
        }
        let s = CandidateAppliedSplit.compute(samples: samples)
        XCTAssertEqual(s.meanCandidateRAnklePitch, 2.0, accuracy: 0.01)
        XCTAssertEqual(s.meanAppliedRAnklePitch, 0.5, accuracy: 0.01)
        XCTAssertEqual(s.meanCandidateLAnklePitch, -2.0, accuracy: 0.01)
        XCTAssertEqual(s.meanAppliedLAnklePitch, -0.5, accuracy: 0.01)
    }

    // MARK: - 6. ClaudeCriticResponse

    /// schema 예시 그대로 decode.
    func testCriticResponseDecodeExample() throws {
        let json = #"""
        {
          "summary": "v110 fall 패턴",
          "sessionsAnalyzed": ["s1", "s2"],
          "dataQuality": { "verdict": "pass", "reasons": [] },
          "diagnosis": [
            { "axis": "gainProfile", "severity": "high", "evidence": ["session s1: peakPitch 38°"], "confidence": 0.85 }
          ],
          "nextExperiment": {
            "changeOneAxisOnly": true,
            "axis": "gainProfile",
            "from": "v110Experimental",
            "to": "robotisOriginal",
            "preset": "slowWalk",
            "safety": "cradle",
            "successMetric": "peakPitch < 20° (baseline -18° delta)",
            "rollbackCondition": "peakPitch > 25 or fall"
          },
          "forbiddenChanges": ["hybridBA + applyToRobot"],
          "recommendation": { "action": "holdAndObserve", "requiresHumanApproval": true },
          "confidence": 0.8
        }
        """#.data(using: .utf8)!
        let r = try JSONDecoder().decode(ClaudeCriticResponse.self, from: json)
        XCTAssertEqual(r.dataQuality.verdict, .pass)
        XCTAssertEqual(r.diagnosis.count, 1)
        XCTAssertEqual(r.diagnosis[0].axis, .gainProfile)
        XCTAssertEqual(r.nextExperiment?.changeOneAxisOnly, true)
        XCTAssertEqual(r.nextExperiment?.from, "v110Experimental")
        XCTAssertEqual(r.validate().passed, true)
    }

    /// unknown axis → .unknown fallback (forward-compat).
    func testCriticResponseUnknownAxis() throws {
        let json = #"""
        {
          "dataQuality": { "verdict": "fail", "reasons": ["data short"] },
          "diagnosis": [
            { "axis": "newMagicAxis", "severity": "low", "evidence": ["x"], "confidence": 0.1 }
          ],
          "forbiddenChanges": []
        }
        """#.data(using: .utf8)!
        let r = try JSONDecoder().decode(ClaudeCriticResponse.self, from: json)
        XCTAssertEqual(r.diagnosis[0].axis, .unknown,
            "unknown axis → .unknown fallback")
    }

    /// quality.fail 인데 nextExperiment 있으면 validation fail.
    func testCriticResponseValidationFailsWhenQualityFailWithExperiment() throws {
        let json = #"""
        {
          "dataQuality": { "verdict": "fail", "reasons": ["x"] },
          "diagnosis": [],
          "nextExperiment": {
            "changeOneAxisOnly": true,
            "axis": "hipPitchOffsetTrimDeg",
            "from": "13", "to": "5", "preset": "slowWalk",
            "safety": "cradle", "successMetric": "x", "rollbackCondition": "x"
          },
          "forbiddenChanges": []
        }
        """#.data(using: .utf8)!
        let r = try JSONDecoder().decode(ClaudeCriticResponse.self, from: json)
        XCTAssertFalse(r.validate().passed,
            "quality.fail + nextExperiment != nil → validation fail")
    }

    /// applyToRobot=true 직접 권고 → validation fail.
    func testCriticResponseValidationFailsOnDirectApplyToRobot() throws {
        let json = #"""
        {
          "dataQuality": { "verdict": "pass", "reasons": [] },
          "diagnosis": [{ "axis": "applyToRobot", "severity": "med", "evidence": ["x"], "confidence": 0.5 }],
          "nextExperiment": {
            "changeOneAxisOnly": true,
            "axis": "applyToRobot",
            "from": "false", "to": "true", "preset": "march",
            "safety": "cradle", "successMetric": "x", "rollbackCondition": "x"
          },
          "forbiddenChanges": []
        }
        """#.data(using: .utf8)!
        let r = try JSONDecoder().decode(ClaudeCriticResponse.self, from: json)
        XCTAssertFalse(r.validate().passed,
            "applyToRobot true 직접 권고 → reject")
    }

    // MARK: - 7. Prompt V2 7 section

    func testPromptV2HasSevenSections() {
        let prompt = WalkSessionClaudePromptV2.build(
            sessions: [],
            userReport: "",
            sampleStatsBuilder: { _ in [] }
        )
        XCTAssertTrue(prompt.contains("ROBOTIS-OP2"), "system section")
        XCTAssertTrue(prompt.contains("Critic, NOT Controller"), "critic role section")
        XCTAssertTrue(prompt.contains("절대 권고 금지 조합"), "forbidden section")
        XCTAssertTrue(prompt.contains("Quality Gate 지시"), "quality gate section")
        XCTAssertTrue(prompt.contains("<userReport>"), "user report section")
        XCTAssertTrue(prompt.contains("STRICT JSON"), "JSON schema section")
        XCTAssertTrue(prompt.contains("ClaudeCriticResponse"), "schema 본문 포함")
    }

    func testPromptV2IncludesSessionAxisValues() {
        let h = WalkSessionHeader(
            sessionId: "test1", startTimeIso: "x", preset: "march",
            intensityLevelAtStart: 2, appVersion: "1.11.10", isRealRobot: true,
            balanceAlgorithmMode: "hybridBA",
            walkingEngine: "macSparseKeyframe",
            pitchInputConvention: "negateForwardIsNegative",
            hipPitchOffsetTrimDegAtStart: 5.0
        )
        let s = mockSummary(id: "test1", preset: "march")
        let prompt = WalkSessionClaudePromptV2.build(
            sessions: [s],
            headers: ["test1": h],
            userReport: "",
            sampleStatsBuilder: { _ in [] }
        )
        XCTAssertTrue(prompt.contains("walkingEngine"), "axis name")
        XCTAssertTrue(prompt.contains("macSparseKeyframe"), "axis value")
        XCTAssertTrue(prompt.contains("hybridBA"), "algorithm value")
        XCTAssertTrue(prompt.contains("negateForwardIsNegative"), "pitchInput value")
        XCTAssertTrue(prompt.contains("5.0"), "trim value")
    }

    // MARK: - 8. Analyst markdown fence strip

    func testStripMarkdownFenceWithJsonTag() {
        let input = "```json\n{\"a\":1}\n```"
        XCTAssertEqual(WalkSessionClaudeAnalyst.stripMarkdownFence(input), "{\"a\":1}")
    }

    func testStripMarkdownFencePlain() {
        let input = "```\n{\"a\":1}\n```"
        XCTAssertEqual(WalkSessionClaudeAnalyst.stripMarkdownFence(input), "{\"a\":1}")
    }

    func testStripMarkdownFenceNoFence() {
        let input = "{\"a\":1}"
        XCTAssertEqual(WalkSessionClaudeAnalyst.stripMarkdownFence(input), "{\"a\":1}")
    }

    // MARK: - Helpers

    private func mockHeader(isReal: Bool = true, applyMode: String = "robotApplied") -> WalkSessionHeader {
        WalkSessionHeader(
            sessionId: "test", startTimeIso: "x", preset: "march",
            intensityLevelAtStart: 2, appVersion: "1.11.10", isRealRobot: isReal,
            correctionApplyMode: applyMode
        )
    }

    private func mockSummary(id: String, preset: String) -> WalkSessionSummary {
        WalkSessionSummary(
            id: id, preset: preset, startTimeIso: "x",
            durationSec: 10, sampleCount: 200, intensityLevelUsed: 2,
            meanAbsRoll: 5, meanAbsPitch: 13, rollStdev: 3, pitchStdev: 4,
            peakAbsRoll: 18, peakAbsPitch: 25,
            oscillationScore: 1.5, correctorEffectivenessScore: 0.3,
            recommendedIntensityLevel: 3, recommendationReason: "test", confidence: 0.7
        )
    }

    private func mockSample(t: Double, walkPhase: Double?, pitch: Double, roll: Double,
                            imuSeq: UInt32? = nil, ageMs: Double? = nil,
                            applied: [Double]? = nil) -> WalkSessionSample {
        WalkSessionSample(
            t: t, preset: "march", intensityLevel: 2,
            imuRollDeg: roll, imuPitchDeg: pitch,
            correctorRollErrDeg: 0, correctorPitchErrDeg: 0,
            balanceState: "normal",
            correctorDeltas: Array(repeating: 0.0, count: 8),
            imuSource: "real", batteryVolts: nil, motorAvgTemp: nil,
            imuSampleAgeMs: ageMs,
            walkPhase01: walkPhase,
            appliedDeltas: applied,
            imuSequence: imuSeq
        )
    }
}
