import Foundation
import XCTest
@testable import DarwinForgeUI

/// Cycle 225: insight rules for TelemetryKind constants from cycles 220-224.
final class HarnessInsightsCycle225Tests: XCTestCase {

    // MARK: - helpers

    private let base = Date(timeIntervalSince1970: 1_716_000_000)

    private func ev(
        _ kind: TelemetryKind,
        level: TelemetryLevel = .info,
        actor: TelemetryActor = .user,
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

    // MARK: - pilot.safety_gate_blocked_frequent

    func testSafetyGateBlockedFrequentFiresAt5() {
        // 5 blocked events should fire the rule.
        let events: [TelemetryEvent] = (0..<5).map { i in
            ev(.pilotSafetyGateBlocked, seq: UInt64(i + 1),
               secondsFromBase: Double(i),
               payload: ["reason": AnyCodable("blockUnarmed"),
                         "motion_name": AnyCodable("kick")])
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "pilot.safety_gate_blocked_frequent" },
                      "5 pilotSafetyGateBlocked events should trigger the frequent rule")
    }

    func testSafetyGateBlockedDoesNotFireBelow5() {
        // 4 blocked events should NOT fire.
        let events: [TelemetryEvent] = (0..<4).map { i in
            ev(.pilotSafetyGateBlocked, seq: UInt64(i + 1),
               secondsFromBase: Double(i),
               payload: ["reason": AnyCodable("blockUnarmed")])
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "pilot.safety_gate_blocked_frequent" },
                       "4 events is below threshold -- rule should not fire")
    }

    // MARK: - pilot.action_bar_risk_cancel_frequent

    func testRiskCancelFrequentFiresAt3() {
        let events: [TelemetryEvent] = (0..<3).map { i in
            ev(.pilotActionBarRiskCancelled, seq: UInt64(i + 1),
               secondsFromBase: Double(i),
               payload: ["slot": AnyCodable(i),
                         "safety_class": AnyCodable("high")])
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "pilot.action_bar_risk_cancel_frequent" },
                      "3 risk cancel events should trigger the frequent rule")
    }

    func testRiskCancelDoesNotFireBelow3() {
        let events: [TelemetryEvent] = (0..<2).map { i in
            ev(.pilotActionBarRiskCancelled, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "pilot.action_bar_risk_cancel_frequent" },
                       "2 events is below threshold -- rule should not fire")
    }

    // MARK: - claude.intent_error_pattern

    func testClaudeIntentErrorPatternFiresAt3() {
        let events: [TelemetryEvent] = (0..<3).map { i in
            ev(.claudeIntentError, level: .error, actor: .claude,
               seq: UInt64(i + 1), secondsFromBase: Double(i),
               payload: ["tool": AnyCodable("walk"),
                         "error_case": AnyCodable("timeout")])
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "claude.intent_error_pattern" },
                      "3 claudeIntentError events should trigger intent_error_pattern")
    }

    func testClaudeIntentErrorDoesNotFireBelow3() {
        let events: [TelemetryEvent] = (0..<2).map { i in
            ev(.claudeIntentError, level: .error, actor: .claude,
               seq: UInt64(i + 1), secondsFromBase: Double(i),
               payload: ["tool": AnyCodable("walk"),
                         "error_case": AnyCodable("timeout")])
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "claude.intent_error_pattern" },
                       "2 events is below threshold -- rule should not fire")
    }

    // MARK: - walklab.diagnostics_export_failure

    func testDiagnosticsExportFailureFiresOnFailure() {
        let events = [
            ev(.walklabDiagnosticsExport, seq: 1,
               payload: ["sample_count": AnyCodable(100),
                         "success": AnyCodable(false)])
        ]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "walklab.diagnostics_export_failure" },
                      "A single export with success=false should trigger the failure rule")
    }

    func testDiagnosticsExportSuccessDoesNotFire() {
        let events = [
            ev(.walklabDiagnosticsExport, seq: 1,
               payload: ["sample_count": AnyCodable(100),
                         "success": AnyCodable(true)])
        ]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "walklab.diagnostics_export_failure" },
                       "Export with success=true should not fire the failure rule")
    }

    // MARK: - walklab.balance_risky_pattern

    func testBalanceRiskyPatternFiresAt2() {
        let events: [TelemetryEvent] = (0..<2).map { i in
            ev(.walklabBalanceRiskyConfirmed, seq: UInt64(i + 1),
               secondsFromBase: Double(i),
               payload: ["algorithm": AnyCodable("PID"),
                         "sign": AnyCodable(1),
                         "gain": AnyCodable(2.0)])
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "walklab.balance_risky_pattern" },
                      "2 risky confirmed events should trigger the risky pattern rule")
    }

    func testBalanceRiskyPatternDoesNotFireBelow2() {
        let events = [
            ev(.walklabBalanceRiskyConfirmed, seq: 1,
               payload: ["algorithm": AnyCodable("PID"),
                         "sign": AnyCodable(1),
                         "gain": AnyCodable(2.0)])
        ]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "walklab.balance_risky_pattern" },
                       "1 event is below threshold -- rule should not fire")
    }

    // MARK: - walklab.calibration_incomplete

    func testCalibrationIncompleteFiresWhenStartWithoutDone() {
        // Two capture starts with no matching capture done -- incomplete.
        let events = [
            ev(.walklabCalibrationCaptureStart, seq: 1,
               secondsFromBase: 0, payload: ["axis": AnyCodable("roll")]),
            ev(.walklabCalibrationCaptureStart, seq: 2,
               secondsFromBase: 1, payload: ["axis": AnyCodable("pitch")])
        ]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "walklab.calibration_incomplete" },
                      "Capture starts without matching done should trigger incomplete rule")
    }

    func testCalibrationCompleteDoesNotFire() {
        // One start matched by one done -- complete, no insight.
        let events = [
            ev(.walklabCalibrationCaptureStart, seq: 1,
               secondsFromBase: 0, payload: ["axis": AnyCodable("roll")]),
            ev(.walklabCalibrationCaptureDone, seq: 2,
               secondsFromBase: 1,
               payload: ["axis": AnyCodable("roll"),
                         "sample_count": AnyCodable(250)])
        ]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "walklab.calibration_incomplete" },
                       "Matched start/done pair should not fire incomplete rule")
    }

    func testCalibrationPartiallyIncomplete() {
        // Two starts, only one done -- one axis incomplete.
        let events = [
            ev(.walklabCalibrationCaptureStart, seq: 1,
               secondsFromBase: 0, payload: ["axis": AnyCodable("roll")]),
            ev(.walklabCalibrationCaptureDone, seq: 2,
               secondsFromBase: 1,
               payload: ["axis": AnyCodable("roll"),
                         "sample_count": AnyCodable(250)]),
            ev(.walklabCalibrationCaptureStart, seq: 3,
               secondsFromBase: 2, payload: ["axis": AnyCodable("pitch")])
            // no done for pitch
        ]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "walklab.calibration_incomplete" },
                      "One unmatched axis should still trigger incomplete rule")
    }

    // MARK: - pilot.demo_mode_failure

    func testDemoModeFailureFiresAt2() {
        let events: [TelemetryEvent] = (0..<2).map { i in
            ev(.pilotDemoModeResult, seq: UInt64(i + 1),
               secondsFromBase: Double(i),
               payload: ["mode": AnyCodable("ballFollow"),
                         "success": AnyCodable(false)])
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "pilot.demo_mode_failure" },
                      "2 demo mode failures should trigger the rule")
    }

    func testDemoModeSuccessDoesNotFire() {
        let events: [TelemetryEvent] = (0..<3).map { i in
            ev(.pilotDemoModeResult, seq: UInt64(i + 1),
               secondsFromBase: Double(i),
               payload: ["mode": AnyCodable("ballFollow"),
                         "success": AnyCodable(true)])
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "pilot.demo_mode_failure" },
                       "All-success results should not fire the failure rule")
    }

    func testDemoModeFailureDoesNotFireBelow2() {
        let events = [
            ev(.pilotDemoModeResult, seq: 1,
               payload: ["mode": AnyCodable("ballFollow"),
                         "success": AnyCodable(false)])
        ]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "pilot.demo_mode_failure" },
                       "1 failure is below threshold -- rule should not fire")
    }

    // MARK: - walklab.data_deletion_frequent

    func testDataDeletionFrequentFiresAt3() {
        let events: [TelemetryEvent] = (0..<3).map { i in
            ev(.walklabDataSessionDeleted, level: .warn, seq: UInt64(i + 1),
               secondsFromBase: Double(i),
               payload: ["session_id_hash": AnyCodable("hash\(i)")])
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "walklab.data_deletion_frequent" },
                      "3 deletion events should trigger the frequent rule")
    }

    func testDataDeletionDoesNotFireBelow3() {
        let events: [TelemetryEvent] = (0..<2).map { i in
            ev(.walklabDataSessionDeleted, level: .warn, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "walklab.data_deletion_frequent" },
                       "2 events is below threshold -- rule should not fire")
    }

    // MARK: - Insight.Kind new cases

    func testInsightKindIncludesNewCases() {
        // Verify the new enum cases exist and round-trip via rawValue.
        let setup: Insight.Kind = .setup
        let remote: Insight.Kind = .remote
        let claude: Insight.Kind = .claude
        XCTAssertEqual(setup.rawValue, "setup")
        XCTAssertEqual(remote.rawValue, "remote")
        XCTAssertEqual(claude.rawValue, "claude")
    }

    // MARK: - Severity assertions

    func testSafetyGateBlockedSeverityIsNotice() {
        let events: [TelemetryEvent] = (0..<5).map { i in
            ev(.pilotSafetyGateBlocked, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        let matched = insights.first { $0.ruleID == "pilot.safety_gate_blocked_frequent" }
        XCTAssertEqual(matched?.severity, .notice,
                       "pilot.safety_gate_blocked_frequent severity should be notice")
    }

    func testClaudeIntentErrorSeverityIsWarn() {
        let events: [TelemetryEvent] = (0..<3).map { i in
            ev(.claudeIntentError, level: .error, actor: .claude,
               seq: UInt64(i + 1), secondsFromBase: Double(i),
               payload: ["tool": AnyCodable("walk"),
                         "error_case": AnyCodable("timeout")])
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        let matched = insights.first { $0.ruleID == "claude.intent_error_pattern" }
        XCTAssertEqual(matched?.severity, .warn,
                       "claude.intent_error_pattern severity should be warn")
    }

    func testDiagnosticsExportFailureSeverityIsWarn() {
        let events = [
            ev(.walklabDiagnosticsExport, seq: 1,
               payload: ["sample_count": AnyCodable(100),
                         "success": AnyCodable(false)])
        ]
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        let matched = insights.first { $0.ruleID == "walklab.diagnostics_export_failure" }
        XCTAssertEqual(matched?.severity, .warn,
                       "walklab.diagnostics_export_failure severity should be warn")
    }

    func testDataDeletionFrequentSeverityIsInfo() {
        let events: [TelemetryEvent] = (0..<3).map { i in
            ev(.walklabDataSessionDeleted, level: .warn, seq: UInt64(i + 1),
               secondsFromBase: Double(i))
        }
        let analysis = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: analysis, events: events)
        let matched = insights.first { $0.ruleID == "walklab.data_deletion_frequent" }
        XCTAssertEqual(matched?.severity, .info,
                       "walklab.data_deletion_frequent severity should be info")
    }
}
