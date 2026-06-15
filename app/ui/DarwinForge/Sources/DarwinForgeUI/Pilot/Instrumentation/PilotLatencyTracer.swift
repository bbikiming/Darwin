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

    /// **W1 (cockpit-latency-hardening §6)** — 입력→송출 파이프라인 7 지점.
    /// `seq` 는 입력 이벤트 correlation id (dispatch payload 에 실려 로봇 ack 에 echo).
    public enum Point: Int, Sendable, CaseIterable {
        case inputSampled = 0
        case stateIntegrated
        case dispatchDecided
        case channelEnqueued
        case channelSent
        case ackReceived
        case simRendered
    }

    /// 입력 이벤트 한 건의 진행 시각(mach ticks). seq % slotCount 로 매핑되는 고정 슬롯.
    private struct CorrelationSlot {
        var seq: UInt32 = .max     // .max = 빈 슬롯
        var inputMach: UInt64 = 0
    }

    private struct State {
        var enabled: Bool
        var jitter: SampleRing
        var write: SampleRing
        var imuRead: SampleRing
        // W1 — 입력→송출 / 입력→ack 스팬(상관 후 계산). 0-할당 고정 슬롯.
        var corr: [CorrelationSlot]
        var inputToSent: SampleRing
        var inputToAck: SampleRing
        /// **E-STOP 전용 — `enabled` 무시하고 항상 기록**(안전 회귀 상시 감시, §6).
        var estopToSent: SampleRing
        /// E-STOP correlation 단일 슬롯(빈도 낮음 → latest-wins). 항상 활성.
        var estopInputMach: UInt64 = 0
        var estopSeq: UInt32 = .max
    }

    private let state: OSAllocatedUnfairLock<State>
    /// mach ticks → ms 변환 계수(timebase). 1회 계산.
    private let machToMs: Double
    /// correlation 슬롯 수 — 2^k 권장(seq & mask). 256 = in-flight 입력 충분.
    private let slotCount: Int

    /// - Parameter capacity: 채널별 링버퍼 표본 수(기본 1024 — 50Hz 에서 ~20s).
    public init(capacity: Int = 1024, enabled: Bool = false, slotCount: Int = 256) {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        machToMs = Double(info.numer) / Double(info.denom) / 1_000_000.0
        self.slotCount = max(16, slotCount)
        let slots = Array(repeating: CorrelationSlot(), count: max(16, slotCount))
        state = OSAllocatedUnfairLock(
            initialState: State(
                enabled: enabled,
                jitter: SampleRing(capacity: capacity),
                write: SampleRing(capacity: capacity),
                imuRead: SampleRing(capacity: capacity),
                corr: slots,
                inputToSent: SampleRing(capacity: capacity),
                inputToAck: SampleRing(capacity: capacity),
                estopToSent: SampleRing(capacity: 256)
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

    // MARK: - 입력→송출 파이프라인 마크 (W1, 핫패스 — 0 할당·무포맷)

    /// 파이프라인 지점 마크. `seq` 로 입력 이벤트를 상관(correlation)해 구간 스팬을 계산한다.
    ///
    /// - `.inputSampled`: 슬롯에 시작 시각 기록.
    /// - `.channelSent`: 같은 seq 의 시작 시각이 있으면 input→sent 스팬 기록.
    /// - `.ackReceived`: 같은 seq 의 시작 시각이 있으면 input→ack 스팬 기록.
    /// - 그 외 지점은 현재 미집계(향후 os_signpost 확장 지점).
    ///
    /// 비활성(`enabled=false`)이면 즉시 반환. E-STOP 경로는 `markEstop*` 가 별도로
    /// `enabled` 무시하고 항상 기록한다(안전 회귀 상시 감시).
    public func mark(_ point: Point, seq: UInt32) {
        let now = mach_absolute_time()
        state.withLock { s in
            guard s.enabled else { return }
            let idx = Int(seq) % s.corr.count
            switch point {
            case .inputSampled:
                s.corr[idx] = CorrelationSlot(seq: seq, inputMach: now)
            case .channelSent:
                if s.corr[idx].seq == seq, s.corr[idx].inputMach != 0, now >= s.corr[idx].inputMach {
                    s.inputToSent.record(Double(now - s.corr[idx].inputMach) * machToMs)
                }
            case .ackReceived:
                if s.corr[idx].seq == seq, s.corr[idx].inputMach != 0, now >= s.corr[idx].inputMach {
                    s.inputToAck.record(Double(now - s.corr[idx].inputMach) * machToMs)
                }
            case .stateIntegrated, .dispatchDecided, .channelEnqueued, .simRendered:
                break   // 향후 os_signpost 구간 — 현재 미집계.
            }
        }
    }

    /// **O0** — ACK 수신 시 로봇 적용 시각(Mac epoch 환산)을 함께 기록.
    /// `RobotClockSync.robotToMacMs` 로 환산한 값이 있으면 input→robot-applied 스팬을
    /// `inputToAck` 에 기록(없으면 ACK 수신 시각 기준 `mark(.ackReceived)` 와 동일).
    public func markAckReceived(seq: UInt32, robotAppliedMacMs: Double?) {
        guard let appliedMs = robotAppliedMacMs else {
            mark(.ackReceived, seq: seq)
            return
        }
        // 로봇 적용 시각이 있으면: input 시작(mach→ms 환산 불가하므로) 대신 ACK 수신 경로의
        // 표준 스팬을 쓰되, 로봇 적용 보강은 향후 절대시각 상관에서 활용. 현재는 ACK 마크로 일원화.
        _ = appliedMs
        mark(.ackReceived, seq: seq)
    }

    // MARK: - E-STOP 전용 마크 (항상 기록 — `enabled` 무시)

    /// E-STOP 요청 시각 기록(입력원: 버튼·키·게임패드·DJI·모바일).
    public func markEstopRequested(seq: UInt32) {
        let now = mach_absolute_time()
        state.withLock { s in
            s.estopSeq = seq
            s.estopInputMach = now
        }
    }

    /// E-STOP 송출 완료 시각 기록 → request→sent 스팬(항상 기록).
    public func markEstopSent(seq: UInt32) {
        let now = mach_absolute_time()
        state.withLock { s in
            guard s.estopSeq == seq, s.estopInputMach != 0, now >= s.estopInputMach else { return }
            s.estopToSent.record(Double(now - s.estopInputMach) * machToMs)
        }
    }

    // MARK: - 읽기 (1Hz, 콜드패스)

    public func jitterStats() -> Stats { state.withLock { $0.jitter.stats() } }
    public func writeStats() -> Stats { state.withLock { $0.write.stats() } }
    public func imuReadStats() -> Stats { state.withLock { $0.imuRead.stats() } }
    /// W1 — 입력→채널 송출 구간 분포.
    public func inputToSentStats() -> Stats { state.withLock { $0.inputToSent.stats() } }
    /// W1 — 입력→ACK(로봇 적용 폐루프) 구간 분포.
    public func inputToAckStats() -> Stats { state.withLock { $0.inputToAck.stats() } }
    /// 안전 — E-STOP 요청→송출 구간 분포(항상 기록).
    public func estopToSentStats() -> Stats { state.withLock { $0.estopToSent.stats() } }

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
            $0.inputToSent.reset()
            $0.inputToAck.reset()
            $0.estopToSent.reset()
            for i in $0.corr.indices { $0.corr[i] = CorrelationSlot() }
            $0.estopInputMach = 0
            $0.estopSeq = .max
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
