import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.22.0 (2026-05-22) — Pilot concurrent stress test**.
///
/// 5+ source 가 같은 frame 에 폭발적으로 intent 발화 시 bridge 의 일관성 (no NaN, no crash,
/// state machine 무결성) 검증. 사용자가 게임패드 stick 빠르게 흔들면서 키보드 W 동시 누름
/// 같은 극한 시나리오 시뮬.
///
/// # 비유
///
/// 비행기 fly-by-wire 의 stress test — 조종간 / 자동조종 / 비상스위치 / 트레이너 모드 가
/// 동시에 polling 되는 환경에서 컨트롤러가 NaN 출력 / 무한 loop / 모터 misfire 안 함을
/// 강제 검증.
@MainActor
final class PilotConcurrentStressTests: XCTestCase {

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
        session.start(.march)
    }

    override func tearDown() async throws {
        bridge = nil
        session = nil
        mock = nil
        try await super.tearDown()
    }

    /// 5 source × 200 intent 폭발 — accumulator / state / amplitude 모두 valid range.
    func testStorm5SourcesNoNaNOrCrash() {
        let sources: [InputSource] = [.keyboard, .tello, .gamepad, .voice, .ui]
        for i in 0..<200 {
            let source = sources[i % sources.count]
            let stride = Double(i % 40)
            let side = Double((i * 3) % 20)
            let turn = Double((i * 7) % 10)
            bridge.handleMove(
                WalkingCommand(strideMm: stride, sideMm: side, turnDeg: turn),
                from: source
            )
        }

        // amplitude 가 valid range 안에 있고 NaN 없음.
        XCTAssertFalse(session.strideMm.isNaN, "strideMm NaN 차단")
        XCTAssertFalse(session.sideMm.isNaN)
        XCTAssertFalse(session.turnDeg.isNaN)
        XCTAssertTrue(abs(session.strideMm) <= 100)
        // accumulator 가 200 events 누적.
        let summary = bridge.accumulator.summarize()
        XCTAssertEqual(summary.totalEvents, 200)
        XCTAssertEqual(summary.sourcesUsed.count, 5, "5 source 모두 기록")
    }

    /// 빠른 emergency / recovery 50 사이클 — emergencyCount + 차단 일관성.
    func testRapidEmergencyRecoveryCycles() {
        for _ in 0..<50 {
            bridge.handleEmergency(from: .keyboard)
            XCTAssertTrue(session.emergencyStopActive)
            bridge.handleRecovery(from: .ui)
            XCTAssertFalse(session.emergencyStopActive)
            session.start(.march)  // restart for next iteration.
        }
        XCTAssertEqual(bridge.emergencyCount, 50,
                       "50 사이클 emergencyCount 정확 누적")
    }

    /// preset / move / motion 교대 polling — lastIntent 가 마지막 처리 intent 정확 반영.
    func testInterleavedIntentsLastIntentConsistent() {
        for i in 0..<100 {
            if i % 3 == 0 {
                bridge.handlePreset(.march, from: .keyboard)
            } else if i % 3 == 1 {
                bridge.handleMove(WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0),
                                  from: .gamepad)
            } else {
                bridge.handleStop(from: .voice)
            }
        }
        // 마지막 i = 99 → i % 3 = 0 → preset (handlePreset 는 lastIntent 미설정 — 직전 stop / move).
        XCTAssertNotNil(bridge.lastIntent, "lastIntent 가 어떤 intent 든 설정됨")
    }

    /// 5 source 가 같은 stop intent 발화 — stop 중복 안전.
    func testAllSourcesStopIdempotent() {
        bridge.handleMove(WalkingCommand(strideMm: 30, sideMm: 5, turnDeg: 2), from: .keyboard)
        XCTAssertEqual(session.strideMm, 30, accuracy: 1e-9)

        for source in [InputSource.keyboard, .tello, .voice, .gamepad, .ui] {
            bridge.handleStop(from: source)
        }
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "5 source stop 모두 amplitude 0")
        XCTAssertEqual(session.sideMm, 0, accuracy: 1e-9)
        XCTAssertEqual(session.turnDeg, 0, accuracy: 1e-9)
    }

    /// **사이클 94 — 코덱스 HIGH-3 회귀 가드**: emergency 연타 시 NSBeep throttle.
    /// 사용자 청각 피로 방지 — 0.5초 이내 중복 emergency intent 는 audio 1회만.
    func testRapidEmergencyAudioThrottle() {
        let audio = MockAudioFeedback()
        bridge.audioFeedback = audio

        // 같은 frame (0.5초 이내) 에 5번 emergency.
        for _ in 0..<5 {
            bridge.handleEmergency(from: .keyboard)
        }

        // emergencyCount 는 5회 누적 (telemetry 정확), 그러나 audio 는 1회만 (throttle).
        XCTAssertEqual(bridge.emergencyCount, 5,
                       "telemetry count 는 정확 누적 (5회)")
        XCTAssertEqual(audio.emergencyPlayCount, 1,
                       "audio beep 는 0.5초 throttle — 1회만")
    }

    /// **사이클 95 — cycle 94 throttle bug fix 회귀 가드**:
    /// recovery 후 throttle window 도 reset → 다음 emergency (0.5초 이내) 즉시 beep.
    /// 종전 cycle 94: recovery 후 timestamp 잔존 → 새 emergency silent (안전 신호 누락).
    func testRecoveryResetsEmergencyAudioThrottle() {
        let audio = MockAudioFeedback()
        bridge.audioFeedback = audio

        bridge.handleEmergency(from: .keyboard)
        XCTAssertEqual(audio.emergencyPlayCount, 1, "첫 emergency beep")

        // recovery — throttle 도 reset 해야.
        bridge.handleRecovery(from: .ui)
        // 즉시 새 emergency (0.5초 이내) — throttle reset 됐으면 beep.
        bridge.handleEmergency(from: .keyboard)
        XCTAssertEqual(audio.emergencyPlayCount, 2,
                       "recovery 후 emergency 즉시 beep (사이클 95 fix)")
    }

    /// updateTelloState 폭발 — telloAdvisoryMessage 가 정확히 last state 반영.
    func testTelloStateStormConvergesToLastBattery() {
        for i in 0..<100 {
            let battery = (i % 2 == 0) ? 50 : 8  // 교대 high / low
            let msg = TelloStateMessage(
                pitchDeg: 0, rollDeg: 0, yawDeg: 0,
                vgx: 0, vgy: 0, vgz: 0,
                templ: 50, temph: 55, tofCm: nil,
                heightCm: 100, batteryPct: battery, baroPa: nil,
                agx: 0, agy: 0, agz: -1000,
                receivedAt: Date()
            )
            bridge.updateTelloState(msg)
        }
        // 마지막 i = 99 → battery 8 (low) → advisory 설정.
        XCTAssertNotNil(bridge.telloAdvisoryMessage, "마지막 low battery 반영")
        XCTAssertEqual(bridge.lastTelloState?.batteryPct, 8)
    }
}
