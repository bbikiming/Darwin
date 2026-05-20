import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.14.2 (2026-05-21)** — 21개 미발화 kind 중 핵심 hook 추가의 통합 검증.
/// 성공/실패/원인 추적 chain 이 실제로 작동하는지 fixture 로 검증.
@MainActor
final class HarnessHookExpansionTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_716_000_000)

    private func ev(_ kind: TelemetryKind,
                    level: TelemetryLevel = .info,
                    actor: TelemetryActor = .system,
                    seq: UInt64 = 1,
                    secondsFromBase: Double = 0,
                    payload: [String: AnyCodable] = [:]) -> TelemetryEvent {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wall = f.string(from: base.addingTimeInterval(secondsFromBase))
        return TelemetryEvent(
            session: "TEST", seq: seq, wall: wall, mono: UInt64(abs(secondsFromBase) * 1e9),
            kind: kind, level: level, actor: actor,
            data: TelemetryPayload(payload), context: nil)
    }

    // MARK: - IMU recovered → flapping rule

    func testImuFlappingRuleFiresOnRepeatedRecoveries() {
        // imu.unavailable → recovered 3회 발생.
        var events: [TelemetryEvent] = []
        for i in 0..<3 {
            events.append(ev(.imuUnavailable, level: .warn, actor: .robot,
                              seq: UInt64(i * 2 + 1), secondsFromBase: Double(i) * 10,
                              payload: ["consecutive_failures": AnyCodable(3)]))
            events.append(ev(.imuRecovered, level: .notice, actor: .robot,
                              seq: UInt64(i * 2 + 2), secondsFromBase: Double(i) * 10 + 2,
                              payload: ["from_state": AnyCodable("unavailable"),
                                        "prior_failures": AnyCodable(3)]))
        }
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "imu.flapping" },
                       "IMU recovered 3회 → flapping rule 발화")
    }

    func testImuFlappingRuleNotFiredBelowThreshold() {
        let events = [
            ev(.imuUnavailable, level: .warn, actor: .robot, seq: 1, secondsFromBase: 0),
            ev(.imuRecovered, level: .notice, actor: .robot, seq: 2, secondsFromBase: 2),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertFalse(insights.contains { $0.ruleID == "imu.flapping" })
    }

    // MARK: - reconnect frequent

    func testReconnectFrequentRuleFires() {
        let events: [TelemetryEvent] = (0..<5).map { i in
            ev(.connectReconnectAttempt, level: .info, actor: .system,
               seq: UInt64(i + 1), secondsFromBase: Double(i) * 5,
               payload: ["attempt": AnyCodable(i + 1)])
        }
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "connection.reconnect_frequent" })
    }

    // MARK: - bus flapping

    func testBusFlappingRuleFires() {
        let events: [TelemetryEvent] = (0..<5).map { i in
            ev(.busRecovered, level: .notice, actor: .robot,
               seq: UInt64(i + 1), secondsFromBase: Double(i) * 10,
               payload: ["prior_consecutive": AnyCodable(2)])
        }
        let a = SessionAnalyzer.analyze(events: events)
        let insights = HarnessInsights.compute(analysis: a, events: events)
        XCTAssertTrue(insights.contains { $0.ruleID == "bus.flapping" })
    }

    // MARK: - Kind 정의 검증 — 21 개 모두 분명한 kind 존재

    func testAllPreviouslyMissingKindsExist() {
        // 정의 자체만 검증 — 발화 site 추가는 별도. 컴파일 통과면 OK.
        let kinds: [TelemetryKind] = [
            .connectReconnectStart, .connectReconnectAttempt, .connectEndpointSwitch,
            .busRecovered, .busEStopRecover,
            .imuStale, .imuUnavailable, .imuRecovered, .imuScaleChanged,
            .walkLabPresetApplied, .walkLabConfigChange, .walkLabOnboardAck,
            .pilotModeChanged, .pilotEStop,
            .claudeResponseReceived, .claudeError,
            .motionLoad, .motionStepAdded, .motionStepRemoved,
            .errorException, .telemetrySkip
        ]
        XCTAssertEqual(kinds.count, 21)
        XCTAssertEqual(Set(kinds.map(\.rawValue)).count, 21, "모든 kind 가 고유한 rawValue")
    }

    // MARK: - 진단 payload — bus.read_fail 의 joint 첨부 검증

    func testBusReadFailWithJointPayloadEncodesAndDecodes() throws {
        let event = ev(.busReadFail, level: .warn, actor: .robot,
                       seq: 1, secondsFromBase: 0,
                       payload: [
                            "consecutive": AnyCodable(3),
                            "op": AnyCodable("readState"),
                            "joint": AnyCodable("HeadPan"),
                            "error_len": AnyCodable(20),
                            "error_hash": AnyCodable("abcd1234")
                       ])
        let enc = JSONEncoder()
        let data = try enc.encode(event)
        let dec = try JSONDecoder().decode(TelemetryEvent.self, from: data)
        XCTAssertEqual(dec.d.raw["joint"]?.value as? String, "HeadPan")
        XCTAssertEqual(dec.d.raw["op"]?.value as? String, "readState")
    }

    // MARK: - Claude error/response telemetry payload 안전 — PII 없음

    func testClaudeResponsePayloadHasNoBody() throws {
        // 정상 호출 시 payload: tool, needs_confirmation, is_refuse, turn — 본문 X.
        let event = ev(.claudeResponseReceived, level: .info, actor: .claude,
                       seq: 1, secondsFromBase: 0,
                       payload: [
                            "tool": AnyCodable("emergencyStop"),
                            "needs_confirmation": AnyCodable(true),
                            "is_refuse": AnyCodable(false),
                            "turn": AnyCodable(3)
                       ])
        let json = try JSONEncoder().encode(event)
        let s = String(data: json, encoding: .utf8)!
        XCTAssertFalse(s.contains("speak"), "speak 본문이 들어가면 PII 누출")
        XCTAssertTrue(s.contains("\"tool\""))
        XCTAssertTrue(s.contains("\"turn\""))
    }

    // MARK: - WalkLab preset_applied + config_change 통합

    func testWalkLabPresetAndConfigEventsAnalyzable() {
        let events: [TelemetryEvent] = [
            ev(.walkLabPresetApplied, level: .info, actor: .user, seq: 1, secondsFromBase: 0,
               payload: ["preset": AnyCodable("normalWalk"),
                         "stride_mm": AnyCodable(40.0),
                         "balance_gain": AnyCodable(0.8)]),
            ev(.walkLabConfigChange, level: .info, actor: .user, seq: 2, secondsFromBase: 1,
               payload: ["field": AnyCodable("enableBalanceCorrection"),
                         "value": AnyCodable(true),
                         "is_walking": AnyCodable(false)]),
            ev(.walkLabStart, level: .notice, actor: .user, seq: 3, secondsFromBase: 5,
               payload: ["preset": AnyCodable("normalWalk")]),
            ev(.walkLabStop, level: .notice, actor: .user, seq: 4, secondsFromBase: 60,
               payload: ["duration_s": AnyCodable(55.0)]),
        ]
        let a = SessionAnalyzer.analyze(events: events)
        // namespace 카운트에 walklab 가 잡혀야 함.
        let walklab = a.summary.namespaceCounts.first(where: { $0.namespace == "walklab" })
        XCTAssertNotNil(walklab)
        XCTAssertEqual(walklab?.count, 4, "preset_applied + config_change + start + stop = 4")
    }

    // MARK: - JSON scrub 가 새 hook payload 도 안전하게 처리

    func testJSONScrubAllowsKnownKeysIncludingNewOnes() {
        let raw: [String: AnyCodable] = [
            "preset": AnyCodable("normalWalk"),
            "stride_mm": AnyCodable(40.0),
            "balance_gain": AnyCodable(0.8),
            "field": AnyCodable("enableBalanceCorrection"),
            "value": AnyCodable(true),
            "is_walking": AnyCodable(false),
            "from_state": AnyCodable("unavailable"),
            "prior_failures": AnyCodable(3),
            "prior_consecutive": AnyCodable(2),
            "stale_for_s": AnyCodable(5.5),
            "from": AnyCodable("looksValid16Bit"),
            "to": AnyCodable("outOfRange"),
            "accelz_mag_avg": AnyCodable(250.0),
            "consecutive_failures": AnyCodable(4),
            // 알 수 없는 키 — scrub 대상.
            "user_secret_text": AnyCodable("very-private")
        ]
        let scrubbed = HarnessRedaction.scrubPayload(raw)
        // safe 키 통과 확인 (일부).
        XCTAssertEqual(scrubbed["preset"]?.value as? String, "normalWalk")
        XCTAssertEqual(scrubbed["stride_mm"]?.value as? Double, 40.0)
        // 알 수 없는 String 키는 len/hash 로.
        XCTAssertNil(scrubbed["user_secret_text"], "원본 키 사라져야 함")
        XCTAssertNotNil(scrubbed["user_secret_text_len"])
        XCTAssertNotNil(scrubbed["user_secret_text_hash"])
    }
}
