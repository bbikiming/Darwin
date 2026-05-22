import Foundation
import XCTest
@testable import DarwinForgeUI

/// **WalkLabRCBridge stick/deadzone/smoothing 단위 테스트**.
///
/// 범위: handleTelloStick / handleMove / EMA smoothing / amplitude 매핑.
/// hardware 없이 MockTelloLink + WalkLabSession 으로 end-to-end 검증.
@MainActor
final class WalkLabRCBridgeStickTests: XCTestCase {

    private var mock: MockTelloLink!
    private var session: WalkLabSession!
    private var bridge: WalkLabRCBridge!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockTelloLink()
        session = WalkLabSession()
        bridge = WalkLabRCBridge(tello: mock)
        bridge.session = session
    }

    override func tearDown() async throws {
        bridge = nil
        session = nil
        mock = nil
        try await super.tearDown()
    }

    // MARK: - 기본 stick → amplitude

    func testStickFullForwardAppliesMaxStride() {
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)

        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9)
        XCTAssertEqual(session.sideMm, 0, accuracy: 1e-9)
        XCTAssertEqual(session.turnDeg, 0, accuracy: 1e-9)
        XCTAssertNotNil(bridge.lastIntent)
        XCTAssertEqual(bridge.lastIntent?.source, .tello)
    }

    func testStickDeadzoneStops() {
        session.start(.march)
        session.strideMm = 25
        bridge.handleTelloStick(lr: 2, fb: -3, ud: 0, yaw: 1)

        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9)
        XCTAssertEqual(bridge.lastIntent?.kind, .stop)
    }

    func testKeyboardSourceProcessed() {
        session.start(.march)
        let cmd = WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0)
        bridge.handleMove(cmd, from: .keyboard)
        XCTAssertEqual(session.strideMm, 20, accuracy: 1e-9)
        XCTAssertEqual(bridge.lastIntent?.source, .keyboard)
    }

    func testApplyAmplitudeAutoEnablesAdvanced() {
        XCTAssertFalse(session.advanced, "사전: advanced=false")
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        XCTAssertTrue(session.advanced, "pilot move 후 advanced=true 자동 활성")
    }

    func testStickIgnoredWhenDisabled() {
        session.start(.march)
        bridge.enabled = false
        let strideBefore = session.strideMm
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, strideBefore, accuracy: 1e-9, "disabled stride 미변경")
        XCTAssertTrue(bridge.safetyMessage?.contains("Bridge 비활성") ?? false)
    }

    // MARK: - Idle guard / auto-start

    func testStickInputIgnoredWhenIdleAndAutoStartDisabled() {
        bridge.pilotAutoStartPreset = nil
        bridge.handleTelloStick(lr: 50, fb: 50, ud: 0, yaw: 0)

        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "idle + auto-start off → stride 미변경")
        XCTAssertEqual(session.current, .idle, "session 도 idle 유지")
        XCTAssertNotNil(bridge.safetyMessage)
        XCTAssertTrue(bridge.safetyMessage?.contains("preset 먼저 선택") ?? false,
                      "기존 안전 메시지 보존")
    }

    func testAutoStartPresetOnIdleMoveInput() {
        session.pilotBridge = bridge
        XCTAssertEqual(session.current, .idle, "사전: idle")
        XCTAssertEqual(bridge.pilotAutoStartPreset, .march, "default auto-start preset = .march")

        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)

        XCTAssertEqual(session.current, .march, "auto-start 발화 → preset 진입")
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9, "auto-start 후 amplitude 적용")
        let summary = bridge.accumulator.summarize()
        XCTAssertEqual(summary.totalEvents, 1, "auto-start triggering intent 가 새 trial 의 첫 event")
    }

    func testAutoStartBlockedByPreflightFailure() {
        session.pilotBridge = bridge
        bridge.pilotAutoStartPreset = .jog
        XCTAssertFalse(session.riskAcknowledged, "사전: risk 미동의")

        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)

        XCTAssertEqual(session.current, .idle, "preflight 차단 → idle 유지")
        XCTAssertNotNil(bridge.safetyMessage)
        XCTAssertTrue(bridge.safetyMessage?.contains("Auto-start") ?? false,
                      "auto-start 차단 안전 메시지")
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "amplitude 미적용")
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 1,
                       "차단 path 도 사용자 입력 1회 기록")
    }

    func testAutoStartDoesNotFireOnStopIntent() {
        bridge.handleTelloStick(lr: 2, fb: 1, ud: 0, yaw: 1)
        XCTAssertEqual(session.current, .idle, "stop intent → auto-start skip")
        XCTAssertNotNil(bridge.safetyMessage, "기존 idle 안전 메시지")
    }

    func testAutoStartIncrementsPresetChangeMirror() {
        session.pilotBridge = bridge
        XCTAssertEqual(bridge.presetChangeMirror, 0)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.current, .march)
        XCTAssertEqual(bridge.presetChangeMirror, 1, "auto-start = preset transition")
    }

    // MARK: - Smoothing (EMA)

    func testSmoothingFactorDefaultIsImmediate() {
        XCTAssertEqual(bridge.smoothingFactor, 1.0, "default backward-compat")
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9, "default 1.0 → 즉시 max")
    }

    func testSmoothingFactorHalfBlend() {
        bridge.smoothingFactor = 0.5
        session.start(.march)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "사전 0")
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 20, accuracy: 1e-9, "0.5 × 40 + 0.5 × 0 = 20")
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 30, accuracy: 1e-9, "0.5 × 40 + 0.5 × 20 = 30")
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 35, accuracy: 1e-9, "0.5 × 40 + 0.5 × 30 = 35")
    }

    func testSmoothingRampUpThenStopHardZeros() {
        bridge.smoothingFactor = 0.5
        session.start(.march)
        for _ in 0..<5 {
            bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        }
        XCTAssertEqual(session.strideMm, 38.75, accuracy: 0.01, "5 EMA ramp")
        bridge.handleTelloStick(lr: 0, fb: 0, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "stop hard-zero")
    }

    // MARK: - Full pipeline

    func testFullPilotPipelineReachesEffectiveCommand() {
        session.start(.march)
        XCTAssertEqual(session.current, .march)
        XCTAssertFalse(session.advanced, "사전: advanced=false")

        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)

        XCTAssertTrue(session.advanced, "advanced 자동 활성 (CRITICAL fix)")
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9, "strideMm 적용")
        let cmd = session.effectiveCommand
        XCTAssertEqual(cmd.x, 0.040, accuracy: 1e-9, "x_m = strideMm/1000")
        XCTAssertEqual(cmd.y, 0, accuracy: 1e-9)
        XCTAssertEqual(cmd.a, 0, accuracy: 1e-9)
        XCTAssertTrue(cmd.enabled, "current != .idle → enabled true")
    }

    func testFullPilotPipelineStopReachesEffectiveCommand() {
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertGreaterThan(session.effectiveCommand.x, 0)

        bridge.handleTelloStick(lr: 0, fb: 0, ud: 0, yaw: 0)

        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "stop hard-zero")
        XCTAssertEqual(session.effectiveCommand.x, 0, accuracy: 1e-9,
                       "effectiveCommand 도 zero — robot 실 정지")
    }

    // MARK: - Bridge defaults / metrics

    func testBridgeDefaultValues() {
        XCTAssertTrue(bridge.enabled, "default enabled=true")
        XCTAssertEqual(bridge.scale, .default, "default scale = Tello default")
        XCTAssertEqual(bridge.smoothingFactor, 1.0, "default smoothingFactor=1.0")
        XCTAssertEqual(bridge.pilotAutoStartPreset, .march, "default auto-start=.march")
        XCTAssertEqual(bridge.emergencyCount, 0)
        XCTAssertEqual(bridge.presetChangeMirror, 0)
        XCTAssertNil(bridge.lastIntent)
        XCTAssertNil(bridge.safetyMessage)
        XCTAssertFalse(bridge.isActive)
        XCTAssertFalse(bridge.isInputFresh)
    }

    func testBridgeLastInputTracking() {
        XCTAssertNil(bridge.lastInputAt)
        XCTAssertNil(bridge.lastInputAge)
        bridge.handleStop(from: .keyboard)
        XCTAssertNotNil(bridge.lastInputAt)
        XCTAssertNotNil(bridge.lastInputAge)
        XCTAssertLessThan(bridge.lastInputAge!, 1.0, "방금 — 1초 미만")
    }

    func testBridgeActivityRateAfterRecord() {
        session.start(.march)
        XCTAssertEqual(bridge.activityRate, 0, accuracy: 0.01, "사전: 0")
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 30, fb: 0, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertGreaterThanOrEqual(bridge.activityRate, 2.5, "3개 입력 직후 rate ~3")
    }

    func testBridgeIsActiveThreshold() {
        session.start(.march)
        XCTAssertFalse(bridge.isActive, "사전: 입력 없음 → inactive")
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        XCTAssertTrue(bridge.isActive, "1 event > 0.5 threshold → active")
    }

    func testHandleStopIdempotent() {
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9)
        bridge.handleStop(from: .keyboard)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "1차 stop")
        bridge.handleStop(from: .keyboard)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "2차 stop idempotent")
        bridge.handleStop(from: .keyboard)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "3차 stop idempotent")
    }

    func testBridgeDisableHardZerosAmplitude() {
        session.pilotBridge = bridge
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9, "사전: amplitude 적용")

        bridge.enabled = false

        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9,
                       "disable → hard-zero (안전 invariant)")
        XCTAssertNotNil(bridge.safetyMessage)
    }

    // MARK: - Tello state forwarding

    func testUpdateTelloStateStoresLastMessage() {
        XCTAssertNil(bridge.lastTelloState, "사전: nil")
        let msg = makeTelloState(battery: 75, height: 100)
        bridge.updateTelloState(msg)
        XCTAssertEqual(bridge.lastTelloState?.batteryPct, 75)
        XCTAssertEqual(bridge.lastTelloState?.heightCm, 100)
    }

    func testUpdateTelloStateLowBatteryWarning() {
        let msg = makeTelloState(battery: 10, height: 50)
        bridge.updateTelloState(msg)
        XCTAssertNotNil(bridge.safetyMessage)
        XCTAssertTrue(bridge.safetyMessage?.contains("배터리") ?? false,
                      "low battery safety 메시지")
    }

    func testUpdateTelloStateNormalBatteryNoWarning() {
        let msg = makeTelloState(battery: 80, height: 0)
        bridge.updateTelloState(msg)
        XCTAssertNil(bridge.safetyMessage, "normal battery — message 없음")
    }

    // MARK: - Helpers

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
