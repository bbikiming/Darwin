import Foundation
import XCTest
@testable import DarwinForgeUI

/// **WalkLabRCBridge handlePreset 단위 테스트**.
///
/// 범위: preset 시작/정지, idempotent, preflight 차단, telemetry 카운터.
@MainActor
final class WalkLabRCBridgePresetTests: XCTestCase {

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

    // MARK: - 기본 preset 전환

    func testHandlePresetStartsWalking() {
        XCTAssertEqual(session.current, .idle)
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(session.current, .march, "preset 시작 성공")
        XCTAssertNil(bridge.safetyMessage)
    }

    func testHandlePresetIdleStopsWalking() {
        session.start(.march)
        XCTAssertEqual(session.current, .march)
        bridge.handlePreset(.idle, from: .keyboard)
        XCTAssertEqual(session.current, .idle, ".idle preset → session.stop")
    }

    func testHandlePresetBlockedByPreflight() {
        XCTAssertFalse(session.riskAcknowledged)
        bridge.handlePreset(.jog, from: .keyboard)
        XCTAssertEqual(session.current, .idle, "preflight 차단 → idle 유지")
        XCTAssertNotNil(bridge.safetyMessage)
        XCTAssertTrue(bridge.safetyMessage?.contains("위험") ?? false,
                      "highRiskNotAcknowledged userMessage 노출 (\"위험 동의 필요\")")
    }

    func testHandlePresetIgnoredWhenDisabled() {
        bridge.enabled = false
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(session.current, .idle, "disabled bridge → preset 무시")
        XCTAssertTrue(bridge.safetyMessage?.contains("비활성") ?? false)
    }

    func testHandlePresetWithoutSessionReturnsSafetyMessage() {
        let lonely = WalkLabRCBridge(tello: MockTelloLink())
        lonely.handlePreset(.march, from: .ui)
        XCTAssertNotNil(lonely.safetyMessage)
        XCTAssertTrue(lonely.safetyMessage?.contains("WalkLabSession") ?? false)
    }

    // MARK: - Idempotent (same-preset)

    func testHandlePresetSamePresetIsIdempotentNoOp() {
        session.start(.march)
        XCTAssertEqual(session.current, .march)

        bridge.handlePreset(.march, from: .keyboard)

        XCTAssertEqual(session.current, .march, "current 변화 없음")
        XCTAssertNil(bridge.safetyMessage,
                     "no-op — 차단 메시지 없음 (게임 UX silent)")
    }

    // MARK: - Telemetry 카운터

    func testHandlePresetIncrementsPresetChangeCount() {
        session.pilotBridge = bridge
        XCTAssertEqual(bridge.accumulator.summarize().presetChangeCount, 0)
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(bridge.accumulator.summarize().presetChangeCount, 1,
                       "march 시작 trial 의 첫 preset = 1")
        bridge.handlePreset(.slowWalk, from: .keyboard)
        XCTAssertEqual(bridge.accumulator.summarize().presetChangeCount, 1,
                       "slowWalk 새 trial 의 첫 preset = 1 (reset 후 re-record)")
        XCTAssertTrue(bridge.accumulator.summarize().sourcesUsed.contains(.keyboard))
    }

    func testHandlePresetCountPreservedAfterSessionStartResets() {
        session.pilotBridge = bridge
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(session.current, .march)
        XCTAssertEqual(bridge.accumulator.summarize().presetChangeCount, 1,
                       "session.start reset 후 re-record (사이클 23-fix MEDIUM 1)")
    }

    func testHandlePresetIncrementsObservableMirror() {
        XCTAssertEqual(bridge.presetChangeMirror, 0)
        bridge.handlePreset(.march, from: .keyboard)
        XCTAssertEqual(bridge.presetChangeMirror, 1, "observable mirror 증가")
        bridge.handlePreset(.slowWalk, from: .keyboard)
        XCTAssertEqual(bridge.presetChangeMirror, 2)
    }

    // MARK: - Legacy PilotInputSummary JSON

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
}
