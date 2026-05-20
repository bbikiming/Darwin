import Foundation

/// **v1.11.11 (2026-05-19)** — A/B 실험 loop backbone.
///
/// 진단 문서 §5 "비교 실험 단위" + Agent 5 architect 설계.
///
/// **책임**:
/// - experimentId 발급 + baseline 고정
/// - **한 번에 한 axis 만** 변경 강제 (assert)
/// - baseline 세션 vs 실험 세션 summary 비교 → success metric 자동 계산
/// - 위험 metric 변화 시 rollback 권고 (deterministic)
///
/// **Critic-Controller 분리**:
/// - Critic (Claude) → `NextExperiment` 권고 (논리적 제안)
/// - Controller (이 actor) → 사용자 명시 승인 후 실행 + 결과 비교
/// - safetyVerdict.blocked 변경은 자동 reject (deterministic gate)
public actor WalkLabExperimentLoop {

    /// 진행 중 실험 — 동시 1개만.
    private(set) public var current: Experiment? = nil

    /// 완료된 실험 history (메모리 + 디스크).
    private(set) public var history: [Experiment] = []

    public struct Experiment: Codable, Identifiable, Sendable, Equatable {
        public let id: String                   // exp-{ISO timestamp}-{4 char}
        public let baselineSessionId: String
        public let proposal: ClaudeCriticResponse.NextExperimentRecord  // critic 권고 snapshot
        public let approvedAt: String           // ISO
        public var experimentSessionIds: [String] = []   // 실험 실행 시 기록되는 세션 ids
        public var verdict: Verdict? = nil       // 비교 후 결정
        public var verdictReason: String? = nil

        public enum Verdict: String, Codable, Sendable, CaseIterable {
            case success         // success metric 통과
            case failRollback    // rollback 권고
            case inconclusive    // 데이터 부족
        }
    }

    public init() {
        Task {
            await loadHistory()
        }
    }

    /// **사용자 승인 후 호출**: critic 권고 → experiment 등록.
    /// - safetyVerdict.blocked 인 변경은 자동 reject.
    /// - 진행 중 실험 있으면 reject (중복 차단).
    /// - 정확히 1 axis 변경 invariant.
    public func startExperiment(
        from response: ClaudeCriticResponse,
        baselineSessionId: String,
        proposedConfig: BalanceExperimentConfig
    ) -> StartResult {
        guard current == nil else {
            return .failure("이미 진행 중인 실험 있음 (\(current!.id)) — 종료 후 재시도")
        }
        guard let next = response.nextExperiment else {
            return .failure("Critic 응답에 nextExperiment 없음")
        }
        guard next.changeOneAxisOnly else {
            return .failure("changeOneAxisOnly=false — multi-axis 차단")
        }
        // Deterministic safety: applyToRobot=true 인 새 config 가 blocked 면 reject.
        if case .blocked(let reason) = proposedConfig.safetyVerdict {
            return .failure("safetyVerdict.blocked — \(reason)")
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let id = "exp-\(isoFormatter.string(from: Date()))-\(String(UUID().uuidString.prefix(4)))"
        let proposalRecord = ClaudeCriticResponse.NextExperimentRecord(
            axis: next.axis.rawValue,
            from: next.from, to: next.to,
            preset: next.preset, safety: next.safety,
            successMetric: next.successMetric,
            rollbackCondition: next.rollbackCondition,
            riskNote: next.riskNote
        )
        let exp = Experiment(
            id: id,
            baselineSessionId: baselineSessionId,
            proposal: proposalRecord,
            approvedAt: isoFormatter.string(from: Date())
        )
        current = exp
        return .success(id)
    }

    /// 실험 세션 ID 등록 — 보행 1회 끝났을 때 호출.
    public func appendExperimentSession(_ sessionId: String) {
        guard var exp = current else { return }
        exp.experimentSessionIds.append(sessionId)
        current = exp
    }

    /// 실험 비교 — baseline summary vs experiment summary 들의 평균 성능.
    /// 성공/실패/inconclusive 판정.
    public func compareWithBaseline(
        baselineSummary: WalkSessionSummary,
        experimentSummaries: [WalkSessionSummary]
    ) -> ComparisonResult {
        guard let exp = current else {
            return ComparisonResult(verdict: .inconclusive,
                                    reason: "진행 중 실험 없음",
                                    metrics: [:])
        }
        guard !experimentSummaries.isEmpty else {
            return ComparisonResult(verdict: .inconclusive,
                                    reason: "실험 세션 0건 — 보행 1회 이상 실행 필요",
                                    metrics: [:])
        }
        // **v1.11.14 (2026-05-19)** — 다축 metric 비교. 진단 문서 §4 verdict 단순함 fix.
        func avg(_ kp: KeyPath<WalkSessionSummary, Double>) -> Double {
            experimentSummaries.map { $0[keyPath: kp] }.reduce(0, +) / Double(experimentSummaries.count)
        }
        func avgInt(_ kp: KeyPath<WalkSessionSummary, Int>) -> Double {
            Double(experimentSummaries.map { $0[keyPath: kp] }.reduce(0, +)) / Double(experimentSummaries.count)
        }

        // Pitch 변화 (음수 = 개선).
        let basePitchMean = baselineSummary.meanAbsPitch
        let expPitchMean = avg(\.meanAbsPitch)
        let basePitchPeak = baselineSummary.peakAbsPitch
        let expPitchPeak = avg(\.peakAbsPitch)
        let pitchDelta = expPitchMean - basePitchMean
        let peakPitchDelta = expPitchPeak - basePitchPeak

        // Roll 변화 (악화 검출).
        let baseRollMean = baselineSummary.meanAbsRoll
        let expRollMean = avg(\.meanAbsRoll)
        let baseRollPeak = baselineSummary.peakAbsRoll
        let expRollPeak = avg(\.peakAbsRoll)
        let rollDelta = expRollMean - baseRollMean
        let peakRollDelta = expRollPeak - baseRollPeak

        // Data quality (verdict / stale / duplicate / bus / appliedZero).
        let expQualityFails = experimentSummaries.filter {
            $0.dataQuality?.verdict == .fail
        }.count
        let avgStaleRatio = experimentSummaries.compactMap { $0.dataQuality?.staleSampleRatio }
            .reduce(0, +) / Double(max(1, experimentSummaries.count))
        let avgBusFails = experimentSummaries.compactMap { $0.dataQuality?.busWriteFailureDelta }
            .reduce(0, +)

        // Sample count (abort 검출 — baseline 대비 70% 미만이면 의심).
        let baseSampleCount = baselineSummary.sampleCount
        let expSampleCount = Int(avgInt(\.sampleCount))
        let sampleRatio = baseSampleCount > 0 ? Double(expSampleCount) / Double(baseSampleCount) : 1.0
        let abortLike = sampleRatio < 0.7

        // Sagittal drift (앞기울 누적).
        let avgDrift = experimentSummaries.compactMap { $0.sagittal?.pitchDriftPerSec }
            .reduce(0, +) / Double(max(1, experimentSummaries.count))

        let metrics: [String: Double] = [
            "baseline_meanAbsPitch": basePitchMean,
            "experiment_meanAbsPitch": expPitchMean,
            "delta_meanAbsPitch": pitchDelta,
            "baseline_peakAbsPitch": basePitchPeak,
            "experiment_peakAbsPitch": expPitchPeak,
            "delta_peakAbsPitch": peakPitchDelta,
            "baseline_meanAbsRoll": baseRollMean,
            "experiment_meanAbsRoll": expRollMean,
            "delta_meanAbsRoll": rollDelta,
            "delta_peakAbsRoll": peakRollDelta,
            "experiment_qualityFails": Double(expQualityFails),
            "experiment_avgStaleRatio": avgStaleRatio,
            "experiment_busFailures": Double(avgBusFails),
            "experiment_sampleCountRatio": sampleRatio,
            "experiment_pitchDriftPerSec": avgDrift,
        ]

        // **다축 verdict 규칙** (우선순위 — 위 → 아래로 가장 보수적 verdict).
        // **v1.11.14.7 — 사용자 평가 MED fix**: 임계값 ExperimentThresholds 외부화.
        // 종전 hardcode 값 (peakPitchDelta>=10 등) → UserDefaults 저장 가능한 struct.
        // 단, actor 격리 라 UserDefaults read 는 caller (main actor) 가 미리 read.
        let t = ExperimentThresholds.loadFromDisk()
        let verdict: Experiment.Verdict
        let reason: String
        if expQualityFails > 0 {
            verdict = .inconclusive
            reason = "실험 세션 \(expQualityFails)건 data quality fail — 재수집 필요"
        } else if sampleRatio < t.abortSampleRatio {
            verdict = .failRollback
            reason = "실험 세션 sampleCount 가 baseline 의 \(String(format: "%.0f", sampleRatio * 100))% — abort/fall 의심"
        } else if peakPitchDelta >= t.peakPitchDeltaFailDeg {
            verdict = .failRollback
            reason = "peakAbsPitch 가 baseline 대비 +\(String(format: "%.1f", peakPitchDelta))° 증가"
        } else if peakRollDelta >= t.peakRollDeltaFailDeg {
            verdict = .failRollback
            reason = "peakAbsRoll 가 +\(String(format: "%.1f", peakRollDelta))° 악화 — lateral 안정성 손실"
        } else if avgBusFails > t.busFailsMax {
            verdict = .failRollback
            reason = "bus write 실패 누적 \(Int(avgBusFails))건 — 통신 불안정"
        } else if avgStaleRatio > t.maxStaleRatio {
            verdict = .inconclusive
            reason = "IMU staleness \(String(format: "%.0f", avgStaleRatio * 100))% — 데이터 신뢰도 부족"
        } else if pitchDelta <= t.successPitchDelta && peakPitchDelta <= t.successPeakPitchDelta
                  && rollDelta <= t.successRollDelta && peakRollDelta <= t.successPeakRollDelta {
            verdict = .success
            reason = "pitch \(String(format: "%+.1f", pitchDelta))°/peak\(String(format: "%+.1f", peakPitchDelta))°, roll \(String(format: "%+.1f", rollDelta))°/peak\(String(format: "%+.1f", peakRollDelta))° — 다축 성공 기준 충족"
        } else {
            verdict = .inconclusive
            reason = "pitch \(String(format: "%+.1f", pitchDelta))°, roll \(String(format: "%+.1f", rollDelta))°, drift \(String(format: "%+.2f", avgDrift))°/s — 추가 보행 권고"
        }
        // abortLike 변수는 신 임계값 기반 — sampleRatio 비교에서 제거.
        _ = abortLike
        // 결과 저장.
        var updated = exp
        updated.verdict = verdict
        updated.verdictReason = reason
        current = updated
        return ComparisonResult(verdict: verdict, reason: reason, metrics: metrics)
    }

    /// 실험 완료 → history 이동.
    public func finalize() {
        guard let exp = current else { return }
        history.insert(exp, at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        current = nil
        Task { await saveHistory() }
    }

    /// 진행 중 실험 즉시 cancel (사용자 abort).
    public func cancel() {
        current = nil
    }

    public enum StartResult: Sendable {
        case success(String)         // experimentId
        case failure(String)          // 이유
    }

    public struct ComparisonResult: Sendable {
        public let verdict: Experiment.Verdict
        public let reason: String
        public let metrics: [String: Double]
    }

    // MARK: - Disk persistence

    private static let historyFileName = "experiment-loop-history.json"

    /// non-isolated 직접 path 계산 (analysesDir 가 @MainActor 라 actor 안에서 접근 불가).
    private static func resolveHistoryFileURL() -> URL? {
        let fm = FileManager.default
        guard let appSup = try? fm.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil, create: true) else {
            return nil
        }
        return appSup
            .appendingPathComponent("DarwinForge", isDirectory: true)
            .appendingPathComponent("analyses", isDirectory: true)
            .appendingPathComponent(historyFileName)
    }

    private func loadHistory() async {
        guard let url = Self.resolveHistoryFileURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Experiment].self, from: data)
        else { return }
        history = decoded
    }

    private func saveHistory() async {
        guard let url = Self.resolveHistoryFileURL() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(history) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Codable record for ClaudeCriticResponse.NextExperiment

extension ClaudeCriticResponse {
    /// 실험 snapshot 용 — NextExperiment 의 axis 만 String 으로 캡처.
    /// Codable 호환을 위해 별도 struct.
    public struct NextExperimentRecord: Codable, Equatable, Sendable {
        public let axis: String
        public let from: String
        public let to: String
        public let preset: String
        public let safety: String
        public let successMetric: String
        public let rollbackCondition: String
        public let riskNote: String?

        public init(axis: String, from: String, to: String, preset: String,
                    safety: String, successMetric: String, rollbackCondition: String,
                    riskNote: String?) {
            self.axis = axis
            self.from = from
            self.to = to
            self.preset = preset
            self.safety = safety
            self.successMetric = successMetric
            self.rollbackCondition = rollbackCondition
            self.riskNote = riskNote
        }
    }
}
