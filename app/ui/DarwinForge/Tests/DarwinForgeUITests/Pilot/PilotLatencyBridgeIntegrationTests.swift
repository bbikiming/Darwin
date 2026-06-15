import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.20.45 (2026-05-22) 사이클 59-ui — Bridge ↔ PilotLatencyTracker 통합 테스트**.
///
/// PilotLatencyTrackerTests 는 tracker 자체 unit. 본 테스트는 bridge 의 process /
/// applyAmplitude 가 4 stage 를 실제 record 하고, emergency / blocked path 가 leak
/// (미완성 cycle 누적) 을 일으키지 않는지 검증.
///
/// # 검증 시나리오
///
/// 1. handleMove → 4 stage 완료 → sample 1 누적
/// 2. emergency path → engineSynced 누락 → sample 0 (다음 inputReceived 자동 폐기)
/// 3. 30 + α cycle → ring buffer wrap (capacity 유지)
/// 4. 20 cycle 의 p95 / max 정확성
/// 5. reset → sample 0
@MainActor
final class PilotLatencyBridgeIntegrationTests: XCTestCase {

    private var mock: MockTelloLink!
    private var session: WalkLabSession!
    private var bridge: WalkLabRCBridge!
    private var tracker: PilotLatencyTracker!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockTelloLink()
        session = WalkLabSession()
        bridge = WalkLabRCBridge(tello: mock)
        bridge.session = session
        tracker = PilotLatencyTracker()
        bridge.latencyTracker = tracker
        session.start(.march)  // walking 진입 — applyAmplitude path 활성.
    }

    override func tearDown() async throws {
        tracker = nil
        bridge = nil
        session = nil
        mock = nil
        try await super.tearDown()
    }

    // MARK: - 1) bridge.process → tracker 누적

    /// handleMove 한 번 → 4 stage 통과 → endToEnd sample 1.
    func testHandleMoveAccumulatesOneSample() {
        XCTAssertEqual(tracker.statistics(for: .endToEnd).count, 0,
                       "초기: tracker 빈 상태")

        bridge.handleMove(WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0),
                          from: .keyboard)

        let stats = tracker.statistics(for: .endToEnd)
        XCTAssertEqual(stats.count, 1, "handleMove 1회 = sample 1")
        XCTAssertGreaterThanOrEqual(stats.median, 0, "delta non-negative")
    }

    /// 4 stage span 모두 (safety / amplitude / engine) 가 각각 측정됨.
    func testAllSpansRecordOnHandleMove() {
        bridge.handleMove(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0),
                          from: .keyboard)

        XCTAssertEqual(tracker.statistics(for: .endToEnd).count, 1)
        XCTAssertEqual(tracker.statistics(for: .safety).count, 1,
                       "inputReceived → safetyGated 기록")
        XCTAssertEqual(tracker.statistics(for: .amplitude).count, 1,
                       "safetyGated → amplitudeApplied 기록")
        XCTAssertEqual(tracker.statistics(for: .engine).count, 1,
                       "amplitudeApplied → engineSynced 기록")
    }

    // MARK: - 2) Emergency / blocked path leak 검증

    /// emergency intent — engineSynced 미발화 → sample 누적 안 함.
    /// 다음 정상 handleMove 의 inputReceived 가 이전 partial cycle 자동 폐기.
    func testEmergencyPathDoesNotAccumulateSampleButRecoversCleanly() {
        bridge.handleEmergency(from: .ui)
        XCTAssertEqual(tracker.statistics(for: .endToEnd).count, 0,
                       "emergency = engineSynced 없음 → cycle 미완성")

        // recovery 후 정상 path — leak 없음 (자동 폐기).
        bridge.handleRecovery(from: .ui)
        session.start(.march)
        bridge.handleMove(WalkingCommand(strideMm: 15, sideMm: 0, turnDeg: 0),
                          from: .keyboard)

        let stats = tracker.statistics(for: .endToEnd)
        XCTAssertEqual(stats.count, 1, "정상 cycle 만 누적 — 이전 emergency leak 0")
    }

    /// bridge.enabled=false 시 process 가 safetyGated 도달 전 early return →
    /// engineSynced 미발화 → sample 누적 안 함.
    func testDisabledBridgeDoesNotAccumulateSample() {
        bridge.enabled = false
        bridge.handleMove(WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0),
                          from: .keyboard)

        XCTAssertEqual(tracker.statistics(for: .endToEnd).count, 0,
                       "disabled bridge → cycle 미완성 → leak 0")
    }

    // MARK: - 3) Ring buffer wrap

    /// 35 cycles 누적 → capacity=30 유지 (FIFO drop).
    func testRingBufferWrapsAtCapacity() {
        let n = 35
        for i in 0..<n {
            // 매 cycle 다른 stride — sample distinctness 확보.
            bridge.handleMove(WalkingCommand(strideMm: Double(i % 30 + 1),
                                              sideMm: 0, turnDeg: 0),
                              from: .keyboard)
        }
        let stats = tracker.statistics(for: .endToEnd)
        XCTAssertEqual(stats.count, 30, "capacity=30 → 최근 30 cycles 만 유지")
    }

    // MARK: - 4) Statistics 정확성 — 외부 tracker 주입으로 deterministic 검증

    /// 알려진 분포 (1..20ms) 주입 → median / p95 / max 가 nearest-rank percentile 정의 일치.
    /// bridge instrument 가 정확한 stage 순서로 record 한다는 가정 하의 정합성.
    func testStatisticsPercentilesMatchKnownDistribution() {
        // bridge instrument 와 무관한 직접 record — tracker statistics 로직만 검증.
        let direct = PilotLatencyTracker(capacity: 100)
        let base = Date(timeIntervalSince1970: 5_000)
        for i in 1...20 {
            let start = base.addingTimeInterval(Double(i))
            let end = start.addingTimeInterval(Double(i) * 0.001)
            direct.record(stage: .inputReceived, timestamp: start)
            direct.record(stage: .engineSynced, timestamp: end)
        }
        let stats = direct.statistics(for: .endToEnd)
        XCTAssertEqual(stats.count, 20)
        // median of even-sized = avg(10ms, 11ms) = 10.5ms.
        XCTAssertEqual(stats.median, 0.0105, accuracy: 1e-6, "p50 = 10.5ms")
        // p95 nearest-rank = ceil(0.95 * 20) = 19 → idx 18 = 19ms.
        XCTAssertEqual(stats.p95, 0.019, accuracy: 1e-6, "p95 = 19ms")
        XCTAssertEqual(stats.max, 0.020, accuracy: 1e-6, "max = 20ms")
    }

    // MARK: - 5) Reset

    /// reset 후 sample 0 — UI 의 "측정 초기화" 버튼 검증.
    func testResetClearsAllSamples() {
        for _ in 0..<5 {
            bridge.handleMove(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0),
                              from: .keyboard)
        }
        XCTAssertEqual(tracker.statistics(for: .endToEnd).count, 5)

        tracker.reset()
        XCTAssertEqual(tracker.statistics(for: .endToEnd).count, 0,
                       "reset → sample 초기화")
        // reset 후 새 cycle 정상 누적.
        bridge.handleMove(WalkingCommand(strideMm: 12, sideMm: 0, turnDeg: 0),
                          from: .keyboard)
        XCTAssertEqual(tracker.statistics(for: .endToEnd).count, 1,
                       "reset 후 새 sample 정상 누적")
    }

    // MARK: - 사이클 71 — 코덱스 CRITICAL-1 회귀 가드 (rejectedCount)

    /// **사이클 71 CRITICAL-1**: emergency path 의 cycle 미완료 → rejectedCount 증가.
    /// 종전 동작: orphan cycle 이 다음 inputReceived 자동 폐기 → 통계 영향 0 이지만 visibility 0.
    /// 신규: cancel() 호출 시 rejectedCount +1 → UI 가 rejected 비율 표시 가능.
    func testEmergencyIntentIncrementsRejectedCount() {
        XCTAssertEqual(tracker.rejectedCount, 0, "초기: rejected 0")
        XCTAssertEqual(tracker.statistics(for: .endToEnd).count, 0, "초기: 완료 sample 0")

        bridge.handleEmergency(from: .keyboard)

        // emergency 는 engineSynced 까지 안 감 → rejectedCount 1.
        XCTAssertEqual(tracker.rejectedCount, 1,
                       "emergency early-return → rejectedCount 1")
        XCTAssertEqual(tracker.statistics(for: .endToEnd).count, 0,
                       "emergency path 는 완료 sample 미생성 (engineSynced 누락)")
    }

    /// **사이클 71 CRITICAL-1**: emergency 후 recovery + 정상 move → mixed counter 검증.
    /// rejected 와 accepted 가 독립 카운터 (둘 다 정확).
    func testMixedEmergencyAndMoveCountsCorrectly() {
        bridge.handleEmergency(from: .keyboard)
        XCTAssertEqual(tracker.rejectedCount, 1)

        bridge.handleRecovery(from: .ui)
        session.start(.march)  // recovery 후 재시작.

        // 정상 move 3회.
        for _ in 0..<3 {
            bridge.handleMove(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0),
                              from: .keyboard)
        }

        // accepted = 3 (정상 완료), rejected = 1 (emergency).
        XCTAssertEqual(tracker.statistics(for: .endToEnd).count, 3,
                       "accepted cycles count 정확")
        XCTAssertEqual(tracker.rejectedCount, 1,
                       "rejected count 누적 (recovery 가 reset 안 함)")
    }

    /// **사이클 71 CRITICAL-1**: tracker.reset() 이 rejectedCount 도 0 으로.
    func testResetClearsRejectedCount() {
        bridge.handleEmergency(from: .keyboard)
        XCTAssertEqual(tracker.rejectedCount, 1)
        tracker.reset()
        XCTAssertEqual(tracker.rejectedCount, 0,
                       "reset → rejectedCount 도 0 (trial 경계 깨끗한 시작)")
    }

    /// **사이클 71 CRITICAL-1**: bridge disabled / no-session 같은 다른 early-return path 도
    /// rejectedCount 증가. 모든 path 에서 cancel() 호출 검증.
    func testDisabledBridgeRejectsCorrectly() {
        bridge.enabled = false
        bridge.handleMove(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0),
                          from: .keyboard)
        XCTAssertEqual(tracker.rejectedCount, 1,
                       "disabled bridge → rejectedCount 1 (cycle 71 cancel)")
    }
}
