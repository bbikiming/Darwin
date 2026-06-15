import Foundation
import XCTest
@testable import DarwinForgeUI


/// **PilotIntent + PilotInputSummary value 타입 테스트**.
final class PilotIntentTests: XCTestCase {

    func testMoveIntentEquality() {
        let cmd = WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0)
        let intent1 = PilotIntent.move(cmd, from: .tello)
        let intent2 = PilotIntent.move(cmd, from: .tello)
        // timestamp 가 다르지만 kind/source 동일.
        XCTAssertEqual(intent1.kind, intent2.kind)
        XCTAssertEqual(intent1.source, intent2.source)
    }

    func testSourceCodableRoundtrip() throws {
        let summary = PilotInputSummary(
            sourcesUsed: [.tello, .ui],
            totalEvents: 5, avgAbsStrideMm: 10, avgAbsSideMm: 5, avgAbsTurnDeg: 2,
            peakStrideMm: 30, peakSideMm: 15, peakTurnDeg: 10,
            emergencyTriggered: false
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(PilotInputSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
    }

    func testEmptySummary() {
        XCTAssertFalse(PilotInputSummary.empty.hasData)
        XCTAssertEqual(PilotInputSummary.empty.totalEvents, 0)
        // **사이클 52** — hasMoveData (Cycle 42) 도 false.
        XCTAssertFalse(PilotInputSummary.empty.hasMoveData,
                       "empty → hasMoveData false")
    }

    /// **v1.20.30.1 사이클 36-fix MEDIUM 1 (코덱스)** — comfortLevel 100% 초과 차단.
    /// raw peak 값이 정규화 한도 초과 시에도 0..1 clamp.
    func testPilotInputSummaryComfortLevelClamps() {
        let over = PilotInputSummary(
            sourcesUsed: [.keyboard], totalEvents: 1, moveEventCount: 1,
            avgAbsStrideMm: 100, avgAbsSideMm: 100, avgAbsTurnDeg: 100,
            peakStrideMm: 100, peakSideMm: 100, peakTurnDeg: 100,  // 한도 (40/25/20) 초과
            peakNegStrideMm: 0, peakNegSideMm: 0, peakNegTurnDeg: 0,
            emergencyTriggered: false
        )
        XCTAssertEqual(over.comfortLevel, 1.0, accuracy: 1e-9,
                       "한도 초과 → clamp 1.0 (HUD 100% 초과 차단)")
    }

    /// **v1.20.28 사이클 34** — comfortLevel 정규화 검증.
    func testPilotInputSummaryComfortLevel() {
        let empty = PilotInputSummary.empty
        XCTAssertEqual(empty.comfortLevel, 0, accuracy: 1e-9, "pilot 미사용 → 0")

        let max = PilotInputSummary(
            sourcesUsed: [.keyboard], totalEvents: 1, moveEventCount: 1,
            avgAbsStrideMm: 40, avgAbsSideMm: 25, avgAbsTurnDeg: 20,
            peakStrideMm: 40, peakSideMm: 25, peakTurnDeg: 20,
            peakNegStrideMm: 0, peakNegSideMm: 0, peakNegTurnDeg: 0,
            emergencyTriggered: false
        )
        XCTAssertEqual(max.comfortLevel, 1.0, accuracy: 1e-9, "모든 축 max → 1.0")

        let half = PilotInputSummary(
            sourcesUsed: [.keyboard], totalEvents: 1, moveEventCount: 1,
            avgAbsStrideMm: 0, avgAbsSideMm: 0, avgAbsTurnDeg: 0,
            peakStrideMm: 20, peakSideMm: 12.5, peakTurnDeg: 10,
            peakNegStrideMm: 0, peakNegSideMm: 0, peakNegTurnDeg: 0,
            emergencyTriggered: false
        )
        XCTAssertEqual(half.comfortLevel, 0.5, accuracy: 1e-9, "half × 3축 평균 → 0.5")
    }

    func testAccumulatorAvgCalculation() {
        let acc = PilotInputAccumulator()
        acc.record(.move(WalkingCommand(strideMm: 10, sideMm: 5, turnDeg: -3), from: .tello))
        acc.record(.move(WalkingCommand(strideMm: 30, sideMm: -5, turnDeg: 9), from: .tello))
        let s = acc.summarize()
        XCTAssertEqual(s.avgAbsStrideMm, 20, accuracy: 1e-9, "(10+30)/2 = 20")
        XCTAssertEqual(s.avgAbsSideMm, 5, accuracy: 1e-9, "(|5|+|-5|)/2 = 5")
        XCTAssertEqual(s.avgAbsTurnDeg, 6, accuracy: 1e-9, "(|-3|+|9|)/2 = 6")
        XCTAssertEqual(s.peakStrideMm, 30, accuracy: 1e-9, "양수 peak")
    }

    // MARK: - Cycle 13: event rate metric

    /// **v1.20.7 사이클 13** — 마지막 1초 동안의 event count = events/sec.
    func testEventsPerSecondBasic() {
        let acc = PilotInputAccumulator()
        let now = Date()
        // 5 events within last 1 sec.
        for i in 0..<5 {
            let intent = PilotIntent(
                kind: .move(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0)),
                source: .keyboard,
                timestamp: now.addingTimeInterval(-Double(i) * 0.1)
            )
            acc.record(intent)
        }
        let rate = acc.eventsPerSecond(window: 1.0, now: now)
        XCTAssertEqual(rate, 5.0, accuracy: 0.01, "5 events in 1s window")
    }

    /// **v1.20.7 사이클 13** — window 밖 event 는 제외.
    func testEventsPerSecondExcludesOldEvents() {
        let acc = PilotInputAccumulator()
        let now = Date()
        // 3 recent + 2 old (5초 전).
        for i in 0..<3 {
            let intent = PilotIntent(
                kind: .stop, source: .keyboard,
                timestamp: now.addingTimeInterval(-Double(i) * 0.2)
            )
            acc.record(intent)
        }
        for _ in 0..<2 {
            let intent = PilotIntent(
                kind: .stop, source: .keyboard,
                timestamp: now.addingTimeInterval(-5.0)
            )
            acc.record(intent)
        }
        XCTAssertEqual(acc.eventsPerSecond(window: 1.0, now: now), 3.0, accuracy: 0.01,
                       "old events (5s ago) 제외")
    }

    /// **v1.20.7 사이클 13** — reset 후 rate 0.
    func testEventsPerSecondAfterReset() {
        let acc = PilotInputAccumulator()
        acc.record(.move(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0), from: .keyboard))
        acc.reset()
        XCTAssertEqual(acc.eventsPerSecond(), 0, accuracy: 0.01)
    }

    /// **v1.20.7 사이클 13** — 큰 window 도 capacity 64 로 cap.
    func testEventsPerSecondCapacityCap() {
        let acc = PilotInputAccumulator()
        let now = Date()
        // 100 events injected — capacity 64 라 64만 keep.
        for i in 0..<100 {
            let intent = PilotIntent(
                kind: .stop, source: .keyboard,
                timestamp: now.addingTimeInterval(-Double(i) * 0.01)
            )
            acc.record(intent)
        }
        // 1 second window 에 64 entries 가 모두 들어옴 (0.64s 까지의 이력).
        let rate = acc.eventsPerSecond(window: 1.0, now: now)
        XCTAssertLessThanOrEqual(rate, 64.0, "capacity cap")
    }
}
