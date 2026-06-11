import Foundation
import os

/// 레이턴시 계측 sink — **bus(직결) 경로** (cockpit-latency-hardening §6).
///
/// 비유: 공장 라인 옆에 둔 스톱워치 묶음. 라인을 멈추지 않고(=핫패스 0-할당·무포맷)
/// 구간 시간만 적어두고, 1초에 한 번 관리자(HUD)가 요약을 읽어간다.
///
/// **P5(bus D0) 범위**: step 케이던스 지터 + SYNC_WRITE 지연 + IMU read 지연을
/// 고정 크기 링버퍼에 기록한다. 입력→송출(input→sent) 7지점 `mark(_:seq:)` 풀 모델은
/// W1(P3)에서 확장한다 — 본 sink 는 그 토대.
///
/// 동시성: 기록은 보행 사이클 Task(단일 writer)에서, 요약 읽기는 1Hz HUD(MainActor)에서
/// 일어난다. `OSAllocatedUnfairLock` 으로 보호 — 단일 writer 라 사실상 무경합이고
/// `withLock` 진입은 수십 ns(할당 없음). 비활성(`enabled=false`)이면 기록은 즉시 반환.
public final class PilotLatencyTracer: Sendable {
    /// 한 측정 채널의 분포 요약.
    public struct Stats: Sendable, Equatable {
        public let count: Int
        public let p50Ms: Double
        public let p95Ms: Double
        /// 절댓값 최대 — 지터(부호 있음)에서도 최악 편차를 본다.
        public let maxAbsMs: Double

        public static let empty = Stats(count: 0, p50Ms: 0, p95Ms: 0, maxAbsMs: 0)
    }

    /// 프로세스 공유 인스턴스 — 보행 루프가 마크하고 진단 HUD 가 읽는다.
    public static let shared = PilotLatencyTracer()

    /// 활성 게이트 UserDefaults 키.
    public static let enabledDefaultsKey = "df.latency.busTracer"

    private struct State {
        var enabled: Bool
        var jitter: SampleRing
        var write: SampleRing
        var imuRead: SampleRing
    }

    private let state: OSAllocatedUnfairLock<State>

    /// - Parameter capacity: 채널별 링버퍼 표본 수(기본 1024 — 50Hz 에서 ~20s).
    public init(capacity: Int = 1024, enabled: Bool = false) {
        state = OSAllocatedUnfairLock(
            initialState: State(
                enabled: enabled,
                jitter: SampleRing(capacity: capacity),
                write: SampleRing(capacity: capacity),
                imuRead: SampleRing(capacity: capacity)
            )
        )
    }

    /// UserDefaults(`df.latency.busTracer`)로 활성 상태 동기화.
    public func configureFromDefaults(_ defaults: UserDefaults = .standard) {
        setEnabled(defaults.bool(forKey: Self.enabledDefaultsKey))
    }

    public func setEnabled(_ on: Bool) {
        state.withLock { $0.enabled = on }
    }

    public var isEnabled: Bool {
        state.withLock { $0.enabled }
    }

    // MARK: - 기록 (핫패스)

    /// step 발화 지터: 의도한 wake 시각 대비 실제 wake 편차(ms). 양수=늦음.
    public func recordStepJitter(deviationMs: Double) {
        state.withLock { if $0.enabled { $0.jitter.record(deviationMs) } }
    }

    /// SYNC_WRITE 1패킷 전송 소요(ms).
    public func recordWriteLatency(ms: Double) {
        state.withLock { if $0.enabled { $0.write.record(ms) } }
    }

    /// IMU burst READ 왕복 소요(ms). 보행 중 밸런스 폴에서 호출(D2/P6 에서 결선).
    public func recordImuReadLatency(ms: Double) {
        state.withLock { if $0.enabled { $0.imuRead.record(ms) } }
    }

    // MARK: - 읽기 (1Hz, 콜드패스)

    public func jitterStats() -> Stats { state.withLock { $0.jitter.stats() } }
    public func writeStats() -> Stats { state.withLock { $0.write.stats() } }
    public func imuReadStats() -> Stats { state.withLock { $0.imuRead.stats() } }

    /// HUD 디버그 1줄(1Hz). 비활성이거나 표본 0이면 `nil`.
    public func hudSummary() -> String? {
        let (enabled, j, w) = state.withLock { ($0.enabled, $0.jitter.stats(), $0.write.stats()) }
        guard enabled, j.count > 0 else { return nil }
        let jitter = String(format: "±%.1f", j.p95Ms)
        let writeMs = w.count > 0 ? String(format: "%.1f", w.p95Ms) : "—"
        return "bus jitter p95 \(jitter)ms · write p95 \(writeMs)ms · n=\(j.count)"
    }

    public func reset() {
        state.withLock {
            $0.jitter.reset()
            $0.write.reset()
            $0.imuRead.reset()
        }
    }
}

/// 고정 크기 순환 표본 버퍼. 기록은 0-할당, 백분위는 읽기 시점에만 복사·정렬(콜드패스).
struct SampleRing: Sendable {
    private var buffer: [Double]
    private var count: Int = 0
    private var head: Int = 0

    init(capacity: Int) {
        buffer = Array(repeating: 0, count: max(1, capacity))
    }

    mutating func record(_ value: Double) {
        buffer[head] = value
        head = (head + 1) % buffer.count
        if count < buffer.count { count += 1 }
    }

    mutating func reset() {
        count = 0
        head = 0
    }

    var sampleCount: Int { count }

    func stats() -> PilotLatencyTracer.Stats {
        guard count > 0 else { return .empty }
        var sorted = Array(buffer.prefix(count))
        sorted.sort()
        return PilotLatencyTracer.Stats(
            count: count,
            p50Ms: percentile(of: sorted, 50),
            p95Ms: percentile(of: sorted, 95),
            maxAbsMs: sorted.map { Swift.abs($0) }.max() ?? 0
        )
    }

    /// 최근접 순위(nearest-rank) 백분위. `sorted` 는 오름차순 정렬된 표본.
    private func percentile(of sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p / 100.0 * Double(sorted.count - 1)).rounded())
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
