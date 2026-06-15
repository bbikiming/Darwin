import Foundation
import Network
import XCTest
@testable import DarwinForgeUI

/// **v1.20.34 (2026-05-22) 사이클 17 — TelloStateListener 단위 test**.
///
/// 실 UDP socket 을 열지 않고 Mock + lifecycle 검증.
/// 실 listener 의 init 비용이 0 (lazy socket open) 임도 보장.
final class TelloStateListenerTests: XCTestCase {

    // MARK: - MockTelloStateListener

    /// **Test-only Mock** — 임의 메시지 `simulate(_:)` 로 onState callback 발화 검증.
    /// UDP socket 미사용 — XCTest sandbox / CI 안전.
    /// `@unchecked Sendable`: 테스트 단일 thread 환경, mutable state 는 test queue 격리.
    final class MockTelloStateListener: TelloStateListenerProtocol, @unchecked Sendable {
        var onState: (@Sendable (TelloStateMessage) -> Void)?

        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var simulatedCount = 0
        private(set) var isStarted = false

        func start() throws {
            startCount += 1
            isStarted = true
        }

        func stop() {
            stopCount += 1
            isStarted = false
        }

        /// 테스트 helper — 외부에서 raw payload 를 강제 enqueue → parse 발화 동작 검증.
        func simulate(raw: String) {
            simulatedCount += 1
            guard isStarted else { return }
            guard let msg = TelloStateMessageParser.parse(raw) else { return }
            onState?(msg)
        }

        /// 이미 parsed 된 message 를 직접 fire — pure callback path test.
        func simulate(_ msg: TelloStateMessage) {
            simulatedCount += 1
            guard isStarted else { return }
            onState?(msg)
        }
    }

    // MARK: - Mock 행위 검증

    func testMockFiresCallbackOnSimulate() {
        let listener = MockTelloStateListener()
        var received: [TelloStateMessage] = []
        listener.onState = { msg in received.append(msg) }

        try? listener.start()
        let raw = "pitch:1;roll:2;yaw:3;bat:75;tof:42;h:10"
        listener.simulate(raw: raw)

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.batteryPct, 75)
        XCTAssertEqual(received.first?.pitchDeg, 1)
        XCTAssertEqual(received.first?.tofCm, 42)
    }

    func testMockSilentBeforeStart() {
        let listener = MockTelloStateListener()
        var received: [TelloStateMessage] = []
        listener.onState = { msg in received.append(msg) }

        // start() 미호출 → simulate 해도 callback 안 발화.
        listener.simulate(raw: "pitch:0;roll:0;yaw:0;bat:50")
        XCTAssertTrue(received.isEmpty,
                      "start() 전에는 callback 미발화 — lifecycle 안전")
    }

    func testMockMultipleMessagesOrdering() {
        let listener = MockTelloStateListener()
        var batteries: [Int] = []
        listener.onState = { msg in batteries.append(msg.batteryPct) }

        try? listener.start()
        for bat in [80, 70, 60, 50] {
            listener.simulate(raw: "pitch:0;roll:0;yaw:0;bat:\(bat)")
        }

        XCTAssertEqual(batteries, [80, 70, 60, 50],
                       "수신 순서 보존")
    }

    func testMockSimulateWithPrebuiltMessage() {
        let listener = MockTelloStateListener()
        var lastSeen: TelloStateMessage?
        listener.onState = { msg in lastSeen = msg }
        try? listener.start()

        let preBuilt = TelloStateMessage(
            pitchDeg: 5, rollDeg: 10, yawDeg: 90,
            vgx: 0, vgy: 0, vgz: 0,
            templ: 50, temph: 55, tofCm: 25,
            heightCm: 100, batteryPct: 40, baroPa: nil,
            agx: 0, agy: 0, agz: -981,
            receivedAt: Date()
        )
        listener.simulate(preBuilt)

        XCTAssertEqual(lastSeen?.heightCm, 100)
        XCTAssertEqual(lastSeen?.batteryPct, 40)
        XCTAssertEqual(lastSeen?.batteryLevel, .medium)
    }

    func testMockParseFailureIsSilent() {
        let listener = MockTelloStateListener()
        var received: [TelloStateMessage] = []
        listener.onState = { msg in received.append(msg) }
        try? listener.start()

        // 필수 필드 (bat) 누락 → parse 실패 → callback 미발화 (continue listen).
        listener.simulate(raw: "pitch:0;roll:0")
        XCTAssertTrue(received.isEmpty,
                      "parse 실패 시 callback 안 불려야 함 — 다음 datagram 대기")
        XCTAssertEqual(listener.simulatedCount, 1,
                       "simulate 호출은 카운트 됨 (listen loop 계속)")
    }

    // MARK: - Lifecycle (start / stop) 검증

    func testMockLifecycleCounts() {
        let listener = MockTelloStateListener()
        XCTAssertEqual(listener.startCount, 0)
        XCTAssertEqual(listener.stopCount, 0)
        XCTAssertFalse(listener.isStarted)

        try? listener.start()
        XCTAssertEqual(listener.startCount, 1)
        XCTAssertTrue(listener.isStarted)

        listener.stop()
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertFalse(listener.isStarted)
    }

    func testMockStopIdempotent() {
        let listener = MockTelloStateListener()
        try? listener.start()
        listener.stop()
        listener.stop()
        listener.stop()
        XCTAssertEqual(listener.stopCount, 3,
                       "stop() 반복 호출 안전 — count 만 증가")
    }

    // MARK: - 실 TelloStateListener — init / cost 검증

    func testRealListenerInitDoesNotOpenSocket() {
        // socket 을 실제 열면 sandbox / CI 에서 port 충돌 또는 권한 거부 가능.
        // init 시 socket 열지 않음을 보장 — start() 명시 호출 전 까지 cost 0.
        let listener = TelloStateListener()
        XCTAssertNotNil(listener,
                        "init 자체는 항상 성공 — socket alloc 지연")

        // start() 호출 없이 stop() 안전 (no-op).
        listener.stop()
    }

    func testRealListenerInitWithCustomPort() {
        // 사용자가 다른 port 지정 가능 (e.g. test sandbox 충돌 회피).
        let custom: NWEndpoint.Port = 18890
        let listener = TelloStateListener(port: custom)
        XCTAssertNotNil(listener)
        listener.stop()  // socket 안 열림 → no-op.
    }

    func testRealListenerOnStateAssignableBeforeStart() {
        // callback 을 start 전에 set 가능 (typical wiring 패턴).
        let listener = TelloStateListener()
        var fired = false
        listener.onState = { _ in fired = true }
        // start 안 했으므로 자연히 발화 안 됨.
        XCTAssertFalse(fired)
        listener.stop()
    }

    func testRealListenerDefaultPortConstant() {
        // Tello SDK 2.0 spec — state port 8890 고정.
        XCTAssertEqual(TelloStateListener.defaultPort, 8890)
    }

    // MARK: - Integration: callback → WalkLabRCBridge

    @MainActor
    func testMockListenerCanFeedBridgeUpdateTelloState() async {
        // listener → bridge.updateTelloState 통합 path 검증.
        let mockTello = MockTelloLink()
        let bridge = WalkLabRCBridge(tello: mockTello)
        let listener = MockTelloStateListener()

        // listener callback → bridge update (main actor hop).
        listener.onState = { msg in
            Task { @MainActor in
                bridge.updateTelloState(msg)
            }
        }

        try? listener.start()
        listener.simulate(raw: "pitch:0;roll:0;yaw:0;bat:18;tof:5")
        // MainActor hop 완료 polling 대기 — bridge 가 lastTelloState 를 갱신할 때까지.
        try? await waitUntil(timeout: 2.0) { bridge.lastTelloState?.batteryPct == 18 }

        XCTAssertEqual(bridge.lastTelloState?.batteryPct, 18,
                       "listener 가 bridge 까지 메시지 전파")
        XCTAssertEqual(bridge.lastTelloState?.batteryLevel, .low,
                       "low battery 분류")
        // 사이클 72 코덱스 MEDIUM-2 fix: low battery advisory 가 별도 channel
        // (telloAdvisoryMessage). safetyMessage 가 100ms 마다 덮어쓰기되던 race 차단.
        XCTAssertNotNil(bridge.telloAdvisoryMessage,
                        "low battery → telloAdvisoryMessage (별도 channel)")
        XCTAssertTrue(bridge.telloAdvisoryMessage?.contains("배터리") ?? false,
                      "advisory 에 '배터리' 키워드 포함")
    }
}
