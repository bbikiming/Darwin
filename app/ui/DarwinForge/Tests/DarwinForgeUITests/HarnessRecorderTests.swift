import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.12.0 (2026-05-20) — Telemetry Harness Tests.**
///
/// 검증 범위:
///  - Recorder 가 JSONL 1-line-per-event 로 디스크에 쓴다.
///  - meta.json 이 event count / size / connect count / error count 를 누적한다.
///  - finalize 후 meta.ended 가 채워진다.
///  - schema version / session id / seq 가 모두 보존된다.
///  - JSON round-trip (encode → decode) 이 같은 값을 복원한다.
///  - PII redaction — 네트워크 IP 마지막 옥텟이 마스크되는지 (context helper).
///
/// **Why disk + actor?** Recorder 가 background actor → async API. 실제 디스크 IO 가
/// 발생하므로 임시 디렉토리에 격리된 세션을 만들고, 검증 후 청소.
final class HarnessRecorderTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessRecorderTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    private func makeMeta(id: String = UUID().uuidString) -> TelemetrySessionMeta {
        TelemetrySessionMeta(
            id: id,
            started: ISO8601DateFormatter().string(from: Date()),
            appVersion: "0.0.0-test",
            appBuild: "0",
            os: "test-os",
            device: "test-device"
        )
    }

    // MARK: - 기본 write + decode

    func testWritesOneLinePerEvent() async throws {
        let meta = makeMeta()
        let recorder = try TelemetryRecorder(directory: tempDir, meta: meta)

        for i in 0..<3 {
            let ev = TelemetryEvent(
                session: meta.id, seq: 0,
                wall: "2026-05-20T00:00:00.000Z",
                mono: UInt64(i),
                kind: .connectAttempt,
                level: .info, actor: .user,
                data: TelemetryPayload(["i": AnyCodable(i)])
            )
            await recorder.enqueue(ev)
        }
        await recorder.flush()

        let url = tempDir.appendingPathComponent("events.jsonl")
        let raw = try Data(contentsOf: url)
        let lines = String(decoding: raw, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3, "한 줄당 한 이벤트")

        let decoder = JSONDecoder()
        let decoded = try lines.map { try decoder.decode(TelemetryEvent.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded.map { $0.k.rawValue }, Array(repeating: "connection.attempt", count: 3))
        // seq 1..3 가 자동 부여돼야 한다.
        XCTAssertEqual(decoded.map { $0.i }, [1, 2, 3])
        for d in decoded {
            XCTAssertEqual(d.s, meta.id)
            XCTAssertEqual(d.v, TelemetryRecorder.schemaVersion)
        }
    }

    // MARK: - meta counters

    func testMetaCountersAccumulate() async throws {
        let recorder = try TelemetryRecorder(directory: tempDir, meta: makeMeta())

        await recorder.enqueue(TelemetryEvent(
            session: "x", seq: 0, wall: "t", mono: 0,
            kind: .connectSuccess, level: .notice, actor: .system))
        await recorder.enqueue(TelemetryEvent(
            session: "x", seq: 0, wall: "t", mono: 0,
            kind: .busReadFail, level: .error, actor: .robot))
        await recorder.enqueue(TelemetryEvent(
            session: "x", seq: 0, wall: "t", mono: 0,
            kind: .heartbeat, level: .trace, actor: .system))
        await recorder.flush()

        let snapshot = await recorder.meta
        XCTAssertEqual(snapshot.eventCount, 3)
        XCTAssertEqual(snapshot.connectCount, 1)
        XCTAssertEqual(snapshot.errorCount, 1, "busReadFail at .error level counts as error")
        XCTAssertGreaterThan(snapshot.sizeBytes, 0)
    }

    /// 사이클 188: cycle 181 + 182 신규 error-level kind 도 errorCount 에 반영.
    /// regression guard — 향후 신규 error kinds 추가 시 본 테스트 깨지면 switch case 갱신.
    func testNewErrorKindsBumpErrorCount() async throws {
        let recorder = try TelemetryRecorder(directory: tempDir, meta: makeMeta())

        // cycle 181 — claude plan dispatcher fail.
        await recorder.enqueue(TelemetryEvent(
            session: "x", seq: 0, wall: "t", mono: 0,
            kind: .claudePlanExecutionFailed, level: .error, actor: .system))
        // cycle 182 — remote SSH/SMB command error.
        await recorder.enqueue(TelemetryEvent(
            session: "x", seq: 0, wall: "t", mono: 0,
            kind: .remoteCommandError, level: .error, actor: .system))
        // 추가 non-error level 같은 kind 는 카운트 안 함 (lv != .error).
        await recorder.enqueue(TelemetryEvent(
            session: "x", seq: 0, wall: "t", mono: 0,
            kind: .claudePlanExecutionFailed, level: .warn, actor: .system))
        // 비교용 — info level 의 신규 kind 는 카운트 안 함.
        await recorder.enqueue(TelemetryEvent(
            session: "x", seq: 0, wall: "t", mono: 0,
            kind: .claudePlanApproved, level: .info, actor: .user))
        await recorder.flush()

        let snapshot = await recorder.meta
        XCTAssertEqual(snapshot.eventCount, 4)
        XCTAssertEqual(
            snapshot.errorCount, 2,
            "cycle 181 claudePlanExecutionFailed + cycle 182 remoteCommandError " +
            "둘 다 .error level → errorCount += 2. .warn / .info 는 비카운트."
        )
    }

    /// 사이클 188: pilotEStop 은 의도적으로 level=.warn (사용자 안전 액션, 시스템 오류 X).
    /// errorCount 에 반영 안 됨 — 분석 시 별도 kind 카운트 가능.
    func testPilotEStopDoesNotBumpErrorCount() async throws {
        let recorder = try TelemetryRecorder(directory: tempDir, meta: makeMeta())
        await recorder.enqueue(TelemetryEvent(
            session: "x", seq: 0, wall: "t", mono: 0,
            kind: .pilotEStop, level: .warn, actor: .user))
        await recorder.flush()
        let snapshot = await recorder.meta
        XCTAssertEqual(snapshot.errorCount, 0,
                       "pilotEStop@.warn 은 의도적 — errorCount 비반영")
    }

    /// 사이클 214: pilotVoiceError 는 .error level — errorCount 반영 필수.
    /// adapter telemetry (cycle 213) 추가 후 errorCountedKinds 에 포함.
    func testPilotVoiceErrorBumpsErrorCount() async throws {
        let recorder = try TelemetryRecorder(directory: tempDir, meta: makeMeta())
        await recorder.enqueue(TelemetryEvent(
            session: "x", seq: 0, wall: "t", mono: 0,
            kind: .pilotVoiceError, level: .error, actor: .system))
        await recorder.flush()
        let snapshot = await recorder.meta
        XCTAssertEqual(snapshot.errorCount, 1,
                       "pilotVoiceError@.error → errorCount += 1")
    }

    // MARK: - finalize

    func testFinalizeSetsEndedTimestamp() async throws {
        let recorder = try TelemetryRecorder(directory: tempDir, meta: makeMeta())
        await recorder.enqueue(TelemetryEvent(
            session: "x", seq: 0, wall: "t", mono: 0,
            kind: .appLaunch, level: .info, actor: .system))
        let endIso = "2026-05-20T22:00:00.000Z"
        await recorder.finalize(endIso: endIso)
        let snapshot = await recorder.meta
        XCTAssertEqual(snapshot.ended, endIso)

        // 디스크 meta.json 도 동일해야 한다.
        let metaURL = tempDir.appendingPathComponent("meta.json")
        let data = try Data(contentsOf: metaURL)
        let onDisk = try JSONDecoder().decode(TelemetrySessionMeta.self, from: data)
        XCTAssertEqual(onDisk.ended, endIso)
    }

    // MARK: - schema round trip with all fields

    func testEventRoundTripPreservesAllFields() throws {
        let ctx = TelemetryContext(
            connection: .connected, endpoint: "net:10.0.0.x:5530",
            section: "walkLab", batteryV: 11.4, rttMs: 12.4, imuStale: false
        )
        let event = TelemetryEvent(
            schema: 1, session: "SID", seq: 42,
            wall: "2026-05-20T12:00:00.500Z", mono: 1_000_000_000,
            kind: .walkLabStart, level: .notice, actor: .user,
            data: TelemetryPayload([
                "preset": AnyCodable("smooth-default"),
                "advanced": AnyCodable(false),
                "duration_ms": AnyCodable(942)
            ]),
            context: ctx
        )
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        let bytes = try enc.encode(event)
        let back = try dec.decode(TelemetryEvent.self, from: bytes)
        XCTAssertEqual(back, event)
        XCTAssertEqual(back.k.namespace, "walklab")
    }
}

// MARK: - PII redaction (HarnessRedaction)
//
// **v1.12.2 (Codex P3 fix)** — 종전 테스트는 production 함수를 mirror 한 helper 를 호출.
// 그래서 production 가 leak 해도 테스트는 통과. 이제는 직접 `HarnessRedaction` API 호출.

@MainActor
final class HarnessRedactionTests: XCTestCase {
    func testIPv4LastOctetMasked() throws {
        XCTAssertEqual(HarnessRedaction.host("10.0.0.42"), "10.0.0.x")
        XCTAssertEqual(HarnessRedaction.host("192.168.1.5"), "192.168.1.x")
    }

    func testMDNSHostnameStripsAllButFirstLabel() throws {
        // 종전 spec: 그대로 두기. 변경된 spec: leftmost label 만 유지.
        XCTAssertEqual(HarnessRedaction.host("op2.local"), "op2.x")
        XCTAssertEqual(HarnessRedaction.host("robot.lab.example.com"), "robot.x")
    }

    func testIPv6LastHextetMasked() throws {
        XCTAssertEqual(HarnessRedaction.host("2001:db8::1"), "2001:db8::x")
    }

    func testUsbNameStripsSerialSuffix() throws {
        // "/dev/tty.usbserial-A50285BI" → lastPath = "tty.usbserial-A50285BI" → 마지막 - 뒤 제거.
        XCTAssertEqual(HarnessRedaction.usbName("tty.usbserial-A50285BI"), "tty.usbserial-X")
        XCTAssertEqual(HarnessRedaction.usbName("tty.usbmodem14201"), "tty.usbmodemX")
    }

    func testEndpointBuildsRedactedString() throws {
        let usb = HarnessRedaction.endpoint(.usbSerial(path: "/dev/tty.usbserial-A50285BI"))
        XCTAssertEqual(usb, "usb:tty.usbserial-X")
        let net = HarnessRedaction.endpoint(.network(host: "10.0.0.42", port: 5530))
        XCTAssertEqual(net, "net:10.0.0.x:5530")
    }

    func testShortHashStable() throws {
        let a = Harness.shortHash("hello")
        let b = Harness.shortHash("hello")
        XCTAssertEqual(a, b, "결정론적")
        XCTAssertNotEqual(Harness.shortHash("hello"), Harness.shortHash("world"))
        XCTAssertEqual(a.count, 8, "8 자리 hex prefix")
    }
}
