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
        // 단순 metric 비교: meanAbsPitch 평균.
        let baseMeanPitch = baselineSummary.meanAbsPitch
        let expMeanPitch = experimentSummaries.map(\.meanAbsPitch).reduce(0, +) / Double(experimentSummaries.count)
        let basePeakPitch = baselineSummary.peakAbsPitch
        let expPeakPitch = experimentSummaries.map(\.peakAbsPitch).reduce(0, +) / Double(experimentSummaries.count)

        let pitchDelta = expMeanPitch - baseMeanPitch    // 음수 = 개선
        let peakDelta = expPeakPitch - basePeakPitch
        let metrics: [String: Double] = [
            "baseline_meanAbsPitch": baseMeanPitch,
            "experiment_meanAbsPitch": expMeanPitch,
            "delta_meanAbsPitch": pitchDelta,
            "baseline_peakAbsPitch": basePeakPitch,
            "experiment_peakAbsPitch": expPeakPitch,
            "delta_peakAbsPitch": peakDelta,
        ]
        // 권고: success metric 에 명시된 변화량 매칭 시도.
        // 간단 규칙: meanAbsPitch 감소 ≥ 0.5° AND peakAbsPitch 증가 ≤ 5° → success
        // peakAbsPitch 증가 ≥ 10° → failRollback (위험)
        // 그 외 → inconclusive
        let verdict: Experiment.Verdict
        let reason: String
        if peakDelta >= 10.0 {
            verdict = .failRollback
            reason = "peakAbsPitch 가 baseline 대비 +\(String(format: "%.1f", peakDelta))° 증가 — rollback 권고"
        } else if pitchDelta <= -0.5 && peakDelta <= 5.0 {
            verdict = .success
            reason = "meanAbsPitch \(String(format: "%+.1f", pitchDelta))°, peak \(String(format: "%+.1f", peakDelta))° — 성공 기준 충족"
        } else {
            verdict = .inconclusive
            reason = "meanAbsPitch \(String(format: "%+.1f", pitchDelta))°, peak \(String(format: "%+.1f", peakDelta))° — 추가 데이터 권고"
        }
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
