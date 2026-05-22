import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.20.35 (2026-05-22) 사이클 18 — TelloStateListenerOwner 통합 test**.
///
/// owner 가 listener.onState → bridge.updateTelloState 까지 정확히 전파하는지,
/// lifecycle (start/stop/재사용) 이 idempotent + 안전한지, bridge nil 시 no-op
/// 인지 검증. MockTelloStateListener (UDP 사용 안 함) 주입 — CI 안전.
@MainActor
final class TelloStateListenerOwnerTests: XCTestCase {

    // MARK: - Test-only Mock (TelloStateListenerTests 와 의도적 분리 — independent test fixture)

    /// 동일 protocol 의 별개 mock — onState callback 검증 + start/stop count.
    /// `@unchecked Sendable`: 테스트 단일 thread 환경 가정.
    final class MockListener: TelloStateListenerProtocol, @unchecked Sendable {
        var onState: (@Sendable (TelloStateMessage) -> Void)?

        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var isStarted = false
        /// start() 가 throw 할지 — 권한 거부 시뮬레이션.
        var startError: Error?

        func start() throws {
            startCount += 1
            if let err = startError {
                throw err
            }
            isStarted = true
        }

        func stop() {
            stopCount += 1
            isStarted = false
        }

        /// 외부에서 pre-built 메시지 fire — onState 직접 호출.
        func simulate(_ msg: TelloStateMessage) {
            guard isStarted, let cb = onState else { return }
            cb(msg)
        }
    }

    /// 테스트용 sample message helper — 매번 receivedAt 신선.
    private func sampleMessage(battery: Int = 75) -> TelloStateMessage {
        TelloStateMessage(
            pitchDeg: 1, rollDeg: 2, yawDeg: 3,
            vgx: 0, vgy: 0, vgz: 0,
            templ: 50, temph: 55, tofCm: 20,
            heightCm: 50, batteryPct: battery, baroPa: nil,
            agx: 0, agy: 0, agz: -981,
            receivedAt: Date()
        )
    }

    // MARK: - 1. start() → simulate → bridge.updateTelloState 호출 검증

    func testStartConnectsListenerToBridge() async {
        let mockTello = MockTelloLink()
        let bridge = WalkLabRCBridge(tello: mockTello)
        let listener = MockListener()
        let owner = TelloStateListenerOwner(bridge: bridge, listener: listener)

        owner.start()
        XCTAssertTrue(owner.isActive, "start 성공 시 isActive=true")
        XCTAssertEqual(listener.startCount, 1)

        listener.simulate(sampleMessage(battery: 75))
        // MainActor hop 대기.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        XCTAssertEqual(bridge.lastTelloState?.batteryPct, 75,
                       "listener → owner → bridge 전체 path 동작")
        XCTAssertEqual(owner.messagesReceived, 1, "수신 카운터 정확")
        XCTAssertNotNil(owner.lastReceived, "lastReceived 타임스탬프 갱신")
    }

    // MARK: - 2. stop() → onState 해제 / callback 미발화 검증

    func testStopReleasesCallback() async {
        let mockTello = MockTelloLink()
        let bridge = WalkLabRCBridge(tello: mockTello)
        let listener = MockListener()
        let owner = TelloStateListenerOwner(bridge: bridge, listener: listener)

        owner.start()
        owner.stop()
        XCTAssertFalse(owner.isActive, "stop 후 isActive=false")
        XCTAssertEqual(listener.stopCount, 1)
        XCTAssertNil(listener.onState, "callback 해제됨")

        // 이미 isStarted=false → simulate 가 no-op (mock 이 guard).
        listener.simulate(sampleMessage(battery: 50))
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(bridge.lastTelloState, "stop 이후 메시지 전파 안 됨")
        XCTAssertEqual(owner.messagesReceived, 0)
    }

    // MARK: - 3. messagesReceived counter 정확성 (다중 메시지)

    func testMessagesReceivedCounterAccuracy() async {
        let mockTello = MockTelloLink()
        let bridge = WalkLabRCBridge(tello: mockTello)
        let listener = MockListener()
        let owner = TelloStateListenerOwner(bridge: bridge, listener: listener)

        owner.start()
        for bat in [80, 70, 60, 50, 40] {
            listener.simulate(sampleMessage(battery: bat))
        }
        // 모든 MainActor hop 완료 대기.
        for _ in 0..<3 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        XCTAssertEqual(owner.messagesReceived, 5, "5개 메시지 모두 카운트")
        XCTAssertEqual(bridge.lastTelloState?.batteryPct, 40,
                       "마지막 메시지가 bridge 에 반영")
    }

    // MARK: - 4. bridge nil 시 safe (no-op)

    func testBridgeNilIsSafe() async {
        let listener = MockListener()
        let owner = TelloStateListenerOwner(bridge: nil, listener: listener)

        owner.start()
        XCTAssertTrue(owner.isActive)

        // bridge nil 이라도 callback 자체는 발화 — counter 증가, bridge 호출 skip.
        listener.simulate(sampleMessage(battery: 60))
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(owner.messagesReceived, 1, "counter 는 진행 — owner state 갱신")
        XCTAssertNotNil(owner.lastReceived, "lastReceived 도 갱신")
        // 검증 핵심: crash 없이 안전. bridge 가 약한 참조라 nil 이면 그냥 skip.
    }

    // MARK: - 5. start() idempotency — 중복 호출 시 listener.start 한 번만

    func testStartIsIdempotent() {
        let listener = MockListener()
        let owner = TelloStateListenerOwner(bridge: nil, listener: listener)

        owner.start()
        owner.start()
        owner.start()

        XCTAssertEqual(listener.startCount, 1,
                       "이미 active 면 listener.start 미 재호출")
        XCTAssertTrue(owner.isActive)
    }

    // MARK: - 6. stop() idempotency + 재사용 (stop → start)

    func testStopThenRestartReusable() async {
        let mockTello = MockTelloLink()
        let bridge = WalkLabRCBridge(tello: mockTello)
        let listener = MockListener()
        let owner = TelloStateListenerOwner(bridge: bridge, listener: listener)

        owner.start()
        owner.stop()
        owner.stop()  // double stop — 안전.
        XCTAssertEqual(listener.stopCount, 2, "stop 중복 호출 안전")

        // 재 start — callback 재등록 + listener.start 재호출.
        owner.start()
        XCTAssertTrue(owner.isActive)
        XCTAssertEqual(listener.startCount, 2)
        XCTAssertNotNil(listener.onState)

        // 재 start 후 메시지 정상 전파 검증.
        listener.simulate(sampleMessage(battery: 30))
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(bridge.lastTelloState?.batteryPct, 30,
                       "재 start 후 메시지 전파 정상")
    }

    // MARK: - 7. start 실패 시 silent — isActive=false 유지

    func testStartFailureKeepsInactive() {
        let listener = MockListener()
        listener.startError = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Permission denied (NSLocalNetworkUsage)"]
        )
        let owner = TelloStateListenerOwner(bridge: nil, listener: listener)

        owner.start()  // throw 가 owner 내부에서 캐치되어 silent.
        XCTAssertFalse(owner.isActive,
                       "start 실패 시 isActive=false — silent 처리")
        XCTAssertEqual(listener.startCount, 1, "start 시도는 카운트")
    }
}
