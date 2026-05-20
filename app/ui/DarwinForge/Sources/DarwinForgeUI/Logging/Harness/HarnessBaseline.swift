import Foundation

// MARK: - HarnessBaseline (v1.14.0, 2026-05-20)
//
// 세션 간 비교 — 사용자가 한 세션을 baseline 으로 지정 → 새 세션 vs baseline diff.
// "이번이 지난번보다 나아졌나?" 에 직접 답하는 모듈.
//
// 자세한 설계: docs/harness/log-utilization-system.md

public struct MetricDelta: Sendable, Equatable {
    public let label: String
    public let baseline: Double?
    public let current: Double?
    public let deltaAbsolute: Double?    // current - baseline
    public let deltaPercent: Double?     // (current - baseline) / baseline * 100
    /// "낮을수록 좋은 지표인가" — verdict 가중치 계산용.
    public let lowerIsBetter: Bool
}

public struct CountDelta: Sendable, Equatable {
    public let label: String
    public let baseline: Int
    public let current: Int
    public let delta: Int                // current - baseline
    public let lowerIsBetter: Bool
}

public struct SessionDiff: Sendable, Equatable {
    public let baselineId: String
    public let currentId: String
    public let metrics: [MetricDelta]
    public let counts: [CountDelta]
    public let verdict: Verdict
    /// 가중 변화 score — 음수 = 개선 / 양수 = 회귀.
    public let weightedScorePercent: Double

    public enum Verdict: Sendable, Equatable {
        case improvement(reason: String)
        case regression(reason: String)
        case similar
    }
}

public enum HarnessBaseline {

    // MARK: - 핵심 API

    /// baseline 세션 분석 + 현재 세션 분석 → SessionDiff.
    public static func compare(baseline: (id: String, analysis: SessionAnalysis),
                                 current: (id: String, analysis: SessionAnalysis)) -> SessionDiff {
        let metrics = computeMetricDeltas(baseline: baseline.analysis, current: current.analysis)
        let counts = computeCountDeltas(baseline: baseline.analysis, current: current.analysis)
        let (verdict, score) = computeVerdict(metrics: metrics, counts: counts)
        return SessionDiff(
            baselineId: baseline.id,
            currentId: current.id,
            metrics: metrics,
            counts: counts,
            verdict: verdict,
            weightedScorePercent: score
        )
    }

    // MARK: - Metric deltas

    private static func computeMetricDeltas(baseline: SessionAnalysis,
                                              current: SessionAnalysis) -> [MetricDelta] {
        var out: [MetricDelta] = []
        out.append(makeDelta(label: "RTT p95 (ms)",
                             baseline: baseline.summary.rttMs?.p95,
                             current: current.summary.rttMs?.p95,
                             lowerIsBetter: true))
        out.append(makeDelta(label: "RTT mean (ms)",
                             baseline: baseline.summary.rttMs?.mean,
                             current: current.summary.rttMs?.mean,
                             lowerIsBetter: true))
        out.append(makeDelta(label: "배터리 min (V)",
                             baseline: baseline.summary.batteryV?.min,
                             current: current.summary.batteryV?.min,
                             lowerIsBetter: false))
        out.append(makeDelta(label: "IMU stale ratio",
                             baseline: baseline.summary.imuStaleRatio,
                             current: current.summary.imuStaleRatio,
                             lowerIsBetter: true))
        out.append(makeDelta(label: "연결 성공률",
                             baseline: ratio(baseline.summary.connectSuccesses,
                                              baseline.summary.connectAttempts),
                             current: ratio(current.summary.connectSuccesses,
                                              current.summary.connectAttempts),
                             lowerIsBetter: false))
        return out
    }

    private static func makeDelta(label: String,
                                    baseline: Double?,
                                    current: Double?,
                                    lowerIsBetter: Bool) -> MetricDelta {
        let abs = (baseline != nil && current != nil) ? (current! - baseline!) : nil
        let pct: Double? = {
            guard let b = baseline, let c = current, b != 0 else { return nil }
            return (c - b) / b * 100.0
        }()
        return MetricDelta(label: label,
                           baseline: baseline, current: current,
                           deltaAbsolute: abs, deltaPercent: pct,
                           lowerIsBetter: lowerIsBetter)
    }

    private static func ratio(_ num: Int, _ den: Int) -> Double? {
        guard den > 0 else { return nil }
        return Double(num) / Double(den)
    }

    // MARK: - Count deltas

    private static func computeCountDeltas(baseline: SessionAnalysis,
                                             current: SessionAnalysis) -> [CountDelta] {
        return [
            CountDelta(label: "에러", baseline: baseline.summary.errorCount,
                       current: current.summary.errorCount, delta: current.summary.errorCount - baseline.summary.errorCount, lowerIsBetter: true),
            CountDelta(label: "경고", baseline: baseline.summary.warnCount,
                       current: current.summary.warnCount, delta: current.summary.warnCount - baseline.summary.warnCount, lowerIsBetter: true),
            CountDelta(label: "Bus 읽기 실패", baseline: baseline.summary.busReadFailures,
                       current: current.summary.busReadFailures, delta: current.summary.busReadFailures - baseline.summary.busReadFailures, lowerIsBetter: true),
            CountDelta(label: "Bus 쓰기 실패", baseline: baseline.summary.busWriteFailures,
                       current: current.summary.busWriteFailures, delta: current.summary.busWriteFailures - baseline.summary.busWriteFailures, lowerIsBetter: true),
            CountDelta(label: "E-stop", baseline: baseline.summary.eStops,
                       current: current.summary.eStops, delta: current.summary.eStops - baseline.summary.eStops, lowerIsBetter: true),
            CountDelta(label: "보행 시작", baseline: baseline.summary.walkLabStarts,
                       current: current.summary.walkLabStarts, delta: current.summary.walkLabStarts - baseline.summary.walkLabStarts, lowerIsBetter: false),
            CountDelta(label: "보행 비상 정지", baseline: baseline.summary.walkLabEmergencyStops,
                       current: current.summary.walkLabEmergencyStops, delta: current.summary.walkLabEmergencyStops - baseline.summary.walkLabEmergencyStops, lowerIsBetter: true),
            CountDelta(label: "보행 차단", baseline: baseline.summary.walkLabStartBlocks,
                       current: current.summary.walkLabStartBlocks, delta: current.summary.walkLabStartBlocks - baseline.summary.walkLabStartBlocks, lowerIsBetter: true),
        ]
    }

    // MARK: - Verdict

    /// 가중 합 — 음수 = 개선 / 양수 = 회귀. ±20% 이상이면 verdict 발화.
    ///
    /// **v1.14.1 (Critic P1-2 fix, 2026-05-21)** — baseline=0, current>0 인 count 지표
    /// (특히 e-stop / emergency stop) 가 `relativeChange` nil 반환으로 verdict 가중치에서
    /// 빠지던 안전 critical false negative 수정. 0 → N (>0) 은 명시적 sentinel 로
    /// 회귀 (가중치 100% 적용). 그리고 0 → 0 은 0%.
    private static func computeVerdict(metrics: [MetricDelta], counts: [CountDelta])
            -> (SessionDiff.Verdict, Double) {
        // 핵심 지표 가중치:
        //   RTT p95: 1, 연결 성공률: 2, 에러 카운트: 1, e-stop: 3, 보행 차단: 1.
        var weighted: Double = 0
        var totalWeight: Double = 0
        var reasonsImproved: [String] = []
        var reasonsRegressed: [String] = []
        /// **v1.14.1 Critic P1-2** — count 가 0 → >0 인 경우 절대 회귀 마커.
        /// `relativeChange` 가 nil 이라도 verdict 가 .regression 으로 강제되도록.
        var hardRegressionMarker = false

        // **v1.14.1 Code-reviewer P1-1 fix** — metric 한 번만 lookup, force unwrap 제거.
        if let rttMetric = metrics.first(where: { $0.label == "RTT p95 (ms)" }),
           let rttDelta = rttMetric.deltaPercent {
            let signed = rttDelta * (rttMetric.lowerIsBetter ? 1.0 : -1.0)
            weighted += signed * 1.0
            totalWeight += 1.0
            if rttDelta > 30 { reasonsRegressed.append("RTT p95 +\(Int(rttDelta))%") }
            else if rttDelta < -20 { reasonsImproved.append("RTT p95 \(Int(rttDelta))%") }
        }
        // 연결 성공률.
        if let connDelta = metrics.first(where: { $0.label == "연결 성공률" })?.deltaPercent {
            let signed = connDelta * -1     // lowerIsBetter=false → 부호 반전.
            weighted += signed * 2.0
            totalWeight += 2.0
            if connDelta < -10 { reasonsRegressed.append("연결 성공률 \(Int(connDelta))%") }
            else if connDelta > 10 { reasonsImproved.append("연결 성공률 +\(Int(connDelta))%") }
        }
        // 에러 카운트.
        if let errCount = counts.first(where: { $0.label == "에러" }) {
            if let p = relativeChange(baseline: errCount.baseline, current: errCount.current) {
                weighted += p * 1.0; totalWeight += 1.0
                if p > 50 { reasonsRegressed.append("에러 +\(Int(p))%") }
                else if p < -50 { reasonsImproved.append("에러 \(Int(p))%") }
            } else if errCount.current > errCount.baseline {
                // baseline=0, current>0 — sentinel 회귀.
                weighted += 100 * 1.0; totalWeight += 1.0
                reasonsRegressed.append("에러 0 → \(errCount.current)")
                hardRegressionMarker = true
            }
        }
        // E-stop — 큰 가중치. **안전 critical**: baseline=0 → current>0 도 반드시 회귀.
        if let estop = counts.first(where: { $0.label == "E-stop" }) {
            if let p = relativeChange(baseline: estop.baseline, current: estop.current) {
                weighted += p * 3.0; totalWeight += 3.0
                if p > 0 { reasonsRegressed.append("E-stop +\(estop.delta)") }
                else if p < 0 { reasonsImproved.append("E-stop \(estop.delta)") }
            } else if estop.current > estop.baseline {
                // **Critic P1-2 — 핵심 안전 fix**: baseline=0, current>0 인 e-stop 증가는
                // 가중치 3 으로 강한 회귀. hardRegressionMarker 도 set 해서 verdict 보장.
                weighted += 100 * 3.0; totalWeight += 3.0
                reasonsRegressed.append("E-stop 0 → \(estop.current)")
                hardRegressionMarker = true
            }
        }
        // 보행 차단.
        if let blocked = counts.first(where: { $0.label == "보행 차단" }) {
            if let p = relativeChange(baseline: blocked.baseline, current: blocked.current) {
                weighted += p * 1.0; totalWeight += 1.0
            } else if blocked.current > blocked.baseline {
                weighted += 100 * 1.0; totalWeight += 1.0
                reasonsRegressed.append("보행 차단 0 → \(blocked.current)")
                hardRegressionMarker = true
            }
        }
        // 보행 비상 정지 (별도 카운터).
        if let walkEstop = counts.first(where: { $0.label == "보행 비상 정지" }) {
            if let p = relativeChange(baseline: walkEstop.baseline, current: walkEstop.current) {
                weighted += p * 3.0; totalWeight += 3.0
            } else if walkEstop.current > walkEstop.baseline {
                weighted += 100 * 3.0; totalWeight += 3.0
                reasonsRegressed.append("보행 비상 정지 0 → \(walkEstop.current)")
                hardRegressionMarker = true
            }
        }

        let scorePct = totalWeight > 0 ? weighted / totalWeight : 0
        // hardRegressionMarker 가 set 됐는데 scorePct 가 +20% 미달하면 (다른 지표가 강하게
        // 개선됐을 때) 사용자에게 "안전 측면은 회귀했음" 을 분명히 표현하려고
        // 최소 +21% 로 부스트. 종합 verdict 가 안전 회귀를 묻히지 않도록.
        let effectiveScore = (hardRegressionMarker && scorePct < 21) ? 21.0 : scorePct
        if effectiveScore > 20 {
            let reason = reasonsRegressed.isEmpty ? "지표 종합 +\(Int(effectiveScore))%" : reasonsRegressed.joined(separator: ", ")
            return (.regression(reason: reason), effectiveScore)
        }
        if effectiveScore < -20 {
            let reason = reasonsImproved.isEmpty ? "지표 종합 \(Int(effectiveScore))%" : reasonsImproved.joined(separator: ", ")
            return (.improvement(reason: reason), effectiveScore)
        }
        return (.similar, effectiveScore)
    }

    /// 정수 baseline → current 의 상대 변화 %.
    /// baseline=0 인 경우 — 0/0 = 0%, 0/N (N>0) 은 nil 반환 (수학적 정의 불가).
    /// 호출자가 nil 인 경우 "0 → N" 패턴을 별도 처리해야 안전.
    private static func relativeChange(baseline: Int, current: Int) -> Double? {
        if baseline == 0 {
            return current == 0 ? 0 : nil
        }
        return Double(current - baseline) / Double(baseline) * 100.0
    }

    // MARK: - Baseline 선택 / 저장 (Inspector 가 사용)

    /// UserDefaults 키 — 동시에 1개만.
    public static let baselineSessionIdKey = "harness.baseline_session_id"

    public static func currentBaselineId() -> String? {
        UserDefaults.standard.string(forKey: baselineSessionIdKey)
    }

    public static func setBaseline(_ id: String?) {
        if let id = id {
            UserDefaults.standard.set(id, forKey: baselineSessionIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: baselineSessionIdKey)
        }
    }

    /// **v1.14.1 (Critic P1-1 fix, 2026-05-21)** — UserDefaults + 모든 세션의 meta.json
    /// `isBaseline` 필드 동기화. 이전 baseline 의 isBaseline=false, 새 baseline 의
    /// isBaseline=true. UserDefaults 가 손실되더라도 meta.json 으로 복원 가능 +
    /// JSON Export 의 isBaseline 필드가 실제 상태 반영.
    @MainActor
    public static func setBaselineWithMetaSync(_ newId: String?) {
        let previousId = currentBaselineId()
        // 1) UserDefaults 갱신 — fast 경로.
        setBaseline(newId)
        // 2) 디스크의 모든 archived 세션의 meta.json 동기화.
        //    이전 baseline → false, 새 baseline → true.
        let allSessions = TelemetryStore.archivedSessions()
        for (dir, meta) in allSessions {
            let shouldBeBaseline = (meta.id == newId)
            let wasBaseline = (meta.id == previousId)
            // 변경 필요한 세션만 디스크 write — I/O 최소화.
            if shouldBeBaseline != meta.isBaseline || (wasBaseline && !shouldBeBaseline) {
                writeMetaIsBaseline(dir: dir, meta: meta, isBaseline: shouldBeBaseline)
            }
        }
    }

    private static func writeMetaIsBaseline(dir: URL, meta: TelemetrySessionMeta, isBaseline: Bool) {
        var updated = meta
        updated.isBaseline = isBaseline
        let url = dir.appendingPathComponent("meta.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(updated) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
