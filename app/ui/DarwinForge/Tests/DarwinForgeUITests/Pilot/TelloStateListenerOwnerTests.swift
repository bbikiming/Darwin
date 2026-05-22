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

    // MARK: - 8. 사이클 73 (코덱스 HIGH-2): 사용자 명시 start() 호출 전엔 inactive 유지

    /// RootView 의 자동 owner.start() 제거 후 회귀 가드.
    /// owner alloc 만 했고 사용자가 "Tello 활성화" 버튼 클릭 안 했으면 isActive=false +
    /// health() == .inactive. macOS 권한 다이얼로그도 발화 안 함 (NWListener 미생성).
    func testStartRequiresExplicitInvocation() {
        let listener = MockListener()
        let owner = TelloStateListenerOwner(bridge: nil, listener: listener)

        // 명시 start() 미호출 — alloc 직후 상태.
        XCTAssertFalse(owner.isActive, "alloc 직후 isActive=false (자동 start 금지)")
        XCTAssertEqual(listener.startCount, 0, "listener.start 미호출")
        XCTAssertEqual(owner.health(), .inactive,
                       "사용자 명시 활성화 대기 — banner 가 'Tello 활성화' 토글 표시")
        XCTAssertNil(owner.startedAt, "startedAt nil — 시작 안 됨")
        XCTAssertFalse(owner.lastStartFailed, "lastStartFailed false — 실패 아님")
    }

    // MARK: - 9. 사이클 73: start 실패 후 health() == .startFailed

    /// silent fail 가시화: owner.lastStartFailed 가 true 되며 health() 가 분류.
    /// HUD 가 "🔌 listener 비활성 + 다시 시도" banner 표시.
    func testStartFailureMarksHealthAsStartFailed() {
        let listener = MockListener()
        listener.startError = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
        )
        let owner = TelloStateListenerOwner(bridge: nil, listener: listener)

        owner.start()

        XCTAssertFalse(owner.isActive, "isActive=false (silent fail)")
        XCTAssertTrue(owner.lastStartFailed, "실패 플래그 설정")
        XCTAssertEqual(owner.health(), .startFailed,
                       "사용자 안내: '다시 시도' 버튼 + 권한 안내")
    }

    // MARK: - 10. 사이클 73: stalled state — Date 주입으로 결정적 검증

    /// 활성화 후 N초간 메시지 무수신 시 health() == .stalled(elapsedSec).
    /// Wi-Fi 미연결 / Info.plist 누락 시뮬레이션. clock 주입으로 wall-time 의존 제거.
    func testStalledStateDetectedAfterThreshold() {
        // T0 = 시작 시점. clock 이 mutable now 를 가리키게 한다.
        let nowBox = NowBox(value: Date(timeIntervalSince1970: 1_000_000))
        let listener = MockListener()
        let owner = TelloStateListenerOwner(
            bridge: nil,
            listener: listener,
            clock: { nowBox.value }
        )

        owner.start()
        XCTAssertEqual(owner.health(stalledThreshold: 5.0), .healthy,
                       "활성 직후 — 메시지 도착 대기 (5초 미만)")

        // 4초 경과 — 아직 stalled 아님.
        nowBox.value = nowBox.value.addingTimeInterval(4.0)
        XCTAssertEqual(owner.health(stalledThreshold: 5.0), .healthy,
                       "4초 < 5초 threshold")

        // 5초 정확 도달 — stalled.
        nowBox.value = nowBox.value.addingTimeInterval(1.0)  // T+5
        if case .stalled(let elapsed) = owner.health(stalledThreshold: 5.0) {
            XCTAssertEqual(elapsed, 5.0, accuracy: 0.01,
                           "stalled elapsedSec 정확")
        } else {
            XCTFail("5초 도달 시 .stalled 분류 필요")
        }

        // 8초 — 여전히 stalled, elapsed 갱신.
        nowBox.value = nowBox.value.addingTimeInterval(3.0)  // T+8
        if case .stalled(let elapsed) = owner.health(stalledThreshold: 5.0) {
            XCTAssertEqual(elapsed, 8.0, accuracy: 0.01)
        } else {
            XCTFail("8초 도달 시 .stalled 분류 필요")
        }
    }

    // MARK: - 11. 사이클 73: 메시지 1건이라도 수신 시 healthy

    /// stalled threshold 초과해도 메시지가 들어오면 healthy 로 분류 — banner 사라짐.
    func testFirstMessageClearsStalledState() async {
        let nowBox = NowBox(value: Date(timeIntervalSince1970: 2_000_000))
        let listener = MockListener()
        let owner = TelloStateListenerOwner(
            bridge: nil,
            listener: listener,
            clock: { nowBox.value }
        )

        owner.start()
        nowBox.value = nowBox.value.addingTimeInterval(10.0)
        // 10초 경과 — stalled.
        if case .stalled = owner.health(stalledThreshold: 5.0) {} else {
            XCTFail("precondition: stalled 상태여야 함")
        }

        // 메시지 1건 도착.
        listener.simulate(sampleMessage(battery: 50))
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(owner.health(stalledThreshold: 5.0), .healthy,
                       "messagesReceived > 0 → healthy")
    }

    // MARK: - 12. 사이클 73: 권한 거부 시뮬레이션 — start 다시 시도 시 복구 가능

    /// 사용자가 "다시 시도" 버튼 클릭 → start() 재호출. 두번째 호출은 성공 시뮬.
    /// owner state 가 reset 후 healthy 로 전환.
    func testRetryAfterStartFailureRecovers() {
        let listener = MockListener()
        listener.startError = NSError(domain: "test", code: 1)
        let owner = TelloStateListenerOwner(bridge: nil, listener: listener)

        owner.start()  // 첫 시도 실패.
        XCTAssertEqual(owner.health(), .startFailed)
        XCTAssertTrue(owner.lastStartFailed)

        // 사용자가 권한 허용 후 "다시 시도" 클릭.
        listener.startError = nil
        owner.start()

        XCTAssertTrue(owner.isActive, "재시도 성공 → isActive=true")
        XCTAssertFalse(owner.lastStartFailed, "실패 플래그 reset")
        XCTAssertNotNil(owner.startedAt, "startedAt 갱신")
        XCTAssertEqual(listener.startCount, 2, "두 번 시도 카운트")
    }
}

/// **사이클 73**: clock injection 을 위한 mutable wrapper.
/// `@Sendable` closure 가 외부 mutable state 를 read 하려면 reference type 필요.
/// 테스트 단일 thread 환경 가정 — `@unchecked Sendable`.
private final class NowBox: @unchecked Sendable {
    var value: Date
    init(value: Date) { self.value = value }
}
