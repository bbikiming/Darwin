import Foundation
import Observation

/// **v1.20.45 (2026-05-22) 사이클 59 — input → engine latency tracker**.
///
/// critic 지적 응답 — keyboard press → robot joint 변화까지 end-to-end latency 가
/// "game character" 경험의 유일한 정량 기준. 본 tracker 는 WalkLabRCBridge 파이프라인의
/// 4 단계 (`inputReceived` → `safetyGated` → `amplitudeApplied` → `engineSynced`) 각 시각을
/// 기록 → ring buffer 누적 → median / p95 / max 통계 제공. 실 motor 시간은 hw 가 노출
/// 안 해 미측정 — engine sync 까지만 capture.
///
/// # 비유
///
/// 비행기 black box — 매 비행마다 4 sensor (입력 / 안전 / 보조 / 엔진) 의 시각을 기록.
/// 30 비행분만 ring 으로 유지하고, "최근 평균 응답 시간" 을 한 줄로 보여줌. 비행기 가
/// 비정상이면 oldest 부터 덮어쓰는 한도가 있다.
///
/// # 비활성 사용 (default)
///
/// `bridge.latencyTracker = nil` (default) 일 때 record 호출 자체가 없음 → overhead 0.
/// 측정 원할 때만 `bridge.latencyTracker = PilotLatencyTracker()` 으로 활성.
///
/// # @MainActor + @Observable
///
/// HUD 가 statistics 를 reactive 하게 표시할 수 있도록 @Observable. record 호출은
/// bridge 의 main actor context 안에서 이루어짐.
@MainActor
@Observable
public final class PilotLatencyTracker {

    // MARK: - Stages

    /// 측정 단계 — keyboard press → engine sync 파이프라인.
    public enum Stage: String, Sendable, Hashable, CaseIterable {
        /// process(_:) 진입 — bridge 가 intent 수신 즉시.
        case inputReceived
        /// safetyGate (enabled / emergencyStopActive / preflight) 통과 직후.
        case safetyGated
        /// applyAmplitude 가 session.strideMm 등 setter 호출 직후.
        case amplitudeApplied
        /// session.syncCommandToEngine 호출 직후. 실 motor 는 hw — 본 layer 까지.
        case engineSynced
    }

    /// 통계 산출 범위 — stage 간 delta 또는 end-to-end.
    public enum Span: String, Sendable, Hashable {
        /// inputReceived → engineSynced (사용자가 체감하는 응답 시간).
        case endToEnd
        /// inputReceived → safetyGated (안전 검사 비용).
        case safety
        /// safetyGated → amplitudeApplied (slider mutation 비용).
        case amplitude
        /// amplitudeApplied → engineSynced (engine sync 비용).
        case engine
    }

    /// Span 통계 — count / median / p95 / max (초 단위).
    public struct Statistics: Equatable, Sendable {
        public let count: Int
        public let median: TimeInterval
        public let p95: TimeInterval
        public let max: TimeInterval

        public static let zero = Statistics(count: 0, median: 0, p95: 0, max: 0)
    }

    // MARK: - State

    /// ring buffer 용량 — 가장 최근 N cycles 만 유지. 기본 30.
    public let capacity: Int

    /// 한 cycle 의 stage → timestamp 매핑. cycle 완료 시 deltas 로 변환 후 ring 에 push.
    /// `_currentCycle` 는 현재 진행 중인 cycle (아직 engineSynced 미수신).
    private var _currentCycle: [Stage: Date] = [:]

    /// 완료된 cycle 의 delta. FIFO — 새 cycle 추가 시 capacity 초과면 oldest drop.
    private var _completedDeltas: [CompletedCycle] = []

    /// **사이클 71 — 코덱스 CRITICAL-1 fix**: 거부 (rejected) 카운터.
    /// process() 의 early-return path (emergency / blocked / disabled 등) 에서 호출되는
    /// `cancel()` 가 +1. statistics 는 **accepted cycle 만** 산출 — 정확한 latency 의미 보존.
    /// 사용자는 rejected 비율을 별도 visibility 로 확인 (UI 가 표시).
    public private(set) var rejectedCount: Int = 0

    public init(capacity: Int = 30) {
        precondition(capacity > 0, "capacity must be > 0")
        self.capacity = capacity
        self._completedDeltas.reserveCapacity(capacity)
    }

    // MARK: - Record

    /// stage 시각 기록. `engineSynced` 수신 시 cycle 완료 → ring 에 push.
    ///
    /// 같은 cycle 안에서 동일 stage 재호출은 마지막 값으로 덮어쓰기 (재시도 시나리오).
    /// 새 `inputReceived` 가 들어오면 진행 중 cycle (engineSynced 못 받음) 은 폐기 — 사용자가
    /// 연타 시 partial cycle 누적 차단.
    public func record(stage: Stage, timestamp: Date = Date()) {
        if stage == .inputReceived && !_currentCycle.isEmpty {
            // 이전 cycle 미완료 (engineSynced 못 받음) — 폐기.
            _currentCycle.removeAll(keepingCapacity: true)
        }
        _currentCycle[stage] = timestamp

        if stage == .engineSynced {
            if let completed = CompletedCycle(from: _currentCycle) {
                appendCompleted(completed)
            }
            _currentCycle.removeAll(keepingCapacity: true)
        }
    }

    private func appendCompleted(_ cycle: CompletedCycle) {
        _completedDeltas.append(cycle)
        if _completedDeltas.count > capacity {
            _completedDeltas.removeFirst(_completedDeltas.count - capacity)
        }
    }

    // MARK: - Statistics

    /// `span` 에 해당하는 모든 완료 cycle 의 통계 산출.
    /// 빈 ring → `.zero` 반환.
    public func statistics(for span: Span) -> Statistics {
        let samples: [TimeInterval] = _completedDeltas.compactMap { $0.delta(for: span) }
        guard !samples.isEmpty else { return .zero }
        let sorted = samples.sorted()
        return Statistics(
            count: sorted.count,
            median: Self.median(sorted: sorted),
            p95: Self.percentile(sorted: sorted, q: 0.95),
            max: sorted.last ?? 0
        )
    }

    /// **사이클 71 — 코덱스 CRITICAL-1 fix**: 현재 진행 중 cycle 의 명시 거부 (rejected).
    ///
    /// process() 의 early-return path (emergency / blocked / disabled 등) 에서 호출.
    /// 종전 동작: orphan cycle 이 _currentCycle 에 잔존 → 다음 inputReceived 가 자동 폐기 →
    /// statistics 에 영향 0. 그러나 사용자가 "rejected 비율" 을 알 수 없어 진단 어려움.
    /// 신규: cancel() 호출 시 `rejectedCount += 1` + _currentCycle 즉시 clear. UI 가
    /// rejected 비율을 별도 표시 가능 (예: "5 sample / 12 rejected").
    ///
    /// **호출 site (process / applyAmplitude 의 5+ early-return)**:
    /// 1. no-session (line 266)
    /// 2. disabled (line 271)
    /// 3. emergency (line 281)
    /// 4. idle-without-autostart (line 308)
    /// 5. blocked auto-start (line 314)
    /// 6. motion-id without descriptor (line 350)
    /// 7. .emergency / .recovery / .stop kind (engineSynced 미도달)
    public func cancel() {
        if !_currentCycle.isEmpty {
            rejectedCount += 1
            _currentCycle.removeAll(keepingCapacity: true)
        }
    }

    /// 모든 데이터 reset — trial 경계에서 호출. rejectedCount 도 0 으로 reset.
    public func reset() {
        _currentCycle.removeAll(keepingCapacity: true)
        _completedDeltas.removeAll(keepingCapacity: true)
        rejectedCount = 0
    }

    // MARK: - Statistics helpers

    /// median — 짝수 size 는 두 중간 값의 평균.
    private static func median(sorted: [TimeInterval]) -> TimeInterval {
        let n = sorted.count
        guard n > 0 else { return 0 }
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }

    /// nearest-rank percentile — `q ∈ [0,1]`. ceil(q*n) → 1-indexed → 0-indexed.
    private static func percentile(sorted: [TimeInterval], q: Double) -> TimeInterval {
        let n = sorted.count
        guard n > 0 else { return 0 }
        let rank = Int((q * Double(n)).rounded(.up))
        let idx = max(0, min(n - 1, rank - 1))
        return sorted[idx]
    }
}

// MARK: - CompletedCycle (internal)

/// 한 cycle 의 stage 별 timestamp → span delta 변환.
private struct CompletedCycle {
    let inputReceived: Date
    let safetyGated: Date?
    let amplitudeApplied: Date?
    let engineSynced: Date

    init?(from stages: [PilotLatencyTracker.Stage: Date]) {
        guard let input = stages[.inputReceived],
              let synced = stages[.engineSynced] else {
            return nil
        }
        self.inputReceived = input
        self.engineSynced = synced
        self.safetyGated = stages[.safetyGated]
        self.amplitudeApplied = stages[.amplitudeApplied]
    }

    func delta(for span: PilotLatencyTracker.Span) -> TimeInterval? {
        switch span {
        case .endToEnd:
            return engineSynced.timeIntervalSince(inputReceived)
        case .safety:
            guard let g = safetyGated else { return nil }
            return g.timeIntervalSince(inputReceived)
        case .amplitude:
            guard let g = safetyGated, let a = amplitudeApplied else { return nil }
            return a.timeIntervalSince(g)
        case .engine:
            guard let a = amplitudeApplied else { return nil }
            return engineSynced.timeIntervalSince(a)
        }
    }
}
