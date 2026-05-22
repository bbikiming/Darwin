import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.20.45 (2026-05-22) 사이클 59 — PilotLatencyTracker 단위 테스트**.
///
/// critic 지적 응답 — keyboard press → robot joint 변화까지 end-to-end latency 측정.
/// "game character" 여부 판단의 유일한 정량 기준. tracker 자체는 단계별 시간 차이만
/// 측정 — 실 motor 시간은 hw 가 노출하지 않아 미측정.
///
/// # 검증 범위
///
/// 1. record() 가 stage 별 latency 정확 측정 (delta = end - start)
/// 2. ring buffer 가 capacity 초과 시 oldest drop (FIFO)
/// 3. statistics (median / p95 / max) 가 정렬된 표본에서 정확
/// 4. bridge.latencyTracker 옵셔널 — nil 시 overhead 0
@MainActor
final class PilotLatencyTrackerTests: XCTestCase {

    // MARK: - 1) 측정 정확성

    /// inputReceived → engineSynced 사이 delta 가 record 호출 시각 차이와 일치.
    func testRecordCapturesDeltaBetweenStages() {
        let tracker = PilotLatencyTracker(capacity: 30)
        let t0 = Date(timeIntervalSince1970: 1_000.000)
        let t1 = Date(timeIntervalSince1970: 1_000.005)  // +5ms
        let t2 = Date(timeIntervalSince1970: 1_000.008)  // +3ms

        tracker.record(stage: .inputReceived, timestamp: t0)
        tracker.record(stage: .safetyGated,    timestamp: t1)
        tracker.record(stage: .engineSynced,   timestamp: t2)

        // 한 cycle 완료 — endToEnd = t2 - t0 = 8ms.
        let stats = tracker.statistics(for: .endToEnd)
        XCTAssertEqual(stats.count, 1, "1 cycle 측정 = 1 sample")
        XCTAssertEqual(stats.median, 0.008, accuracy: 1e-6, "8ms end-to-end")
    }

    /// 각 stage 별로 누적된 delta 가 통계에 합쳐짐.
    func testMultipleCyclesAccumulateStatistics() {
        let tracker = PilotLatencyTracker(capacity: 30)
        // 3 cycles — 5ms / 10ms / 15ms.
        let base = Date(timeIntervalSince1970: 2_000)
        let durations: [TimeInterval] = [0.005, 0.010, 0.015]
        for (i, d) in durations.enumerated() {
            let start = base.addingTimeInterval(Double(i) * 1.0)
            tracker.record(stage: .inputReceived, timestamp: start)
            tracker.record(stage: .engineSynced,   timestamp: start.addingTimeInterval(d))
        }

        let stats = tracker.statistics(for: .endToEnd)
        XCTAssertEqual(stats.count, 3)
        XCTAssertEqual(stats.median, 0.010, accuracy: 1e-6, "median 10ms")
        XCTAssertEqual(stats.max, 0.015, accuracy: 1e-6, "max 15ms")
    }

    // MARK: - 2) Ring buffer

    /// capacity=3 + 5 cycles → 마지막 3 cycles 만 유지 (FIFO).
    func testRingBufferDropsOldestWhenFull() {
        let tracker = PilotLatencyTracker(capacity: 3)
        let base = Date(timeIntervalSince1970: 3_000)
        // 5 cycles — 1ms, 2ms, 3ms, 4ms, 5ms.
        for i in 1...5 {
            let start = base.addingTimeInterval(Double(i) * 1.0)
            let end = start.addingTimeInterval(Double(i) * 0.001)
            tracker.record(stage: .inputReceived, timestamp: start)
            tracker.record(stage: .engineSynced,   timestamp: end)
        }

        let stats = tracker.statistics(for: .endToEnd)
        XCTAssertEqual(stats.count, 3, "capacity=3 → 최근 3 cycles 만 유지")
        // 마지막 3 = 3ms, 4ms, 5ms.
        XCTAssertEqual(stats.median, 0.004, accuracy: 1e-6)
        XCTAssertEqual(stats.max, 0.005, accuracy: 1e-6, "가장 최근 max = 5ms")
    }

    /// default capacity = 30 (요청 사양).
    func testDefaultCapacityIs30() {
        let tracker = PilotLatencyTracker()
        XCTAssertEqual(tracker.capacity, 30, "default capacity per spec")
    }

    // MARK: - 3) Statistics

    /// median / p95 / max 가 표본 분포와 일치 (deterministic dataset).
    func testStatisticsMedianP95Max() {
        let tracker = PilotLatencyTracker(capacity: 100)
        // 20 cycles — 1ms..20ms. median=10.5ms (avg of 10,11), p95=19ms (index 18 of 20),
        // max=20ms.
        let base = Date(timeIntervalSince1970: 4_000)
        for i in 1...20 {
            let start = base.addingTimeInterval(Double(i) * 1.0)
            let end = start.addingTimeInterval(Double(i) * 0.001)
            tracker.record(stage: .inputReceived, timestamp: start)
            tracker.record(stage: .engineSynced,   timestamp: end)
        }

        let stats = tracker.statistics(for: .endToEnd)
        XCTAssertEqual(stats.count, 20)
        // median of even-sized = avg of two middle = (10+11)/2 = 10.5ms.
        XCTAssertEqual(stats.median, 0.0105, accuracy: 1e-6)
        // p95 of 20 samples — nearest-rank: ceil(0.95 * 20) = 19 → samples[18] (0-idx) = 19ms.
        XCTAssertEqual(stats.p95, 0.019, accuracy: 1e-6)
        XCTAssertEqual(stats.max, 0.020, accuracy: 1e-6)
    }

    /// 빈 tracker — statistics 모두 0, count 0.
    func testStatisticsEmptyTracker() {
        let tracker = PilotLatencyTracker()
        let stats = tracker.statistics(for: .endToEnd)
        XCTAssertEqual(stats.count, 0)
        XCTAssertEqual(stats.median, 0)
        XCTAssertEqual(stats.p95, 0)
        XCTAssertEqual(stats.max, 0)
    }

    // MARK: - 4) Bridge injection (옵셔널, default nil)

    /// bridge.latencyTracker 기본 nil — 측정 비활성 (overhead 0).
    func testBridgeLatencyTrackerDefaultsNil() {
        let mock = MockTelloLink()
        let bridge = WalkLabRCBridge(tello: mock)
        XCTAssertNil(bridge.latencyTracker, "default nil — overhead 0")
    }

    /// tracker 활성 시 handleMove → record stages → statistics 1 cycle.
    func testBridgeWithTrackerRecordsOneCycleOnHandleMove() {
        let mock = MockTelloLink()
        let session = WalkLabSession()
        let bridge = WalkLabRCBridge(tello: mock)
        bridge.session = session
        let tracker = PilotLatencyTracker()
        bridge.latencyTracker = tracker
        session.start(.march)

        // 한 번의 handleMove → inputReceived / safetyGated / amplitudeApplied / engineSynced.
        let cmd = WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0)
        bridge.handleMove(cmd, from: .keyboard)

        let stats = tracker.statistics(for: .endToEnd)
        XCTAssertEqual(stats.count, 1, "1 handleMove = 1 cycle")
        XCTAssertGreaterThanOrEqual(stats.median, 0, "delta non-negative")
    }
}
