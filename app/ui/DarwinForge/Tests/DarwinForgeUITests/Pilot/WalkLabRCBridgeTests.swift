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

    func testStickInputIgnoredWhenIdle() {
        // session.current == .idle — bridge 가 safety message 만 설정.
        bridge.handleTelloStick(lr: 50, fb: 50, ud: 0, yaw: 0)

        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "idle 시 stride 미변경")
        XCTAssertNotNil(bridge.safetyMessage)
        XCTAssertTrue(bridge.safetyMessage?.contains("preset 먼저 선택") ?? false)
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
