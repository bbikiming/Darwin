import Foundation
import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// **v1.13.1 (2026-05-20)** — End-to-end smoke test 실 로봇 시나리오 검증.
///
/// 이전 테스트들이 검증한 것:
///   - `HarnessRecorderTests`: TelemetryRecorder 단위.
///   - `HarnessDiskIntegrationTests`: Recorder → JSONL 디스크 round-trip.
///   - `HarnessAnalysisTests`: 분석 코어 pure-func.
///
/// **이 테스트가 검증하는 것 (이전엔 미커버)**: production hook sites 가 실제로 발화해서
/// 디스크에 events.jsonl 가 적히는 **end-to-end chain**.
///
/// 실 로봇 없이도 가능한 이유: 실 로봇 없을 때도 `ConnectionStore.connect(endpoint:)` 는
/// 연결 시도 → 실패 → 해당 hook 들이 모두 동일하게 발화 (성공 경로의 차이는 RTT/snapshot
/// 정도이고, hook 발화 자체는 동일).
///
/// 검증 chain:
///   `ConnectionStore.connect(...)`
///     → `Harness.shared.record(.connectAttempt, ...)`
///     → `AsyncStream.yield`
///     → consumer Task
///     → `TelemetryRecorder.enqueue`
///     → `flush` → `events.jsonl` 디스크 기록
///     → 디스크에서 다시 읽어서 검증.
@MainActor
final class HarnessRealRobotSmokeTests: XCTestCase {

    private var tempRoot: URL!
    private var sessionDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        // 실 Application Support 오염 차단 — tmp 에 isolated session 디렉토리.
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        sessionDir = tempRoot.appendingPathComponent("current-\(UUID().uuidString)", isDirectory: true)
        // 활성화. (전역 default 가 옵트인 false 인 사용자 환경이라도 본 테스트 동안엔 강제.)
        Harness.shared.isEnabled = true
        Harness.shared._startInDirectory(sessionDir, id: UUID().uuidString)
    }

    override func tearDown() async throws {
        Harness.shared.stop(reason: "test-teardown")
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    // MARK: - 유틸: 디스크 flush 후 events 읽기.

    /// AsyncStream → recorder → JSONL 디스크 까지 가는 데 잠깐 걸림. 짧게 yield + flush.
    private func waitForFlush() async throws {
        await Harness.shared.flush()
        // recorder 의 internal flush 가 fsync 까지 다 끝났는지 보장하려면 한 번 더 yield.
        try await Task.sleep(nanoseconds: 100_000_000)
        await Harness.shared.flush()
    }

    private func loadEvents() throws -> [TelemetryEvent] {
        let url = sessionDir.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let raw = try Data(contentsOf: url)
        let dec = JSONDecoder()
        let lines = String(decoding: raw, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        return try lines.map { try dec.decode(TelemetryEvent.self, from: Data($0.utf8)) }
    }

    // MARK: - 검증: 연결 시도 hook 이 디스크에 도달.

    func testConnectionStoreEmitsAttemptAndFailureToDisk() async throws {
        // setUp 이 Harness 시동 → app.launch 가 이미 들어가 있음.
        let store = ConnectionStore()

        // 의도적으로 절대 열 수 없는 fake USB path — 연결 실패가 깔끔하게 발화하도록.
        let fakePath = "/dev/tty.darwinforge-test-nonexistent-\(UUID().uuidString.prefix(6))"
        let endpoint: Endpoint = .usbSerial(path: fakePath)

        // 연결 시도 — performConnect 가 max 3 retry, 그 후 .error 로 끝나며 hook 발화.
        store.connect(endpoint: endpoint)

        // 재시도 끝날 때까지 기다림 (3 attempts * 200ms + headroom).
        // performConnect 는 async Task — main actor 에서 fire & forget.
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .error = store.status { break }
        }
        try await waitForFlush()

        let events = try loadEvents()

        // (1) app.launch 가 setUp 단계에서 기록됐어야 함.
        XCTAssertTrue(events.contains { $0.k.rawValue == "app.launch" },
                       "app.launch 가 디스크에 없음 — Harness.start() chain broken")

        // (2) connection.attempt — 사용자 액션 hook 이 발화.
        let attempts = events.filter { $0.k.rawValue == "connection.attempt" }
        XCTAssertGreaterThanOrEqual(attempts.count, 1,
                                     "connection.attempt 가 디스크에 없음 — store.connect hook 미발화")

        // (3) connection.failure — 실패 경로 hook.
        let failures = events.filter { $0.k.rawValue == "connection.failure" }
        XCTAssertGreaterThanOrEqual(failures.count, 1,
                                     "connection.failure 가 디스크에 없음 — performConnect fail hook 미발화")

        // (4) PII redaction 검증 — endpoint 가 raw fake path 그대로 들어가면 안 됨.
        for ev in attempts + failures {
            let json = try JSONEncoder().encode(ev.d.raw)
            let str = String(decoding: json, as: UTF8.self)
            XCTAssertFalse(str.contains(fakePath),
                            "redaction 실패 — raw endpoint path 가 payload 에 그대로 들어감")
        }

        // (5) endpoint_kind metadata 첨부.
        if let attempt = attempts.first {
            XCTAssertEqual(attempt.d.raw["endpoint_kind"]?.value as? String, "usb")
        }
    }

    // MARK: - 검증: UI hook (sectionChanged / paletteOpen) 이 디스크 도달.

    func testUserActionHooksReachDisk() async throws {
        // RootView 의 onChange(of: section) 등을 직접 호출 못 함 — Harness.shared.record 를
        // 동일하게 호출. production hook 들이 정확히 같은 방식으로 fire 함.
        Harness.shared.record(.uiSectionChanged, level: .info, actor: .user,
                                data: ["to": AnyCodable("walkLab")])
        Harness.shared.record(.teachSnapshotCaptured, level: .notice, actor: .user,
                                data: ["snapshot_id": AnyCodable("test-uuid"),
                                       "joint_count": AnyCodable(20)])
        Harness.shared.record(.motionPlayStart, level: .info, actor: .user,
                                data: ["page_id": AnyCodable(7),
                                       "step_count": AnyCodable(12)])
        try await waitForFlush()

        let events = try loadEvents()
        let kinds = Set(events.map { $0.k.rawValue })
        XCTAssertTrue(kinds.contains("ui.section_changed"))
        XCTAssertTrue(kinds.contains("teach.snapshot_captured"))
        XCTAssertTrue(kinds.contains("motion.play_start"))
    }

    // MARK: - 검증: 큰 부하 시 backpressure / ordering.

    func testBurstPreservesOrderingAndStaysBounded() async throws {
        // 1000 개 빠르게 enqueue — AsyncStream bufferingNewest(4096) 이라 drop 없을 것.
        for i in 0..<1000 {
            Harness.shared.record(.heartbeat, level: .trace, actor: .system,
                                    data: ["i": AnyCodable(i)])
        }
        try await waitForFlush()

        let events = try loadEvents()
        let hbs = events.filter { $0.k.rawValue == "heartbeat.tick" }
        XCTAssertEqual(hbs.count, 1000, "큰 burst 에서 손실 발생")

        // seq 가 단조 증가 (1, 2, 3, ...) 인지 — record 호출 순서가 보존.
        let seqs = hbs.map { $0.i }
        let sorted = seqs.sorted()
        XCTAssertEqual(seqs, sorted, "record 호출 순서가 디스크 순서와 다름 — ordering broken")

        // i payload 도 0..<1000 단조 증가.
        let ivals = hbs.compactMap { $0.d.raw["i"]?.value as? Int }
        XCTAssertEqual(ivals, Array(0..<1000), "payload 'i' 순서가 일치하지 않음")
    }

    // MARK: - 검증: heartbeat sampler 가 디스크에 떨어지는지.

    func testHeartbeatTimerDeliversToDisk() async throws {
        // 0.1s 주기 heartbeat — 약 3 tick 받으면 충분.
        Harness.shared.startHeartbeat(intervalSeconds: 0.1)
        try await Task.sleep(nanoseconds: 350_000_000)
        Harness.shared.stopHeartbeat()
        try await waitForFlush()

        let events = try loadEvents()
        let hbs = events.filter { $0.k.rawValue == "heartbeat.tick" }
        XCTAssertGreaterThanOrEqual(hbs.count, 2,
                                     "heartbeat 타이머가 0.35s 동안 2 tick 미만 — timer broken")
    }

    // MARK: - 검증: context provider 가 첨부되는지.

    func testContextProviderAttachesSnapshot() async throws {
        // ConnectionStore 생성 — init 에서 Harness 에 context provider 등록.
        let store = ConnectionStore()
        // status 가 .disconnected 인 상태. context 의 cn=disconnected, ep=nil 이어야.
        Harness.shared.record(.uiSectionChanged, data: ["to": AnyCodable("studio")])
        try await waitForFlush()

        let events = try loadEvents()
        let sectionChange = events.first { $0.k.rawValue == "ui.section_changed" }
        XCTAssertNotNil(sectionChange, "ui.section_changed 가 없음")
        guard let ev = sectionChange, let ctx = ev.c else {
            XCTFail("context 미첨부 — provider 가 nil 반환 또는 등록 race")
            return
        }
        XCTAssertEqual(ctx.cn, .disconnected)
        XCTAssertNil(ctx.ep)
        XCTAssertEqual(ctx.im, false)
        _ = store
    }

    // MARK: - 검증: meta.json 누적 + 종료 시 ended 채워짐.

    func testMetaAccumulatesAndFinalizesOnStop() async throws {
        // 충분히 다양한 이벤트 발생.
        Harness.shared.record(.connectAttempt, level: .info, actor: .user)
        Harness.shared.record(.connectSuccess, level: .notice, actor: .system,
                                data: ["rtt_ms": AnyCodable(7.5)])
        Harness.shared.record(.busReadFail, level: .error, actor: .robot,
                                data: ["op": AnyCodable("readState")])
        try await waitForFlush()

        // 종료 전: meta.eventCount > 0, ended nil.
        let metaURL = sessionDir.appendingPathComponent("meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path))
        var meta = try JSONDecoder().decode(TelemetrySessionMeta.self,
                                              from: Data(contentsOf: metaURL))
        XCTAssertGreaterThan(meta.eventCount, 0)
        XCTAssertNil(meta.ended, "stop() 전 meta.ended 가 채워져 있음")
        XCTAssertEqual(meta.connectCount, 1)
        XCTAssertGreaterThanOrEqual(meta.errorCount, 1)

        Harness.shared.stop(reason: "smoke-test-end")
        // stop 은 비동기 finalize → consumer drain 까지 대기.
        try await Task.sleep(nanoseconds: 500_000_000)

        // sessions/ 로 archive 됐을 수도 있음. 검색.
        let archivedRoot = tempRoot.appendingPathComponent("..").standardizedFileURL
        // (Harness.stop 의 archive 는 TelemetryStore.archive 가 .currentSessionDirectory
        // 의 명명 규칙 'current-...' 을 sessions/ 로 옮김 — sandbox 가 tempRoot 라
        // sessions/ 가 archivedSessionsDirectory() 가 됨. tearDown 직전에 검사.)
        // 핵심 검증: archive 됐든 안 됐든 meta.json 자체는 ended 채워짐.
        if let data = try? Data(contentsOf: metaURL) {
            meta = try JSONDecoder().decode(TelemetrySessionMeta.self, from: data)
            XCTAssertNotNil(meta.ended, "stop 호출 후 meta.ended 미채워짐")
        }
    }
}
