import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.14.0** — Log utilization (Insights / Baseline / LiveAlerts / JSON) 테스트.
@MainActor
final class HarnessUtilizationTests: XCTestCase {

    // MARK: - 헬퍼

    private let base = Date(timeIntervalSince1970: 1_716_000_000)

    private func ev(_ kind: TelemetryKind,
                    level: TelemetryLevel = .info,
                    actor: TelemetryActor = .system,
                    seq: UInt64 = 1,
                    secondsFromBase: Double = 0,
                    payload: [String: AnyCodable] = [:],
                    context: TelemetryContext? = nil) -> TelemetryEvent {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wall = f.string(from: base.addingTimeInterval(secondsFromBase))
        // 음수 secondsFromBase 도 안전 — mono ns 는 절댓값으로.
        let monoNs = UInt64(max(0, abs(secondsFromBase) * 1e9))
        return TelemetryEvent(
            session: "TEST", seq: seq,
            wall: wall, mono: monoNs,
            kind: kind, level: level, actor: actor,
            data: TelemetryPayload(payload),
            context: context
        )
    }

    // MARK: - Insights — connection rules

    func testConnectionHighFailureRateInsight() {
        let events: [TelemetryEvent] = [
            ev(.connectAttempt, seq: 1, secondsFromBase: 0),
            ev(.connectFailure, level: .error, seq: 2, secondsFromBase: 1),
            ev(.connectAttempt, seq: 3, secondsFromBase: 2),
            ev(.connectFailure, level: .error, seq: 4, secondsFromBase: 3),
            ev(.connectAttempt, seq: 5, secondsFromBase: 4),
            ev(.connectSuccess, level: .notice, seq: 6, secondsFromBase: 5,
               payload: ["rtt_ms": AnyCodable(10.0)]),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "connection.high_failure_rate" })
    }

    func testConnectionFlappingInsight() {
        // 60 초 안에 success → disconnect → success → disconnect → success → disconnect (3 cycles).
        let events: [TelemetryEvent] = [
            ev(.connectSuccess, level: .notice, seq: 1, secondsFromBase: 0,
               payload: ["rtt_ms": AnyCodable(10.0)]),
            ev(.connectDisconnect, level: .notice, actor: .user, seq: 2, secondsFromBase: 5),
            ev(.connectSuccess, level: .notice, seq: 3, secondsFromBase: 10,
               payload: ["rtt_ms": AnyCodable(10.0)]),
            ev(.connectDisconnect, level: .notice, actor: .user, seq: 4, secondsFromBase: 15),
            ev(.connectSuccess, level: .notice, seq: 5, secondsFromBase: 20,
               payload: ["rtt_ms": AnyCodable(10.0)]),
            ev(.connectDisconnect, level: .notice, actor: .user, seq: 6, secondsFromBase: 25),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "connection.flapping" },
                       "60초 내 3 cycle 이면 flapping 검출돼야 함")
    }

    // MARK: - Insights — RTT rules

    func testRttSevereInsight() {
        let events: [TelemetryEvent] = (1...5).map { i in
            ev(.connectSuccess, level: .notice, seq: UInt64(i), secondsFromBase: Double(i),
               payload: ["rtt_ms": AnyCodable(120.0)])
        }
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "rtt.severe" })
    }

    func testRttRegressionInsightForMidValues() {
        let events: [TelemetryEvent] = (1...5).map { i in
            ev(.connectSuccess, level: .notice, seq: UInt64(i), secondsFromBase: Double(i),
               payload: ["rtt_ms": AnyCodable(60.0)])
        }
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "rtt.regression" })
    }

    func testNoRttInsightWhenLow() {
        let events: [TelemetryEvent] = (1...5).map { i in
            ev(.connectSuccess, level: .notice, seq: UInt64(i), secondsFromBase: Double(i),
               payload: ["rtt_ms": AnyCodable(8.0)])
        }
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID.hasPrefix("rtt.") })
    }

    // MARK: - Insights — IMU rules

    func testImuStaleInsightFiresAtThreshold() {
        let staleCtx = TelemetryContext(connection: .connected, endpoint: "usb:test",
                                         section: nil, batteryV: 11.0, rttMs: 8.0, imuStale: true)
        let okCtx = TelemetryContext(connection: .connected, endpoint: "usb:test",
                                      section: nil, batteryV: 11.0, rttMs: 8.0, imuStale: false)
        var events: [TelemetryEvent] = []
        // 25% stale 비율 (1/4).
        events.append(ev(.heartbeat, level: .trace, seq: 1, secondsFromBase: 0, context: staleCtx))
        events.append(ev(.heartbeat, level: .trace, seq: 2, secondsFromBase: 1, context: okCtx))
        events.append(ev(.heartbeat, level: .trace, seq: 3, secondsFromBase: 2, context: okCtx))
        events.append(ev(.heartbeat, level: .trace, seq: 4, secondsFromBase: 3, context: okCtx))
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "imu.stale_persistent" })
    }

    // MARK: - Insights — WalkLab

    func testWalkLabStartBlockedRepeatInsight() {
        let events: [TelemetryEvent] = (1...3).map { i in
            ev(.walkLabStartBlocked, level: .warn, actor: .user, seq: UInt64(i),
               secondsFromBase: Double(i),
               payload: ["reason": AnyCodable("imuStale")])
        }
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains {
            $0.ruleID == "walklab.start_blocked_repeat" && $0.title.contains("imuStale")
        })
    }

    func testWalkLabEmergencyPatternInsightFires() {
        let events: [TelemetryEvent] = [
            ev(.walkLabStart, level: .notice, actor: .user, seq: 1, secondsFromBase: 0),
            ev(.walkLabEmergencyStop, level: .error, actor: .user, seq: 2, secondsFromBase: 30),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "walklab.emergency_pattern" })
    }

    // MARK: - Insights — Harness self

    func testHarnessDroppedInsight() {
        let events: [TelemetryEvent] = [
            ev(.harnessDropped, level: .warn, seq: 1, payload: ["count": AnyCodable(50)])
        ]
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "harness.dropped_present" })
    }

    // MARK: - Insights — Connection wizard (cycle 218)

    func testSetupConnRepeatedFailureFiresAtThreshold() {
        // 3회 oneclick_all_failed → insight 발화.
        let events: [TelemetryEvent] = (1...3).map { i in
            ev(.setupConnOneClickAllFailed, level: .notice, actor: .system,
               seq: UInt64(i), secondsFromBase: Double(i))
        }
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        let match = insights.first { $0.ruleID == "setup.conn_repeated_failure" }
        XCTAssertNotNil(match, "3회 이상이면 setup.conn_repeated_failure 발화돼야 함")
        XCTAssertEqual(match?.severity, .warn)
        XCTAssertEqual(match?.kind, .connection)
    }

    func testSetupConnRepeatedFailureDoesNotFireBelowThreshold() {
        // 2회 oneclick_all_failed → insight 미발화.
        let events: [TelemetryEvent] = (1...2).map { i in
            ev(.setupConnOneClickAllFailed, level: .notice, actor: .system,
               seq: UInt64(i), secondsFromBase: Double(i))
        }
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "setup.conn_repeated_failure" },
                        "2회면 임계 미달 — 발화 X")
    }

    func testSetupConnWizardFrequencyFiresAtThreshold() {
        // 5회 wizard_started → insight 발화.
        let events: [TelemetryEvent] = (1...5).map { i in
            ev(.setupConnWizardStarted, level: .info, actor: .user,
               seq: UInt64(i), secondsFromBase: Double(i))
        }
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        let match = insights.first { $0.ruleID == "setup.conn_wizard_frequency" }
        XCTAssertNotNil(match, "5회 이상이면 setup.conn_wizard_frequency 발화돼야 함")
        XCTAssertEqual(match?.severity, .notice)
        XCTAssertEqual(match?.kind, .connection)
    }

    func testSetupConnWizardFrequencyDoesNotFireBelowThreshold() {
        // 4회 wizard_started → insight 미발화.
        let events: [TelemetryEvent] = (1...4).map { i in
            ev(.setupConnWizardStarted, level: .info, actor: .user,
               seq: UInt64(i), secondsFromBase: Double(i))
        }
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "setup.conn_wizard_frequency" },
                        "4회면 임계 미달 — 발화 X")
    }

    // MARK: - Insights — clean session ≠ no insight

    func testCleanSessionProducesNoCriticalInsights() {
        let events: [TelemetryEvent] = [
            ev(.appLaunch, level: .notice, seq: 1, secondsFromBase: 0),
            ev(.connectSuccess, level: .notice, seq: 2, secondsFromBase: 1,
               payload: ["rtt_ms": AnyCodable(8.0)]),
            ev(.heartbeat, level: .trace, seq: 3, secondsFromBase: 2),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertFalse(insights.contains { $0.severity == .critical },
                        "정상 세션엔 critical insight 없어야 함")
    }

    // MARK: - Baseline diff

    func testBaselineDiffSimilarVerdict() {
        let baseline = makeAnalysis(connects: 5, successes: 5, errors: 0, eStops: 0,
                                      rttMs: [10, 12, 14])
        let current = makeAnalysis(connects: 5, successes: 5, errors: 0, eStops: 0,
                                     rttMs: [11, 13, 13])
        let diff = HarnessBaseline.compare(
            baseline: (id: "B", analysis: baseline),
            current: (id: "C", analysis: current)
        )
        if case .similar = diff.verdict { /* OK */ } else {
            XCTFail("similar 으로 분류돼야 하는데 \(diff.verdict)")
        }
    }

    func testBaselineDiffRegressionVerdict() {
        // RTT 큰 증가 + 에러 증가 + e-stop 발생.
        let baseline = makeAnalysis(connects: 10, successes: 10, errors: 0, eStops: 0,
                                      rttMs: [10, 12, 11])
        let current = makeAnalysis(connects: 10, successes: 5, errors: 5, eStops: 2,
                                     rttMs: [60, 70, 80])
        let diff = HarnessBaseline.compare(
            baseline: (id: "B", analysis: baseline),
            current: (id: "C", analysis: current)
        )
        if case .regression = diff.verdict { /* OK */ } else {
            XCTFail("regression 으로 분류돼야 하는데 \(diff.verdict)")
        }
    }

    func testBaselineDiffImprovementVerdict() {
        let baseline = makeAnalysis(connects: 10, successes: 5, errors: 5, eStops: 2,
                                      rttMs: [60, 70, 80])
        let current = makeAnalysis(connects: 10, successes: 10, errors: 0, eStops: 0,
                                     rttMs: [10, 12, 11])
        let diff = HarnessBaseline.compare(
            baseline: (id: "B", analysis: baseline),
            current: (id: "C", analysis: current)
        )
        if case .improvement = diff.verdict { /* OK */ } else {
            XCTFail("improvement 으로 분류돼야 하는데 \(diff.verdict)")
        }
    }

    func testMetricDeltaPercentComputation() {
        let baseline = makeAnalysis(connects: 1, successes: 1, errors: 0, eStops: 0,
                                      rttMs: [10])
        let current = makeAnalysis(connects: 1, successes: 1, errors: 0, eStops: 0,
                                     rttMs: [20])
        let diff = HarnessBaseline.compare(
            baseline: (id: "B", analysis: baseline),
            current: (id: "C", analysis: current)
        )
        let rttDelta = diff.metrics.first(where: { $0.label == "RTT p95 (ms)" })
        XCTAssertNotNil(rttDelta)
        XCTAssertEqual(rttDelta?.deltaPercent ?? 0, 100, accuracy: 0.01)
    }

    // MARK: - LiveAlerts

    func testLiveAlertRttFiresAboveThreshold() async {
        let ctx = TelemetryContext(connection: .connected, endpoint: "usb:test",
                                    section: nil, batteryV: 11.0, rttMs: 150.0, imuStale: false)
        let events: [TelemetryEvent] = (1...10).map { i in
            ev(.heartbeat, level: .trace, seq: UInt64(i),
               secondsFromBase: -Double(i) + 30,    // 최근 30초 안.
               context: ctx)
        }
        // base 시각으로부터 30 초 후 -> 이벤트들 모두 base..base+30 사이에 분포.
        // 그렇지만 evaluate 는 Date() 의 -60s 윈도우로 자름. 따라서 이벤트의 wall 이 현재 시간 기준이어야.
        // 따라서 fixture 의 base 를 현재 시간 기준으로 재구성.
        let now = Date()
        let nowFmt = ISO8601DateFormatter()
        nowFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let recentEvents: [TelemetryEvent] = events.map { e in
            TelemetryEvent(
                session: e.s, seq: e.i,
                wall: nowFmt.string(from: now.addingTimeInterval(-Double.random(in: 1...30))),
                mono: e.tm,
                kind: e.k, level: e.lv, actor: e.a,
                data: e.d, context: e.c
            )
        }
        HarnessLiveAlerts.shared.reset()
        HarnessLiveAlerts.shared.evaluate(events: recentEvents)
        XCTAssertTrue(HarnessLiveAlerts.shared.active.contains { $0.id == "rtt.window_mean" },
                       "RTT 평균 150ms 면 임계 80ms 초과 → 알림 발화")
    }

    func testLiveAlertClearsWhenEventsAge() async {
        // 모든 이벤트가 60초 윈도우 밖이면 alert 자동 해제.
        let oldEvents: [TelemetryEvent] = [
            ev(.heartbeat, level: .trace, seq: 1, secondsFromBase: -3600)
        ]
        HarnessLiveAlerts.shared.reset()
        HarnessLiveAlerts.shared.evaluate(events: oldEvents)
        XCTAssertTrue(HarnessLiveAlerts.shared.active.isEmpty,
                       "윈도우 밖 이벤트는 alert 발화 X")
    }

    func testLiveAlertEStopFiresCritical() async {
        let now = Date()
        let nowFmt = ISO8601DateFormatter()
        nowFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let estop = TelemetryEvent(
            session: "TEST", seq: 1,
            wall: nowFmt.string(from: now.addingTimeInterval(-5)),
            mono: 0,
            kind: .busEStop, level: .error, actor: .user,
            data: TelemetryPayload([:]), context: nil
        )
        HarnessLiveAlerts.shared.reset()
        HarnessLiveAlerts.shared.evaluate(events: [estop])
        let estopAlert = HarnessLiveAlerts.shared.active.first { $0.id == "estop.window" }
        XCTAssertNotNil(estopAlert)
        XCTAssertEqual(estopAlert?.severity, .critical)
    }

    // MARK: - JSON Report

    func testJSONReportSchemaAndCoreFields() throws {
        let events: [TelemetryEvent] = [
            ev(.appLaunch, level: .notice, seq: 1, secondsFromBase: 0),
            ev(.connectSuccess, level: .notice, seq: 2, secondsFromBase: 1,
               payload: ["rtt_ms": AnyCodable(15.0)]),
            ev(.busReadFail, level: .warn, actor: .robot, seq: 3, secondsFromBase: 2),
        ]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        let meta = TelemetrySessionMeta(
            id: "AB123456-FAKE", started: events[0].tw,
            ended: events.last?.tw,
            appVersion: "1.14.0", appBuild: "1",
            os: "macOS-test", device: "Test"
        )
        let json = SessionJSONRenderer.renderString(
            meta: meta, analysis: analysis, events: events, insights: insights
        )
        XCTAssertTrue(json.contains("\"schema\""))
        XCTAssertTrue(json.contains("\"darwinforge-harness/1.0\""))
        XCTAssertTrue(json.contains("\"connection\""))
        XCTAssertTrue(json.contains("\"insights\""))
        // Parse 가능한 JSON 인지.
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionJSONReport.self, from: data)
        XCTAssertEqual(decoded.schema, "darwinforge-harness/1.0")
        XCTAssertEqual(decoded.session.id, meta.id)
        XCTAssertEqual(decoded.summary.totalEvents, 3)
    }

    func testJSONReportIncludesDiffWhenProvided() throws {
        let baseline = makeAnalysis(connects: 1, successes: 1, errors: 0, eStops: 0, rttMs: [10])
        let current = makeAnalysis(connects: 1, successes: 1, errors: 5, eStops: 1, rttMs: [50])
        let diff = HarnessBaseline.compare(
            baseline: (id: "BASE", analysis: baseline),
            current: (id: "CURR", analysis: current)
        )
        let meta = TelemetrySessionMeta(
            id: "CURR", started: "2026-05-20T12:00:00.000Z",
            appVersion: "1.14.0", appBuild: "1", os: "test", device: "test"
        )
        let json = SessionJSONRenderer.renderString(
            meta: meta, analysis: current, events: [], insights: [], diff: diff
        )
        let decoded = try JSONDecoder().decode(SessionJSONReport.self,
                                                  from: try XCTUnwrap(json.data(using: .utf8)))
        XCTAssertNotNil(decoded.diff)
        XCTAssertEqual(decoded.diff?.baselineId, "BASE")
    }

    // MARK: - Forward-compat meta

    func testMetaDecodesOldFormatWithoutIsBaseline() throws {
        let oldJson = """
        {"schema":1,"id":"x","started":"2026-05-20T12:00:00.000Z",
         "appVersion":"1.13.0","appBuild":"1","os":"test","device":"test",
         "eventCount":0,"sizeBytes":0,"droppedCount":0,
         "connectCount":0,"errorCount":0,"pinned":false}
        """
        let meta = try JSONDecoder().decode(TelemetrySessionMeta.self,
                                              from: try XCTUnwrap(oldJson.data(using: .utf8)))
        XCTAssertEqual(meta.isBaseline, false, "옛 meta.json 은 isBaseline=false 폴백")
    }

    // MARK: - 헬퍼

    private func makeAnalysis(connects: Int, successes: Int,
                                errors: Int, eStops: Int,
                                rttMs: [Double]) -> SessionAnalysis {
        var events: [TelemetryEvent] = []
        for i in 0..<connects {
            events.append(ev(.connectAttempt, seq: UInt64(i + 1), secondsFromBase: Double(i)))
        }
        for i in 0..<successes {
            events.append(ev(.connectSuccess, level: .notice, seq: UInt64(connects + i + 1),
                              secondsFromBase: Double(connects + i),
                              payload: ["rtt_ms": AnyCodable(rttMs[i % rttMs.count])]))
        }
        for i in 0..<errors {
            events.append(ev(.busReadFail, level: .error, actor: .robot,
                              seq: UInt64(connects + successes + i + 1),
                              secondsFromBase: Double(connects + successes + i)))
        }
        for i in 0..<eStops {
            events.append(ev(.busEStop, level: .error, actor: .user,
                              seq: UInt64(connects + successes + errors + i + 1),
                              secondsFromBase: Double(connects + successes + errors + i)))
        }
        return SessionAnalyzer.analyze(events: events)
    }
}
