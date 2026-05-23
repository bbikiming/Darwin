import Foundation
import XCTest
@testable import DarwinForgeUI

/// Cycle 226: insight rules for error-class TelemetryKind constants.
/// 기존 errorCountedKinds 에 포함되지만 진단 surfacing 이 없던 kind 들에 대한 rule 추가.
final class HarnessInsightsCycle226Tests: XCTestCase {

    // MARK: - helpers

    private let base = Date(timeIntervalSince1970: 1_716_000_000)

    private func ev(
        _ kind: TelemetryKind,
        level: TelemetryLevel = .error,
        actor: TelemetryActor = .system,
        seq: UInt64 = 1,
        secondsFromBase: Double = 0,
        payload: [String: AnyCodable] = [:]
    ) -> TelemetryEvent {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wall = f.string(from: base.addingTimeInterval(secondsFromBase))
        let monoNs = UInt64(max(0, abs(secondsFromBase) * 1e9))
        return TelemetryEvent(
            session: "TEST", seq: seq,
            wall: wall, mono: monoNs,
            kind: kind, level: level, actor: actor,
            data: TelemetryPayload(payload)
        )
    }

    // MARK: - claude.error_pattern

    func testClaudeErrorPatternFiresAt3() {
        let events = (0..<3).map { i in
            ev(.claudeError, actor: .claude, seq: UInt64(i), secondsFromBase: Double(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "claude.error_pattern" })
    }

    func testClaudeErrorPatternDoesNotFireBelow3() {
        let events = (0..<2).map { i in
            ev(.claudeError, actor: .claude, seq: UInt64(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "claude.error_pattern" })
    }

    // MARK: - claude.plan_exec_fail_pattern

    func testClaudePlanExecFailFiresAt2() {
        let events = (0..<2).map { i in
            ev(.claudePlanExecutionFailed, seq: UInt64(i), secondsFromBase: Double(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "claude.plan_exec_fail_pattern" })
    }

    func testClaudePlanExecFailDoesNotFireBelow2() {
        let events = [ev(.claudePlanExecutionFailed, seq: 0)]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "claude.plan_exec_fail_pattern" })
    }

    // MARK: - joint.action_failed_pattern

    func testJointActionFailedFiresAt3() {
        let events = (0..<3).map { i in
            ev(.jointActionFailed, seq: UInt64(i), secondsFromBase: Double(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "joint.action_failed_pattern" })
    }

    func testJointActionFailedDoesNotFireBelow3() {
        let events = (0..<2).map { i in
            ev(.jointActionFailed, seq: UInt64(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "joint.action_failed_pattern" })
    }

    // MARK: - remote.command_error_pattern

    func testRemoteCommandErrorFiresAt3() {
        let events = (0..<3).map { i in
            ev(.remoteCommandError, seq: UInt64(i), secondsFromBase: Double(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "remote.command_error_pattern" })
    }

    func testRemoteCommandErrorDoesNotFireBelow3() {
        let events = (0..<2).map { i in
            ev(.remoteCommandError, seq: UInt64(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "remote.command_error_pattern" })
    }

    func testRemoteCommandErrorKindIsRemote() {
        let events = (0..<3).map { i in
            ev(.remoteCommandError, seq: UInt64(i), secondsFromBase: Double(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        let found = insights.first { $0.ruleID == "remote.command_error_pattern" }
        XCTAssertEqual(found?.kind, .remote)
    }

    // MARK: - error.exception_pattern

    func testErrorExceptionFiresAt1() {
        let events = [
            ev(.errorException, seq: 0,
               payload: ["source": AnyCodable("pilot.action_bar"), "error_hash": AnyCodable("abc123")])
        ]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "error.exception_pattern" })
    }

    func testErrorExceptionSeverityCriticalAt3() {
        let events = (0..<3).map { i in
            ev(.errorException, seq: UInt64(i), secondsFromBase: Double(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        let found = insights.first { $0.ruleID == "error.exception_pattern" }
        XCTAssertEqual(found?.severity, .critical)
    }

    func testErrorExceptionSeverityWarnAt1() {
        let events = [ev(.errorException, seq: 0)]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        let found = insights.first { $0.ruleID == "error.exception_pattern" }
        XCTAssertEqual(found?.severity, .warn)
    }

    // MARK: - bus.write_storm

    func testBusWriteStormFiresWhenHighRate() {
        // 30초 안에 10건 bus write fail = 분당 20회
        var events: [TelemetryEvent] = []
        for i in 0..<10 {
            events.append(ev(.busWriteFail, level: .error, actor: .robot,
                             seq: UInt64(i), secondsFromBase: Double(i) * 3))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "bus.write_storm" })
    }

    func testBusWriteStormDoesNotFireBelowThreshold() {
        // 4건 — threshold 미만
        let events = (0..<4).map { i in
            ev(.busWriteFail, level: .error, actor: .robot,
               seq: UInt64(i), secondsFromBase: Double(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "bus.write_storm" })
    }

    func testBusWriteStormSeverityIsCritical() {
        var events: [TelemetryEvent] = []
        for i in 0..<10 {
            events.append(ev(.busWriteFail, level: .error, actor: .robot,
                             seq: UInt64(i), secondsFromBase: Double(i) * 3))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        let found = insights.first { $0.ruleID == "bus.write_storm" }
        XCTAssertEqual(found?.severity, .critical)
    }
}
