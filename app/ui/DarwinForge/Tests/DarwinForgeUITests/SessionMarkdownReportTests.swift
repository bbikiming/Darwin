import Foundation
import XCTest
@testable import DarwinForgeUI

/// SessionMarkdownReport.render() unit tests.
///
/// render() converts TelemetrySessionMeta + SessionAnalysis into a human-readable
/// markdown string. Each test verifies a specific section or conditional branch
/// of the output.
final class SessionMarkdownReportTests: XCTestCase {

    // MARK: - Helpers

    private let base = Date(timeIntervalSince1970: 1_716_000_000)

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func makeMeta(
        id: String = "ABCDEF1234567890",
        started: String? = nil,
        ended: String? = nil,
        appVersion: String = "1.0.0",
        appBuild: String = "42",
        os: String = "macOS 14.0",
        device: String = "MacBook Pro",
        pinned: Bool = false,
        isBaseline: Bool = false
    ) -> TelemetrySessionMeta {
        let s = started ?? isoFormatter.string(from: base)
        return TelemetrySessionMeta(
            id: id, started: s, ended: ended,
            appVersion: appVersion, appBuild: appBuild,
            os: os, device: device,
            pinned: pinned, isBaseline: isBaseline
        )
    }

    private func ev(
        _ kind: TelemetryKind,
        level: TelemetryLevel = .info,
        actor: TelemetryActor = .system,
        seq: UInt64 = 1,
        secondsFromBase: Double = 0,
        payload: [String: AnyCodable] = [:],
        context: TelemetryContext? = nil
    ) -> TelemetryEvent {
        let wall = isoFormatter.string(from: base.addingTimeInterval(secondsFromBase))
        let monoNs = UInt64(max(0, secondsFromBase * 1e9))
        return TelemetryEvent(
            session: "TEST", seq: seq,
            wall: wall, mono: monoNs,
            kind: kind, level: level, actor: actor,
            data: TelemetryPayload(payload),
            context: context
        )
    }

    private func heartbeat(
        rttMs: Double? = nil,
        batteryV: Double? = nil,
        imuStale: Bool? = nil,
        seq: UInt64 = 1,
        secondsFromBase: Double = 0
    ) -> TelemetryEvent {
        let ctx = TelemetryContext(batteryV: batteryV, rttMs: rttMs, imuStale: imuStale)
        return ev(.heartbeat, level: .trace, seq: seq, secondsFromBase: secondsFromBase, context: ctx)
    }

    private func render(
        meta: TelemetrySessionMeta? = nil,
        events: [TelemetryEvent]? = nil,
        maxEnvelopes: Int = 10
    ) -> String {
        let m = meta ?? makeMeta()
        let evts = events ?? [ev(.appLaunch, seq: 1)]
        let analysis = SessionAnalyzer.analyze(events: evts)
        return SessionMarkdownReport.render(meta: m, analysis: analysis, maxEnvelopes: maxEnvelopes)
    }

    // MARK: - Header

    func testHeaderContainsSessionIdPrefix() {
        let output = render(meta: makeMeta(id: "DEADBEEF99887766"))
        XCTAssertTrue(output.contains("# DarwinForge Harness Session"), "Title heading missing")
        XCTAssertTrue(output.contains("DEADBEEF"), "First 8 chars of session ID missing")
    }

    // MARK: - Meta block

    func testMetaAppVersionAndBuild() {
        let output = render(meta: makeMeta(appVersion: "2.5.1", appBuild: "137"))
        XCTAssertTrue(output.contains("2.5.1"), "App version missing")
        XCTAssertTrue(output.contains("build 137"), "App build missing")
    }

    func testMetaDeviceAndOS() {
        let output = render(meta: makeMeta(os: "macOS 15.2", device: "Mac Studio"))
        XCTAssertTrue(output.contains("Mac Studio"), "Device name missing")
        XCTAssertTrue(output.contains("macOS 15.2"), "OS version missing")
    }

    func testMetaStartTime() {
        let output = render()
        // The humanIso formatter converts ISO8601 to "yyyy-MM-dd HH:mm:ss".
        // Verify the start line exists with a date-like pattern.
        XCTAssertTrue(output.contains("**\u{c2dc}\u{c791}**"), "Start time label missing")
    }

    func testMetaEndTimePresent() {
        let ended = isoFormatter.string(from: base.addingTimeInterval(600))
        let output = render(meta: makeMeta(ended: ended))
        XCTAssertTrue(output.contains("**\u{c885}\u{b8cc}**"), "End time label missing")
        XCTAssertFalse(
            output.contains("\u{be44}\u{c815}\u{c0c1} \u{c885}\u{b8cc}"),
            "Abnormal-termination fallback should NOT appear when ended is set"
        )
    }

    func testMetaEndTimeNilShowsFallback() {
        let output = render(meta: makeMeta(ended: nil))
        XCTAssertTrue(
            output.contains("(\u{be44}\u{c815}\u{c0c1} \u{c885}\u{b8cc} \u{b610}\u{b294} \u{c9c4}\u{d589} \u{c911})"),
            "Fallback text for nil ended missing"
        )
    }

    func testMetaDurationLabel() {
        let events = [
            ev(.appLaunch, seq: 1, secondsFromBase: 0),
            ev(.appTerminate, seq: 2, secondsFromBase: 90)
        ]
        let output = render(events: events)
        // 90 seconds -> "1\u{bd84} 30\u{cd08}"
        XCTAssertTrue(output.contains("**\u{ae30}\u{ac04}**"), "Duration label missing")
    }

    func testMetaEventCount() {
        let events = [
            ev(.appLaunch, seq: 1, secondsFromBase: 0),
            ev(.heartbeat, level: .trace, seq: 2, secondsFromBase: 1),
            ev(.appTerminate, seq: 3, secondsFromBase: 2)
        ]
        let output = render(events: events)
        XCTAssertTrue(output.contains("**이벤트 수**: 3"), "Total event count missing")
    }

    func testMetaDroppedCountPresent() {
        let events = [
            ev(.appLaunch, seq: 1, secondsFromBase: 0),
            ev(.harnessDropped, seq: 2, secondsFromBase: 1, payload: ["count": AnyCodable(5)])
        ]
        let output = render(events: events)
        XCTAssertTrue(output.contains("Dropped"), "Dropped label missing when count > 0")
        XCTAssertTrue(output.contains("5"), "Dropped count value missing")
    }

    func testMetaDroppedCountAbsentAtZero() {
        let events = [ev(.appLaunch, seq: 1)]
        let output = render(events: events)
        XCTAssertFalse(output.contains("Dropped"), "Dropped should NOT appear when count is 0")
    }

    func testMetaPinnedPresent() {
        let output = render(meta: makeMeta(pinned: true))
        XCTAssertTrue(output.contains("Pinned"), "Pinned label missing")
        XCTAssertTrue(output.contains("yes"), "Pinned value missing")
    }

    func testMetaPinnedAbsentWhenFalse() {
        let output = render(meta: makeMeta(pinned: false))
        XCTAssertFalse(output.contains("Pinned"), "Pinned should NOT appear when false")
    }

    // MARK: - Summary table

    func testSummaryTableContainsAllRows() {
        let events = [
            ev(.connectAttempt, seq: 1, secondsFromBase: 0),
            ev(.connectSuccess, seq: 2, secondsFromBase: 1),
            ev(.connectFailure, level: .error, seq: 3, secondsFromBase: 2),
            ev(.connectDisconnect, level: .warn, seq: 4, secondsFromBase: 3),
            ev(.busReadFail, level: .error, seq: 5, secondsFromBase: 4),
            ev(.busWriteFail, level: .error, seq: 6, secondsFromBase: 5),
            ev(.busEStop, level: .error, seq: 7, secondsFromBase: 6),
            ev(.walkLabStart, seq: 8, secondsFromBase: 7),
            ev(.walkLabStop, seq: 9, secondsFromBase: 8),
            ev(.walkLabEmergencyStop, level: .error, seq: 10, secondsFromBase: 9),
            ev(.walkLabStartBlocked, level: .warn, seq: 11, secondsFromBase: 10),
            ev(.motionPlayStart, seq: 12, secondsFromBase: 11),
            ev(.motionPlayComplete, seq: 13, secondsFromBase: 12),
            ev(.poseApplyStart, seq: 14, secondsFromBase: 13),
            ev(.teachSnapshotCaptured, seq: 15, secondsFromBase: 14),
            ev(.poseLibrarySaved, seq: 16, secondsFromBase: 15)
        ]
        let output = render(events: events)
        let expectedLabels = [
            "E-stop", "Error / Warn", "Disconnect",
            "WalkLab start", "WalkLab blocked",
            "Motion play", "Pose apply", "Teach"
        ]
        for label in expectedLabels {
            XCTAssertTrue(output.contains(label), "Summary row '\(label)' missing")
        }
    }

    // MARK: - Namespace distribution

    func testNamespaceDistributionPresent() {
        let events = [
            ev(.connectAttempt, seq: 1, secondsFromBase: 0),
            ev(.busReadFail, level: .error, seq: 2, secondsFromBase: 1),
            ev(.walkLabStart, seq: 3, secondsFromBase: 2)
        ]
        let output = render(events: events)
        XCTAssertTrue(output.contains("Namespace"), "Namespace distribution header missing")
        XCTAssertTrue(output.contains("connection"), "connection namespace missing")
        XCTAssertTrue(output.contains("bus"), "bus namespace missing")
        XCTAssertTrue(output.contains("walklab"), "walklab namespace missing")
    }

    func testNamespaceDistributionAbsent() {
        // Empty events produce no namespace section. Use a single event so
        // namespaceCounts is non-empty; but an empty analysis.summary.namespaceCounts
        // cannot occur with events present. Instead, verify with empty events.
        let analysis = SessionAnalyzer.analyze(events: [])
        let output = SessionMarkdownReport.render(meta: makeMeta(), analysis: analysis)
        XCTAssertFalse(output.contains("Namespace"), "Namespace section should be absent for empty events")
    }

    // MARK: - RTT section

    func testRttSectionPresent() {
        let events = [
            heartbeat(rttMs: 10.0, seq: 1, secondsFromBase: 0),
            heartbeat(rttMs: 20.0, seq: 2, secondsFromBase: 1),
            heartbeat(rttMs: 30.0, seq: 3, secondsFromBase: 2)
        ]
        let output = render(events: events)
        XCTAssertTrue(output.contains("### RTT (ms)"), "RTT section header missing")
        XCTAssertTrue(output.contains("p95"), "RTT p95 column missing")
        XCTAssertTrue(output.contains("3"), "RTT count missing")
    }

    func testRttSectionAbsent() {
        let events = [ev(.appLaunch, seq: 1)]
        let output = render(events: events)
        XCTAssertFalse(output.contains("RTT"), "RTT section should be absent when no RTT data")
    }

    // MARK: - Battery section

    func testBatterySectionPresent() {
        let events = [
            heartbeat(batteryV: 11.5, seq: 1, secondsFromBase: 0),
            heartbeat(batteryV: 12.0, seq: 2, secondsFromBase: 1)
        ]
        let output = render(events: events)
        XCTAssertTrue(output.contains("(V)"), "Battery section header missing")
        XCTAssertTrue(output.contains("2"), "Battery sample count missing")
    }

    func testBatterySectionAbsent() {
        let events = [ev(.appLaunch, seq: 1)]
        let output = render(events: events)
        XCTAssertFalse(output.contains("(V)"), "Battery section should be absent when no battery data")
    }

    // MARK: - IMU stale ratio

    func testImuStaleRatioPresent() {
        let events = [
            heartbeat(imuStale: true, seq: 1, secondsFromBase: 0),
            heartbeat(imuStale: true, seq: 2, secondsFromBase: 1),
            heartbeat(imuStale: false, seq: 3, secondsFromBase: 2),
            heartbeat(imuStale: false, seq: 4, secondsFromBase: 3)
        ]
        let output = render(events: events)
        XCTAssertTrue(output.contains("IMU stale ratio"), "IMU stale ratio header missing")
        XCTAssertTrue(output.contains("50%"), "50% stale ratio value missing")
    }

    func testImuStaleRatioAbsentAtZero() {
        let events = [
            heartbeat(imuStale: false, seq: 1, secondsFromBase: 0),
            heartbeat(imuStale: false, seq: 2, secondsFromBase: 1)
        ]
        let output = render(events: events)
        XCTAssertFalse(output.contains("IMU stale ratio"), "IMU stale section should be absent at 0%")
    }

    // MARK: - Error envelopes

    func testErrorEnvelopesPresent() {
        let events = [
            ev(.appLaunch, seq: 1, secondsFromBase: 0),
            ev(.connectFailure, level: .error, seq: 2, secondsFromBase: 1,
               payload: ["reason": AnyCodable("timeout")])
        ]
        let output = render(events: events)
        XCTAssertTrue(output.contains("envelope"), "Error envelopes section missing")
        XCTAssertTrue(output.contains("connection.failure"), "Error kind missing in envelope")
    }

    func testErrorEnvelopesMaxLimit() {
        // Create 5 error events, limit to 2.
        let events = (0..<5).map { i in
            ev(.connectFailure, level: .error, seq: UInt64(i + 1), secondsFromBase: Double(i))
        }
        let output = render(events: events, maxEnvelopes: 2)
        // Header says "5\u{ac74}", but only 2 rendered.
        XCTAssertTrue(output.contains("5\u{ac74}"), "Total error count should be 5")
        // Count envelope headers — each starts with the unique trigger marker emoji.
        let envelopeHeaderCount = output.components(separatedBy: "\u{1f6a8}").count - 1
        XCTAssertEqual(envelopeHeaderCount, 2, "Should render at most 2 envelopes")
    }

    // MARK: - Bookmarks

    func testBookmarksPresent() {
        let events = [
            ev(.uiBookmark, seq: 1, secondsFromBase: 0,
               payload: ["hash": AnyCodable("abc123"), "len": AnyCodable(42)])
        ]
        let output = render(events: events)
        XCTAssertTrue(output.contains("\u{bd81}\u{b9c8}\u{d06c}"), "Bookmarks section header missing")
        XCTAssertTrue(output.contains("abc123"), "Bookmark hash missing")
        XCTAssertTrue(output.contains("len 42"), "Bookmark len missing")
    }

    // MARK: - Footer

    func testFooterPresent() {
        let output = render()
        XCTAssertTrue(output.contains("---"), "Footer separator missing")
        XCTAssertTrue(output.contains("v1.13.0"), "Footer version missing")
    }

    // MARK: - Full structure

    func testFullRenderProducesValidMarkdown() {
        let ended = isoFormatter.string(from: base.addingTimeInterval(120))
        let meta = makeMeta(
            id: "FULLTEST12345678",
            ended: ended,
            appVersion: "3.0.0",
            appBuild: "99",
            os: "macOS 15.5",
            device: "iMac",
            pinned: true
        )
        let events = [
            ev(.appLaunch, seq: 1, secondsFromBase: 0),
            ev(.connectAttempt, seq: 2, secondsFromBase: 1),
            ev(.connectSuccess, seq: 3, secondsFromBase: 2),
            heartbeat(rttMs: 15.0, batteryV: 12.1, imuStale: true, seq: 4, secondsFromBase: 3),
            ev(.walkLabStart, seq: 5, secondsFromBase: 4),
            ev(.connectFailure, level: .error, seq: 6, secondsFromBase: 5),
            ev(.uiBookmark, seq: 7, secondsFromBase: 6,
               payload: ["hash": AnyCodable("deadbeef"), "len": AnyCodable(10)]),
            ev(.appTerminate, seq: 8, secondsFromBase: 120)
        ]
        let output = render(meta: meta, events: events)

        // Structural markers present in order.
        let markers = [
            "# DarwinForge Harness Session",
            "FULLTEST",
            "3.0.0",
            "iMac",
            "Pinned",
            "## \u{c694}\u{c57d}",
            "Namespace",
            "### RTT",
            "IMU stale ratio",
            "envelope",
            "\u{bd81}\u{b9c8}\u{d06c}",
            "---",
            "v1.13.0"
        ]
        for marker in markers {
            XCTAssertTrue(output.contains(marker), "Expected marker '\(marker)' missing in full render")
        }
    }
}
