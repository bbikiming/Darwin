import Foundation
import XCTest
@testable import DarwinForgeUI

/// **고도화 v1.13.0** — SessionAnalyzer + SessionMarkdownReport pure-func 테스트.
final class HarnessAnalysisTests: XCTestCase {

    // MARK: - helpers

    private func ev(_ kind: TelemetryKind,
                    level: TelemetryLevel = .info,
                    actor: TelemetryActor = .system,
                    seq: UInt64 = 1,
                    secondsFromBase: Double = 0,
                    base: Date = Date(timeIntervalSince1970: 1_716_000_000),
                    payload: [String: AnyCodable] = [:],
                    context: TelemetryContext? = nil) -> TelemetryEvent {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wall = f.string(from: base.addingTimeInterval(secondsFromBase))
        return TelemetryEvent(
            session: "TEST", seq: seq,
            wall: wall, mono: UInt64(secondsFromBase * 1e9),
            kind: kind, level: level, actor: actor,
            data: TelemetryPayload(payload),
            context: context
        )
    }

    private let base = Date(timeIntervalSince1970: 1_716_000_000)

    // MARK: - Empty

    func testEmptyEventsProducesEmptyAnalysis() {
        let a = SessionAnalyzer.analyze(events: [])
        XCTAssertEqual(a.summary.totalEvents, 0)
        XCTAssertTrue(a.timeline.isEmpty)
        XCTAssertTrue(a.errors.isEmpty)
        XCTAssertEqual(a.dropped, 0)
        XCTAssertNil(a.summary.durationSeconds)
    }

    // MARK: - Summary counters

    func testCountersAccumulateAcrossKinds() {
        let events: [TelemetryEvent] = [
            ev(.appLaunch, level: .notice, seq: 1),
            ev(.connectAttempt, seq: 2, secondsFromBase: 1),
            ev(.connectSuccess, level: .notice, seq: 3, secondsFromBase: 2,
               payload: ["rtt_ms": AnyCodable(8.0)]),
            ev(.connectAttempt, seq: 4, secondsFromBase: 3),
            ev(.connectFailure, level: .error, seq: 5, secondsFromBase: 4),
            ev(.busReadFail, level: .warn, actor: .robot, seq: 6, secondsFromBase: 5),
            ev(.busEStop, level: .error, actor: .user, seq: 7, secondsFromBase: 6),
            ev(.walkLabStart, level: .notice, actor: .user, seq: 8, secondsFromBase: 7),
            ev(.walkLabEmergencyStop, level: .error, actor: .user, seq: 9, secondsFromBase: 8),
            ev(.teachSnapshotCaptured, level: .notice, actor: .user, seq: 10, secondsFromBase: 9),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        XCTAssertEqual(a.summary.connectAttempts, 2)
        XCTAssertEqual(a.summary.connectSuccesses, 1)
        XCTAssertEqual(a.summary.connectFailures, 1)
        XCTAssertEqual(a.summary.busReadFailures, 1)
        XCTAssertEqual(a.summary.eStops, 1)
        XCTAssertEqual(a.summary.walkLabStarts, 1)
        XCTAssertEqual(a.summary.walkLabEmergencyStops, 1)
        XCTAssertEqual(a.summary.teachSnapshots, 1)
        XCTAssertEqual(a.summary.errorCount, 3, "connectFailure + eStop + emergencyStop")
        XCTAssertEqual(a.summary.warnCount, 1, "busReadFail")
        XCTAssertEqual(a.summary.totalEvents, events.count)
        XCTAssertEqual(a.summary.durationSeconds ?? -1, 9, accuracy: 0.01)
    }

    func testRttStatisticsCollectedFromConnectSuccess() {
        let events: [TelemetryEvent] = (1...5).map { i in
            ev(.connectSuccess, level: .notice, seq: UInt64(i),
               secondsFromBase: Double(i),
               payload: ["rtt_ms": AnyCodable(Double(i) * 10.0)])
        }
        let a = SessionAnalyzer.analyze(events: events)
        let s = a.summary.rttMs
        XCTAssertNotNil(s)
        XCTAssertEqual(s?.count, 5)
        XCTAssertEqual(s?.mean ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(s?.min, 10)
        XCTAssertEqual(s?.max, 50)
    }

    func testBatteryAndImuStaleRatioFromHeartbeat() {
        let ctxFull = TelemetryContext(connection: .connected, endpoint: "usb:test",
                                        section: nil, batteryV: 11.5, rttMs: 8.0, imuStale: false)
        let ctxStale = TelemetryContext(connection: .connected, endpoint: "usb:test",
                                        section: nil, batteryV: 9.8, rttMs: 9.0, imuStale: true)
        let events: [TelemetryEvent] = [
            ev(.heartbeat, level: .trace, seq: 1, secondsFromBase: 0, context: ctxFull),
            ev(.heartbeat, level: .trace, seq: 2, secondsFromBase: 1, context: ctxFull),
            ev(.heartbeat, level: .trace, seq: 3, secondsFromBase: 2, context: ctxStale),
            ev(.heartbeat, level: .trace, seq: 4, secondsFromBase: 3, context: ctxStale),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        XCTAssertNotNil(a.summary.batteryV)
        XCTAssertEqual(a.summary.batteryV?.min, 9.8)
        XCTAssertEqual(a.summary.batteryV?.max, 11.5)
        XCTAssertEqual(a.summary.imuStaleRatio ?? -1, 0.5, accuracy: 0.01)
    }

    // MARK: - Timeline

    func testTimelineDistributesEventsIntoBins() {
        // 0 to 9 sec, 10 events evenly distributed, request 10 bins → 1 event each.
        let events: [TelemetryEvent] = (0..<10).map { i in
            ev(.heartbeat, level: .trace, seq: UInt64(i + 1), secondsFromBase: Double(i))
        }
        let a = SessionAnalyzer.analyze(events: events, timelineBins: 10)
        XCTAssertEqual(a.timeline.count, 10)
        XCTAssertEqual(a.timeline.reduce(0) { $0 + $1.totalCount }, 10)
    }

    func testTimelinePeakLevelReflectsMostSevere() {
        let events: [TelemetryEvent] = [
            ev(.heartbeat, level: .trace, seq: 1, secondsFromBase: 0),
            ev(.busReadFail, level: .warn, actor: .robot, seq: 2, secondsFromBase: 1),
            ev(.busEStop, level: .error, actor: .user, seq: 3, secondsFromBase: 2),
        ]
        let a = SessionAnalyzer.analyze(events: events, timelineBins: 1)
        XCTAssertEqual(a.timeline.first?.peakLevel, .error)
    }

    // MARK: - Envelopes

    func testEnvelopesIncludePrecedingAndFollowing() {
        let events: [TelemetryEvent] = [
            ev(.appLaunch, level: .notice, seq: 1, secondsFromBase: 0),
            ev(.uiSectionChanged, seq: 2, secondsFromBase: 1),
            ev(.connectAttempt, seq: 3, secondsFromBase: 2),
            ev(.connectFailure, level: .error, seq: 4, secondsFromBase: 3),    // trigger
            ev(.uiSectionChanged, seq: 5, secondsFromBase: 4),
            ev(.connectAttempt, seq: 6, secondsFromBase: 5),
        ]
        let a = SessionAnalyzer.analyze(events: events, envelopeContextCount: 2)
        XCTAssertEqual(a.errors.count, 1)
        let env = a.errors[0]
        XCTAssertEqual(env.trigger.k.rawValue, "connection.failure")
        XCTAssertEqual(env.preceding.map { $0.i }, [2, 3])
        XCTAssertEqual(env.following.map { $0.i }, [5, 6])
    }

    func testEnvelopesIncludeWarnsNotJustErrors() {
        let events: [TelemetryEvent] = [
            ev(.heartbeat, level: .trace, seq: 1, secondsFromBase: 0),
            ev(.busReadFail, level: .warn, actor: .robot, seq: 2, secondsFromBase: 1),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        XCTAssertEqual(a.errors.count, 1)
        XCTAssertEqual(a.errors[0].trigger.lv, .warn)
    }

    // MARK: - Bookmarks + drops

    func testBookmarksAndDroppedExtracted() {
        let events: [TelemetryEvent] = [
            ev(.uiBookmark, level: .notice, actor: .user, seq: 1,
               payload: ["len": AnyCodable(8), "hash": AnyCodable("deadbeef")]),
            ev(.harnessDropped, level: .warn, actor: .system, seq: 2, secondsFromBase: 1,
               payload: ["count": AnyCodable(150)]),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        XCTAssertEqual(a.bookmarks.count, 1)
        XCTAssertEqual(a.dropped, 150)
    }

    // MARK: - Markdown report

    func testMarkdownReportContainsCoreSections() {
        let events: [TelemetryEvent] = [
            ev(.appLaunch, level: .notice, seq: 1, secondsFromBase: 0),
            ev(.connectSuccess, level: .notice, seq: 2, secondsFromBase: 1,
               payload: ["rtt_ms": AnyCodable(10.0)]),
            ev(.busReadFail, level: .warn, actor: .robot, seq: 3, secondsFromBase: 2),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        let meta = TelemetrySessionMeta(
            id: "DEADBEEF-1234",
            started: ISO8601DateFormatter().string(from: base),
            ended: ISO8601DateFormatter().string(from: base.addingTimeInterval(2)),
            appVersion: "1.13.0", appBuild: "1",
            os: "macOS 14", device: "Test"
        )
        let md = SessionMarkdownReport.render(meta: meta, analysis: a)
        XCTAssertTrue(md.contains("# DarwinForge Harness Session"))
        XCTAssertTrue(md.contains("## 요약"))
        XCTAssertTrue(md.contains("connection.success") || md.contains("bus.read_fail"))
        XCTAssertTrue(md.contains("RTT (ms)"))
        XCTAssertTrue(md.contains("에러 / 경고 envelopes") || md.contains("envelopes"))
    }

    // MARK: - namespaceCounts ordered descending

    func testNamespaceCountsOrderedDescending() {
        let events: [TelemetryEvent] = [
            ev(.heartbeat, level: .trace, seq: 1),
            ev(.heartbeat, level: .trace, seq: 2, secondsFromBase: 1),
            ev(.heartbeat, level: .trace, seq: 3, secondsFromBase: 2),
            ev(.connectAttempt, seq: 4, secondsFromBase: 3),
            ev(.connectSuccess, level: .notice, seq: 5, secondsFromBase: 4),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        XCTAssertEqual(a.summary.namespaceCounts.first?.namespace, "heartbeat")
        XCTAssertEqual(a.summary.namespaceCounts.first?.count, 3)
    }
}
