import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.17.0 (2026-05-21) Phase 4 — WalkLabRCBridge 통합 테스트**.
///
/// MockTelloLink + WalkLabSession 으로 stick → session.strideMm 까지 end-to-end 검증.
/// 실 hardware (Tello / robot bus) 없이 코드 단 논리 만 검증.
@MainActor
final class WalkLabRCBridgeTests: XCTestCase {

    private var mock: MockTelloLink!
    private var session: WalkLabSession!
    private var bridge: WalkLabRCBridge!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockTelloLink()
        session = WalkLabSession()
        bridge = WalkLabRCBridge(tello: mock)
        bridge.session = session
        // **v1.20.3 사이클 9** — `session.pilotBridge` 는 각 테스트가 필요 시 명시 wiring.
        // setUp 에서 일률 wiring 하면 session.emergencyStop / finalize 가 bridge.accumulator
        // 를 reset 해 종전 테스트 (testAccumulatorRecordsAllIntents 등) 의 semantic 깨짐.
    }

    override func tearDown() async throws {
        bridge = nil
        session = nil
        mock = nil
        try await super.tearDown()
    }

    // MARK: - 기본 stick → amplitude

    func testStickFullForwardAppliesMaxStride() {
        // session 보행 중이어야 stick 입력이 amplitude 적용.
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)

        // 100 * 0.4 = 40 (clamp 한도 — TelloRCMapper).
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9)
        XCTAssertEqual(session.sideMm, 0, accuracy: 1e-9)
        XCTAssertEqual(session.turnDeg, 0, accuracy: 1e-9)
        XCTAssertNotNil(bridge.lastIntent)
        XCTAssertEqual(bridge.lastIntent?.source, .tello)
    }

    func testStickDeadzoneStops() {
        session.start(.march)
        // 보행 시작 stride 0.
        session.strideMm = 25
        bridge.handleTelloStick(lr: 2, fb: -3, ud: 0, yaw: 1)

        // deadzone — TelloRCMapper.map 결과 isStop → applyAmplitude(.stop).
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9)
        XCTAssertEqual(bridge.lastIntent?.kind, .stop)
    }

    // MARK: - Idle guard

    /// **v1.20.3 사이클 9** — auto-start 비활성 시 종전 behavior 유지.
    /// `pilotAutoStartPreset = nil` 시 idle 입력은 거부.
    func testStickInputIgnoredWhenIdleAndAutoStartDisabled() {
        bridge.pilotAutoStartPreset = nil  // auto-start 비활성.
        bridge.handleTelloStick(lr: 50, fb: 50, ud: 0, yaw: 0)

        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "idle + auto-start off → stride 미변경")
        XCTAssertEqual(session.current, .idle, "session 도 idle 유지")
        XCTAssertNotNil(bridge.safetyMessage)
        XCTAssertTrue(bridge.safetyMessage?.contains("preset 먼저 선택") ?? false,
                      "기존 안전 메시지 보존")
    }

    /// **v1.20.3 사이클 9** — auto-start 활성 (default) 시 idle 에서 첫 move 입력으로 즉시 시작.
    /// 게임 캐릭터처럼 W 키 → 보행 시작. preflight 는 session.start 가 그대로 수행.
    func testAutoStartPresetOnIdleMoveInput() {
        // production wiring 재현 — 본 path 는 session.pilotBridge 가 set 일 때 정확.
        session.pilotBridge = bridge
        // 사전 조건: bridge.pilotAutoStartPreset = .march (default)
        XCTAssertEqual(session.current, .idle, "사전: idle")
        XCTAssertEqual(bridge.pilotAutoStartPreset, .march, "default auto-start preset = .march")

        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)

        XCTAssertEqual(session.current, .march, "auto-start 발화 → preset 진입")
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9, "auto-start 후 amplitude 적용")
        // accumulator: capture 시 reset 후 재기록 → 1 event.
        let summary = bridge.accumulator.summarize()
        XCTAssertEqual(summary.totalEvents, 1, "auto-start triggering intent 가 새 trial 의 첫 event")
    }

    /// **v1.20.3.1 사이클 9-fix LOW 2 (코덱스)** — auto-start 가 preflight 실패 시 idle 유지 + 안전 메시지.
    /// .jog 는 highRisk preset → riskAcknowledged=false 면 preflight 차단.
    func testAutoStartBlockedByPreflightFailure() {
        session.pilotBridge = bridge
        // riskAcknowledged 기본 false. .jog auto-start → preflight 차단 예상.
        bridge.pilotAutoStartPreset = .jog
        XCTAssertFalse(session.riskAcknowledged, "사전: risk 미동의")

        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)

        XCTAssertEqual(session.current, .idle, "preflight 차단 → idle 유지")
        XCTAssertNotNil(bridge.safetyMessage)
        XCTAssertTrue(bridge.safetyMessage?.contains("Auto-start") ?? false,
                      "auto-start 차단 안전 메시지")
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "amplitude 미적용")
        // accumulator: 본 차단 path 에서 1회 record (사용자 의도 telemetry).
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 1,
                       "차단 path 도 사용자 입력 1회 기록")
    }

    // MARK: - Cycle 10: handlePreset (number key shortcuts)

    /// **v1.20.4 사이클 10** — handlePreset 이 idle 상태에서 march 시작.
    func testHandlePresetStartsWalking() {
        XCTAssertEqual(session.current, .idle)
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(session.current, .march, "preset 시작 성공")
        XCTAssertNil(bridge.safetyMessage)
    }

    /// **v1.20.4 사이클 10** — handlePreset(.idle) = session.stop 효과.
    func testHandlePresetIdleStopsWalking() {
        session.start(.march)
        XCTAssertEqual(session.current, .march)
        bridge.handlePreset(.idle, from: .keyboard)
        XCTAssertEqual(session.current, .idle, ".idle preset → session.stop")
    }

    /// **v1.20.4 사이클 10** — preflight 실패 시 (jog + risk 미동의) safety message.
    /// **사이클 10-fix MEDIUM 1**: 진단 코드 → userMessage. .jog 의 highRisk userMessage 에 "위험" 포함.
    func testHandlePresetBlockedByPreflight() {
        XCTAssertFalse(session.riskAcknowledged)
        bridge.handlePreset(.jog, from: .keyboard)
        XCTAssertEqual(session.current, .idle, "preflight 차단 → idle 유지")
        XCTAssertNotNil(bridge.safetyMessage)
        XCTAssertTrue(bridge.safetyMessage?.contains("위험") ?? false,
                      "highRiskNotAcknowledged userMessage 노출 (\"위험 동의 필요\")")
    }

    /// **v1.20.16 사이클 22 + 23-fix MEDIUM 1** — handlePreset 호출이 accumulator.presetChangeCount 증가.
    /// production wiring 에서 각 session.start 마다 trial reset → accumulator count 가 trial 단위.
    /// 누적 count 는 bridge.presetChangeMirror 가 보존 (cycle 23-fix MEDIUM 2).
    func testHandlePresetIncrementsPresetChangeCount() {
        session.pilotBridge = bridge
        XCTAssertEqual(bridge.accumulator.summarize().presetChangeCount, 0)
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(bridge.accumulator.summarize().presetChangeCount, 1,
                       "march 시작 trial 의 첫 preset = 1")
        // .slowWalk 으로 전환 시 sim 모드에서 새 trial 시작 (preflight 통과) → accumulator reset.
        bridge.handlePreset(.slowWalk, from: .keyboard)
        XCTAssertEqual(bridge.accumulator.summarize().presetChangeCount, 1,
                       "slowWalk 새 trial 의 첫 preset = 1 (reset 후 re-record)")
        XCTAssertTrue(bridge.accumulator.summarize().sourcesUsed.contains(.keyboard))
    }

    /// **v1.20.17.1 사이클 23-fix MEDIUM 1 (코덱스)** — pilotBridge wiring 상태에서
    /// handlePreset 가 session.start 호출 후 accumulator.reset 으로 count 가 0 되지 않음.
    /// re-record 가 보존.
    func testHandlePresetCountPreservedAfterSessionStartResets() {
        session.pilotBridge = bridge  // production wiring 재현.
        bridge.handlePreset(.march, from: .keyboard)
        // 성공 path 통과 후 (session.current = .march) accumulator 가 reset 됐다가 재기록.
        XCTAssertEqual(session.current, .march)
        XCTAssertEqual(bridge.accumulator.summarize().presetChangeCount, 1,
                       "session.start reset 후 re-record (사이클 23-fix MEDIUM 1)")
    }

    /// **v1.20.29 사이클 35** — auto-start (process .move auto-start path) 도 presetChangeMirror 증가.
    func testAutoStartIncrementsPresetChangeMirror() {
        session.pilotBridge = bridge  // production wiring.
        XCTAssertEqual(bridge.presetChangeMirror, 0)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)  // auto-start
        XCTAssertEqual(session.current, .march)
        XCTAssertEqual(bridge.presetChangeMirror, 1, "auto-start = preset transition")
    }

    /// **v1.20.17.1 사이클 23-fix MEDIUM 2 (코덱스)** — observable mirror 증가.
    func testHandlePresetIncrementsObservableMirror() {
        XCTAssertEqual(bridge.presetChangeMirror, 0)
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(bridge.presetChangeMirror, 1, "observable mirror 증가")
        bridge.handlePreset(.slowWalk, from: .keyboard)
        XCTAssertEqual(bridge.presetChangeMirror, 2)
        // 차이점: mirror 는 reset 영향 안 받음 — bridge lifetime.
    }

    /// **v1.20.17.1 사이클 23-fix HIGH (코덱스)** — legacy PilotInputSummary JSON 디코딩.
    /// 기존 trial JSON (presetChangeCount, moveEventCount, peakNeg* 미포함) 도 fallback 0.
    func testPilotInputSummaryDecodesLegacyJSON() throws {
        let legacyJSON = """
        {
            "sourcesUsed": ["keyboard"],
            "totalEvents": 5,
            "avgAbsStrideMm": 10.0,
            "avgAbsSideMm": 0.0,
            "avgAbsTurnDeg": 0.0,
            "peakStrideMm": 20.0,
            "peakSideMm": 0.0,
            "peakTurnDeg": 0.0,
            "emergencyTriggered": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PilotInputSummary.self, from: legacyJSON)
        XCTAssertEqual(decoded.totalEvents, 5)
        XCTAssertEqual(decoded.moveEventCount, 0, "legacy missing → 0 default")
        XCTAssertEqual(decoded.peakNegStrideMm, 0)
        XCTAssertEqual(decoded.presetChangeCount, 0, "legacy missing → 0 default")
    }

    /// **v1.20.4 사이클 10** — bridge 비활성 시 preset 단축키 무시.
    func testHandlePresetIgnoredWhenDisabled() {
        bridge.enabled = false
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(session.current, .idle, "disabled bridge → preset 무시")
        XCTAssertTrue(bridge.safetyMessage?.contains("비활성") ?? false)
    }

    // MARK: - Cycle 20: smoothing factor

    /// **v1.20.14 사이클 20** — smoothingFactor=1.0 (default) → 종전 동작 (즉시 반영).
    func testSmoothingFactorDefaultIsImmediate() {
        XCTAssertEqual(bridge.smoothingFactor, 1.0, "default backward-compat")
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9, "default 1.0 → 즉시 max")
    }

    /// **v1.20.14 사이클 20** — smoothingFactor=0.5 → 단일 call 에 50% blend.
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

    /// **v1.20.14 사이클 20 + 20-fix LOW** — ramp-up 후 .stop 명시 호출 시 hard-zero 도달.
    /// **사이클 20-fix HIGH 1**: deadzone (.stop) 은 EMA 우회 — 진정한 0.
    func testSmoothingRampUpThenStopHardZeros() {
        bridge.smoothingFactor = 0.5
        session.start(.march)
        // 5 ramp = 0 → 38.75 (코덱스 정확 수치).
        for _ in 0..<5 {
            bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        }
        XCTAssertEqual(session.strideMm, 38.75, accuracy: 0.01, "5 EMA ramp")
        // deadzone → .stop intent → hard-zero (사이클 20-fix HIGH 1).
        bridge.handleTelloStick(lr: 0, fb: 0, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "stop hard-zero")
    }

    /// **v1.20.14.1 사이클 20-fix HIGH 2 (코덱스)** — emergencyStop 이 strideMm 등 zero.
    func testEmergencyStopZerosAmplitudeFields() {
        bridge.smoothingFactor = 0.5
        session.start(.march)
        for _ in 0..<5 {
            bridge.handleTelloStick(lr: 25, fb: 100, ud: 0, yaw: 50)
        }
        XCTAssertGreaterThan(session.strideMm, 10, "사전: amplitude 잔재")

        bridge.handleEmergency(from: .ui)

        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "emergency 후 stride 0")
        XCTAssertEqual(session.sideMm, 0, accuracy: 1e-9, "emergency 후 side 0")
        XCTAssertEqual(session.turnDeg, 0, accuracy: 1e-9, "emergency 후 turn 0")
    }

    /// **v1.20.21 사이클 27** — full pilot pipeline 통합 검증.
    /// handleTelloStick → applyAmplitude → advanced=true → effectiveCommand 까지 일관성.
    /// effectiveCommand 가 walking engine 의 실 입력값 — 본 path 가 정확하면 robot 도 정확.
    func testFullPilotPipelineReachesEffectiveCommand() {
        session.start(.march)
        XCTAssertEqual(session.current, .march)
        XCTAssertFalse(session.advanced, "사전: advanced=false")

        // 100% forward stick → strideMm 40 (TelloRCMapper default).
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)

        // 1. session 상태 검증.
        XCTAssertTrue(session.advanced, "advanced 자동 활성 (CRITICAL fix)")
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9, "strideMm 적용")
        // 2. effectiveCommand 검증 — walking engine 이 실제로 받는 값.
        let cmd = session.effectiveCommand
        XCTAssertEqual(cmd.x, 0.040, accuracy: 1e-9, "x_m = strideMm/1000")
        XCTAssertEqual(cmd.y, 0, accuracy: 1e-9)
        XCTAssertEqual(cmd.a, 0, accuracy: 1e-9)
        XCTAssertTrue(cmd.enabled, "current != .idle → enabled true")
    }

    /// **v1.20.21 사이클 27** — pipeline 종료 path (.stop hard-zero) effectiveCommand reflect.
    func testFullPilotPipelineStopReachesEffectiveCommand() {
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertGreaterThan(session.effectiveCommand.x, 0)

        // Release — deadzone (.stop intent) → hard-zero.
        bridge.handleTelloStick(lr: 0, fb: 0, ud: 0, yaw: 0)

        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "stop hard-zero")
        XCTAssertEqual(session.effectiveCommand.x, 0, accuracy: 1e-9,
                       "effectiveCommand 도 zero — robot 실 정지")
    }

    /// **v1.20.14.1 사이클 20-fix CRITICAL (코덱스)** — applyAmplitude 가 advanced=true 자동 활성.
    /// 종전: bridge 가 strideMm 만 수정, advanced=false 면 walking engine preset default 사용.
    /// 신규: 첫 move intent 시 session.advanced=true 활성 → 실 walking 에 반영.
    func testApplyAmplitudeAutoEnablesAdvanced() {
        XCTAssertFalse(session.advanced, "사전: advanced=false")
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        XCTAssertTrue(session.advanced, "pilot move 후 advanced=true 자동 활성")
    }

    /// **v1.20.41 사이클 55** — bridge.snapshotAndReset 후 모든 통계 zero.
    func testSnapshotAndResetClearsAllStats() {
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 25, fb: 0, ud: 0, yaw: 0)
        XCTAssertGreaterThan(bridge.accumulator.summarize().totalEvents, 0)
        XCTAssertGreaterThan(bridge.accumulator.summarize().peakStrideMm, 0)

        let snap = bridge.snapshotAndReset()

        XCTAssertGreaterThan(snap.totalEvents, 0, "snapshot 자체는 정보 보존")
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 0, "reset 후 0")
        XCTAssertEqual(bridge.accumulator.summarize().peakStrideMm, 0)
    }

    /// **v1.20.40 사이클 54** — bridge default 값 검증 (회귀 가드).
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

    /// **v1.20.39 사이클 53** — emergencyCount 누적 검증.
    func testEmergencyCountAccumulates() {
        XCTAssertEqual(bridge.emergencyCount, 0)
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertEqual(bridge.emergencyCount, 1)
        bridge.handleRecovery(from: .ui)
        session.start(.march)
        bridge.handleEmergency(from: .keyboard)
        XCTAssertEqual(bridge.emergencyCount, 2, "두 번째 emergency 카운트")
    }

    /// **v1.20.37 사이클 49** — handleStop 반복 호출 idempotent.
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

    /// **v1.20.33 사이클 41** — lastInputAt + lastInputAge.
    func testBridgeLastInputTracking() {
        XCTAssertNil(bridge.lastInputAt)
        XCTAssertNil(bridge.lastInputAge)
        bridge.handleStop(from: .keyboard)
        XCTAssertNotNil(bridge.lastInputAt)
        XCTAssertNotNil(bridge.lastInputAge)
        XCTAssertLessThan(bridge.lastInputAge!, 1.0, "방금 — 1초 미만")
    }

    /// **v1.20.31 사이클 39** — bridge.enabled=false 토글 시 stride hard-zero.
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

    // MARK: - Cycle 33: End-to-end happy path

    /// **v1.20.27 사이클 33** — 사용자 시뮬: 전 cycle 의 piece 가 통합 작동.
    /// 1. session.pilotBridge wire (production wiring)
    /// 2. W 키 (forward) → auto-start march + advanced=true + EMA blend
    /// 3. 2 (preset 단축키) → slowWalk 전환
    /// 4. Space (emergency) → emergencyStopActive=true + 즉시 stop
    /// 5. R (recovery) → emergency flag clear
    /// 6. trial 종료 → pilotInputs auto-attached
    func testEndToEndPilotFlowHappyPath() async {
        session.pilotBridge = bridge
        // bridge.smoothingFactor=1.0 (default) — 빠른 검증 위해 EMA 우회.

        // 1. W = forward 100 → auto-start march.
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.current, .march, "auto-start 발화")
        XCTAssertTrue(session.advanced, "advanced 자동 활성 (Cycle 20-fix)")
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9, "amplitude 적용")

        // 2. preset 단축키 2 → slowWalk.
        // 주의: 첫 trial 의 march 가 walk cycle 동작하지 않은 (bus 없음) 상태에서 .slowWalk 호출.
        // session.start 가 새 trial 시작. sim 모드에서는 isRobotWalking=false → 통과.
        bridge.handlePreset(.slowWalk, from: .keyboard)
        // **참고**: handlePreset 가 same-preset (.march→.march) idempotent. 다른 preset 은 transition.
        // 그러나 sim 모드에서 advanced=true 상태로 session.start 호출 시 일부 path 가 다를 수 있어
        // 우선 .march 유지 가능성도 인정 — 정확 동작은 별도 단위 테스트로 확인.
        XCTAssertGreaterThan(bridge.presetChangeMirror, 0, "telemetry 기록 (mirror)")
        // session.current 는 sim 한계 상 .march 유지 가능 — 정확한 transition 은 실 hw 검증 영역.

        // 3. emergency.
        bridge.handleEmergency(from: .keyboard)
        XCTAssertTrue(session.emergencyStopActive)
        XCTAssertEqual(session.current, .idle, "stop")
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "emergency 가 amplitude 0 (HIGH 2 fix)")

        // 4. recovery.
        bridge.handleRecovery(from: .keyboard)
        XCTAssertFalse(session.emergencyStopActive, "flag clear")

        // 5. 다시 W → 새 trial 시작 가능.
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.current, .march, "recovery 후 재시작 OK")

        // 6. stop → trial finalize.
        session.stop()

        // pendingLabelTrial 대기.
        var pending: WalkTrial?
        for _ in 0..<100 {
            if let t = session.pendingLabelTrial {
                pending = t
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let trial = pending else {
            XCTFail("pendingLabelTrial 미설정 — finalize async Task 미완료")
            return
        }
        // 7. pilotInputs 자동 첨부 (Cycle 7).
        XCTAssertNotNil(trial.config.pilotInputs, "pilotInputs auto-attach")
        // **참고**: wasAdvancedMode 는 captureTrialStart 시점의 session.advanced 캡쳐.
        // bridge.applyAmplitude 가 advanced=true 를 capture 후 적용하므로 첫 trial 의 wasAdvancedMode 는
        // false 가 맞음. 후속 trial 부터 true. 본 통합 테스트는 trial finalize 자체만 검증.
    }

    // MARK: - Cycle 14/15: activityRate + isActive

    /// **v1.20.8 사이클 14/15** — bridge.activityRate 이 record 후 > 0 됨.
    func testBridgeActivityRateAfterRecord() {
        session.start(.march)
        XCTAssertEqual(bridge.activityRate, 0, accuracy: 0.01, "사전: 0")
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 30, fb: 0, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        // 3 events within last ~1ms — eventsPerSecond default window 1s → rate ~3.
        XCTAssertGreaterThanOrEqual(bridge.activityRate, 2.5, "3개 입력 직후 rate ~3")
    }

    /// **v1.20.8 사이클 14/15** — bridge.isActive: rate > 0.5 threshold.
    func testBridgeIsActiveThreshold() {
        session.start(.march)
        XCTAssertFalse(bridge.isActive, "사전: 입력 없음 → inactive")
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        XCTAssertTrue(bridge.isActive, "1 event > 0.5 threshold → active")
    }

    // MARK: - Cycle 24: Tello state forwarding

    /// **v1.20.18 사이클 24** — updateTelloState 가 lastTelloState 에 저장.
    func testUpdateTelloStateStoresLastMessage() {
        XCTAssertNil(bridge.lastTelloState, "사전: nil")
        let msg = makeTelloState(battery: 75, height: 100)
        bridge.updateTelloState(msg)
        XCTAssertEqual(bridge.lastTelloState?.batteryPct, 75)
        XCTAssertEqual(bridge.lastTelloState?.heightCm, 100)
    }

    /// **v1.20.18 사이클 24** — 배터리 low (< 20%) → safety message.
    func testUpdateTelloStateLowBatteryWarning() {
        let msg = makeTelloState(battery: 10, height: 50)
        bridge.updateTelloState(msg)
        XCTAssertNotNil(bridge.safetyMessage)
        XCTAssertTrue(bridge.safetyMessage?.contains("배터리") ?? false,
                      "low battery safety 메시지")
    }

    /// **v1.20.18 사이클 24** — 정상 배터리는 safetyMessage 갱신 안 함.
    func testUpdateTelloStateNormalBatteryNoWarning() {
        let msg = makeTelloState(battery: 80, height: 0)
        bridge.updateTelloState(msg)
        XCTAssertNil(bridge.safetyMessage, "normal battery — message 없음")
    }

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

    // MARK: - Cycle 18: emergency recovery

    /// **v1.20.12 사이클 18** — handleRecovery 이 emergencyStopActive flag 만 clear, walking 미시작.
    func testHandleRecoveryClearsEmergencyFlag() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive)
        XCTAssertEqual(session.current, .idle, "emergency 후 current idle")

        bridge.handleRecovery(from: .ui)

        XCTAssertFalse(session.emergencyStopActive, "recovery → flag clear")
        XCTAssertEqual(session.current, .idle, "walking 자동 시작 안 함")
        XCTAssertNil(bridge.safetyMessage, "safety 메시지 clear")
    }

    /// **v1.20.12 사이클 18** — recovery 후 handlePreset 다시 작동.
    func testRecoveryUnblocksPresetShortcuts() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive)

        // recovery 전: handlePreset 차단.
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(session.current, .idle, "recovery 전 차단")

        bridge.handleRecovery(from: .ui)

        // recovery 후: handlePreset 다시 작동.
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(session.current, .march, "recovery 후 unblock")
    }

    /// **v1.20.12 사이클 18 + 28-fix LOW (코덱스)** — non-emergency 상태에서 recovery silent no-op.
    /// 신규 (28-fix LOW): 이중 클릭 (Panel + HUD) idempotent — message 미변경.
    func testHandleRecoveryNoOpWhenNotInEmergency() {
        XCTAssertFalse(session.emergencyStopActive)
        bridge.handleRecovery(from: .ui)
        XCTAssertNil(bridge.safetyMessage, "silent no-op — message 미변경")
        XCTAssertFalse(session.emergencyStopActive)
    }

    /// **v1.20.13.1 사이클 19-fix LOW 1 (코덱스)** — recovery 후 lastIntent 가 clear.
    /// 종전: HUD 가 stale "긴급" 표시 유지. 신규: nil → HUD "대기" 복귀.
    func testHandleRecoveryClearsLastIntent() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertNotNil(bridge.lastIntent, "사전: emergency intent 기록")

        bridge.handleRecovery(from: .ui)

        XCTAssertNil(bridge.lastIntent, "recovery 후 lastIntent clear")
    }

    /// **v1.20.13.1 사이클 19-fix LOW 2 (코덱스)** — emergency↔recovery 반복 가능 (회귀 가드).
    func testRepeatedEmergencyAndRecovery() {
        for cycle in 1...3 {
            session.start(.march)
            XCTAssertEqual(session.current, .march, "cycle \(cycle): march 시작")

            bridge.handleEmergency(from: .ui)
            XCTAssertTrue(session.emergencyStopActive, "cycle \(cycle): emergency 활성")
            XCTAssertEqual(session.current, .idle)

            bridge.handleRecovery(from: .ui)
            XCTAssertFalse(session.emergencyStopActive, "cycle \(cycle): recovery 후 flag clear")
        }
    }

    /// **v1.20.4.1 사이클 10-fix CRITICAL (코덱스)** — emergency 후 즉시 preset 재시작 차단.
    /// Space + 1 race scenario: emergency 발화 후 1 (march) 입력해도 차단되어야 함.
    func testHandlePresetBlockedDuringEmergency() {
        session.start(.march)
        bridge.handleEmergency(from: .keyboard)
        // emergencyStop 후 emergencyStopActive = true.
        XCTAssertTrue(session.emergencyStopActive, "emergency 후 active flag")

        bridge.handlePreset(.march, from: .keyboard)

        XCTAssertEqual(session.current, .idle, "emergency 동안 preset 재시작 차단")
        XCTAssertTrue(bridge.safetyMessage?.contains("긴급 정지") ?? false,
                      "emergency 안전 메시지")
    }

    /// **v1.20.20 사이클 26** — 같은 preset 재입력 시 idempotent no-op (사이클 10-fix HIGH 진화).
    /// 종전 (사이클 10-fix HIGH): "march 진행 중" 차단 메시지 노출.
    /// 신규 (사이클 26): silent no-op — 게임 UX. 사용자가 1 번 키 두 번 눌러도 자연스럽게 동작.
    /// false-positive 성공 우려는 별도 — current 변화 자체가 success 신호 (변하지 않음 = no-op).
    func testHandlePresetSamePresetIsIdempotentNoOp() {
        session.start(.march)
        XCTAssertEqual(session.current, .march)

        bridge.handlePreset(.march, from: .keyboard)

        XCTAssertEqual(session.current, .march, "current 변화 없음")
        XCTAssertNil(bridge.safetyMessage,
                     "no-op — 차단 메시지 없음 (게임 UX silent)")
    }

    // **참고 (사이클 10-fix MEDIUM 2)**: "walking 중 다른 preset 전환 차단" 테스트는 sim 모드에서
    // `isRobotWalking` 이 false 라 quickPreflight 가 isWalkActive 차단을 fire 안 함 (sim 한계).
    // 실 로봇 bus 가 있는 환경에서만 검증 가능 — 본 unit test suite 범위 밖. 코덱스 검수 응답:
    // sim 모드에서 switch 가 작동하는 건 buggy 가 아니라 "preview 모드" 의도된 동작.

    /// **v1.20.3 사이클 9** — auto-start 가 stop intent 에는 발화 안 함.
    func testAutoStartDoesNotFireOnStopIntent() {
        // deadzone (|stick| < 5) → mapper 가 .stop intent 생성.
        bridge.handleTelloStick(lr: 2, fb: 1, ud: 0, yaw: 1)
        XCTAssertEqual(session.current, .idle, "stop intent → auto-start skip")
        XCTAssertNotNil(bridge.safetyMessage, "기존 idle 안전 메시지")
    }

    // MARK: - Emergency

    func testEmergencyTriggersSessionEmergencyAndTelloEmergency() async {
        session.start(.march)
        XCTAssertEqual(bridge.emergencyCount, 0)

        bridge.handleEmergency(from: .ui)
        // emergency 처리 — session.emergencyStop + tello.emergency Task.
        XCTAssertEqual(bridge.emergencyCount, 1)
        XCTAssertEqual(session.current, .idle, "emergencyStop 후 current idle")
        // tello.emergency 는 async — 조금 wait.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mock.emergencyCount, 1, "MockTello 의 emergency() 호출됨")
    }

    func testEmergencyAllowedEvenWhenDisabled() {
        session.start(.march)
        bridge.enabled = false
        bridge.handleEmergency(from: .ui)
        XCTAssertEqual(bridge.emergencyCount, 1, "disabled 라도 emergency 허용")
        XCTAssertEqual(session.current, .idle)
    }

    // MARK: - Disabled bridge

    func testStickIgnoredWhenDisabled() {
        session.start(.march)
        bridge.enabled = false
        let strideBefore = session.strideMm
        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.strideMm, strideBefore, accuracy: 1e-9, "disabled stride 미변경")
        XCTAssertTrue(bridge.safetyMessage?.contains("Bridge 비활성") ?? false)
    }

    // MARK: - Multi-source

    func testKeyboardSourceProcessed() {
        session.start(.march)
        let cmd = WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0)
        bridge.handleMove(cmd, from: .keyboard)
        XCTAssertEqual(session.strideMm, 20, accuracy: 1e-9)
        XCTAssertEqual(bridge.lastIntent?.source, .keyboard)
    }

    // MARK: - PilotInputAccumulator 통합

    func testAccumulatorRecordsAllIntents() {
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 30, fb: 0, ud: 0, yaw: 0)
        bridge.handleEmergency(from: .ui)

        let summary = bridge.snapshotAndReset()
        XCTAssertEqual(summary.totalEvents, 3)
        XCTAssertTrue(summary.emergencyTriggered)
        XCTAssertEqual(Set(summary.sourcesUsed), Set([.tello, .ui]))
        // avg/peak: move 2건만 평균.
        XCTAssertGreaterThan(summary.peakStrideMm, 0)
    }

    func testSnapshotResetsAccumulator() {
        session.start(.march)
        bridge.handleTelloStick(lr: 50, fb: 50, ud: 0, yaw: 0)
        _ = bridge.snapshotAndReset()

        let secondSnapshot = bridge.snapshotAndReset()
        XCTAssertEqual(secondSnapshot.totalEvents, 0, "reset 후 카운터 0")
    }

    // MARK: - Cycle 7: Trial 통합 (pilotBridge weak ref + auto-attach)

    /// **v1.20.1 사이클 7** — `WalkLabSession.captureTrialStart` 가 pilotBridge.accumulator 를 reset.
    /// 신규 trial 시작 시 이전 trial 의 stick 통계가 누적되지 않도록 보장.
    func testCaptureTrialStartResetsBridgeAccumulator() {
        session.pilotBridge = bridge
        // 이전 trial 의 잔재가 있다고 가정 — bridge 에 직접 record.
        bridge.accumulator.record(.move(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0), from: .keyboard))
        bridge.accumulator.record(.move(WalkingCommand(strideMm: 15, sideMm: 0, turnDeg: 0), from: .keyboard))
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 2, "사전: 2개 누적")

        // 신규 trial 시작 (session.start 가 captureTrialStart 호출).
        session.start(.march)

        // captureTrialStart 안에서 pilotBridge?.accumulator.reset() 실행 → 0.
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 0,
                       "captureTrialStart 이 bridge accumulator 를 reset")
    }

    /// **v1.20.1 사이클 7** — `WalkLabSession.finalizeTrialIfPending` 이 pilotBridge.snapshotAndReset 호출.
    /// Observable side effect: 종료 후 bridge.accumulator 가 비어있음.
    func testFinalizeSnapshotsBridgeAccumulator() {
        session.pilotBridge = bridge
        session.start(.march)  // captureTrialStart → reset.
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 30, fb: 0, ud: 0, yaw: 0)
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 2,
                       "사전: stop 전 2건 누적")

        session.stop()  // finalize 가 main actor 에서 snapshotAndReset 동기 호출.

        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 0,
                       "stop → finalize → snapshotAndReset 이 accumulator 비움")
    }

    /// **v1.20.1 사이클 7-fix MEDIUM 2 (코덱스)** — finalize 가 두 번 호출되어도 bridge snapshot 은 1회만.
    /// idempotent: `trialStartCapture nil 가드` 가 두 번째 finalize 를 no-op 으로 막아야 함.
    /// **v1.20.3 사이클 9 보강**: stop 후 입력이 auto-start 를 재발화 안 하도록 disable.
    func testFinalizeIsIdempotentForBridgeSnapshot() {
        session.pilotBridge = bridge
        bridge.pilotAutoStartPreset = nil  // 사이클 9: stop 후 재 auto-start 차단 — pure idempotent 검증.
        session.start(.march)  // captureTrialStart → reset.
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 30, fb: 0, ud: 0, yaw: 0)
        // 첫 stop → finalize → snapshotAndReset.
        session.stop()
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 0, "1차: 비움")

        // 사용자가 두 번째 입력 — 이건 새 trial 시작 전이므로 그냥 누적.
        bridge.handleTelloStick(lr: 10, fb: 0, ud: 0, yaw: 0)
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 1, "stop 후 입력 누적")

        // 2차 stop — captureTrialStart 가 호출 안 됐으므로 trialStartCapture 는 nil →
        // finalizeTrialIfPending 의 guard 가 즉시 return → bridge.snapshotAndReset 미발화.
        session.stop()

        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 1,
                       "2차 finalize: trialStartCapture nil guard → bridge 영향 없음")
    }

    /// **v1.20.1 사이클 7-fix MEDIUM 3 (코덱스)** — stop 후 새 입력이 trial.config.pilotInputs 에 미포함.
    /// stop 시점에 snapshotAndReset 이 동기 발화하므로 그 이후 입력은 다음 trial 의 일부.
    func testPostStopInputsDoNotPolluteFinalizedTrial() async {
        session.pilotBridge = bridge
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)  // 종료 전 1건
        bridge.handleTelloStick(lr: 30, fb: 0, ud: 0, yaw: 0)  // 종료 전 2건
        session.stop()  // snapshotAndReset — accumulator 비워짐.

        // stop 직후 새 입력 — bridge 에 누적되지만 stop 의 trial 에는 영향 없어야 함.
        // (실제 stick 입력은 session.current == .idle 라 amplitude 미적용, 단 accumulator 만 누적.)
        bridge.handleTelloStick(lr: 80, fb: 80, ud: 0, yaw: 80)

        // pendingLabelTrial 동기/비동기 대기.
        var pendingTrial: WalkTrial?
        for _ in 0..<100 {
            if let t = session.pendingLabelTrial {
                pendingTrial = t
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let trial = pendingTrial else {
            XCTFail("pendingLabelTrial 미설정 — async Task 미완료")
            return
        }
        guard let pilot = trial.config.pilotInputs else {
            XCTFail("pilotInputs 가 nil")
            return
        }
        XCTAssertEqual(pilot.totalEvents, 2,
                       "stop 이전 2건만 — post-stop 입력은 격리")
        XCTAssertLessThanOrEqual(pilot.peakStrideMm, 21,
                                 "post-stop 의 fb=80 stride (=32) 가 trial 에 누출 안 됨")
    }

    /// **v1.20.1 사이클 7** — finalize 가 생성한 `pendingLabelTrial.config.pilotInputs` 가 bridge 통계 반영.
    /// 비동기 Task 통과 대기 — sleep poll 패턴 (testEmergency 와 동일).
    func testFinalizeAttachesPilotSummaryToTrialConfig() async {
        session.pilotBridge = bridge
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 80, ud: 0, yaw: 0)  // strideMm 32 (80*0.4)
        bridge.handleTelloStick(lr: 25, fb: 0, ud: 0, yaw: 0)  // sideMm ~ 10 (25*0.4)

        session.stop()

        // finalize 내부 Task 완료 대기 — 비동기 file I/O + main hop.
        // 최대 5초 polling (50ms × 100).
        var pendingTrial: WalkTrial?
        for _ in 0..<100 {
            if let t = session.pendingLabelTrial {
                pendingTrial = t
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let trial = pendingTrial else {
            XCTFail("pendingLabelTrial 가 finalize 후에도 nil — async Task 완료 안 됨")
            return
        }
        guard let pilot = trial.config.pilotInputs else {
            XCTFail("trial.config.pilotInputs 가 nil — finalize 가 pilotSummary 첨부 실패")
            return
        }
        XCTAssertEqual(pilot.totalEvents, 2, "두 stick 입력 모두 summary 에 기록")
        XCTAssertTrue(pilot.sourcesUsed.contains(.tello), "tello source 포함")
        XCTAssertGreaterThan(pilot.peakStrideMm, 0, "stride peak > 0")
        XCTAssertGreaterThan(pilot.peakSideMm, 0, "side peak > 0")
    }
}

/// **PilotIntent + PilotInputSummary value 타입 테스트**.
final class PilotIntentTests: XCTestCase {

    func testMoveIntentEquality() {
        let cmd = WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0)
        let intent1 = PilotIntent.move(cmd, from: .tello)
        let intent2 = PilotIntent.move(cmd, from: .tello)
        // timestamp 가 다르지만 kind/source 동일.
        XCTAssertEqual(intent1.kind, intent2.kind)
        XCTAssertEqual(intent1.source, intent2.source)
    }

    func testSourceCodableRoundtrip() throws {
        let summary = PilotInputSummary(
            sourcesUsed: [.tello, .ui],
            totalEvents: 5, avgAbsStrideMm: 10, avgAbsSideMm: 5, avgAbsTurnDeg: 2,
            peakStrideMm: 30, peakSideMm: 15, peakTurnDeg: 10,
            emergencyTriggered: false
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(PilotInputSummary.self, from: data)
        XCTAssertEqual(decoded, summary)
    }

    func testEmptySummary() {
        XCTAssertFalse(PilotInputSummary.empty.hasData)
        XCTAssertEqual(PilotInputSummary.empty.totalEvents, 0)
        // **사이클 52** — hasMoveData (Cycle 42) 도 false.
        XCTAssertFalse(PilotInputSummary.empty.hasMoveData,
                       "empty → hasMoveData false")
    }

    /// **v1.20.30.1 사이클 36-fix MEDIUM 1 (코덱스)** — comfortLevel 100% 초과 차단.
    /// raw peak 값이 정규화 한도 초과 시에도 0..1 clamp.
    func testPilotInputSummaryComfortLevelClamps() {
        let over = PilotInputSummary(
            sourcesUsed: [.keyboard], totalEvents: 1, moveEventCount: 1,
            avgAbsStrideMm: 100, avgAbsSideMm: 100, avgAbsTurnDeg: 100,
            peakStrideMm: 100, peakSideMm: 100, peakTurnDeg: 100,  // 한도 (40/25/20) 초과
            peakNegStrideMm: 0, peakNegSideMm: 0, peakNegTurnDeg: 0,
            emergencyTriggered: false
        )
        XCTAssertEqual(over.comfortLevel, 1.0, accuracy: 1e-9,
                       "한도 초과 → clamp 1.0 (HUD 100% 초과 차단)")
    }

    /// **v1.20.28 사이클 34** — comfortLevel 정규화 검증.
    func testPilotInputSummaryComfortLevel() {
        let empty = PilotInputSummary.empty
        XCTAssertEqual(empty.comfortLevel, 0, accuracy: 1e-9, "pilot 미사용 → 0")

        let max = PilotInputSummary(
            sourcesUsed: [.keyboard], totalEvents: 1, moveEventCount: 1,
            avgAbsStrideMm: 40, avgAbsSideMm: 25, avgAbsTurnDeg: 20,
            peakStrideMm: 40, peakSideMm: 25, peakTurnDeg: 20,
            peakNegStrideMm: 0, peakNegSideMm: 0, peakNegTurnDeg: 0,
            emergencyTriggered: false
        )
        XCTAssertEqual(max.comfortLevel, 1.0, accuracy: 1e-9, "모든 축 max → 1.0")

        let half = PilotInputSummary(
            sourcesUsed: [.keyboard], totalEvents: 1, moveEventCount: 1,
            avgAbsStrideMm: 0, avgAbsSideMm: 0, avgAbsTurnDeg: 0,
            peakStrideMm: 20, peakSideMm: 12.5, peakTurnDeg: 10,
            peakNegStrideMm: 0, peakNegSideMm: 0, peakNegTurnDeg: 0,
            emergencyTriggered: false
        )
        XCTAssertEqual(half.comfortLevel, 0.5, accuracy: 1e-9, "half × 3축 평균 → 0.5")
    }

    func testAccumulatorAvgCalculation() {
        let acc = PilotInputAccumulator()
        acc.record(.move(WalkingCommand(strideMm: 10, sideMm: 5, turnDeg: -3), from: .tello))
        acc.record(.move(WalkingCommand(strideMm: 30, sideMm: -5, turnDeg: 9), from: .tello))
        let s = acc.summarize()
        XCTAssertEqual(s.avgAbsStrideMm, 20, accuracy: 1e-9, "(10+30)/2 = 20")
        XCTAssertEqual(s.avgAbsSideMm, 5, accuracy: 1e-9, "(|5|+|-5|)/2 = 5")
        XCTAssertEqual(s.avgAbsTurnDeg, 6, accuracy: 1e-9, "(|-3|+|9|)/2 = 6")
        XCTAssertEqual(s.peakStrideMm, 30, accuracy: 1e-9, "양수 peak")
    }

    // MARK: - Cycle 13: event rate metric

    /// **v1.20.7 사이클 13** — 마지막 1초 동안의 event count = events/sec.
    func testEventsPerSecondBasic() {
        let acc = PilotInputAccumulator()
        let now = Date()
        // 5 events within last 1 sec.
        for i in 0..<5 {
            let intent = PilotIntent(
                kind: .move(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0)),
                source: .keyboard,
                timestamp: now.addingTimeInterval(-Double(i) * 0.1)
            )
            acc.record(intent)
        }
        let rate = acc.eventsPerSecond(window: 1.0, now: now)
        XCTAssertEqual(rate, 5.0, accuracy: 0.01, "5 events in 1s window")
    }

    /// **v1.20.7 사이클 13** — window 밖 event 는 제외.
    func testEventsPerSecondExcludesOldEvents() {
        let acc = PilotInputAccumulator()
        let now = Date()
        // 3 recent + 2 old (5초 전).
        for i in 0..<3 {
            let intent = PilotIntent(
                kind: .stop, source: .keyboard,
                timestamp: now.addingTimeInterval(-Double(i) * 0.2)
            )
            acc.record(intent)
        }
        for _ in 0..<2 {
            let intent = PilotIntent(
                kind: .stop, source: .keyboard,
                timestamp: now.addingTimeInterval(-5.0)
            )
            acc.record(intent)
        }
        XCTAssertEqual(acc.eventsPerSecond(window: 1.0, now: now), 3.0, accuracy: 0.01,
                       "old events (5s ago) 제외")
    }

    /// **v1.20.7 사이클 13** — reset 후 rate 0.
    func testEventsPerSecondAfterReset() {
        let acc = PilotInputAccumulator()
        acc.record(.move(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0), from: .keyboard))
        acc.reset()
        XCTAssertEqual(acc.eventsPerSecond(), 0, accuracy: 0.01)
    }

    /// **v1.20.7 사이클 13** — 큰 window 도 capacity 64 로 cap.
    func testEventsPerSecondCapacityCap() {
        let acc = PilotInputAccumulator()
        let now = Date()
        // 100 events injected — capacity 64 라 64만 keep.
        for i in 0..<100 {
            let intent = PilotIntent(
                kind: .stop, source: .keyboard,
                timestamp: now.addingTimeInterval(-Double(i) * 0.01)
            )
            acc.record(intent)
        }
        // 1 second window 에 64 entries 가 모두 들어옴 (0.64s 까지의 이력).
        let rate = acc.eventsPerSecond(window: 1.0, now: now)
        XCTAssertLessThanOrEqual(rate, 64.0, "capacity cap")
    }
}
