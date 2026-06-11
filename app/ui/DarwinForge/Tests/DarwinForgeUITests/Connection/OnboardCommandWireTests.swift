import XCTest
@testable import DarwinForgeUI

/// **W1/O1 — 온보드 명령 채널 순수 와이어·큐 로직** (cockpit-latency-hardening §4/§5.4).
final class OnboardCommandWireTests: XCTestCase {

    // MARK: - SendPolicy

    func testSendPolicy_coalesceKey() {
        XCTAssertEqual(SendPolicy.latestWins(key: "tuning").coalesceKey, "tuning")
        XCTAssertNil(SendPolicy.ordered.coalesceKey)
    }

    // MARK: - CoalescingQueue

    func testQueue_latestWins_replacesSameKey() {
        var q = CoalescingQueue()
        q.enqueue(OnboardCommand(line: "A", cmdId: "1", policy: .latestWins(key: "tuning")))
        q.enqueue(OnboardCommand(line: "B", cmdId: "2", policy: .latestWins(key: "tuning")))
        XCTAssertEqual(q.count, 1)              // coalesced
        XCTAssertEqual(q.dequeue()?.line, "B")  // latest wins
        XCTAssertTrue(q.isEmpty)
    }

    func testQueue_differentKeys_bothKept_orderPreserved() {
        var q = CoalescingQueue()
        q.enqueue(OnboardCommand(line: "walk", cmdId: "1", policy: .latestWins(key: "walk")))
        q.enqueue(OnboardCommand(line: "head", cmdId: "2", policy: .latestWins(key: "head")))
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q.dequeue()?.line, "walk")
        XCTAssertEqual(q.dequeue()?.line, "head")
    }

    func testQueue_ordered_neverCoalesces() {
        var q = CoalescingQueue()
        q.enqueue(OnboardCommand(line: "stop1", cmdId: "1", policy: .ordered))
        q.enqueue(OnboardCommand(line: "stop2", cmdId: "2", policy: .ordered))
        XCTAssertEqual(q.count, 2)   // order-preserving, no merge (estop/모드전환).
        XCTAssertEqual(q.dequeue()?.line, "stop1")
        XCTAssertEqual(q.dequeue()?.line, "stop2")
    }

    func testQueue_orderedNotCoalescedByLatestWins() {
        var q = CoalescingQueue()
        q.enqueue(OnboardCommand(line: "t1", cmdId: "1", policy: .latestWins(key: "k")))
        q.enqueue(OnboardCommand(line: "ord", cmdId: "2", policy: .ordered))
        q.enqueue(OnboardCommand(line: "t2", cmdId: "3", policy: .latestWins(key: "k")))
        // ordered 는 합쳐지지 않고, latestWins k 는 t1→t2 로 대체(t1 제거) 후 말미 추가.
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q.dequeue()?.line, "ord")
        XCTAssertEqual(q.dequeue()?.line, "t2")
    }

    // MARK: - E-STOP datagram

    func testEstopDatagram_payloadAndValidate() {
        let p = OnboardEstopDatagram.payload(token: "TOK", unixMillis: 1748736000123)
        XCTAssertEqual(p, "DF-ESTOP v1 TOK 1748736000123")
        XCTAssertTrue(OnboardEstopDatagram.validate(p, expectedToken: "TOK"))
        XCTAssertFalse(OnboardEstopDatagram.validate(p, expectedToken: "WRONG"))
        XCTAssertFalse(OnboardEstopDatagram.validate("garbage", expectedToken: "TOK"))
    }

    func testEstopDatagram_burstOffsets() {
        XCTAssertEqual(OnboardEstopDatagram.burstOffsetsMs, [0, 50, 100])
    }

    // MARK: - Command datagram

    func testCommandDatagram_payload() {
        let p = OnboardCommandDatagram.payload(token: "TOK", seq: 42, line: "c1 1 28 0 0 600 40")
        XCTAssertEqual(p, "DFCMD TOK 42 c1 1 28 0 0 600 40")
    }

    // MARK: - Persistent SSH sentinel

    func testSentinel_lineAndParse_roundTrip() {
        let line = OnboardChannelSentinel.line(id: 7, exit: 0)
        XCTAssertEqual(line, "__DF_DONE_7_0__")
        let parsed = OnboardChannelSentinel.parse(line)
        XCTAssertEqual(parsed?.id, 7)
        XCTAssertEqual(parsed?.exit, 0)
    }

    func testSentinel_parseNonZeroExit() {
        let parsed = OnboardChannelSentinel.parse("__DF_DONE_123_1__")
        XCTAssertEqual(parsed?.id, 123)
        XCTAssertEqual(parsed?.exit, 1)
    }

    func testSentinel_parseRejectsNonSentinel() {
        XCTAssertNil(OnboardChannelSentinel.parse("hello world"))
        XCTAssertNil(OnboardChannelSentinel.parse("__DF_DONE_x_y__"))
        XCTAssertNil(OnboardChannelSentinel.parse(""))
    }

    func testSentinel_wrapEmitsSentinelWithExitCode() {
        let wrapped = OnboardChannelSentinel.wrap(command: "echo hi", id: 9)
        XCTAssertTrue(wrapped.hasPrefix("echo hi; printf '__DF_DONE_%s_%s__\\n' 9 "))
        XCTAssertTrue(wrapped.contains("\"$?\""))
    }
}
