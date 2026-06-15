import Foundation
import XCTest
@testable import DarwinForgeUI

/// SSHConnectionDiagnostics (2026-06-02) — SSH 연결/제어 진단 분석기 검증.
///
/// # 비유
/// 콜센터 일일 리포트 검수 — 총 통화/대기시간/끊김 사유/최장 통화가 집계대로
/// 나오는지 확인. payload 는 실제 RemoteShell 이 쓰는 SSHDiagnostics 빌더로 생성해
/// 필드 이름 drift 를 원천 차단한다.
final class SSHConnectionDiagnosticsTests: XCTestCase {

    private func ev(_ kind: TelemetryKind,
                    level: TelemetryLevel = .info,
                    actor: TelemetryActor = .system,
                    seq: UInt64 = 1,
                    secondsFromBase: Double = 0,
                    base: Date = Date(timeIntervalSince1970: 1_716_000_000),
                    payload: [String: AnyCodable] = [:]) -> TelemetryEvent {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wall = f.string(from: base.addingTimeInterval(secondsFromBase))
        return TelemetryEvent(
            session: "TEST", seq: seq,
            wall: wall, mono: UInt64(secondsFromBase * 1e9),
            kind: kind, level: level, actor: actor,
            data: TelemetryPayload(payload), context: nil)
    }

    // MARK: - Empty

    func testEmptyEventsProduceEmptyReport() {
        let r = SSHConnectionDiagnostics.analyze(events: [])
        XCTAssertTrue(r.isEmpty)
        XCTAssertNil(r.successRate)
        XCTAssertNil(r.latency)
        XCTAssertTrue(r.slowest.isEmpty)
    }

    func testIrrelevantEventsStayEmpty() {
        let r = SSHConnectionDiagnostics.analyze(events: [
            ev(.appLaunch, seq: 1), ev(.heartbeat, seq: 2),
        ])
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - 종합 세션

    /// sent×4, responded(ok×2, nonzero×1), error(timeout×1), connect 라이프사이클.
    private func sampleSession() -> [TelemetryEvent] {
        [
            ev(.connectAttempt, seq: 1, secondsFromBase: 0),
            ev(.connectSuccess, level: .notice, seq: 2, secondsFromBase: 1),

            // 1) telemetry poll — ok, 30ms
            ev(.remoteCommandSent, actor: .user, seq: 3, secondsFromBase: 2,
               payload: SSHDiagnostics.sentData(command: "cat /tmp/df-walklab-telemetry", channel: "ssh")),
            ev(.remoteCommandResponded, seq: 4, secondsFromBase: 2.1,
               payload: SSHDiagnostics.respondedData(command: "cat /tmp/df-walklab-telemetry",
                                                     channel: "ssh", exitCode: 0,
                                                     elapsedMs: 30, resultLen: 50)),
            // 2) walk — ok, 80ms
            ev(.remoteCommandSent, actor: .user, seq: 5, secondsFromBase: 3,
               payload: SSHDiagnostics.sentData(command: "printf '%s\\n' 'id 1 28 0 0' > /tmp/df-walklab-cmd", channel: "ssh")),
            ev(.remoteCommandResponded, seq: 6, secondsFromBase: 3.1,
               payload: SSHDiagnostics.respondedData(command: "printf '%s\\n' 'id 1 28 0 0' > /tmp/df-walklab-cmd",
                                                     channel: "ssh", exitCode: 0,
                                                     elapsedMs: 80, resultLen: 10)),
            // 3) walk — 로봇 거부(nonzero exit), 120ms
            ev(.remoteCommandSent, actor: .user, seq: 7, secondsFromBase: 4,
               payload: SSHDiagnostics.sentData(command: "printf '%s\\n' 'id 1 99 0 0' > /tmp/df-walklab-cmd", channel: "ssh")),
            ev(.remoteCommandResponded, level: .warn, seq: 8, secondsFromBase: 4.1,
               payload: SSHDiagnostics.respondedData(command: "printf '%s\\n' 'id 1 99 0 0' > /tmp/df-walklab-cmd",
                                                     channel: "ssh", exitCode: 1,
                                                     elapsedMs: 120, resultLen: 6)),
            // 4) stop — 실패(timeout), 4000ms
            ev(.remoteCommandSent, actor: .user, seq: 9, secondsFromBase: 5,
               payload: SSHDiagnostics.sentData(command: "touch /tmp/df-walklab-estop", channel: "ssh")),
            ev(.remoteCommandError, level: .warn, seq: 10, secondsFromBase: 9,
               payload: SSHDiagnostics.errorData(command: "touch /tmp/df-walklab-estop",
                                                 channel: "ssh", error: SSHShell.SSHError.timeout,
                                                 elapsedMs: 4000, multiplex: true)),

            ev(.remoteChannelChanged, seq: 11, secondsFromBase: 9.1,
               payload: ["from": AnyCodable("ssh"), "to": AnyCodable("unavailable")]),
        ]
    }

    func testCountsAndSuccessRate() {
        let r = SSHConnectionDiagnostics.analyze(events: sampleSession())
        XCTAssertEqual(r.commandsSent, 4)
        XCTAssertEqual(r.commandsResponded, 3)
        XCTAssertEqual(r.commandsErrored, 1)
        XCTAssertEqual(r.nonzeroExits, 1)
        XCTAssertEqual(r.connectAttempts, 1)
        XCTAssertEqual(r.connectSuccesses, 1)
        XCTAssertEqual(r.channelTransitions, 1)
        // ok=2, denom = responded(3)+errored(1)=4 → 0.5
        XCTAssertEqual(r.successRate ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertFalse(r.isEmpty)
    }

    func testLatencyStatsFromRespondedOnly() {
        let r = SSHConnectionDiagnostics.analyze(events: sampleSession())
        guard let l = r.latency else { return XCTFail("latency nil") }
        // responded elapsed = [30, 80, 120] (error 의 4000 은 latency 에 미포함).
        XCTAssertEqual(l.count, 3)
        XCTAssertEqual(l.max, 120, accuracy: 0.001)
        XCTAssertEqual(l.mean, (30 + 80 + 120) / 3.0, accuracy: 0.001)
    }

    func testErrorAndCategoryBreakdown() {
        let r = SSHConnectionDiagnostics.analyze(events: sampleSession())
        XCTAssertEqual(r.errorBreakdown.first?.key, "timeout")
        XCTAssertEqual(r.errorBreakdown.first?.count, 1)

        // 카테고리 송신: telemetry×1, walk×2, stop×1 → walk 가 최다.
        let cats = Dictionary(uniqueKeysWithValues: r.categoryBreakdown.map { ($0.key, $0.count) })
        XCTAssertEqual(cats["walk"], 2)
        XCTAssertEqual(cats["telemetry"], 1)
        XCTAssertEqual(cats["stop"], 1)
        XCTAssertEqual(r.categoryBreakdown.first?.key, "walk")  // 내림차순 정렬.
    }

    func testSlowestOrderedByElapsedDescending() {
        let r = SSHConnectionDiagnostics.analyze(events: sampleSession())
        XCTAssertEqual(r.slowest.first?.elapsedMs, 4000)        // timeout 이 가장 느림.
        XCTAssertEqual(r.slowest.first?.outcome, "timeout")
        // 내림차순 단조.
        let elapsed = r.slowest.map { $0.elapsedMs }
        XCTAssertEqual(elapsed, elapsed.sorted(by: >))
        // nonzero exit 결과 표기.
        XCTAssertTrue(r.slowest.contains { $0.outcome == "nonzero(1)" })
    }

    // MARK: - percentile 헬퍼

    func testPercentileNearestRank() {
        let sorted: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        XCTAssertEqual(SSHConnectionDiagnostics.percentile(sorted, 0.50), 50, accuracy: 0.001)
        XCTAssertEqual(SSHConnectionDiagnostics.percentile(sorted, 0.95), 100, accuracy: 0.001)
        XCTAssertEqual(SSHConnectionDiagnostics.percentile([42], 0.95), 42, accuracy: 0.001)
    }

    // MARK: - markdown

    func testMarkdownContainsKeySignals() {
        let md = SSHConnectionDiagnostics.markdown(SSHConnectionDiagnostics.analyze(events: sampleSession()))
        XCTAssertTrue(md.contains("SSH 연결·조종 진단"))
        XCTAssertTrue(md.contains("timeout"))
        XCTAssertTrue(md.contains("walk"))
        XCTAssertTrue(md.contains("성공률"))
    }

    func testMarkdownEmptyStateIsExplicit() {
        let md = SSHConnectionDiagnostics.markdown(SSHConnectionDiagnostics.analyze(events: []))
        XCTAssertTrue(md.contains("SSH 제어/연결 이벤트가 없습니다"))
    }
}
