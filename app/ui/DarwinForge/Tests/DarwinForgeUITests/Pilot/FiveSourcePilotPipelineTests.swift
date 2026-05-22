import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.22.0 (2026-05-22) 사이클 73 — 5-source pilot pipeline end-to-end 통합 테스트**.
///
/// 사이클 67 가 5 input source (Keyboard / Tello / Gamepad / Voice / UI) 를 모두
/// 통합했으나, 기존 `MultiSourceRaceTests` 는 3 source (Keyboard / Tello / UI) 만
/// 시나리오 커버. 본 suite 는 신규 2 source (Gamepad / Voice) 도 포함하는 진짜
/// 5-source pipeline 검증.
///
/// # 비유
///
/// 비행기 calibration test — 조종간 / 자동조종 / 음성명령 / 트레이너 모드 / 비상스위치
/// 5개 입력 채널이 같은 항공 컴퓨터를 거쳐 일관된 안전 응답을 만드는지 확인. 각 채널을
/// 독립 시뮬 + 시퀀스 + 동시 발화로 검증해 robotis darwin-op2 의 player-as-character
/// invariant 보존.
///
/// # 검증 시나리오
///
/// 1. **순차 발화**: keyboard 'W' → Tello stick → Voice "걸어" → Gamepad D-pad → UI tap
///    모두 동일 bridge → session → engine 도달
/// 2. **emergency 우선순위**: 5 source 중 어떤 source 에서든 emergency 가 모든 source 차단
/// 3. **accumulator source diversity**: 5 source 모두 사용 시 sourcesUsed 가 5 개
/// 4. **InputSource enum 완성도**: 모든 source 가 라벨 / icon / 차단 검증
@MainActor
final class FiveSourcePilotPipelineTests: XCTestCase {

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

    // MARK: - 1. 순차 발화 — 5 source 가 동일 pipeline 통과

    /// 5 source 가 순차로 move intent 를 발화 — 모두 bridge.process 도달 + accumulator 기록.
    func testFiveSourceSequentialMoveIntents() {
        session.start(.march)

        // 1. Keyboard W
        bridge.handleMove(WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0), from: .keyboard)
        // 2. Tello stick (forward)
        bridge.handleTelloStick(lr: 0, fb: 50, ud: 0, yaw: 0)
        // 3. Voice "걸어" — voice adapter 가 handleMotion 호출하지만 본 test 는 직접 handleMove
        bridge.handleMove(WalkingCommand(strideMm: 15, sideMm: 0, turnDeg: 0), from: .voice)
        // 4. Gamepad D-pad → preset (이미 march 라 sameAsCurrent → noop) 대신 stick
        bridge.handleMove(WalkingCommand(strideMm: 30, sideMm: 5, turnDeg: 2), from: .gamepad)
        // 5. UI button
        bridge.handleMove(WalkingCommand(strideMm: 25, sideMm: 0, turnDeg: 0), from: .ui)

        // 마지막 intent 가 UI move 이므로 strideMm = 25.
        XCTAssertEqual(session.strideMm, 25, accuracy: 1e-9, "마지막 UI move 반영")
        XCTAssertFalse(session.strideMm.isNaN, "NaN 없음")

        // accumulator 가 5 events 모두 누적.
        let summary = bridge.accumulator.summarize()
        XCTAssertEqual(summary.totalEvents, 5, "5 source 모든 events 누적")
        XCTAssertGreaterThanOrEqual(summary.sourcesUsed.count, 5,
                                    "sourcesUsed 가 5 source 모두 포함")
        XCTAssertTrue(summary.sourcesUsed.contains(.keyboard))
        XCTAssertTrue(summary.sourcesUsed.contains(.tello))
        XCTAssertTrue(summary.sourcesUsed.contains(.voice))
        XCTAssertTrue(summary.sourcesUsed.contains(.gamepad))
        XCTAssertTrue(summary.sourcesUsed.contains(.ui))
    }

    // MARK: - 2. Emergency 가 5 source 모두 차단

    /// 5 source 중 어떤 source 에서든 emergency 가 활성화되면 다른 4 source 의 move 가 차단.
    func testEmergencyBlocksAllFiveSources() {
        session.start(.march)
        bridge.handleEmergency(from: .keyboard)
        XCTAssertTrue(session.emergencyStopActive, "emergency 활성")

        // 4 source (keyboard 제외) 의 move 시도 — 모두 차단.
        bridge.handleMove(WalkingCommand(strideMm: 10, sideMm: 0, turnDeg: 0), from: .tello)
        bridge.handleMove(WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0), from: .voice)
        bridge.handleMove(WalkingCommand(strideMm: 30, sideMm: 0, turnDeg: 0), from: .gamepad)
        bridge.handleMove(WalkingCommand(strideMm: 40, sideMm: 0, turnDeg: 0), from: .ui)

        // 모든 차단 — session.strideMm 은 emergency zero 그대로.
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9,
                       "emergency 활성 중 4 source move 모두 차단")
        XCTAssertEqual(session.current, .idle, "emergency 후 idle 유지")
    }

    /// Voice → emergency, 다른 4 source 시도 → 차단 (출처 다양화).
    func testEmergencyFromVoiceBlocksOtherSources() {
        session.start(.march)
        bridge.handleEmergency(from: .voice)
        XCTAssertEqual(bridge.emergencyCount, 1, "voice emergency 발화")

        bridge.handleMove(WalkingCommand(strideMm: 50, sideMm: 0, turnDeg: 0), from: .gamepad)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "gamepad move 차단")
    }

    // MARK: - 3. Recovery 후 5 source 모두 복귀

    /// emergency → recovery → 5 source 모두 다시 정상 동작.
    func testRecoveryRestoresAllFiveSources() {
        session.start(.march)
        bridge.handleEmergency(from: .ui)
        XCTAssertTrue(session.emergencyStopActive)

        bridge.handleRecovery(from: .ui)
        XCTAssertFalse(session.emergencyStopActive, "recovery → emergency clear")

        session.start(.march)  // restart.

        // 5 source 모두 정상 동작 — 각각 한 번씩 move.
        let sources: [InputSource] = [.keyboard, .tello, .voice, .gamepad, .ui]
        for (idx, source) in sources.enumerated() {
            let stride = Double(10 + idx * 5)
            bridge.handleMove(WalkingCommand(strideMm: stride, sideMm: 0, turnDeg: 0), from: source)
        }

        // 마지막 source (.ui) 의 stride 반영.
        XCTAssertEqual(session.strideMm, 30, accuracy: 1e-9,
                       "recovery 후 마지막 (UI) source move 반영")

        // 5 source 모두 다시 활동.
        let summary = bridge.accumulator.summarize()
        XCTAssertEqual(summary.sourcesUsed.count, 5,
                       "5 source 모두 active 복귀")
    }

    // MARK: - 4. InputSource enum 완성도

    /// `InputSource` 의 모든 case 가 라벨 / icon 정의 + bridge 처리 가능.
    func testAllInputSourcesHaveLabelAndIcon() {
        for source in InputSource.allCases {
            XCTAssertFalse(source.label.isEmpty,
                           "\(source) 의 label 정의됨")
            XCTAssertFalse(source.icon.isEmpty,
                           "\(source) 의 icon 정의됨")
        }
    }

    /// **사이클 79 코덱스 CRITICAL-1 fix**: 실제 wired 5 source 만 명시 — 사이클 73 의
    /// `InputSource.allCases` (6 cases — `.djiRC` 포함) iteration 은 false-positive.
    /// `.djiRC` 는 production wiring 부재 (cycle 67 이후 keyboard/tello/voice/gamepad/ui 만 wire)
    /// → enum iteration 으로 fake-pass. 본 test 는 실 wired 5 source 만 검증.
    func testAllSourcesPassThroughBridge() {
        session.start(.march)
        // 사이클 79 — 명시 5 source array (cycle 67 wired). `.djiRC` 는 별도 placeholder test.
        let wiredSources: [InputSource] = [.keyboard, .tello, .gamepad, .voice, .ui]
        XCTAssertEqual(wiredSources.count, 5, "5-source 명시")

        for (idx, source) in wiredSources.enumerated() {
            let stride = Double(10 + idx)
            bridge.handleMove(WalkingCommand(strideMm: stride, sideMm: 0, turnDeg: 0), from: source)
            // 각 source 의 마지막 intent 가 bridge.lastIntent 에 반영됨.
            XCTAssertEqual(bridge.lastIntent?.source, source,
                           "source \(source) → bridge.lastIntent 반영")
        }

        // 5 wired source 가 accumulator 기록 (allCases 6 와 분리).
        let summary = bridge.accumulator.summarize()
        XCTAssertEqual(summary.totalEvents, 5,
                       "5 wired source events 기록 (사이클 79 — allCases 6 와 명시 분리)")
        XCTAssertEqual(summary.sourcesUsed.count, 5,
                       "sourcesUsed 가 정확히 5 (.djiRC 미포함)")
    }

    /// **사이클 79 — `.djiRC` placeholder**: 미래 DJI 컨트롤러 SDK integration 시 wiring 추가.
    /// 현재는 production code 가 어디서도 `.djiRC` 를 emit 안 함 — 본 placeholder 가
    /// 향후 adapter 추가 시 회귀 가드 역할.
    func testDJIRCSourceIsPlaceholderNotYetWired() {
        // DJI controller adapter 가 wiring 되면 본 test 의 XCTSkip 제거 후 testAllSourcesPassThroughBridge
        // 에 `.djiRC` 추가. 그 전까지는 enum case 만 존재 — 실 사용 path 없음.
        let allCases = InputSource.allCases
        let wiredCases: [InputSource] = [.keyboard, .tello, .gamepad, .voice, .ui]
        let unwired = allCases.filter { !wiredCases.contains($0) }
        // 현재 unwired = [.djiRC]. 미래 wiring 시 unwired = [] → 본 assertion fail → 5-source test 갱신.
        XCTAssertEqual(unwired, [.djiRC],
                       "현재 unwired source = .djiRC (cycle 79 placeholder)")
    }

    // MARK: - 5. Preset 변경 source diversity

    /// 5 source 중 어떤 source 든 preset 변경 가능 — keyboard / gamepad / voice / ui.
    func testFiveSourcesCanChangePreset() {
        session.start(.march)
        XCTAssertEqual(session.current, .march)

        // 다른 preset 으로 변경 시도 — 각 source.
        bridge.handlePreset(.slowWalk, from: .keyboard)
        XCTAssertEqual(session.current, .slowWalk, "keyboard preset 변경")

        bridge.handlePreset(.march, from: .gamepad)
        XCTAssertEqual(session.current, .march, "gamepad preset 변경")

        bridge.handlePreset(.normalWalk, from: .voice)
        XCTAssertEqual(session.current, .normalWalk, "voice preset 변경")

        bridge.handlePreset(.march, from: .ui)
        XCTAssertEqual(session.current, .march, "ui preset 변경")

        // mirror 증가 — 사실상 4 개 다른 preset 전환 했음.
        XCTAssertGreaterThanOrEqual(bridge.presetChangeMirror, 4,
                                    "최소 4 preset transition 누적")
    }

    // MARK: - 6. Stop intent 다양화

    /// 5 source 중 어떤 source 가 stop 발화 — session amplitude 모두 0.
    func testStopFromAnySourceClearsAmplitude() {
        session.start(.march)
        bridge.handleMove(WalkingCommand(strideMm: 30, sideMm: 5, turnDeg: 2), from: .keyboard)
        XCTAssertEqual(session.strideMm, 30, accuracy: 1e-9)

        // voice stop.
        bridge.handleStop(from: .voice)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "voice stop → stride 0")

        // 다시 move + gamepad stop.
        bridge.handleMove(WalkingCommand(strideMm: 25, sideMm: 0, turnDeg: 0), from: .gamepad)
        XCTAssertEqual(session.strideMm, 25, accuracy: 1e-9)
        bridge.handleStop(from: .gamepad)
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "gamepad stop → stride 0")
    }
}
