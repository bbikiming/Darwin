import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.21.0 (2026-05-22) — GamepadPilotAdapter 단위 테스트**.
///
/// 실 `GCController` 없이 `MockGamepad` 로 stick / 버튼 상태를 enqueue 해
/// adapter → bridge 경로의 정확한 호출 (handleMove / handleEmergency / handlePreset
/// / handleRecovery) + edge-trigger + 멀티 버튼 동시 입력을 검증.
@MainActor
final class GamepadPilotAdapterTests: XCTestCase {

    private var mock: MockGamepad!
    private var session: WalkLabSession!
    private var bridge: WalkLabRCBridge!
    private var adapter: GamepadPilotAdapter!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockGamepad(controllerName: "MockController")
        session = WalkLabSession()
        bridge = WalkLabRCBridge(tello: MockTelloLink())
        bridge.session = session
        adapter = GamepadPilotAdapter(bridge: bridge, source: mock)
    }

    override func tearDown() async throws {
        adapter.stop()
        adapter = nil
        bridge = nil
        session = nil
        mock = nil
        try await super.tearDown()
    }

    // MARK: - 기본 / lifecycle

    func testAdapterInitDefaults() {
        XCTAssertFalse(adapter.isRunning, "init 후 미실행")
        XCTAssertNil(adapter.lastActionLabel, "입력 없음 → label nil")
        XCTAssertEqual(adapter.stickScale, .default, "default scale")
    }

    func testStartSetsRunningAndDetectsController() {
        XCTAssertNil(adapter.connectedControllerName, "사전: 컨트롤러 이름 nil")
        adapter.start()
        XCTAssertTrue(adapter.isRunning, "start 후 running=true")
        XCTAssertEqual(adapter.connectedControllerName, "MockController",
                       "start 시점에 mock 컨트롤러 이름 캐치")
    }

    func testStopClearsRunning() {
        adapter.start()
        XCTAssertTrue(adapter.isRunning)
        adapter.stop()
        XCTAssertFalse(adapter.isRunning, "stop 후 running=false")
    }

    func testStartIsIdempotent() {
        adapter.start()
        let firstName = adapter.connectedControllerName
        adapter.start()  // 두 번째 start — no-op.
        XCTAssertTrue(adapter.isRunning)
        XCTAssertEqual(adapter.connectedControllerName, firstName, "두 번째 start no-op")
    }

    // MARK: - Stick → handleMove

    /// 좌 스틱 전방 max → bridge.handleMove(stride 양수).
    /// auto-start 가 march 진입 → strideMm 40 (TelloRCMapper 한도) 도달.
    func testLeftStickForwardCallsHandleMove() {
        mock.sticks = GamepadStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        adapter.pollOnce()
        XCTAssertEqual(session.current, .march, "auto-start 발화 (bridge default)")
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9, "max forward stride")
        XCTAssertEqual(bridge.lastIntent?.source, .gamepad, "source = gamepad")
        XCTAssertEqual(adapter.lastActionLabel, "stick move")
    }

    func testLeftStickBackwardNegativeStride() {
        session.start(.march)
        mock.sticks = GamepadStickState(leftX: 0, leftY: -1.0, rightX: 0, rightY: 0)
        adapter.pollOnce()
        XCTAssertEqual(session.strideMm, -40, accuracy: 1e-9, "max backward stride")
    }

    func testLeftStickRightCallsHandleMoveSide() {
        session.start(.march)
        mock.sticks = GamepadStickState(leftX: 1.0, leftY: 0, rightX: 0, rightY: 0)
        adapter.pollOnce()
        // lr=100 * 0.3 = 30 → clamp 25.
        XCTAssertEqual(session.sideMm, 25, accuracy: 1e-9)
    }

    func testRightStickXCallsHandleMoveTurn() {
        session.start(.march)
        mock.sticks = GamepadStickState(leftX: 0, leftY: 0, rightX: 1.0, rightY: 0)
        adapter.pollOnce()
        // yaw=100 * 0.2 = 20.
        XCTAssertEqual(session.turnDeg, 20, accuracy: 1e-9)
    }

    func testCombinedSticksAllAxes() {
        session.start(.march)
        // 전진 + 우측 + 우회전.
        mock.sticks = GamepadStickState(leftX: 1.0, leftY: 1.0, rightX: 1.0, rightY: 0)
        adapter.pollOnce()
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9)
        XCTAssertEqual(session.sideMm, 25, accuracy: 1e-9)
        XCTAssertEqual(session.turnDeg, 20, accuracy: 1e-9)
    }

    /// stick zero (deadzone 진입) → 1회만 .stop 전달.
    func testStickStopFiresOnceWhenStickReturnsToZero() {
        session.start(.march)
        // 1) 움직임 — strideMm 적용.
        mock.sticks = GamepadStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        adapter.pollOnce()
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9)

        // 2) Stick 놓음 → zero → .stop intent.
        mock.sticks = .neutral
        adapter.pollOnce()
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "stop hard-zero")
        XCTAssertEqual(adapter.lastActionLabel, "stick stop")
        XCTAssertEqual(bridge.lastIntent?.kind, .stop)
    }

    /// 두 frame 연속 zero → 두 번째는 silent (label 변경 없음).
    func testStickZeroIdempotentSilentAfterFirstStop() {
        session.start(.march)
        // 사전: stick 움직임.
        mock.sticks = GamepadStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        adapter.pollOnce()
        // 1차 zero — stop 발화.
        mock.sticks = .neutral
        adapter.pollOnce()
        XCTAssertEqual(adapter.lastActionLabel, "stick stop")

        // 2차 zero — silent (label 미변경).
        adapter.lastActionLabel = nil  // 추적용 sentinel.
        adapter.pollOnce()
        XCTAssertNil(adapter.lastActionLabel, "연속 zero frame 은 silent")
    }

    /// Stick deadzone (< 5/100) → 0 처리 (TelloRCMapper 동작).
    func testStickWithinDeadzoneIsIgnored() {
        session.start(.march)
        // 0.03 = ~3/100, deadzone threshold 5 미만.
        mock.sticks = GamepadStickState(leftX: 0.03, leftY: 0.03, rightX: 0.03, rightY: 0)
        adapter.pollOnce()
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "deadzone → 0")
    }

    // MARK: - Buttons → emergency / preset / recovery

    func testFaceTopButtonCallsEmergency() {
        session.start(.march)
        XCTAssertEqual(bridge.emergencyCount, 0)

        mock.buttons.faceTop = true
        adapter.pollOnce()

        XCTAssertEqual(bridge.emergencyCount, 1, "faceTop → emergency 1회")
        XCTAssertEqual(session.current, .idle, "emergencyStop 효과")
        XCTAssertEqual(bridge.lastIntent?.source, .gamepad)
    }

    /// 버튼 held 상태에서 두 frame 연속 polling → emergency 1회만 (edge trigger).
    func testEmergencyButtonHeldFiresOnceOnly() {
        session.start(.march)
        mock.buttons.faceTop = true
        adapter.pollOnce()
        adapter.pollOnce()  // 같은 버튼 down 상태 — edge trigger 차단.
        XCTAssertEqual(bridge.emergencyCount, 1, "held 버튼 = 1회만 (edge trigger)")
    }

    /// 누름 → 떼었다 → 다시 누름 = 2회 발화 (정상 edge re-trigger).
    func testEmergencyButtonRetriggerAfterRelease() {
        session.start(.march)
        mock.buttons.faceTop = true
        adapter.pollOnce()
        XCTAssertEqual(bridge.emergencyCount, 1)

        mock.buttons.faceTop = false
        adapter.pollOnce()  // release.
        bridge.handleRecovery(from: .ui)  // emergency unblock for next preset.
        session.start(.march)

        mock.buttons.faceTop = true
        adapter.pollOnce()
        XCTAssertEqual(bridge.emergencyCount, 2, "release 후 재누름 = 두 번째 발화")
    }

    func testFaceLeftButtonCallsPresetIdle() {
        session.start(.march)
        XCTAssertEqual(session.current, .march)

        mock.buttons.faceLeft = true
        adapter.pollOnce()

        XCTAssertEqual(session.current, .idle, "faceLeft → preset.idle = stop")
        // 주의: handlePreset(.idle) 은 session.stop 만 호출, bridge.lastIntent 미설정 (intent
        // 아닌 직접 preset 명령). adapter.lastActionLabel 로 검증.
        XCTAssertEqual(adapter.lastActionLabel, "preset idle (faceLeft / □ / X)")
    }

    func testDpadUpCallsPresetMarch() {
        XCTAssertEqual(session.current, .idle)
        mock.buttons.dpadUp = true
        adapter.pollOnce()
        XCTAssertEqual(session.current, .march, "D-pad ↑ → preset 1 (march)")
        XCTAssertGreaterThan(bridge.presetChangeMirror, 0, "telemetry mirror 증가")
    }

    func testDpadRightCallsPresetSlowWalk() {
        mock.buttons.dpadRight = true
        adapter.pollOnce()
        XCTAssertEqual(session.current, .slowWalk, "D-pad → → preset 2 (slowWalk)")
    }

    func testDpadDownCallsPresetNormalWalk() {
        mock.buttons.dpadDown = true
        adapter.pollOnce()
        XCTAssertEqual(session.current, .normalWalk, "D-pad ↓ → preset 3 (normalWalk)")
    }

    func testDpadLeftCallsPresetFastWalk() {
        // `.fastWalk` 는 caution preset → enableBalanceCorrection 필요.
        session.enableBalanceCorrection = true
        mock.buttons.dpadLeft = true
        adapter.pollOnce()
        XCTAssertEqual(session.current, .fastWalk, "D-pad ← → preset 4 (fastWalk)")
    }

    /// `.fastWalk` 는 caution preset — balance correction OFF 면 차단 (safety message).
    func testDpadLeftFastWalkBlockedWithoutBalanceCorrection() {
        XCTAssertFalse(session.enableBalanceCorrection, "사전: balance correction OFF")
        mock.buttons.dpadLeft = true
        adapter.pollOnce()
        XCTAssertEqual(session.current, .idle, "caution preset 차단")
        XCTAssertNotNil(bridge.safetyMessage, "차단 사유 노출")
    }

    func testMenuButtonCallsRecovery() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive, "사전: emergency 활성")

        mock.buttons.menu = true
        adapter.pollOnce()

        XCTAssertFalse(session.emergencyStopActive, "START / menu → recovery")
    }

    // MARK: - 멀티 버튼 동시 (안전 우선 순서)

    /// 한 frame 에 faceTop + dpadUp 동시 입력 → emergency 가 우선.
    /// adapter 내부 처리 순서: faceTop 먼저 → emergency 발화 → emergencyStopActive=true →
    /// dpadUp 의 handlePreset 가 bridge 의 emergencyStopActive gate 에서 차단.
    func testSimultaneousDpadAndEmergency() {
        mock.buttons.dpadUp = true
        mock.buttons.faceTop = true
        adapter.pollOnce()

        XCTAssertEqual(bridge.emergencyCount, 1, "emergency 발화")
        XCTAssertEqual(session.current, .idle, "emergency 후 idle (preset 차단)")
    }

    // MARK: - 사이클 62 — 코덱스 HIGH 회귀 가드 (button-before-stick + early return)

    /// **사이클 62 코덱스 HIGH**: stick + emergency 같은 frame → emergency 가 stick 보다 먼저.
    ///
    /// 종전: stick → button 순서 → stick 의 amplitude write 가 emergency 가드보다 먼저
    /// 발생 → 1 frame 의 race window (사용자가 panic + stick 을 동시 입력 시 robot 이
    /// 마지막으로 stride 적용 후 정지).
    ///
    /// 수정 후: button 의 emergency edge 가 먼저 처리 → fire 시 stick 처리 skip → write 차단.
    func testStickAndEmergencySameFrameStickIsSkipped() {
        session.start(.march)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "사전: stride 0")

        // 사용자가 emergency 누르며 동시에 stick 도 밀고 있음.
        mock.sticks = GamepadStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        mock.buttons.faceTop = true
        adapter.pollOnce()

        // 핵심: emergency 가 먼저 fire → stick 처리 skip → strideMm 0 유지.
        // 종전 (stick → button): strideMm 40 적용 → emergency → strideMm 0 으로 재초기화.
        // 수정 후 (button → stick early return): strideMm 0 유지 (write 자체가 없음).
        XCTAssertEqual(bridge.emergencyCount, 1, "emergency fire")
        XCTAssertTrue(session.emergencyStopActive, "emergency 활성")
        XCTAssertEqual(session.current, .idle, "emergency 후 idle")
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9,
                       "stick write skip — emergency 와 같은 frame 의 stride 0 유지")
    }

    /// **사이클 62 회귀**: emergency edge frame 의 stick 은 silent. 다음 frame 에서 정상 재개.
    func testStickResumesNextFrameAfterEmergency() {
        session.start(.march)

        // Frame 1: emergency + stick → emergency 만 fire.
        mock.sticks = GamepadStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        mock.buttons.faceTop = true
        adapter.pollOnce()
        XCTAssertEqual(bridge.emergencyCount, 1)

        // Recovery + restart.
        mock.buttons.faceTop = false
        bridge.handleRecovery(from: .ui)
        session.start(.march)

        // Frame 2: stick 만 (emergency 떼었음) → stick 정상 처리.
        adapter.pollOnce()
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9,
                       "다음 frame 의 stick 정상 처리 (button release 후)")
    }

    /// **사이클 62 회귀**: emergency 안 누른 일반 button (D-pad) 은 stick 과 동시 처리 OK.
    /// emergency 만 stick 을 skip — D-pad preset 은 stick 처리 영향 없음.
    func testStickAndDpadPresetSameFrameBothApplied() {
        // D-pad ↑ = march preset, stick = forward.
        mock.buttons.dpadUp = true
        mock.sticks = GamepadStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        adapter.pollOnce()

        XCTAssertEqual(session.current, .march, "D-pad preset 적용")
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9,
                       "stick 도 함께 적용 (emergency 아닌 button 은 race 없음)")
    }

    /// **사이클 62 회귀**: emergency fire 후 stick zero 도 skip — `previousStickWasZero`
    /// 가 갱신 안 됨 → 다음 frame 에서 stick zero 시 stop 발화 정상.
    func testEmergencyFrameDoesNotUpdateStickZeroState() {
        session.start(.march)

        // 사전: 한 frame 의 stick 움직임 (zero → nonzero).
        mock.sticks = GamepadStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        adapter.pollOnce()
        // 이제 previousStickWasZero = false.

        // Frame: emergency + stick zero — emergency 가 fire → stick skip.
        mock.sticks = .neutral
        mock.buttons.faceTop = true
        adapter.pollOnce()
        // emergency frame 이라 stick 처리 skip → previousStickWasZero 그대로 false.

        // Recovery + 다음 frame 에서 stick zero → stop 발화 (silent 안 됨).
        bridge.handleRecovery(from: .ui)
        session.start(.march)
        mock.buttons.faceTop = false
        adapter.lastActionLabel = nil
        adapter.pollOnce()
        XCTAssertEqual(adapter.lastActionLabel, "stick stop",
                       "emergency frame 이 stick state 를 corrupt 하지 않음")
    }

    // MARK: - 컨트롤러 없음

    func testNoControllerPolledQuietly() {
        let emptyMock = MockGamepad(controllerName: nil)
        let lonely = GamepadPilotAdapter(bridge: bridge, source: emptyMock)
        // No-op — 어떤 bridge 호출도 안 함.
        lonely.pollOnce()
        XCTAssertNil(lonely.connectedControllerName)
        XCTAssertEqual(bridge.emergencyCount, 0)
        XCTAssertNil(bridge.lastIntent, "입력 없음 → lastIntent 미설정")
    }

    // MARK: - Bridge nil safety

    func testNilBridgeIsNoOp() {
        let orphan = GamepadPilotAdapter(bridge: nil, source: mock)
        mock.sticks = GamepadStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        mock.buttons.faceTop = true
        // crash 안 함 — bridge nil 시 silent skip.
        orphan.pollOnce()
        XCTAssertNil(orphan.lastActionLabel)
    }

    // MARK: - Snapshot 일관성

    func testSnapshotIsEquatable() {
        let snap1 = GamepadSnapshot(
            controllerName: "Test",
            sticks: GamepadStickState(leftX: 0.5, leftY: 0, rightX: 0, rightY: 0),
            buttons: GamepadButtonState()
        )
        let snap2 = GamepadSnapshot(
            controllerName: "Test",
            sticks: GamepadStickState(leftX: 0.5, leftY: 0, rightX: 0, rightY: 0),
            buttons: GamepadButtonState()
        )
        XCTAssertEqual(snap1, snap2, "Equatable 일관성")
    }

    func testNeutralSnapshotHasNoInput() {
        let neutral = GamepadSnapshot.neutral
        XCTAssertNil(neutral.controllerName)
        XCTAssertEqual(neutral.sticks, GamepadStickState.neutral)
        XCTAssertFalse(neutral.buttons.faceTop)
        XCTAssertFalse(neutral.buttons.dpadUp)
    }

    // MARK: - 사용자 정의 stickScale

    func testCustomStickScaleAppliesToCommand() {
        adapter.stickScale = TelloRCMapper.Scale(fb: 0.1, lr: 0.1, yaw: 0.1)
        mock.sticks = GamepadStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        adapter.pollOnce()
        // 100 * 0.1 = 10mm.
        XCTAssertEqual(session.strideMm, 10, accuracy: 1e-9, "custom scale 적용")
    }
}

// MARK: - MockGamepad

/// **테스트 전용** — `GamepadInputSource` 의 manual 구현. stick / button 상태를
/// 테스트가 직접 enqueue 한 후 `pollOnce()` 호출로 adapter 가 읽음.
@MainActor
final class MockGamepad: GamepadInputSource {
    var controllerName: String?
    var sticks: GamepadStickState
    var buttons: GamepadButtonState

    init(
        controllerName: String? = "MockGamepad",
        sticks: GamepadStickState = .neutral,
        buttons: GamepadButtonState = .init()
    ) {
        self.controllerName = controllerName
        self.sticks = sticks
        self.buttons = buttons
    }

    func snapshot() -> GamepadSnapshot {
        GamepadSnapshot(
            controllerName: controllerName,
            sticks: sticks,
            buttons: buttons
        )
    }
}
