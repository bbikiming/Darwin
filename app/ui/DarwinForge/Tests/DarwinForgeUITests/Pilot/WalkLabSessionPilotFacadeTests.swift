// V288-5: `#if DEBUG` wrap — _testForceWalkActive 는 DEBUG-only.
#if DEBUG
import Foundation
import XCTest
@testable import DarwinForgeUI

/// **사이클 60 — WalkLabSession+Pilot facade 회귀 가드**.
///
/// refactoring-specialist agent 가 추출한 facade method 의 동작 검증.
/// architect agent CRITICAL "god object surface 좁힘" 의 결과를 보존.
@MainActor
final class WalkLabSessionPilotFacadeTests: XCTestCase {

    var session: WalkLabSession!

    override func setUp() async throws {
        try await super.setUp()
        session = WalkLabSession()
    }

    override func tearDown() async throws {
        session = nil
        try await super.tearDown()
    }

    func testPilotSafetyContextComposition() {
        let ctx = session.pilotSafetyContext()
        XCTAssertEqual(ctx.balanceState, session.balanceState, "balanceState 동일")
        XCTAssertEqual(ctx.robotConnected, session.store?.bus != nil, "bus 연결 동일")
        XCTAssertEqual(ctx.riskAcknowledged, session.riskAcknowledged, "risk ack 동일")
    }

    func testPilotCurrentAmplitudeReflectsSliders() {
        session.advanced = true
        session.strideMm = 25
        session.sideMm = 10
        session.turnDeg = 5
        let cmd = session.pilotCurrentAmplitude
        XCTAssertEqual(cmd.strideMm, 25, accuracy: 1e-9)
        XCTAssertEqual(cmd.sideMm, 10, accuracy: 1e-9)
        XCTAssertEqual(cmd.turnDeg, 5, accuracy: 1e-9)
    }

    func testPilotIsEmergencyReflectsState() {
        XCTAssertFalse(session.pilotIsEmergency)
        session.start(.march)
        session.emergencyStop(trigger: .externalEStop)
        XCTAssertTrue(session.pilotIsEmergency)
        session.exitEmergencyMode()
        XCTAssertFalse(session.pilotIsEmergency)
    }

    func testPilotApplyAmplitudeBlockedDuringEmergency() {
        session.start(.march)
        session.emergencyStop(trigger: .externalEStop)
        XCTAssertTrue(session.emergencyStopActive)
        let result = session.pilotApplyAmplitude(WalkingCommand(strideMm: 30, sideMm: 0, turnDeg: 0))
        XCTAssertFalse(result, "emergency 중 write skip → false")
        XCTAssertEqual(session.strideMm, 0, accuracy: 1e-9, "amplitude 유지 (zero)")
    }

    // MARK: - 사이클 61 (codex HIGH-3) — pilotIsWalking invariant 누설 회귀 가드

    /// **HIGH-3 fix 검증 #1** — fresh session 에서 pilotIsWalking == false.
    ///
    /// invariant: `current == .idle && walkCycleTask == nil && !onboardWalkingActive`
    /// → 모든 sub-condition false → pilotIsWalking false.
    func testPilotIsWalkingFalseInIdleState() {
        // setUp 직후 fresh session — 모든 walking 신호 off.
        XCTAssertEqual(session.current, .idle, "fresh session 은 idle")
        XCTAssertFalse(session.isWalkActive, "isWalkActive false")
        XCTAssertFalse(session.pilotIsWalking, "pilotIsWalking false — 모든 sub-condition false")
        XCTAssertFalse(session.isActuallyWalking, "isActuallyWalking single source 도 false")
    }

    /// **HIGH-3 fix 검증 #2** — transitional state (current 만 set, walkCycleTask 미시작) 에서
    /// pilotIsWalking true.
    ///
    /// 종전 facade `current != .idle` 단순 술어는 본 transitional frame 에서도 true 였으나,
    /// 본체의 진짜 invariant (`current != .idle || walkCycleTask != nil || onboardWalkingActive`)
    /// 가 더 넓다. 본 테스트는 facade 가 새 single source 에 위임함을 검증 — 즉
    /// `current` 만으로도 true (sub-condition 1).
    func testPilotIsWalkingTrueWhenCurrentSetButTaskNotStarted() {
        // bus 미연결 상태에서 start() 호출 — bus guard 가 walkCycleTask 시작 차단.
        // 그러나 quickPreflight 통과 후 일부 상태가 set 될 수 있는 race window 시뮬.
        // 직접 `current` 를 set 해서 transitional frame 재현 (public setter).
        session.current = .march

        XCTAssertEqual(session.current, .march, "current 는 transitional 로 march set")
        // walkCycleTask 는 private 이지만 isActuallyWalking 이 흡수 — facade 가 true 반환해야 함.
        XCTAssertTrue(session.isActuallyWalking,
                      "current != .idle 만으로도 single source 가 true — race window 가드")
        XCTAssertTrue(session.pilotIsWalking,
                      "facade 가 isActuallyWalking 위임 → true (false negative 차단)")
    }

    /// **HIGH-3 fix 검증 #3** — stop() 후 즉시 query 시 pilotIsWalking false (recovery).
    ///
    /// invariant: stop() 이 walkCycleTask cancel + current=.idle + onboardWalkingActive=false
    /// 모두 정렬. recovery 후 즉시 query (다음 frame 기다리지 않음) 에서 false 반환.
    /// 종전 단순 facade 도 통과했으나, 새 facade 가 단일 source 로 위임해도 invariant 보존됨을
    /// 회귀 가드. bridge auto-start path 의 idempotent stop 안전 보장.
    func testPilotIsWalkingFalseImmediatelyAfterStop() {
        // 1. _testForceWalkActive 로 보행 시뮬 (bus 없이도 invariant 검증 가능).
        session._testForceWalkActive(.fastWalk)
        XCTAssertTrue(session.pilotIsWalking, "force walk 후 facade true")
        XCTAssertTrue(session.isActuallyWalking, "single source true")

        // 2. stop() 호출 — 모든 sub-condition 동기 reset.
        session.stop()

        // 3. 즉시 query (다음 frame 대기 X) → false.
        XCTAssertEqual(session.current, .idle, "stop 후 current=.idle")
        XCTAssertFalse(session.isWalkActive, "stop 후 isWalkActive=false")
        XCTAssertFalse(session.isActuallyWalking, "single source 가 즉시 false")
        XCTAssertFalse(session.pilotIsWalking,
                       "facade 가 즉시 false — recovery 후 query race 차단")
    }

    // MARK: - 사이클 69 (codex LOW-2) — pilotPostEvent facade 실 가치 검증

    /// source 인자가 있을 때 "[label] " prefix 가 자동 부착되는지.
    /// bridge 의 ad-hoc 패턴 (`"\(source.label) → ..."`) 을 facade 가 흡수.
    func testPilotPostEventAppliesSourcePrefix() {
        session.pilotPostEvent("preset march 시작", source: .ui)
        XCTAssertEqual(session.lastRobotEvent, "[UI 버튼] preset march 시작",
                       "non-nil source → '[label] ' prefix 자동")

        session.pilotPostEvent("stride=10 side=0 turn=0", source: .keyboard)
        XCTAssertEqual(session.lastRobotEvent, "[키보드] stride=10 side=0 turn=0",
                       "keyboard source label 적용")
    }

    /// source 가 nil (default) 이면 raw message 그대로 발행되어 backward compat 유지.
    /// 기존 callers (`session.pilotPostEvent("...")`) 가 깨지지 않음.
    func testPilotPostEventNoPrefixWhenSourceNil() {
        session.pilotPostEvent("raw 메시지 (prefix 없음)")
        XCTAssertEqual(session.lastRobotEvent, "raw 메시지 (prefix 없음)",
                       "source nil → prefix 미부착 (backward compat)")
    }

    /// 120 char (`pilotEventMaxLength`) 초과 시 절단 + "..." 마커 부착.
    /// HUD/badge layout 깨짐 방지.
    func testPilotPostEventEnforcesLengthCap() {
        // 200 char 메시지 (pilotEventMaxLength=120 보다 명확히 초과).
        let longMessage = String(repeating: "x", count: 200)
        session.pilotPostEvent(longMessage)

        guard let stamped = session.lastRobotEvent else {
            XCTFail("lastRobotEvent 미발행")
            return
        }
        XCTAssertEqual(stamped.count, WalkLabSession.pilotEventMaxLength,
                       "stamped 길이 == pilotEventMaxLength (cap 정확히 일치)")
        XCTAssertTrue(stamped.hasSuffix(WalkLabSession.pilotEventTruncationMarker),
                      "절단 마커 부착")
        XCTAssertEqual(String(stamped.prefix(3)), "xxx",
                       "메시지 head 보존 (절단은 tail 에서)")
    }

    /// 1초 (`pilotEventDedupWindow`) 이내 동일 stamped 메시지 silent drop.
    /// stick 빠르게 흔들 때 동일 amplitude 반복 발화 → HUD flicker 차단.
    func testPilotPostEventSuppressesDuplicatesInWindow() {
        session.pilotPostEvent("stride=10 side=0 turn=0", source: .keyboard)
        XCTAssertEqual(session.lastRobotEvent, "[키보드] stride=10 side=0 turn=0",
                       "첫 발행 성공")

        // 즉시 동일 stamped 재발행 — silent drop 검증 위해 lastRobotEvent 를 인위 변조.
        // dedup 가 lastRobotEvent 를 미터치하면 변조 마커 유지.
        session.lastRobotEvent = "manual mutation 마커"
        session.pilotPostEvent("stride=10 side=0 turn=0", source: .keyboard)
        XCTAssertEqual(session.lastRobotEvent, "manual mutation 마커",
                       "1초 내 동일 메시지 → silent drop (lastRobotEvent 미터치)")

        // 다른 메시지는 정상 발행 (dedup 가 동일성 비교만).
        session.pilotPostEvent("stride=20 side=0 turn=0", source: .keyboard)
        XCTAssertEqual(session.lastRobotEvent, "[키보드] stride=20 side=0 turn=0",
                       "다른 메시지는 dedup 무관 — 정상 발행")
    }

    /// dedup window 외 (1초 후) 동일 메시지는 재발행 허용.
    /// 사용자가 1초 이상 텀을 두고 같은 동작 반복 → 다시 안내 받아야 함.
    func testPilotPostEventReissuesAfterDedupWindow() {
        session.pilotPostEvent("preset march 시작", source: .ui)
        XCTAssertEqual(session.lastRobotEvent, "[UI 버튼] preset march 시작")

        // dedup timestamp 를 1.1초 전으로 인위 후퇴 → window 만료.
        session._lastPilotEventTime = Date().addingTimeInterval(
            -(WalkLabSession.pilotEventDedupWindow + 0.1)
        )
        session.lastRobotEvent = "stale marker"
        session.pilotPostEvent("preset march 시작", source: .ui)
        XCTAssertEqual(session.lastRobotEvent, "[UI 버튼] preset march 시작",
                       "dedup window 만료 → 동일 메시지 재발행 허용")
    }

    /// source label prefix 부착 후에도 length cap 이 stamped 전체 기준으로 적용.
    /// edge: raw 가 cap 이하라도 prefix 부착으로 초과될 수 있음.
    func testPilotPostEventLengthCapAppliesAfterSourcePrefix() {
        // raw 119 char + "[UI 버튼] " prefix 부착 시 cap 초과.
        let raw = String(repeating: "a", count: 119)
        session.pilotPostEvent(raw, source: .ui)

        guard let stamped = session.lastRobotEvent else {
            XCTFail("lastRobotEvent 미발행")
            return
        }
        XCTAssertEqual(stamped.count, WalkLabSession.pilotEventMaxLength,
                       "prefix 부착 후에도 cap 적용 — stamped 길이 정확히 120")
        XCTAssertTrue(stamped.hasPrefix("[UI 버튼]"),
                      "source prefix 는 보존 (head 보존)")
        XCTAssertTrue(stamped.hasSuffix(WalkLabSession.pilotEventTruncationMarker),
                      "tail 절단 마커")
    }
}
#endif
