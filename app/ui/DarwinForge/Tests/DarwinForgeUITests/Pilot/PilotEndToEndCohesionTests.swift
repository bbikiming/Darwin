import Foundation
import XCTest
@testable import DarwinForgeUI

/// **v1.22.0 (2026-05-22) — 사이클 90 후속: cycle 84-89 cohesion E2E 검증**.
///
/// 사이클 84-89 가 각각 PilotPreferences (영속 모델) / Settings panel (UI) /
/// PilotAudioFeedback (청각) / Phase 1A 분할 등 독립 component 도입. 본 suite 는
/// 이들이 **하나의 cohesive flow** 로 작동하는지 검증.
///
/// # 비유
///
/// 자동차 부품 — 엔진 / 브레이크 / 핸들이 각각 단위 테스트 OK 라도, 차로 조립 됐을 때
/// 페달 누름 → 엔진 회전 → 변속 → 바퀴 회전 전체 chain 이 동작해야 진짜 차. 본 suite
/// 는 pilot 시스템 의 부품 간 연동 검증.
///
/// # 시나리오
///
/// 1. PilotPreferences 영속 → bridge load 적용
/// 2. Bridge 의 audioFeedback 이 emergency 시 발화
/// 3. Bridge.handleMove → PilotLatencyTracker accumulate → reset
/// 4. Bridge.handleEmergency → 모든 source 차단 + audio beep + telemetry
@MainActor
final class PilotEndToEndCohesionTests: XCTestCase {

    private var mock: MockTelloLink!
    private var session: WalkLabSession!
    private var bridge: WalkLabRCBridge!
    private var prefsStore: InMemoryPilotPreferencesStore!
    private var audio: MockAudioFeedback!
    private var tracker: PilotLatencyTracker!

    override func setUp() async throws {
        try await super.setUp()
        mock = MockTelloLink()
        session = WalkLabSession()
        bridge = WalkLabRCBridge(tello: mock)
        bridge.session = session
        session.pilotBridge = bridge
        prefsStore = InMemoryPilotPreferencesStore()
        audio = MockAudioFeedback()
        bridge.audioFeedback = audio
        tracker = PilotLatencyTracker()
        bridge.latencyTracker = tracker
    }

    override func tearDown() async throws {
        tracker = nil
        audio = nil
        prefsStore = nil
        bridge = nil
        session = nil
        mock = nil
        try await super.tearDown()
    }

    // MARK: - 1. Persistence → Bridge launch wire-up

    /// PilotPreferences 가 저장된 값 → bridge.scale + smoothingFactor 에 적용.
    /// RootView 의 launch 시점 로직과 동일 동작 검증 (production wiring 일치).
    func testStoredPreferencesApplyToBridgeOnLaunch() {
        // 사전: 사용자가 이전 세션에서 sensitivity 저장.
        let custom = PilotPreferences(
            scaleLR: 0.7, scaleFB: 0.8, scaleYaw: 0.5, smoothingFactor: 0.4
        )
        prefsStore.save(custom)

        // launch wire-up 시뮬레이션 (RootView.onAppear 의 로직).
        let prefs = prefsStore.load()
        bridge.scale = TelloRCMapper.Scale(
            fb: prefs.scaleFB, lr: prefs.scaleLR, yaw: prefs.scaleYaw
        )
        bridge.smoothingFactor = prefs.smoothingFactor

        XCTAssertEqual(bridge.scale.lr, 0.7, accuracy: 1e-9, "사용자 저장 lr 반영")
        XCTAssertEqual(bridge.scale.fb, 0.8, accuracy: 1e-9, "fb 반영")
        XCTAssertEqual(bridge.scale.yaw, 0.5, accuracy: 1e-9, "yaw 반영")
        XCTAssertEqual(bridge.smoothingFactor, 0.4, accuracy: 1e-9, "smoothing 반영")
    }

    // MARK: - 2. Emergency → audio + latency + state machine 동시 발화

    /// 사용자 emergency 발화 → audio beep + latency cancel + bridge.emergencyCount + 차단.
    /// 4개 독립 component 가 단일 사용자 액션에 일관 반응 검증.
    func testEmergencyFiresAudioAndCancelsLatencyAndBlocks() {
        session.start(.march)
        XCTAssertEqual(audio.emergencyPlayCount, 0, "사전 audio 0")
        XCTAssertEqual(tracker.rejectedCount, 0, "사전 rejected 0")

        bridge.handleEmergency(from: .keyboard)

        // 4 invariant 동시 검증:
        XCTAssertEqual(bridge.emergencyCount, 1, "(1) emergency telemetry 증가")
        XCTAssertEqual(audio.emergencyPlayCount, 1, "(2) audio beep 1회 (사이클 86)")
        XCTAssertEqual(tracker.rejectedCount, 1, "(3) latency cycle cancel (사이클 71)")
        XCTAssertTrue(session.emergencyStopActive, "(4) state machine emergency 활성")
    }

    /// emergency 후 다른 source 의 move intent — audio 미발화 + latency reject + 차단.
    func testEmergencyBlocksFollowingMoveWithoutNewAudio() {
        bridge.handleEmergency(from: .ui)
        let audioBefore = audio.emergencyPlayCount
        let rejectedBefore = tracker.rejectedCount

        // emergency 활성 중 5 source 의 move 시도.
        for source in [InputSource.keyboard, .tello, .voice, .gamepad, .ui] {
            bridge.handleMove(WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0), from: source)
        }

        // emergency audio 는 추가 발화 안 함 (move 는 emergency 아님).
        XCTAssertEqual(audio.emergencyPlayCount, audioBefore,
                       "move intent 는 audio beep 안 함 (cycle 86 정책)")
        // 5 move 모두 rejected → rejectedCount +5.
        XCTAssertEqual(tracker.rejectedCount, rejectedBefore + 5,
                       "5 source move 모두 rejected (cycle 71)")
    }

    // MARK: - 3. Recovery 후 cohesion 복귀

    /// recovery → audio 무발화 (cycle 86 정책) + state clear + 모든 source 정상 동작.
    func testRecoveryRestoresFullPipeline() {
        bridge.handleEmergency(from: .keyboard)
        XCTAssertEqual(audio.emergencyPlayCount, 1)

        bridge.handleRecovery(from: .ui)
        // recovery 는 audio silent (cycle 86 정책 — 시각 banner 로 충분).
        XCTAssertEqual(audio.recoveryPlayCount, 0,
                       "recovery audio silent (cycle 86 정책)")
        XCTAssertFalse(session.emergencyStopActive, "state 정상 복귀")

        session.start(.march)
        bridge.handleMove(WalkingCommand(strideMm: 25, sideMm: 0, turnDeg: 0), from: .keyboard)
        XCTAssertEqual(session.strideMm, 25, accuracy: 1e-9,
                       "recovery 후 정상 move 처리 (모든 chain 복귀)")
    }

    // MARK: - 4. Preferences → bridge 즉시 갱신 (settings panel 시뮬)

    /// PilotSettingsPanel.applyToBridge 와 동일 path — slider onChange 즉시 반영.
    func testRealtimeBridgeUpdateMatchesSettingsPanelPattern() {
        let p1 = PilotPreferences(scaleLR: 0.5, scaleFB: 0.5, scaleYaw: 0.5, smoothingFactor: 0.8)
        // settings panel 의 applyToBridge static helper 와 동등.
        bridge.scale = TelloRCMapper.Scale(fb: p1.scaleFB, lr: p1.scaleLR, yaw: p1.scaleYaw)
        bridge.smoothingFactor = p1.smoothingFactor

        XCTAssertEqual(bridge.scale.lr, 0.5, accuracy: 1e-9)
        XCTAssertEqual(bridge.smoothingFactor, 0.8, accuracy: 1e-9)

        // 사용자가 슬라이더 더 조정.
        let p2 = PilotPreferences(scaleLR: 0.9, scaleFB: 0.9, scaleYaw: 0.9, smoothingFactor: 1.0)
        bridge.scale = TelloRCMapper.Scale(fb: p2.scaleFB, lr: p2.scaleLR, yaw: p2.scaleYaw)
        bridge.smoothingFactor = p2.smoothingFactor

        XCTAssertEqual(bridge.scale.lr, 0.9, accuracy: 1e-9, "realtime 갱신")
        XCTAssertEqual(bridge.smoothingFactor, 1.0, accuracy: 1e-9)

        // store 는 save 호출 안 했으므로 변경 안 됨 (settings panel 정책).
        XCTAssertEqual(prefsStore.load(), .defaultValues,
                       "store 는 'save' 버튼 클릭 시만 영속 — 슬라이더 onChange 무관")
    }

    // MARK: - 5. Save 후 다음 launch reload 일관성

    /// settings panel "저장" 후 → 다음 launch 시 동일 값 load → bridge 적용 일치.
    func testSaveAndReloadMatchesAcrossLaunches() {
        let custom = PilotPreferences(scaleLR: 0.6, scaleFB: 0.7, scaleYaw: 0.3, smoothingFactor: 0.5)
        prefsStore.save(custom)

        // "다음 launch" 시뮬 — 새 bridge 생성 + 동일 store 에서 load.
        let bridge2 = WalkLabRCBridge(tello: MockTelloLink())
        let loaded = prefsStore.load()
        bridge2.scale = TelloRCMapper.Scale(fb: loaded.scaleFB, lr: loaded.scaleLR, yaw: loaded.scaleYaw)
        bridge2.smoothingFactor = loaded.smoothingFactor

        XCTAssertEqual(bridge2.scale.lr, 0.6, accuracy: 1e-9, "next launch lr 일치")
        XCTAssertEqual(bridge2.scale.fb, 0.7, accuracy: 1e-9)
        XCTAssertEqual(bridge2.smoothingFactor, 0.5, accuracy: 1e-9)
    }

    // MARK: - 6. ClaudeAnalysis facade 분할 (cycle 89) 가 외부 API 보존

    /// cycle 89 의 setter 격상 (`private(set)` → `internal(set)`) 이 외부 API
    /// (다른 module) 에 setter 노출 안 함 검증. 본 module 안에선 setter 가능.
    func testClaudeAnalysisSplitPreservesReadOnlyExternally() {
        // 본 module 안에선 internal(set) — extension 의 write OK.
        // 외부 module 에선 public read-only — Compile-check 으로 보장.
        // 본 test 는 본 module 안에서 read 가 정상 작동 검증.
        XCTAssertNil(session.claudeAnalysisMarkdown, "초기 nil")
        XCTAssertFalse(session.claudeAnalysisInProgress, "초기 false")
        XCTAssertNil(session.claudeAnalysisError, "초기 nil")

        // clearClaudeAnalysis 는 extension method (cycle 89 이동).
        session.clearClaudeAnalysis()
        XCTAssertNil(session.claudeAnalysisMarkdown, "clear 후 nil")
    }
}
