import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.22.0 (2026-05-22) 사이클 90 — DJIControllerAdapter 단위 테스트**.
///
/// 실 DJI Mobile SDK / Onboard SDK 없이 `MockDJIController` 로 stick / 버튼 상태를 enqueue 해
/// adapter → bridge 경로의 정확한 호출 (handleMove / handleEmergency / handlePreset
/// / handleRecovery) 과 nil-bridge 안전성을 검증.
///
/// # 검증 전략
///
/// - **stick → handleMove**: `session.strideMm` / `bridge.lastIntent?.source` 로 라우팅 확인.
/// - **button edge → handleEmergency**: `bridge.emergencyCount` 증가 확인.
/// - **lifecycle**: `start` / `stop` / `pollOnce` idempotency.
/// - **nil bridge**: silent skip (no crash, no state change).
///
/// # 참고
///
/// GamepadPilotAdapterTests 와 동일 패턴 — Adapter pattern parity 보장. 사이클 90 stub
/// 단계 이후 실 DJI SDK 통합 시 production source 만 교체.
@MainActor
final class DJIControllerAdapterTests: XCTestCase {

    private var mock: MockDJIController!
    private var session: WalkLabSession!
    private var bridge: WalkLabRCBridge!
    private var adapter: DJIControllerAdapter!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockDJIController(controllerName: "MockDJIController")
        session = WalkLabSession()
        bridge = WalkLabRCBridge(tello: MockTelloLink())
        bridge.session = session
        adapter = DJIControllerAdapter(bridge: bridge, source: mock)
    }

    override func tearDown() async throws {
        adapter.stop()
        adapter = nil
        bridge = nil
        session = nil
        mock = nil
        try await super.tearDown()
    }

    // MARK: - 1. 초기 상태 / Init

    func testAdapterInitDefaults() {
        XCTAssertFalse(adapter.isRunning, "init 후 미실행")
        XCTAssertNil(adapter.lastActionLabel, "입력 없음 → label nil")
        XCTAssertNil(adapter.connectedControllerName, "init 직후 컨트롤러 이름 nil")
        XCTAssertEqual(adapter.stickScale, .default, "default scale")
    }

    // MARK: - 2. Lifecycle (start / stop / idempotent)

    func testStartSetsRunningAndDetectsController() {
        adapter.start()
        XCTAssertTrue(adapter.isRunning, "start 후 running=true")
        XCTAssertEqual(adapter.connectedControllerName, "MockDJIController",
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

    func testStopWhenNotRunningIsNoOp() {
        XCTAssertFalse(adapter.isRunning)
        adapter.stop()  // 미실행 시 stop — no-op.
        XCTAssertFalse(adapter.isRunning, "running=false 유지")
    }

    // MARK: - 3. Stick → handleMove (source=.djiRC)

    /// 좌 스틱 전방 max → bridge.handleMove(stride 양수). auto-start 가 march 진입.
    func testLeftStickForwardCallsHandleMoveWithDJIRCSource() {
        mock.sticks = DJIControllerStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        adapter.pollOnce()
        XCTAssertEqual(session.current, .march, "auto-start 발화 (bridge default)")
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9, "max forward stride")
        XCTAssertEqual(bridge.lastIntent?.source, .djiRC,
                       "source = .djiRC — 사이클 90 stub adapter wired")
        XCTAssertEqual(adapter.lastActionLabel, "stick move")
    }

    func testLeftStickBackwardNegativeStride() {
        session.start(.march)
        mock.sticks = DJIControllerStickState(leftX: 0, leftY: -1.0, rightX: 0, rightY: 0)
        adapter.pollOnce()
        XCTAssertEqual(session.strideMm, -40, accuracy: 1e-9, "max backward stride")
    }

    func testRightStickXCallsHandleMoveTurn() {
        session.start(.march)
        mock.sticks = DJIControllerStickState(leftX: 0, leftY: 0, rightX: 1.0, rightY: 0)
        adapter.pollOnce()
        // yaw=100 * 0.2 = 20.
        XCTAssertEqual(session.turnDeg, 20, accuracy: 1e-9)
    }

    /// stick zero (deadzone 진입) → 1회만 .stop 전달.
    func testStickStopFiresOnceWhenStickReturnsToZero() {
        session.start(.march)
        // 1) 움직임.
        mock.sticks = DJIControllerStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        adapter.pollOnce()
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9)

        // 2) Stick 놓음 → zero → .stop intent.
        mock.sticks = .neutral
        adapter.pollOnce()
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "stop hard-zero")
        XCTAssertEqual(adapter.lastActionLabel, "stick stop")
        XCTAssertEqual(bridge.lastIntent?.kind, .stop)
        XCTAssertEqual(bridge.lastIntent?.source, .djiRC, "stop intent 도 .djiRC source")
    }

    // MARK: - 4. Button → handleEmergency (source=.djiRC)

    func testReturnToHomeButtonCallsEmergency() {
        session.start(.march)
        XCTAssertEqual(bridge.emergencyCount, 0)

        mock.buttons.returnToHome = true
        adapter.pollOnce()

        XCTAssertEqual(bridge.emergencyCount, 1, "RTH → emergency 1회")
        XCTAssertEqual(session.current, .idle, "emergencyStop 효과")
        XCTAssertEqual(bridge.lastIntent?.source, .djiRC,
                       "emergency intent 의 source = .djiRC")
        XCTAssertEqual(adapter.lastActionLabel, "emergency (RTH / Home)")
    }

    /// 버튼 held 상태에서 두 frame 연속 polling → emergency 1회만 (edge trigger).
    func testEmergencyButtonHeldFiresOnceOnly() {
        session.start(.march)
        mock.buttons.returnToHome = true
        adapter.pollOnce()
        adapter.pollOnce()  // 같은 버튼 down 상태 — edge trigger 차단.
        XCTAssertEqual(bridge.emergencyCount, 1, "held 버튼 = 1회만 (edge trigger)")
    }

    /// emergency frame 의 stick → bridge.handleMove 까지 도달 안 함 (Gamepad 사이클 62 패턴).
    func testStickEmergencySameFrameNoMoveEventDispatched() {
        session.start(.march)
        let movesBefore = bridge.accumulator.summarize().moveEventCount

        // 사용자가 emergency + stick 동시 입력.
        mock.sticks = DJIControllerStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        mock.buttons.returnToHome = true
        adapter.pollOnce()

        let movesAfter = bridge.accumulator.summarize().moveEventCount

        // 핵심: moveEventCount 가 1 증가 안 함 — stick.move 가 dispatch 자체 안 됨.
        XCTAssertEqual(movesAfter, movesBefore,
                       "emergency frame 의 stick .move 가 accumulator 까지 도달 안 함")
        XCTAssertEqual(bridge.emergencyCount, 1, "emergency 는 정상 dispatch")
    }

    // MARK: - 5. Preset / Recovery 라우팅

    func testPauseButtonCallsPresetIdle() {
        session.start(.march)
        XCTAssertEqual(session.current, .march)

        mock.buttons.pause = true
        adapter.pollOnce()

        XCTAssertEqual(session.current, .idle, "Pause → preset.idle = stop")
        XCTAssertEqual(adapter.lastActionLabel, "preset idle (Pause)")
    }

    func testC1ButtonCallsRecovery() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive, "사전: emergency 활성")

        mock.buttons.customC1 = true
        adapter.pollOnce()

        XCTAssertFalse(session.emergencyStopActive, "C1 → recovery")
        XCTAssertEqual(adapter.lastActionLabel, "recovery (C1)")
    }

    // MARK: - 6. Bridge nil safety

    func testNilBridgeIsNoOp() {
        let orphan = DJIControllerAdapter(bridge: nil, source: mock)
        mock.sticks = DJIControllerStickState(leftX: 0, leftY: 1.0, rightX: 0, rightY: 0)
        mock.buttons.returnToHome = true
        // crash 안 함 — bridge nil 시 silent skip.
        orphan.pollOnce()
        XCTAssertNil(orphan.lastActionLabel, "bridge nil → adapter 부수효과 없음")
    }

    // MARK: - 7. djiRC 가 InputSource 의 정식 case (사이클 79 → 90 wiring)

    /// 사이클 79 placeholder 가 사이클 90 stub adapter 로 wiring 됨 — `.djiRC` 도 다른
    /// source 와 동일하게 bridge.lastIntent 에 surface.
    func testDJIRCInputSourceHasLabelAndIcon() {
        XCTAssertEqual(InputSource.djiRC.label, "DJI RC")
        XCTAssertEqual(InputSource.djiRC.icon, "antenna.radiowaves.left.and.right")
        XCTAssertEqual(InputSource.djiRC.rawValue, "djiRC")
    }
}

// MARK: - MockDJIController

/// **테스트 전용** — `DJIControllerInputSource` 의 manual 구현. stick / button 상태를
/// 테스트가 직접 enqueue 한 후 `pollOnce()` 호출로 adapter 가 읽음.
///
/// 향후 실 DJI Mobile SDK / Onboard SDK 통합 시 본 mock 은 그대로 유지 — production source
/// 와 평행 사용 (mock = 결정론적 테스트, production = 실 hardware).
@MainActor
final class MockDJIController: DJIControllerInputSource {
    var controllerName: String?
    var sticks: DJIControllerStickState
    var buttons: DJIControllerButtonState

    init(
        controllerName: String? = "MockDJIController",
        sticks: DJIControllerStickState = .neutral,
        buttons: DJIControllerButtonState = .init()
    ) {
        self.controllerName = controllerName
        self.sticks = sticks
        self.buttons = buttons
    }

    func snapshot() -> DJIControllerSnapshot {
        DJIControllerSnapshot(
            controllerName: controllerName,
            sticks: sticks,
            buttons: buttons
        )
    }
}
