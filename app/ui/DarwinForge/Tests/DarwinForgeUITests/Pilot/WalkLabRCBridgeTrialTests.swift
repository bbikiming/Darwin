import Foundation
import XCTest
@testable import DarwinForgeUI

/// **WalkLabRCBridge Cycle 7 accumulator wiring + trial finalize 단위 테스트**.
///
/// 범위: captureTrialStart accumulator reset, finalize snapshot attach,
/// idempotent finalize, post-stop 입력 격리, snapshot/reset.
@MainActor
final class WalkLabRCBridgeTrialTests: XCTestCase {

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

    // MARK: - Accumulator wiring (Cycle 7)

    func testCaptureTrialStartResetsBridgeAccumulator() {
        session.pilotBridge = bridge
        bridge.accumulator.record(.move(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0), from: .keyboard))
        bridge.accumulator.record(.move(WalkingCommand(strideMm: 15, sideMm: 0, turnDeg: 0), from: .keyboard))
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 2, "사전: 2개 누적")

        session.start(.march)

        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 0,
                       "captureTrialStart 이 bridge accumulator 를 reset")
    }

    func testFinalizeSnapshotsBridgeAccumulator() {
        session.pilotBridge = bridge
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 30, fb: 0, ud: 0, yaw: 0)
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 2,
                       "사전: stop 전 2건 누적")

        session.stop()

        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 0,
                       "stop → finalize → snapshotAndReset 이 accumulator 비움")
    }

    func testFinalizeIsIdempotentForBridgeSnapshot() {
        session.pilotBridge = bridge
        bridge.pilotAutoStartPreset = nil
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 30, fb: 0, ud: 0, yaw: 0)
        session.stop()
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 0, "1차: 비움")

        bridge.handleTelloStick(lr: 10, fb: 0, ud: 0, yaw: 0)
        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 1, "stop 후 입력 누적")

        session.stop()

        XCTAssertEqual(bridge.accumulator.summarize().totalEvents, 1,
                       "2차 finalize: trialStartCapture nil guard → bridge 영향 없음")
    }

    func testPostStopInputsDoNotPolluteFinalizedTrial() async {
        session.pilotBridge = bridge
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 30, fb: 0, ud: 0, yaw: 0)
        session.stop()

        bridge.handleTelloStick(lr: 80, fb: 80, ud: 0, yaw: 80)

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

    func testFinalizeAttachesPilotSummaryToTrialConfig() async {
        session.pilotBridge = bridge
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 80, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 25, fb: 0, ud: 0, yaw: 0)

        session.stop()

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

    // MARK: - Snapshot/Reset

    func testAccumulatorRecordsAllIntents() {
        session.start(.march)
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        bridge.handleTelloStick(lr: 30, fb: 0, ud: 0, yaw: 0)
        bridge.handleEmergency(from: .ui)

        let summary = bridge.snapshotAndReset()
        XCTAssertEqual(summary.totalEvents, 3)
        XCTAssertTrue(summary.emergencyTriggered)
        XCTAssertEqual(Set(summary.sourcesUsed), Set([.tello, .ui]))
        XCTAssertGreaterThan(summary.peakStrideMm, 0)
    }

    func testSnapshotResetsAccumulator() {
        session.start(.march)
        bridge.handleTelloStick(lr: 50, fb: 50, ud: 0, yaw: 0)
        _ = bridge.snapshotAndReset()

        let secondSnapshot = bridge.snapshotAndReset()
        XCTAssertEqual(secondSnapshot.totalEvents, 0, "reset 후 카운터 0")
    }

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

    func testEventsPerSecondZeroWindow() {
        let acc = PilotInputAccumulator()
        acc.record(.move(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0), from: .keyboard))
        XCTAssertEqual(acc.eventsPerSecond(window: 0), 0, accuracy: 1e-9,
                       "window 0 → divide by zero 방지 (defensive)")
        XCTAssertEqual(acc.eventsPerSecond(window: -1), 0, accuracy: 1e-9,
                       "음수 window 도 0")
    }

    // MARK: - End-to-end happy path (Cycle 33)

    func testEndToEndPilotFlowHappyPath() async {
        session.pilotBridge = bridge

        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.current, .march, "auto-start 발화")
        XCTAssertTrue(session.advanced, "advanced 자동 활성 (Cycle 20-fix)")
        XCTAssertEqual(session.strideMm, 40, accuracy: 1e-9, "amplitude 적용")

        bridge.handlePreset(.slowWalk, from: .keyboard)
        XCTAssertGreaterThan(bridge.presetChangeMirror, 0, "telemetry 기록 (mirror)")

        bridge.handleEmergency(from: .keyboard)
        XCTAssertTrue(session.emergencyStopActive)
        XCTAssertEqual(session.current, .idle, "stop")
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "emergency 가 amplitude 0 (HIGH 2 fix)")

        bridge.handleRecovery(from: .keyboard)
        XCTAssertFalse(session.emergencyStopActive, "flag clear")

        bridge.handleTelloStick(lr: 0, fb: 100, ud: 0, yaw: 0)
        XCTAssertEqual(session.current, .march, "recovery 후 재시작 OK")

        session.stop()

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
        XCTAssertNotNil(trial.config.pilotInputs, "pilotInputs auto-attach")
    }
}
