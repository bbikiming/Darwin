import Foundation
import XCTest
@testable import DarwinForgeUI

/// HarnessBaseline 개별 metric/count delta 검증.
///
/// HarnessBaselineTests.swift 에서 분리 (800줄 상한 유지).
/// verdict 로직은 HarnessBaselineTests 에, delta 수치 검증은 여기에.
final class HarnessBaselineDeltaTests: XCTestCase {

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
        rttMs: Double?,
        batteryV: Double? = nil,
        imuStale: Bool? = nil,
        seq: UInt64 = 1,
        secondsFromBase: Double = 0
    ) -> TelemetryEvent {
        let ctx = TelemetryContext(
            batteryV: batteryV,
            rttMs: rttMs,
            imuStale: imuStale
        )
        return ev(
            .heartbeat, level: .trace, actor: .system,
            seq: seq, secondsFromBase: secondsFromBase,
            context: ctx
        )
    }

    private func analyzed(
        id: String,
        events: [TelemetryEvent]
    ) -> (id: String, analysis: SessionAnalysis) {
        (id: id, analysis: SessionAnalyzer.analyze(events: events))
    }

    private func emptySession() -> [TelemetryEvent] {
        [ev(.heartbeat, level: .trace, seq: 0, secondsFromBase: 0)]
    }

    private func rttSession(rttMs: Double, count: Int = 20) -> [TelemetryEvent] {
        (0..<count).map { i in
            heartbeat(rttMs: rttMs, seq: UInt64(i), secondsFromBase: Double(i))
        }
    }

    // MARK: - Metric delta percent nil when baseline is zero

    func testMetricDeltaPercentNilWhenBaselineIsZero() throws {
        let baselineEvents = rttSession(rttMs: 0.0)
        let currentEvents = rttSession(rttMs: 50.0)

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let rttP95 = try XCTUnwrap(diff.metrics.first { $0.label == "RTT p95 (ms)" })
        XCTAssertNotNil(rttP95.deltaAbsolute,
                        "deltaAbsolute should exist when both values present")
        XCTAssertNil(rttP95.deltaPercent,
                     "deltaPercent should be nil when baseline is 0")
    }

    // MARK: - One nil metric

    func testOneNilMetricDeltasAreNil() throws {
        let baselineEvents = rttSession(rttMs: 100.0)
        let currentEvents = [ev(.appLaunch, level: .notice, seq: 0)]

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let rttP95 = try XCTUnwrap(diff.metrics.first { $0.label == "RTT p95 (ms)" })
        XCTAssertNotNil(rttP95.baseline, "Baseline RTT should not be nil")
        XCTAssertNil(rttP95.current, "Current RTT should be nil")
        XCTAssertNil(rttP95.deltaAbsolute, "deltaAbsolute nil when one side is nil")
        XCTAssertNil(rttP95.deltaPercent, "deltaPercent nil when one side is nil")
    }

    // MARK: - Count delta lowerIsBetter flags

    func testCountDeltaLowerIsBetterFlags() throws {
        let events = emptySession()
        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )

        let expectations: [(String, Bool)] = [
            ("에러", true), ("경고", true),
            ("Bus 읽기 실패", true), ("Bus 쓰기 실패", true),
            ("E-stop", true), ("보행 시작", false),
            ("보행 비상 정지", true), ("보행 차단", true),
        ]
        for (label, expected) in expectations {
            let found = try XCTUnwrap(diff.counts.first { $0.label == label },
                                      "Missing count: \(label)")
            XCTAssertEqual(found.lowerIsBetter, expected,
                           "\(label) lowerIsBetter should be \(expected)")
        }
    }

    // MARK: - Warn count delta

    func testWarnCountDelta() throws {
        let baselineEvents = [
            ev(.busReadFail, level: .warn, seq: 0, secondsFromBase: 0),
            ev(.busReadFail, level: .warn, seq: 1, secondsFromBase: 1),
        ]
        let currentEvents = [
            ev(.busReadFail, level: .warn, seq: 0, secondsFromBase: 0),
        ]

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let warnCount = try XCTUnwrap(diff.counts.first { $0.label == "경고" })
        XCTAssertEqual(warnCount.baseline, 2)
        XCTAssertEqual(warnCount.current, 1)
        XCTAssertEqual(warnCount.delta, -1)
    }

    // MARK: - Bus read/write fail deltas

    func testBusReadFailCountDelta() throws {
        let baselineEvents = [
            ev(.busReadFail, level: .error, seq: 0, secondsFromBase: 0),
        ]
        let currentEvents = [
            ev(.busReadFail, level: .error, seq: 0, secondsFromBase: 0),
            ev(.busReadFail, level: .error, seq: 1, secondsFromBase: 1),
            ev(.busReadFail, level: .error, seq: 2, secondsFromBase: 2),
        ]

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let busRead = try XCTUnwrap(diff.counts.first { $0.label == "Bus 읽기 실패" })
        XCTAssertEqual(busRead.baseline, 1)
        XCTAssertEqual(busRead.current, 3)
        XCTAssertEqual(busRead.delta, 2)
    }

    func testBusWriteFailCountDelta() throws {
        let baselineEvents = [
            ev(.busWriteFail, level: .error, seq: 0, secondsFromBase: 0),
            ev(.busWriteFail, level: .error, seq: 1, secondsFromBase: 1),
        ]
        let currentEvents = emptySession()

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let busWrite = try XCTUnwrap(diff.counts.first { $0.label == "Bus 쓰기 실패" })
        XCTAssertEqual(busWrite.baseline, 2)
        XCTAssertEqual(busWrite.current, 0)
        XCTAssertEqual(busWrite.delta, -2)
    }

    // MARK: - Walk lab start delta

    func testWalkLabStartCountDelta() throws {
        let baselineEvents = [
            ev(.walkLabStart, level: .info, seq: 0, secondsFromBase: 0),
        ]
        let currentEvents = [
            ev(.walkLabStart, level: .info, seq: 0, secondsFromBase: 0),
            ev(.walkLabStart, level: .info, seq: 1, secondsFromBase: 1),
            ev(.walkLabStart, level: .info, seq: 2, secondsFromBase: 2),
        ]

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let walkStart = try XCTUnwrap(diff.counts.first { $0.label == "보행 시작" })
        XCTAssertEqual(walkStart.delta, 2)
    }

    // MARK: - Battery metric delta

    func testBatteryMetricDelta() throws {
        let baselineEvents = (0..<20).map { i in
            heartbeat(rttMs: nil, batteryV: 11.5, seq: UInt64(i),
                      secondsFromBase: Double(i))
        }
        let currentEvents = (0..<20).map { i in
            heartbeat(rttMs: nil, batteryV: 12.0, seq: UInt64(i),
                      secondsFromBase: Double(i))
        }

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let battery = try XCTUnwrap(diff.metrics.first { $0.label == "배터리 min (V)" })
        XCTAssertEqual(battery.deltaAbsolute!, 0.5, accuracy: 0.01)
        XCTAssertFalse(battery.lowerIsBetter)
    }

    // MARK: - IMU stale ratio delta

    func testImuStaleRatioDelta() throws {
        let baselineEvents = (0..<20).map { i -> TelemetryEvent in
            heartbeat(rttMs: nil, imuStale: i < 10, seq: UInt64(i),
                      secondsFromBase: Double(i))
        }
        let currentEvents = (0..<20).map { i -> TelemetryEvent in
            heartbeat(rttMs: nil, imuStale: i < 2, seq: UInt64(i),
                      secondsFromBase: Double(i))
        }

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let imu = try XCTUnwrap(diff.metrics.first { $0.label == "IMU stale ratio" })
        XCTAssertEqual(imu.baseline!, 0.5, accuracy: 0.01)
        XCTAssertEqual(imu.current!, 0.1, accuracy: 0.01)
        XCTAssertTrue(imu.lowerIsBetter)
        XCTAssertLessThan(imu.deltaAbsolute!, 0, "IMU stale ratio should decrease")
    }

    // MARK: - Connection success rate delta

    func testConnectionSuccessRateDelta() throws {
        let baselineEvents = [
            ev(.connectAttempt, seq: 0, secondsFromBase: 0),
            ev(.connectSuccess, level: .notice, seq: 1, secondsFromBase: 1),
            ev(.connectAttempt, seq: 2, secondsFromBase: 2),
            ev(.connectFailure, level: .error, seq: 3, secondsFromBase: 3),
            ev(.connectAttempt, seq: 4, secondsFromBase: 4),
            ev(.connectSuccess, level: .notice, seq: 5, secondsFromBase: 5),
            ev(.connectAttempt, seq: 6, secondsFromBase: 6),
            ev(.connectFailure, level: .error, seq: 7, secondsFromBase: 7),
        ]
        let currentEvents = [
            ev(.connectAttempt, seq: 0, secondsFromBase: 0),
            ev(.connectSuccess, level: .notice, seq: 1, secondsFromBase: 1),
            ev(.connectAttempt, seq: 2, secondsFromBase: 2),
            ev(.connectSuccess, level: .notice, seq: 3, secondsFromBase: 3),
            ev(.connectAttempt, seq: 4, secondsFromBase: 4),
            ev(.connectSuccess, level: .notice, seq: 5, secondsFromBase: 5),
            ev(.connectAttempt, seq: 6, secondsFromBase: 6),
            ev(.connectSuccess, level: .notice, seq: 7, secondsFromBase: 7),
        ]

        let diff = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: baselineEvents),
            current: analyzed(id: "c", events: currentEvents)
        )

        let conn = try XCTUnwrap(diff.metrics.first { $0.label == "연결 성공률" })
        XCTAssertEqual(conn.baseline!, 0.5, accuracy: 0.01)
        XCTAssertEqual(conn.current!, 1.0, accuracy: 0.01)
        XCTAssertEqual(conn.deltaAbsolute!, 0.5, accuracy: 0.01)
    }

    // MARK: - Equatable

    func testSessionDiffEquatable() {
        let events = emptySession()
        let diff1 = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )
        let diff2 = HarnessBaseline.compare(
            baseline: analyzed(id: "b", events: events),
            current: analyzed(id: "c", events: events)
        )
        XCTAssertEqual(diff1, diff2,
                       "Identical inputs should produce equal SessionDiff values")
    }
}
