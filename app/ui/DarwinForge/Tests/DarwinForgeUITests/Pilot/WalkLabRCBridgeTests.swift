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
}
