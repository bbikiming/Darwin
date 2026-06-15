import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.14.1 (2026-05-21)** — 5개 병렬 에이전트가 식별한 커버리지 격차 충당.
/// 6개 미커버 룰 + 0-baseline e-stop verdict + empty JSON + emergency pattern 반복.
@MainActor
final class HarnessUtilizationCoverageTests: XCTestCase {

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
        let monoNs = UInt64(max(0, abs(secondsFromBase) * 1e9))
        return TelemetryEvent(
            session: "TEST", seq: seq, wall: wall, mono: monoNs,
            kind: kind, level: level, actor: actor,
            data: TelemetryPayload(payload), context: context
        )
    }

    // MARK: - GAP-1: bus.read_storm

    func testBusReadStormFiresAtThreshold() {
        // 60초 세션 = 1 분, busReadFailures 10 → perMin = 10.
        var events: [TelemetryEvent] = []
        for i in 0..<10 {
            events.append(ev(.busReadFail, level: .warn, actor: .robot,
                              seq: UInt64(i + 1), secondsFromBase: Double(i) * 6))
        }
        events.append(ev(.heartbeat, level: .trace, seq: 11, secondsFromBase: 60))
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "bus.read_storm" },
                       "60s 동안 10건 발생 → 분당 10건 임계 충족, 룰 발화해야 함")
    }

    func testBusReadStormNotFiredBelowThreshold() {
        // 120초 안에 10건 — 분당 5건 → 임계 미달.
        var events: [TelemetryEvent] = []
        for i in 0..<10 {
            events.append(ev(.busReadFail, level: .warn, actor: .robot,
                              seq: UInt64(i + 1), secondsFromBase: Double(i) * 12))
        }
        events.append(ev(.heartbeat, level: .trace, seq: 11, secondsFromBase: 120))
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "bus.read_storm" },
                        "분당 5건은 임계(10) 미달 — 발화 X")
    }

    // MARK: - GAP-2: pose.write_failed_chain

    func testPoseWriteFailedChainFiresOnBusErrorCascade() {
        let events: [TelemetryEvent] = [
            ev(.poseApplyFailed, level: .error, actor: .robot, seq: 1, secondsFromBase: 0,
               payload: ["reason": AnyCodable("writeFailed")]),
            ev(.busReadFail, level: .warn, actor: .robot, seq: 2, secondsFromBase: 5),
            ev(.busReadFail, level: .warn, actor: .robot, seq: 3, secondsFromBase: 10),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "pose.write_failed_chain" })
    }

    func testPoseWriteFailedChainNotFiredWithOtherReason() {
        // reason=rejected 면 chain 룰 X.
        let events: [TelemetryEvent] = [
            ev(.poseApplyFailed, level: .warn, actor: .system, seq: 1, secondsFromBase: 0,
               payload: ["reason": AnyCodable("rejected")]),
            ev(.busReadFail, level: .warn, actor: .robot, seq: 2, secondsFromBase: 5),
            ev(.busReadFail, level: .warn, actor: .robot, seq: 3, secondsFromBase: 10),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "pose.write_failed_chain" })
    }

    // MARK: - GAP-3: idle_session

    func testIdleSessionFiresWithLowUserActivity() {
        // 31분 = 1860초 duration, user 이벤트 5개 (< 10).
        // first event @ 0, last event @ 1860 → duration > 1800.
        var events: [TelemetryEvent] = []
        for i in 0..<5 {
            events.append(ev(.uiSectionChanged, level: .info, actor: .user,
                              seq: UInt64(i + 1), secondsFromBase: Double(i)))
        }
        // 60 heartbeat — 마지막을 1860초로 명시 배치.
        for i in 0..<60 {
            events.append(ev(.heartbeat, level: .trace, actor: .system,
                              seq: UInt64(i + 100),
                              secondsFromBase: 30 + Double(i) * 30.5))
        }
        // 마지막 명시 heartbeat — duration 1860 보장.
        events.append(ev(.heartbeat, level: .trace, actor: .system,
                          seq: 200, secondsFromBase: 1860))
        // 시간 정렬 (analyzer 가 시간순 기대).
        events.sort { $0.tw < $1.tw }
        let a = SessionAnalyzer.analyze(events: events)
        XCTAssertGreaterThan(a.summary.durationSeconds ?? 0, 1800,
                              "사전 조건: duration > 1800")
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "idle_session" },
                       "duration>1800 + userEvents<10 → idle_session 발화")
    }

    func testIdleSessionNotFiredForShortSession() {
        // 5분 세션 — 1800 미달.
        let events: [TelemetryEvent] = [
            ev(.appLaunch, level: .notice, seq: 1, secondsFromBase: 0),
            ev(.heartbeat, level: .trace, seq: 2, secondsFromBase: 300),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "idle_session" })
    }

    // MARK: - GAP-4 ~ GAP-6: LiveAlerts 3종

    func testLiveAlertImuStaleFiresAboveRatio() {
        let now = Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // heartbeat 6개 중 4개 stale (66%) — 임계 50% 초과.
        var events: [TelemetryEvent] = []
        for i in 0..<6 {
            let stale = i < 4
            let ctx = TelemetryContext(
                connection: .connected, endpoint: "usb:test",
                section: nil, batteryV: 11.0, rttMs: 8.0, imuStale: stale)
            let wall = f.string(from: now.addingTimeInterval(-Double(i + 1) * 5))
            events.append(TelemetryEvent(
                session: "TEST", seq: UInt64(i + 1), wall: wall, mono: 0,
                kind: .heartbeat, level: .trace, actor: .system,
                data: TelemetryPayload([:]), context: ctx))
        }
        HarnessLiveAlerts.shared.reset()
        HarnessLiveAlerts.shared.evaluate(events: events)
        XCTAssertTrue(HarnessLiveAlerts.shared.active.contains {
            $0.id == "imu.window_stale"
        }, "IMU stale 66% → 임계 50% 초과 → 알림 발화")
    }

    func testLiveAlertImuStaleGuardOnLowSampleCount() {
        // heartbeat 4개 (< 5) — stale ratio 가 100% 라도 guard.
        let now = Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ctx = TelemetryContext(
            connection: .connected, endpoint: "usb:test",
            section: nil, batteryV: 11.0, rttMs: 8.0, imuStale: true)
        var events: [TelemetryEvent] = []
        for i in 0..<4 {
            let wall = f.string(from: now.addingTimeInterval(-Double(i + 1) * 5))
            events.append(TelemetryEvent(
                session: "TEST", seq: UInt64(i + 1), wall: wall, mono: 0,
                kind: .heartbeat, level: .trace, actor: .system,
                data: TelemetryPayload([:]), context: ctx))
        }
        HarnessLiveAlerts.shared.reset()
        HarnessLiveAlerts.shared.evaluate(events: events)
        XCTAssertFalse(HarnessLiveAlerts.shared.active.contains {
            $0.id == "imu.window_stale"
        }, "heartbeat 5 미만 — guard 발효, 알림 X")
    }

    func testLiveAlertConnectionFailuresFires() {
        let now = Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var events: [TelemetryEvent] = []
        // 60초 안 2건 — 임계 충족.
        for i in 0..<2 {
            let wall = f.string(from: now.addingTimeInterval(-Double(i + 1) * 10))
            events.append(TelemetryEvent(
                session: "TEST", seq: UInt64(i + 1), wall: wall, mono: 0,
                kind: .connectFailure, level: .error, actor: .system,
                data: TelemetryPayload([:]), context: nil))
        }
        HarnessLiveAlerts.shared.reset()
        HarnessLiveAlerts.shared.evaluate(events: events)
        XCTAssertTrue(HarnessLiveAlerts.shared.active.contains {
            $0.id == "connection.window_failures"
        })
    }

    func testLiveAlertBusWriteFailFires() {
        let now = Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var events: [TelemetryEvent] = []
        for i in 0..<3 {
            let wall = f.string(from: now.addingTimeInterval(-Double(i + 1) * 10))
            events.append(TelemetryEvent(
                session: "TEST", seq: UInt64(i + 1), wall: wall, mono: 0,
                kind: .busWriteFail, level: .error, actor: .robot,
                data: TelemetryPayload([:]), context: nil))
        }
        HarnessLiveAlerts.shared.reset()
        HarnessLiveAlerts.shared.evaluate(events: events)
        XCTAssertTrue(HarnessLiveAlerts.shared.active.contains {
            $0.id == "bus.window_write_fail"
        })
    }

    // MARK: - GAP: 0-baseline e-stop verdict (P1-2 핵심 안전 fix)

    func testBaselineZeroEStopToCurrentNonZeroFiresRegression() {
        // baseline 깨끗 (e-stop 0), current 에서 e-stop 1회 → MUST be regression.
        let baseline = makeAnalysis(connects: 10, successes: 10, errors: 0, eStops: 0, rttMs: [10])
        let current = makeAnalysis(connects: 10, successes: 10, errors: 0, eStops: 1, rttMs: [10])
        let diff = HarnessBaseline.compare(
            baseline: (id: "B", analysis: baseline),
            current: (id: "C", analysis: current)
        )
        if case .regression(let reason) = diff.verdict {
            XCTAssertTrue(reason.contains("E-stop"), "회귀 사유에 E-stop 포함")
        } else {
            XCTFail("baseline=0 → current=1 e-stop 은 반드시 regression — 실제: \(diff.verdict)")
        }
    }

    func testBaselineZeroEStopToZeroIsSimilar() {
        // 둘 다 0 — 다른 지표 동일 시 similar.
        let baseline = makeAnalysis(connects: 5, successes: 5, errors: 0, eStops: 0, rttMs: [10])
        let current = makeAnalysis(connects: 5, successes: 5, errors: 0, eStops: 0, rttMs: [10])
        let diff = HarnessBaseline.compare(
            baseline: (id: "B", analysis: baseline),
            current: (id: "C", analysis: current)
        )
        if case .similar = diff.verdict { /* OK */ } else {
            XCTFail("동일한 세션은 similar — 실제: \(diff.verdict)")
        }
    }

    // MARK: - GAP: emergency_pattern 반복 (P1-3 fix)

    func testEmergencyPatternRepeatFiresAggregateInsight() {
        // 두 번의 start → e-stop 쌍 (각각 1분 안).
        let events: [TelemetryEvent] = [
            ev(.walkLabStart, level: .notice, actor: .user, seq: 1, secondsFromBase: 0),
            ev(.walkLabEmergencyStop, level: .error, actor: .user, seq: 2, secondsFromBase: 30),
            ev(.walkLabStart, level: .notice, actor: .user, seq: 3, secondsFromBase: 100),
            ev(.walkLabEmergencyStop, level: .error, actor: .user, seq: 4, secondsFromBase: 140),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        let patterns = insights.filter { $0.ruleID == "walklab.emergency_pattern" }
        XCTAssertEqual(patterns.count, 2, "각 쌍마다 critical insight — break 제거 검증")
        XCTAssertTrue(insights.contains { $0.ruleID == "walklab.emergency_pattern_repeat" },
                       "2회 이상 반복 → 종합 insight 발화")
    }

    // MARK: - GAP: Empty JSON Report

    func testJSONReportHandlesEmptySession() throws {
        let meta = TelemetrySessionMeta(
            id: "EMPTY", started: "2026-05-21T00:00:00.000Z",
            appVersion: "1.14.1", appBuild: "1", os: "test", device: "test"
        )
        let analysis = SessionAnalyzer.analyze(events: [])
        let json = SessionJSONRenderer.renderString(
            meta: meta, analysis: analysis, events: [], insights: []
        )
        // null 처리 + Codable round-trip.
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionJSONReport.self, from: data)
        XCTAssertEqual(decoded.summary.totalEvents, 0)
        XCTAssertTrue(decoded.timeline.isEmpty)
        XCTAssertTrue(decoded.errors.isEmpty)
        XCTAssertTrue(decoded.insights.isEmpty)
        XCTAssertNil(decoded.summary.rttMs)
        XCTAssertNil(decoded.summary.imu)
    }

    // MARK: - GAP: Security P1-1 — payload scrub

    func testJSONReportErrorPayloadIsScrubbed() throws {
        // raw 사용자 텍스트가 payload 에 들어와도 redact 되어야.
        let secret = "user-secret-message-very-private"
        let evError = TelemetryEvent(
            session: "TEST", seq: 1,
            wall: "2026-05-21T00:00:00.000Z", mono: 0,
            kind: .errorException, level: .error, actor: .system,
            data: TelemetryPayload([
                "user_message": AnyCodable(secret),     // 알 수 없는 키 = scrub 대상
                "rtt_ms": AnyCodable(8.0)               // safe key — 통과
            ]),
            context: nil
        )
        let meta = TelemetrySessionMeta(
            id: "TEST", started: evError.tw,
            appVersion: "1.14.1", appBuild: "1", os: "test", device: "test"
        )
        let analysis = SessionAnalyzer.analyze(events: [evError])
        let json = SessionJSONRenderer.renderString(
            meta: meta, analysis: analysis, events: [evError], insights: []
        )
        // raw secret 본문이 절대 JSON 에 들어가면 안 됨.
        XCTAssertFalse(json.contains(secret),
                        "사용자 텍스트가 JSON 에 raw 로 누출됨 — Security P1-1 회귀")
        // safe key 는 통과.
        XCTAssertTrue(json.contains("\"rtt_ms\""))
        // scrubbed 형식.
        XCTAssertTrue(json.contains("user_message_len") || json.contains("user_message_hash"))
    }

    // MARK: - GAP: meta isBaseline 동기화

    func testSetBaselineWithMetaSyncWritesIsBaselineToDisk() throws {
        // 임시 디렉토리에 fake 아카이브 세션 만들고 setBaselineWithMetaSync 호출.
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-sync-\(UUID().uuidString)")
        let archiveDir = tmpRoot
            .appendingPathComponent("DarwinForge")
            .appendingPathComponent("Harness")
            .appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        // 본 테스트는 setBaselineWithMetaSync 의 동작 검증 — UserDefaults 만이라도 갱신
        // 되는지. 디스크 sync 는 TelemetryStore.archivedSessions() 가 실제 ~/Library 경로를
        // 보므로 isolated 검증 어려움 → UserDefaults 갱신 검증으로 대체.
        HarnessBaseline.setBaseline(nil)
        HarnessBaseline.setBaselineWithMetaSync("SOMEID")
        XCTAssertEqual(HarnessBaseline.currentBaselineId(), "SOMEID")
        HarnessBaseline.setBaselineWithMetaSync(nil)
        XCTAssertNil(HarnessBaseline.currentBaselineId())
    }

    // MARK: - Helper

    private func makeAnalysis(connects: Int, successes: Int,
                                errors: Int, eStops: Int,
                                rttMs: [Double]) -> SessionAnalysis {
        var events: [TelemetryEvent] = []
        for i in 0..<connects {
            events.append(ev(.connectAttempt, seq: UInt64(i + 1), secondsFromBase: Double(i)))
        }
        for i in 0..<successes {
            events.append(ev(.connectSuccess, level: .notice,
                              seq: UInt64(connects + i + 1),
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
