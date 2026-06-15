import Foundation
import XCTest
@testable import DarwinForgeUI

/// SessionJSONReport / SessionJSONRenderer 단위 테스트.
///
/// render() 가 meta + analysis + events + insights + diff 를 올바른 JSON 구조로
/// 변환하는지 검증. renderString() 의 valid JSON 출력도 확인.
final class SessionJSONReportTests: XCTestCase {

    // MARK: - Helpers

    private let base = Date(timeIntervalSince1970: 1_716_000_000)

    private func ev(
        _ kind: TelemetryKind,
        level: TelemetryLevel = .info,
        actor: TelemetryActor = .system,
        seq: UInt64 = 1,
        secondsFromBase: Double = 0,
        payload: [String: AnyCodable] = [:],
        context: TelemetryContext? = nil
    ) -> TelemetryEvent {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wall = f.string(from: base.addingTimeInterval(secondsFromBase))
        let monoNs = UInt64(max(0, abs(secondsFromBase) * 1e9))
        return TelemetryEvent(
            session: "TEST", seq: seq,
            wall: wall, mono: monoNs,
            kind: kind, level: level, actor: actor,
            data: TelemetryPayload(payload),
            context: context
        )
    }

    private func makeMeta(
        id: String = "ABCDEF12-3456-7890-ABCD-EF1234567890",
        started: String = "2024-05-18T10:00:00.000Z",
        ended: String? = "2024-05-18T10:30:00.000Z",
        appVersion: String = "1.14.0",
        appBuild: String = "42",
        os: String = "macOS 15.0",
        device: String = "MacBookPro",
        pinned: Bool = false,
        isBaseline: Bool = false
    ) -> TelemetrySessionMeta {
        TelemetrySessionMeta(
            id: id,
            started: started,
            ended: ended,
            appVersion: appVersion,
            appBuild: appBuild,
            os: os,
            device: device,
            pinned: pinned,
            isBaseline: isBaseline
        )
    }

    private func makeInsight(
        ruleID: String = "test.rule",
        severity: Insight.Severity = .warn,
        kind: Insight.Kind = .connection,
        title: String = "Test Insight Title",
        evidence: String = "some evidence",
        recommendation: String = "some recommendation",
        eventRefs: [UInt64] = [1, 2],
        confidence: Double = 0.9
    ) -> Insight {
        Insight(
            id: "\(ruleID)#test",
            ruleID: ruleID,
            severity: severity,
            kind: kind,
            title: title,
            evidence: evidence,
            recommendation: recommendation,
            eventRefs: eventRefs,
            confidence: confidence
        )
    }

    /// Render convenience: builds analysis from events then calls renderer.
    private func render(
        meta: TelemetrySessionMeta? = nil,
        events: [TelemetryEvent] = [],
        insights: [Insight] = [],
        diff: SessionDiff? = nil
    ) -> SessionJSONReport {
        let m = meta ?? makeMeta()
        let analysis = SessionAnalyzer.analyze(events: events)
        return SessionJSONRenderer.render(
            meta: m, analysis: analysis,
            events: events, insights: insights, diff: diff
        )
    }

    // MARK: - 1. Schema constant

    func testSchemaIsCorrect() {
        let report = render()
        XCTAssertEqual(report.schema, "darwinforge-harness/1.0")
    }

    // MARK: - 2. Session block maps meta fields

    func testSessionBlockMapsMetaFields() {
        let meta = makeMeta(
            id: "ABCDEF12-3456-7890-ABCD-EF1234567890",
            appVersion: "2.0.0",
            appBuild: "99",
            os: "macOS 15.1",
            device: "MacStudio",
            pinned: true,
            isBaseline: true
        )
        let report = render(meta: meta)

        XCTAssertEqual(report.session.id, meta.id)
        XCTAssertEqual(report.session.shortId, String(meta.id.prefix(8)))
        XCTAssertEqual(report.session.shortId, "ABCDEF12")
        XCTAssertEqual(report.session.appVersion, "2.0.0")
        XCTAssertEqual(report.session.appBuild, "99")
        XCTAssertEqual(report.session.os, "macOS 15.1")
        XCTAssertEqual(report.session.device, "MacStudio")
        XCTAssertEqual(report.session.pinned, true)
        XCTAssertEqual(report.session.isBaseline, true)
        XCTAssertEqual(report.session.started, meta.started)
        XCTAssertEqual(report.session.ended, meta.ended)
    }

    // MARK: - 3. Summary totalEvents matches event count

    func testSummaryTotalEventsMatchesEventCount() {
        let events = (1...7).map { i in
            ev(.appLaunch, seq: UInt64(i), secondsFromBase: Double(i))
        }
        let report = render(events: events)
        XCTAssertEqual(report.summary.totalEvents, 7)
    }

    // MARK: - 4. Summary connection stats

    func testSummaryConnectionStats() throws {
        let events: [TelemetryEvent] = [
            ev(.connectAttempt, seq: 1, secondsFromBase: 0),
            ev(.connectSuccess, level: .notice, seq: 2, secondsFromBase: 1,
               payload: ["rtt_ms": AnyCodable(5.0)]),
            ev(.connectAttempt, seq: 3, secondsFromBase: 2),
            ev(.connectFailure, level: .error, seq: 4, secondsFromBase: 3),
            ev(.connectAttempt, seq: 5, secondsFromBase: 4),
            ev(.connectSuccess, level: .notice, seq: 6, secondsFromBase: 5,
               payload: ["rtt_ms": AnyCodable(7.0)]),
            ev(.connectDisconnect, seq: 7, secondsFromBase: 6),
        ]
        let report = render(events: events)

        XCTAssertEqual(report.summary.connection.attempts, 3)
        XCTAssertEqual(report.summary.connection.successes, 2)
        XCTAssertEqual(report.summary.connection.failures, 1)
        XCTAssertEqual(report.summary.connection.disconnects, 1)

        // successRate = 2/3
        let rate = try XCTUnwrap(report.summary.connection.successRate)
        XCTAssertEqual(rate, 2.0 / 3.0, accuracy: 0.001)
    }

    // MARK: - 5. Summary bus stats

    func testSummaryBusStats() {
        let events: [TelemetryEvent] = [
            ev(.busReadFail, level: .warn, seq: 1, secondsFromBase: 0),
            ev(.busReadFail, level: .warn, seq: 2, secondsFromBase: 1),
            ev(.busWriteFail, level: .warn, seq: 3, secondsFromBase: 2),
            ev(.busEStop, level: .error, seq: 4, secondsFromBase: 3),
        ]
        let report = render(events: events)

        XCTAssertEqual(report.summary.bus.readFailures, 2)
        XCTAssertEqual(report.summary.bus.writeFailures, 1)
        XCTAssertEqual(report.summary.bus.eStops, 1)
    }

    // MARK: - 6. Empty events produce zero stats

    func testEmptyEventsProduceZeroStats() {
        let report = render(events: [])

        XCTAssertEqual(report.summary.totalEvents, 0)
        XCTAssertEqual(report.summary.connection.attempts, 0)
        XCTAssertEqual(report.summary.connection.successes, 0)
        XCTAssertEqual(report.summary.connection.failures, 0)
        XCTAssertEqual(report.summary.connection.disconnects, 0)
        XCTAssertNil(report.summary.connection.successRate)
        XCTAssertEqual(report.summary.bus.readFailures, 0)
        XCTAssertEqual(report.summary.bus.writeFailures, 0)
        XCTAssertEqual(report.summary.bus.eStops, 0)
        XCTAssertEqual(report.summary.walklab.starts, 0)
        XCTAssertEqual(report.summary.walklab.stops, 0)
        XCTAssertEqual(report.summary.walklab.emergencyStops, 0)
        XCTAssertEqual(report.summary.motion.plays, 0)
        XCTAssertEqual(report.summary.motion.completes, 0)
        XCTAssertEqual(report.summary.motion.poseApplies, 0)
        XCTAssertEqual(report.summary.teach.snapshots, 0)
        XCTAssertEqual(report.summary.teach.librarySaves, 0)
        XCTAssertNil(report.summary.rttMs)
        XCTAssertNil(report.summary.batteryV)
        XCTAssertNil(report.summary.imu)
        XCTAssertTrue(report.timeline.isEmpty)
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertTrue(report.bookmarks.isEmpty)
    }

    // MARK: - 7. JSON round-trip (Codable)

    func testJSONRoundTrip() throws {
        let events: [TelemetryEvent] = [
            ev(.connectAttempt, seq: 1, secondsFromBase: 0),
            ev(.connectSuccess, level: .notice, seq: 2, secondsFromBase: 1,
               payload: ["rtt_ms": AnyCodable(12.0)]),
            ev(.busReadFail, level: .warn, seq: 3, secondsFromBase: 2),
        ]
        let insight = makeInsight(ruleID: "roundtrip.check", severity: .critical, kind: .bus)
        let report = render(events: events, insights: [insight])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SessionJSONReport.self, from: data)

        XCTAssertEqual(decoded.schema, report.schema)
        XCTAssertEqual(decoded.session.id, report.session.id)
        XCTAssertEqual(decoded.session.shortId, report.session.shortId)
        XCTAssertEqual(decoded.session.appVersion, report.session.appVersion)
        XCTAssertEqual(decoded.session.pinned, report.session.pinned)
        XCTAssertEqual(decoded.session.isBaseline, report.session.isBaseline)
        XCTAssertEqual(decoded.summary.totalEvents, report.summary.totalEvents)
        XCTAssertEqual(decoded.summary.connection.attempts, report.summary.connection.attempts)
        XCTAssertEqual(decoded.summary.bus.readFailures, report.summary.bus.readFailures)
        XCTAssertEqual(decoded.insights.count, report.insights.count)
        XCTAssertEqual(decoded.insights.first?.ruleID, "roundtrip.check")
        XCTAssertEqual(decoded.insights.first?.severity, "critical")
        XCTAssertNil(decoded.diff)
    }

    // MARK: - 8. renderString returns valid JSON

    func testRenderStringReturnsValidJSON() throws {
        let events: [TelemetryEvent] = [
            ev(.appLaunch, level: .notice, seq: 1, secondsFromBase: 0),
            ev(.appTerminate, level: .notice, seq: 2, secondsFromBase: 10),
        ]
        let meta = makeMeta()
        let analysis = SessionAnalyzer.analyze(events: events)
        let jsonString = SessionJSONRenderer.renderString(
            meta: meta, analysis: analysis,
            events: events, insights: []
        )

        // Must be non-empty and parseable as JSON.
        XCTAssertFalse(jsonString.isEmpty)
        XCTAssertNotEqual(jsonString, "{}", "Should produce non-trivial JSON")

        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let obj = try? JSONSerialization.jsonObject(with: data, options: [])
        XCTAssertNotNil(obj, "renderString output must be valid JSON")

        // Verify it parses as a dictionary with expected top-level keys.
        let dict = obj as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertNotNil(dict?["schema"])
        XCTAssertNotNil(dict?["session"])
        XCTAssertNotNil(dict?["summary"])
    }

    // MARK: - 9. Insights block maps correctly

    func testInsightsBlockMapsCorrectly() {
        let insight = makeInsight(
            ruleID: "bus.read_storm",
            severity: .warn,
            kind: .bus,
            title: "Bus read failures spiking",
            confidence: 0.85
        )
        let report = render(insights: [insight])

        XCTAssertEqual(report.insights.count, 1)
        let block = report.insights[0]
        XCTAssertEqual(block.ruleID, "bus.read_storm")
        XCTAssertEqual(block.severity, "warn")
        XCTAssertEqual(block.kind, "bus")
        XCTAssertEqual(block.title, "Bus read failures spiking")
        XCTAssertEqual(block.confidence, 0.85, accuracy: 0.001)
        XCTAssertEqual(block.eventRefs, [1, 2])
    }

    func testMultipleInsightsPreserveOrder() {
        let insights = [
            makeInsight(ruleID: "rule.alpha", severity: .info, kind: .connection),
            makeInsight(ruleID: "rule.beta", severity: .critical, kind: .imu),
            makeInsight(ruleID: "rule.gamma", severity: .notice, kind: .walklab),
        ]
        let report = render(insights: insights)

        XCTAssertEqual(report.insights.count, 3)
        XCTAssertEqual(report.insights[0].ruleID, "rule.alpha")
        XCTAssertEqual(report.insights[1].ruleID, "rule.beta")
        XCTAssertEqual(report.insights[2].ruleID, "rule.gamma")
    }

    // MARK: - 10. Diff block present when diff provided

    func testDiffBlockPresentWhenDiffProvided() {
        let diff = SessionDiff(
            baselineId: "BASELINE-SESSION-ID",
            currentId: "CURRENT-SESSION-ID",
            metrics: [
                MetricDelta(
                    label: "RTT p95 (ms)",
                    baseline: 20.0, current: 15.0,
                    deltaAbsolute: -5.0, deltaPercent: -25.0,
                    lowerIsBetter: true
                )
            ],
            counts: [
                CountDelta(
                    label: "Bus read failures",
                    baseline: 10, current: 5,
                    delta: -5, lowerIsBetter: true
                )
            ],
            verdict: .improvement(reason: "RTT p95 -25%"),
            weightedScorePercent: -25.0
        )
        let report = render(diff: diff)

        let block = report.diff
        XCTAssertNotNil(block)
        XCTAssertEqual(report.diff?.baselineId, "BASELINE-SESSION-ID")
        XCTAssertEqual(report.diff?.verdict, "improvement")
        XCTAssertEqual(report.diff?.verdictReason, "RTT p95 -25%")
        XCTAssertEqual(report.diff?.weightedScorePercent ?? 0, -25.0, accuracy: 0.01)
        XCTAssertEqual(report.diff?.metrics.count, 1)
        XCTAssertEqual(report.diff?.metrics.first?.label, "RTT p95 (ms)")
        XCTAssertEqual(report.diff?.metrics.first?.lowerIsBetter, true)
        XCTAssertEqual(report.diff?.counts.count, 1)
        XCTAssertEqual(report.diff?.counts.first?.label, "Bus read failures")
        XCTAssertEqual(report.diff?.counts.first?.delta, -5)
    }

    // MARK: - 11. Diff block nil when no diff

    func testDiffBlockNilWhenNoDiff() {
        let report = render(diff: nil)
        XCTAssertNil(report.diff)
    }

    // MARK: - 12. Verdict string mapping

    func testVerdictImprovementMapping() {
        let diff = SessionDiff(
            baselineId: "B", currentId: "C",
            metrics: [], counts: [],
            verdict: .improvement(reason: "better"),
            weightedScorePercent: -30.0
        )
        let report = render(diff: diff)
        XCTAssertEqual(report.diff?.verdict, "improvement")
        XCTAssertEqual(report.diff?.verdictReason, "better")
    }

    func testVerdictRegressionMapping() {
        let diff = SessionDiff(
            baselineId: "B", currentId: "C",
            metrics: [], counts: [],
            verdict: .regression(reason: "worse"),
            weightedScorePercent: 40.0
        )
        let report = render(diff: diff)
        XCTAssertEqual(report.diff?.verdict, "regression")
        XCTAssertEqual(report.diff?.verdictReason, "worse")
    }

    func testVerdictSimilarMapping() {
        let diff = SessionDiff(
            baselineId: "B", currentId: "C",
            metrics: [], counts: [],
            verdict: .similar,
            weightedScorePercent: 5.0
        )
        let report = render(diff: diff)
        XCTAssertEqual(report.diff?.verdict, "similar")
        XCTAssertNil(report.diff?.verdictReason)
    }

    // MARK: - 13. Bookmarks mapping

    func testBookmarksMapping() {
        let events: [TelemetryEvent] = [
            ev(.appLaunch, level: .notice, seq: 1, secondsFromBase: 0),
            ev(.uiBookmark, level: .info, actor: .user, seq: 2, secondsFromBase: 5,
               payload: ["len": AnyCodable(42), "hash": AnyCodable("abc123")]),
            ev(.uiBookmark, level: .info, actor: .user, seq: 3, secondsFromBase: 10,
               payload: ["len": AnyCodable(0), "hash": AnyCodable("---")]),
            ev(.appTerminate, level: .notice, seq: 4, secondsFromBase: 15),
        ]
        let report = render(events: events)

        XCTAssertEqual(report.bookmarks.count, 2)
        XCTAssertEqual(report.bookmarks[0].seq, 2)
        XCTAssertEqual(report.bookmarks[1].seq, 3)

        // lenHash encodes "len=N hash=H" from the payload.
        XCTAssertEqual(report.bookmarks[0].lenHash, "len=42 hash=abc123")
        XCTAssertEqual(report.bookmarks[1].lenHash, "len=0 hash=---")
    }

    // MARK: - Additional edge cases

    func testSessionShortIdTruncation() {
        // Verify shortId is exactly first 8 characters regardless of id length.
        let shortMeta = makeMeta(id: "ABCD")
        let reportShort = render(meta: shortMeta)
        XCTAssertEqual(reportShort.session.shortId, "ABCD",
                       "shortId should be prefix(8), which for 4-char id is the whole id")

        let longMeta = makeMeta(id: "ABCDEFGHIJKLMNOP")
        let reportLong = render(meta: longMeta)
        XCTAssertEqual(reportLong.session.shortId, "ABCDEFGH")
    }

    func testSummaryDroppedCountFromHarnessDropped() {
        let events: [TelemetryEvent] = [
            ev(.harnessDropped, level: .warn, seq: 1, secondsFromBase: 0,
               payload: ["count": AnyCodable(10)]),
            ev(.harnessDropped, level: .warn, seq: 2, secondsFromBase: 1,
               payload: ["count": AnyCodable(5)]),
            ev(.appLaunch, level: .notice, seq: 3, secondsFromBase: 2),
        ]
        let report = render(events: events)

        // dropped is accumulated from harness.dropped events.
        XCTAssertEqual(report.summary.dropped, 15)
    }

    func testConnectionSuccessRateNilWhenZeroAttempts() {
        let events: [TelemetryEvent] = [
            ev(.appLaunch, level: .notice, seq: 1, secondsFromBase: 0),
        ]
        let report = render(events: events)
        XCTAssertEqual(report.summary.connection.attempts, 0)
        XCTAssertNil(report.summary.connection.successRate)
    }

    func testWalkLabStats() {
        let events: [TelemetryEvent] = [
            ev(.walkLabStart, level: .notice, actor: .user, seq: 1, secondsFromBase: 0),
            ev(.walkLabStop, level: .notice, actor: .user, seq: 2, secondsFromBase: 5),
            ev(.walkLabStart, level: .notice, actor: .user, seq: 3, secondsFromBase: 10),
            ev(.walkLabEmergencyStop, level: .error, actor: .user, seq: 4, secondsFromBase: 12),
            ev(.walkLabStartBlocked, level: .warn, actor: .system, seq: 5, secondsFromBase: 15),
        ]
        let report = render(events: events)

        XCTAssertEqual(report.summary.walklab.starts, 2)
        XCTAssertEqual(report.summary.walklab.stops, 1)
        XCTAssertEqual(report.summary.walklab.emergencyStops, 1)
        XCTAssertEqual(report.summary.walklab.startBlocks, 1)
    }

    func testMotionAndTeachStats() {
        let events: [TelemetryEvent] = [
            ev(.motionPlayStart, level: .notice, seq: 1, secondsFromBase: 0),
            ev(.motionPlayComplete, level: .notice, seq: 2, secondsFromBase: 2),
            ev(.motionPlayStart, level: .notice, seq: 3, secondsFromBase: 4),
            ev(.motionPlayComplete, level: .notice, seq: 4, secondsFromBase: 6),
            ev(.poseApplyStart, level: .notice, seq: 5, secondsFromBase: 8),
            ev(.teachSnapshotCaptured, level: .notice, actor: .user, seq: 6, secondsFromBase: 10),
            ev(.teachSnapshotCaptured, level: .notice, actor: .user, seq: 7, secondsFromBase: 11),
            ev(.poseLibrarySaved, level: .notice, actor: .user, seq: 8, secondsFromBase: 12),
        ]
        let report = render(events: events)

        XCTAssertEqual(report.summary.motion.plays, 2)
        XCTAssertEqual(report.summary.motion.completes, 2)
        XCTAssertEqual(report.summary.motion.poseApplies, 1)
        XCTAssertEqual(report.summary.teach.snapshots, 2)
        XCTAssertEqual(report.summary.teach.librarySaves, 1)
    }

    func testNamespaceCountsPopulated() {
        let events: [TelemetryEvent] = [
            ev(.connectAttempt, seq: 1, secondsFromBase: 0),
            ev(.connectSuccess, level: .notice, seq: 2, secondsFromBase: 1,
               payload: ["rtt_ms": AnyCodable(5.0)]),
            ev(.busReadFail, level: .warn, seq: 3, secondsFromBase: 2),
            ev(.busReadFail, level: .warn, seq: 4, secondsFromBase: 3),
            ev(.appLaunch, level: .notice, seq: 5, secondsFromBase: 4),
        ]
        let report = render(events: events)

        XCTAssertFalse(report.summary.namespaceCounts.isEmpty)
        let connectionNs = report.summary.namespaceCounts.first { $0.namespace == "connection" }
        XCTAssertEqual(connectionNs?.count, 2)
        let busNs = report.summary.namespaceCounts.first { $0.namespace == "bus" }
        XCTAssertEqual(busNs?.count, 2)
        let appNs = report.summary.namespaceCounts.first { $0.namespace == "app" }
        XCTAssertEqual(appNs?.count, 1)
    }

    func testErrorBlocksContainScrubbing() {
        // The ErrorBlock payload should go through HarnessRedaction.scrubPayload.
        // Safe keys pass through, unknown string keys get redacted to len+hash.
        let events: [TelemetryEvent] = [
            ev(.connectFailure, level: .error, seq: 1, secondsFromBase: 0,
               payload: [
                "reason": AnyCodable("timeout"),
                "user_text": AnyCodable("my secret note")
               ]),
        ]
        let report = render(events: events)

        XCTAssertEqual(report.errors.count, 1)
        let errBlock = report.errors[0]
        XCTAssertEqual(errBlock.triggerSeq, 1)
        XCTAssertEqual(errBlock.triggerKind, "connection.failure")
        XCTAssertEqual(errBlock.triggerLevel, "error")

        // "reason" is in the safe allow-list -- passes through.
        XCTAssertNotNil(errBlock.payload["reason"])

        // "user_text" is NOT in the safe list -- scrubbed to user_text_len + user_text_hash.
        XCTAssertNil(errBlock.payload["user_text"],
                     "Unknown string key should be scrubbed from payload")
        XCTAssertNotNil(errBlock.payload["user_text_len"],
                        "Scrubbed key should have _len replacement")
        XCTAssertNotNil(errBlock.payload["user_text_hash"],
                        "Scrubbed key should have _hash replacement")
    }

    func testTimelineBlocksProducedForMultipleEvents() {
        // At least 2 events with different timestamps to produce timeline bins.
        let events: [TelemetryEvent] = [
            ev(.appLaunch, level: .notice, seq: 1, secondsFromBase: 0),
            ev(.connectAttempt, seq: 2, secondsFromBase: 30),
            ev(.connectSuccess, level: .notice, seq: 3, secondsFromBase: 60,
               payload: ["rtt_ms": AnyCodable(10.0)]),
        ]
        let report = render(events: events)
        XCTAssertFalse(report.timeline.isEmpty, "Timeline should have bins for multi-event session")
    }

    func testDiffMetricsAndCountsRoundTrip() throws {
        let diff = SessionDiff(
            baselineId: "BASE",
            currentId: "CURR",
            metrics: [
                MetricDelta(label: "RTT p95 (ms)",
                            baseline: 50.0, current: 30.0,
                            deltaAbsolute: -20.0, deltaPercent: -40.0,
                            lowerIsBetter: true),
                MetricDelta(label: "Battery min (V)",
                            baseline: 11.0, current: 10.5,
                            deltaAbsolute: -0.5, deltaPercent: nil,
                            lowerIsBetter: false),
            ],
            counts: [
                CountDelta(label: "Errors",
                           baseline: 3, current: 1, delta: -2,
                           lowerIsBetter: true),
                CountDelta(label: "Walk starts",
                           baseline: 5, current: 8, delta: 3,
                           lowerIsBetter: false),
            ],
            verdict: .regression(reason: "battery dip"),
            weightedScorePercent: 35.0
        )
        let report = render(diff: diff)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(SessionJSONReport.self, from: data)

        let decodedDiff = try XCTUnwrap(decoded.diff)
        XCTAssertEqual(decodedDiff.metrics.count, 2)
        XCTAssertEqual(decodedDiff.counts.count, 2)
        XCTAssertEqual(decodedDiff.verdict, "regression")
        XCTAssertEqual(decodedDiff.verdictReason, "battery dip")

        // First metric round-trips correctly.
        XCTAssertEqual(decodedDiff.metrics[0].label, "RTT p95 (ms)")
        XCTAssertEqual(decodedDiff.metrics[0].baseline, 50.0)
        XCTAssertEqual(decodedDiff.metrics[0].current, 30.0)
        XCTAssertEqual(decodedDiff.metrics[0].deltaPercent ?? 0, -40.0, accuracy: 0.01)
        XCTAssertEqual(decodedDiff.metrics[0].lowerIsBetter, true)

        // Second metric has nil deltaPercent.
        XCTAssertNil(decodedDiff.metrics[1].deltaPercent)

        // Counts round-trip.
        XCTAssertEqual(decodedDiff.counts[0].delta, -2)
        XCTAssertEqual(decodedDiff.counts[1].delta, 3)
    }

    func testInsightBlockEvidenceAndRecommendation() {
        let insight = makeInsight(
            ruleID: "imu.stale_persistent",
            severity: .notice,
            kind: .imu,
            title: "IMU stale ratio high",
            evidence: "25% stale heartbeats",
            recommendation: "Check IMU hardware"
        )
        let report = render(insights: [insight])
        let block = report.insights[0]
        XCTAssertEqual(block.evidence, "25% stale heartbeats")
        XCTAssertEqual(block.recommendation, "Check IMU hardware")
    }

    func testRenderStringPrettyPrintedFormat() {
        let meta = makeMeta()
        let analysis = SessionAnalyzer.analyze(events: [])
        let jsonString = SessionJSONRenderer.renderString(
            meta: meta, analysis: analysis, events: [], insights: []
        )

        // Pretty-printed JSON should contain newlines and indentation.
        XCTAssertTrue(jsonString.contains("\n"), "Pretty-printed JSON should have newlines")
        XCTAssertTrue(jsonString.contains("  "), "Pretty-printed JSON should have indentation")
    }
}
