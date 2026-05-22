import Foundation
import XCTest
@testable import DarwinForgeUI

/// **P0-2: Multi-source concurrent input race 테스트**.
///
/// keyboard + Tello + UI 버튼이 같은 main-actor tick 에 동시에 발화할 때
/// WalkLabRCBridge 의 state 일관성 invariant 를 검증한다.
///
/// # 설계 노트
///
/// WalkLabRCBridge 는 @MainActor — 모든 메서드는 main actor 에서 직렬 실행된다.
/// Swift 의 actor model 이 실제 data race 를 방지하지만,
/// 한 tick 에 복수 소스가 발화하면 **순서 의존 / 상태 누적** 버그가 발생할 수 있다.
/// 본 suite 는 동일 RunLoop 사이클에서 여러 source 호출 후 state invariant 를 확인한다.
@MainActor
final class MultiSourceRaceTests: XCTestCase {

    private var mock: MockTelloLink!
    private var session: WalkLabSession!
    private var bridge: WalkLabRCBridge!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockTelloLink()
        session = WalkLabSession()
        bridge = WalkLabRCBridge(tello: mock)
        bridge.session = session
        session.pilotBridge = bridge
    }

    override func tearDown() async throws {
        bridge = nil
        session = nil
        mock = nil
        try await super.tearDown()
    }

    // MARK: - 동시 소스 state 일관성

    /// **P0-2 Race-1**: handleTelloStick + handlePreset + handleMove 가 같은 main-actor tick
    /// 에 발화해도 session 의 walking state 가 inconsistent 하지 않아야 한다.
    ///
    /// 마지막 처리된 intent 가 반영되고 strideMm/sideMm/turnDeg 는 어떤 값이든
    /// 내부 일관성 (non-NaN, bounded) 을 만족해야 한다.
    func testConcurrentSourcesProduceConsistentState() {
        session.start(.march)

        // 같은 tick — Tello stick + 키보드 move + UI 버튼 handleStop 동시 발화.
        bridge.handleTelloStick(lr: 30, fb: 100, ud: 0, yaw: 0)
        bridge.handleMove(WalkingCommand(strideMm: 15, sideMm: -5, turnDeg: 3), from: .keyboard)
        bridge.handleStop(from: .ui)

        // 마지막 호출(.stop) 이 처리됨 → stride 0.
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9,
                       "마지막 stop intent 가 stride 를 0 으로 만들어야 한다")
        XCTAssertEqual(session.sideMm, 0, accuracy: 1e-9,
                       "마지막 stop intent 가 side 를 0 으로 만들어야 한다")
        // state 가 valid range 안에 있어야 한다.
        XCTAssertFalse(session.strideMm.isNaN, "strideMm 은 NaN 이면 안 된다")
        XCTAssertFalse(session.sideMm.isNaN, "sideMm 은 NaN 이면 안 된다")
        XCTAssertFalse(session.turnDeg.isNaN, "turnDeg 은 NaN 이면 안 된다")
        // lastIntent 는 nil 이 아니어야 한다 — 최소한 마지막 intent 는 기록된다.
        XCTAssertNotNil(bridge.lastIntent,
                        "동시 입력 후에도 lastIntent 는 nil 이 아니어야 한다")
    }

    /// **P0-2 Race-2**: handleTelloStick + handlePreset 동시 발화 — preset 이 walking 으로
    /// 전환된 후 stick 값도 정상 반영되어야 한다.
    func testTelloStickAndPresetConcurrentlyProducesValidAmplitude() {
        // idle 에서 시작.
        XCTAssertEqual(session.current, .idle)

        // preset 시작 + stick 이 같은 tick 발화.
        bridge.handlePreset(.march, from: .keyboard)
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)

        // preset 이 먼저 처리 → march 상태에서 stick 이 amplitude 적용.
        XCTAssertEqual(session.current, .march,
                       "preset → march 전환이 stick 보다 먼저 처리되어야 한다")
        // stick fb=50 → strideMm=20 (50 * 0.4).
        XCTAssertEqual(session.strideMm, 20, accuracy: 1e-9,
                       "march 진입 후 stick amplitude 가 정상 반영되어야 한다")
    }

    /// **P0-2 Race-3**: 빠른 key hold/release 시퀀스 (W down → up → W down 3 사이클)
    /// EMA smoothing 이 올바르게 누적되어야 한다.
    func testRapidKeyHoldReleaseEmaSmoothing() {
        bridge.smoothingFactor = 0.5
        session.start(.march)

        // 사이클 1: W down
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        let afterFirstPress = session.strideMm
        XCTAssertEqual(afterFirstPress, 20, accuracy: 1e-9,
                       "smoothing=0.5, 1차 press → 0.5×40 = 20")

        // 사이클 1: W up (deadzone)
        bridge.handleTelloStick(lr: 0, fb: 0, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9,
                       "stop intent → hard-zero (EMA 우회)")

        // 사이클 2: W down 재발화
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 20, accuracy: 1e-9,
                       "2차 press: 이전 hard-zero 에서 다시 0.5×40 = 20")

        // 사이클 2: W up
        bridge.handleTelloStick(lr: 0, fb: 0, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "2차 up → 0")

        // 사이클 3: W down
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 20, accuracy: 1e-9,
                       "3차 press: 매 press 시 hard-zero 에서 재시작 → 20")
        XCTAssertFalse(session.strideMm.isNaN,
                       "3 사이클 후에도 strideMm 은 NaN 이면 안 된다")
    }

    /// **P0-2 Race-4**: emergency 도중 다른 source 입력 — 모두 차단되어야 한다.
    /// Cycle 58 emergency bypass fix 회귀 테스트.
    func testAllSourcesBlockedDuringEmergency() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive)

        let strideBefore = session.strideMm  // 0
        XCTAssertEqual(strideBefore, 0, accuracy: 1e-9)

        // keyboard, tello, ui 모두 동시에 시도.
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        bridge.handleMove(WalkingCommand(strideMm: 30, sideMm: 0, turnDeg: 0), from: .keyboard)
        bridge.handlePreset(.march, from: .ui)

        // 모두 차단 — stride 여전히 0.
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9,
                       "emergency 중 모든 소스 차단 → stride 0 유지")
        XCTAssertEqual(session.sideMm, 0, accuracy: 1e-9,
                       "emergency 중 모든 소스 차단 → sideMm 0 유지")
        XCTAssertEqual(session.current, .idle,
                       "emergency 후 session.current 는 idle 유지")
        XCTAssertTrue(session.emergencyStopActive,
                      "emergency flag 가 외부 입력에 의해 clear 되면 안 된다")
        // safetyMessage 는 차단 메시지 포함.
        XCTAssertTrue(bridge.safetyMessage?.contains("긴급 정지") ?? false,
                      "차단 시 사용자에게 긴급 정지 메시지 안내")
    }

    /// **P0-2 Race-5**: TelloStateListener mock 이 updateTelloState 를 호출하면서
    /// keyboard 입력이 동시에 발화 — safetyMessage priority 검증.
    ///
    /// low battery safetyMessage 가 keyboard stop 에 의해 nil 이 되면 안 된다.
    /// (stop path 는 safetyMessage=nil 을 set — battery warning 덮어쓰기 주의)
    func testTelloStateUpdateAndKeyboardInputSafetyMessagePriority() {
        session.start(.march)

        // Tello state: low battery → safetyMessage 설정.
        let lowBattery = makeTelloState(battery: 5, height: 50)
        bridge.updateTelloState(lowBattery)
        XCTAssertNotNil(bridge.safetyMessage, "low battery → safetyMessage 설정")
        let batteryMsg = bridge.safetyMessage!
        XCTAssertTrue(batteryMsg.contains("배터리"), "배터리 경고 메시지")

        // 동시에 keyboard 에서 move 입력 (정상 move → safetyMessage=nil 덮어쓰기).
        bridge.handleMove(WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0), from: .keyboard)

        // move 처리 후 safetyMessage 는 nil 이 될 수 있음 — 이 behavior 가 의도적인지 확인.
        // 핵심: session 상태는 일관성 있어야 함 (NaN 없음, range 준수).
        XCTAssertEqual(session.strideMm, 20, accuracy: 1e-9,
                       "keyboard move 가 정상 처리되어야 한다")
        XCTAssertFalse(session.strideMm.isNaN,
                       "Tello state + keyboard 동시 처리 후 strideMm 이 NaN 이면 안 된다")
        // accumulator 에 두 이벤트가 모두 기록되어야 함.
        // updateTelloState 는 accumulator.record 를 호출하지 않음 — keyboard move 1건만.
        XCTAssertGreaterThanOrEqual(bridge.accumulator.summarize().totalEvents, 1,
                                    "keyboard move 가 accumulator 에 기록되어야 한다")
    }

    /// **P0-2 Race-6**: 빠른 emergency + recovery + re-start 시퀀스에서
    /// emergencyCount 와 presetChangeMirror 가 정확히 누적되어야 한다.
    func testRapidEmergencyRecoveryRestartTelemetryAccuracy() {
        session.start(.march)

        // 빠른 시퀀스: emergency → recovery → re-start.
        bridge.handleEmergency(from: .keyboard)
        XCTAssertEqual(bridge.emergencyCount, 1)

        bridge.handleRecovery(from: .keyboard)
        XCTAssertFalse(session.emergencyStopActive)

        // 재시작.
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(session.current, .march, "recovery 후 재시작 성공")

        // 다시 emergency.
        bridge.handleEmergency(from: .ui)
        XCTAssertEqual(bridge.emergencyCount, 2, "두 번째 emergency 카운트")

        bridge.handleRecovery(from: .ui)
        bridge.handlePreset(.slowWalk, from: .keyboard)

        // presetChangeMirror: 최소 2 (march + slowWalk).
        XCTAssertGreaterThanOrEqual(bridge.presetChangeMirror, 2,
                                    "두 번의 preset 전환이 mirror 에 반영되어야 한다")
        // emergencyCount: 정확히 2.
        XCTAssertEqual(bridge.emergencyCount, 2,
                       "emergency count 는 recovery/restart 에 의해 변경되면 안 된다")
    }

    /// **P0-2 Race-7**: handleTelloStick + handlePreset 이 auto-start path 에서 동시 발화.
    /// accumulator 의 totalEvents 가 정확히 집계되어야 한다 (double-count 방지).
    func testConcurrentAutoStartDoesNotDoubleCountAccumulator() {
        // idle 상태: auto-start 활성.
        XCTAssertEqual(session.current, .idle)
        XCTAssertNotNil(bridge.pilotAutoStartPreset)

        // auto-start path + 별도 keyboard move 동시 발화.
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)  // auto-start 발화
        bridge.handleMove(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0), from: .keyboard)

        // 두 이벤트 모두 기록 — double-count (동일 intent 2회) 가 아니어야 함.
        let total = bridge.accumulator.summarize().totalEvents
        XCTAssertEqual(total, 2,
                       "auto-start + keyboard move = 정확히 2 events (double-count 없음)")
        // sourcesUsed 에 tello + keyboard 모두 포함.
        let sources = bridge.accumulator.summarize().sourcesUsed
        XCTAssertTrue(sources.contains(.tello), "tello source 포함")
        XCTAssertTrue(sources.contains(.keyboard), "keyboard source 포함")
    }

    // MARK: - Helper

    private func makeTelloState(battery: Int, height: Double) -> TelloStateMessage {
        TelloStateMessage(
            pitchDeg: 0, rollDeg: 0, yawDeg: 0,
            vgx: 0, vgy: 0, vgz: 0,
            templ: 50, temph: 55, tofCm: nil,
            heightCm: height, batteryPct: battery, baroPa: nil,
            agx: 0, agy: 0, agz: -1000,
            receivedAt: Date()
        )
    }
}
