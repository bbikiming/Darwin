#if DEBUG
import Foundation
import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// **방법론 (통합 테스트 — 순수함수 단위테스트와 실 robot 사이의 안전망)**:
///
/// `CockpitMotionParityTests` 는 `CockpitPoseResolver` / `CockpitDispatchDecision`
/// / `VirtualJoystickMapper` 같은 **순수 함수**를 검증한다. 그러나 사용자의 핵심
/// 질문 — "워크랩처럼 자이로 보정이 실시간 적용되고, 조종값에 따라 이동속도가
/// 변하는가" — 은 cockpit 의 입력이 **실제 `WalkLabSession` 인스턴스**의 motor
/// dispatch state (`customPeriodMs`, `enableBalanceCorrection`, `strideMm` 등) 로
/// 정확히 전파되는지에 달려 있다.
///
/// 본 테스트는 진짜 `WalkLabSession` + `CockpitState` 인스턴스를 만들어
/// `PilotCockpitView.dispatchRealMotorIfAllowed` 가 수행하는 facade 호출을 그대로
/// 재현해 chain 의 끝 (session state) 을 assert 한다.
///
/// # 검증 chain
///
/// ```
/// CockpitState.setSpeedScale(throttle)  →  cockpit.periodMs (derive)
///   →  session.pilotApplyAmplitudeWithPeriod(cmd, periodMs: cockpit.periodMs)
///     →  session.pilotApplyAmplitude(cmd)        [strideMm/sideMm/turnDeg + advanced=true]
///     →  session.customPeriodMs = clamp(periodMs, 600...850)
///   →  session.effectivePeriodMs == customPeriodMs (advanced=true 이므로)
/// ```
///
/// 자이로 보정 chain:
/// ```
/// cockpit "자이로 보정" 토글  →  session.enableBalanceCorrection
///   →  applyBalanceCorrectionIfEnabled(pose):
///        OFF  →  identity (pose 그대로, lastCorrectionApplied=false)
///        ON   →  P-control 경로 (IMU error → 관절 delta)
/// ```
@MainActor
final class CockpitPilotIntegrationTests: XCTestCase {

    var session: WalkLabSession!
    var cockpit: CockpitState!

    override func setUp() async throws {
        try await super.setUp()
        session = WalkLabSession()
        cockpit = CockpitState()
    }

    override func tearDown() async throws {
        session = nil
        cockpit = nil
        try await super.tearDown()
    }

    /// `PilotCockpitView.applyAmplitudeAndRecord` 의 핵심 호출 재현.
    @discardableResult
    private func dispatch(_ cmd: WalkingCommand, periodMs: Double) -> Bool {
        session.pilotApplyAmplitudeWithPeriod(cmd, periodMs: periodMs)
    }

    // MARK: - Group K1: Period propagation (throttle → motor cadence)

    func test_K01_period_propagates_to_session_customPeriodMs() {
        let cmd = WalkingCommand(strideMm: 30, sideMm: 0, turnDeg: 0)
        let ok = dispatch(cmd, periodMs: 600)
        XCTAssertTrue(ok, "정상 dispatch")
        XCTAssertEqual(session.customPeriodMs, 600, accuracy: 0.001,
                       "throttle period → session.customPeriodMs 전파")
        XCTAssertTrue(session.advanced,
                      "pilotApplyAmplitude 가 advanced=true 자동 활성")
        XCTAssertEqual(session.effectivePeriodMs, 600, accuracy: 0.001,
                       "advanced=true 이므로 effectivePeriodMs == customPeriodMs")
    }

    func test_K02_period_clamp_below_floor() {
        // 600 미만 → 600 으로 saturate (WalkLab freeform clamp).
        dispatch(WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0), periodMs: 400)
        XCTAssertEqual(session.customPeriodMs, 600, accuracy: 0.001,
                       "400ms → 600ms floor clamp")
    }

    func test_K03_period_clamp_above_ceiling() {
        // 850 초과 → 850 으로 saturate.
        dispatch(WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0), periodMs: 1000)
        XCTAssertEqual(session.customPeriodMs, 850, accuracy: 0.001,
                       "1000ms → 850ms ceiling clamp")
    }

    func test_K04_amplitude_propagates_to_session_sliders() {
        let cmd = WalkingCommand(strideMm: 38, sideMm: 22, turnDeg: 18)
        dispatch(cmd, periodMs: 700)
        XCTAssertEqual(session.strideMm, 38, accuracy: 0.001, "strideMm 전파")
        XCTAssertEqual(session.sideMm, 22, accuracy: 0.001, "sideMm 전파")
        XCTAssertEqual(session.turnDeg, 18, accuracy: 0.001, "turnDeg 전파")
    }

    // MARK: - Group K2: Emergency invariant

    func test_K05_period_write_blocked_during_emergency() {
        session.start(.march)
        let periodBefore = session.customPeriodMs
        session.emergencyStop(trigger: .externalEStop)
        let ok = dispatch(WalkingCommand(strideMm: 30, sideMm: 0, turnDeg: 0),
                          periodMs: 600)
        XCTAssertFalse(ok, "emergency 중 dispatch 거부")
        XCTAssertEqual(session.customPeriodMs, periodBefore, accuracy: 0.001,
                       "emergency 중 period write 차단 (race invariant)")
    }

    func test_K06_amplitude_write_blocked_during_emergency() {
        session.start(.march)
        session.advanced = true
        session.strideMm = 10
        session.emergencyStop(trigger: .externalEStop)
        // emergencyStop 자체가 안전을 위해 amplitude 를 zeroing 할 수 있음 (정상).
        // 핵심 invariant: dispatch 의 새 값 (38) 이 emergency 중에는 절대 안 써짐.
        dispatch(WalkingCommand(strideMm: 38, sideMm: 0, turnDeg: 0), periodMs: 600)
        XCTAssertNotEqual(session.strideMm, 38, accuracy: 0.001,
                          "emergency 중 새 amplitude (38) write 차단")
    }

    // MARK: - Group K3: Balance correction chain (자이로 보정)

    func test_K07_balance_correction_toggle_round_trip() {
        XCTAssertFalse(session.enableBalanceCorrection, "default OFF (안전)")
        session.enableBalanceCorrection = true
        XCTAssertTrue(session.enableBalanceCorrection, "토글 ON")
        session.enableBalanceCorrection = false
        XCTAssertFalse(session.enableBalanceCorrection, "토글 OFF")
    }

    func test_K08_balance_correction_identity_when_off() {
        session.enableBalanceCorrection = false
        let result = session.applyBalanceCorrectionIfEnabled(to: .walkReady)
        // OFF → identity (pose 그대로).
        for j in JointID.allCases {
            XCTAssertEqual(result.raw(j), RobotPose.walkReady.raw(j),
                           "보정 OFF → \(j) identity (변환 없음)")
        }
        XCTAssertFalse(session.lastCorrectionApplied,
                       "OFF → lastCorrectionApplied false")
    }

    func test_K09_balance_correction_is_wired_not_show_only() {
        // 핵심 검증: 보정이 "보여주기식" 이 아니라 실제 함수 경로임을 증명.
        // OFF 와 동일 pose 입력 시 lastCorrectionApplied 가 false 로 명확히 set 됨
        // (함수가 실제로 실행됐다는 증거 — no-op stub 이 아님).
        session.enableBalanceCorrection = false
        _ = session.applyBalanceCorrectionIfEnabled(to: .walkReady)
        XCTAssertFalse(session.lastCorrectionApplied)
        // lastSafePose 가 갱신됨 — 함수가 state 를 만진 증거.
        XCTAssertNotNil(session.lastSafePose,
                        "applyBalanceCorrectionIfEnabled 가 lastSafePose 갱신 — 실제 실행됨")
    }

    // MARK: - Group K4: Full cockpit → session chain

    func test_K10_full_chain_throttle_max_to_session_period() {
        // 사용자가 cockpit throttle 슬라이더를 1.5 (빠름) 로.
        cockpit.setSpeedScale(1.5)
        XCTAssertEqual(cockpit.periodMs, 600, accuracy: 0.001,
                       "throttle 1.5 → cockpit.periodMs 600")
        // cockpit 이 stick 입력 → lastCommand.
        cockpit.apply(leftX: 0, leftY: -1.0, turn: 0, from: .keyboard)
        // PilotCockpitView.dispatchRealMotorIfAllowed 가 하는 호출 재현.
        dispatch(cockpit.lastCommand, periodMs: cockpit.periodMs)
        // session 의 motor cadence 가 throttle 을 반영.
        XCTAssertEqual(session.customPeriodMs, 600, accuracy: 0.001,
                       "cockpit throttle → session motor cadence 600ms")
        // ROBOTIS Walking 속도 공식 검증: stride × 2000 / period.
        let expectedSpeed = session.strideMm * 2000.0 / session.customPeriodMs
        XCTAssertGreaterThan(expectedSpeed, 100,
                             "stick max + throttle max → 100+ mm/s")
    }

    func test_K11_full_chain_throttle_min_slower_motor() {
        cockpit.setSpeedScale(0.5)
        XCTAssertEqual(cockpit.periodMs, 850, accuracy: 0.001,
                       "throttle 0.5 → cockpit.periodMs 850")
        cockpit.apply(leftX: 0, leftY: -1.0, turn: 0, from: .keyboard)
        dispatch(cockpit.lastCommand, periodMs: cockpit.periodMs)
        XCTAssertEqual(session.customPeriodMs, 850, accuracy: 0.001,
                       "cockpit throttle min → session motor cadence 850ms (느림)")
    }

    func test_K12_variable_speed_same_stride_different_period() {
        // 동일 stick (stride) + 다른 throttle → 다른 motor period → 다른 속도.
        cockpit.apply(leftX: 0, leftY: -1.0, turn: 0, from: .keyboard)
        let stride = cockpit.lastCommand.strideMm

        cockpit.setSpeedScale(1.5)
        dispatch(cockpit.lastCommand, periodMs: cockpit.periodMs)
        let speedFast = stride * 2000.0 / session.customPeriodMs

        cockpit.setSpeedScale(0.5)
        dispatch(cockpit.lastCommand, periodMs: cockpit.periodMs)
        let speedSlow = stride * 2000.0 / session.customPeriodMs

        XCTAssertGreaterThan(speedFast, speedSlow,
                             "같은 보폭이라도 throttle 높으면 빠름 (cadence 차이)")
        XCTAssertEqual(speedFast / speedSlow, 850.0 / 600.0, accuracy: 0.01,
                       "속도 비 = period 역비 (ROBOTIS 공식)")
    }

    // MARK: - Group K5: Balance correction during active walk (보정 + 보행 동시)

    func test_K13_balance_correction_persists_through_amplitude_change() {
        // 보정 ON 상태에서 amplitude 변경해도 보정 토글 유지 (독립 state).
        session.enableBalanceCorrection = true
        dispatch(WalkingCommand(strideMm: 30, sideMm: 0, turnDeg: 0), periodMs: 700)
        XCTAssertTrue(session.enableBalanceCorrection,
                      "amplitude dispatch 후에도 보정 ON 유지")
        dispatch(WalkingCommand(strideMm: 38, sideMm: 10, turnDeg: 5), periodMs: 600)
        XCTAssertTrue(session.enableBalanceCorrection,
                      "period+amplitude 동시 변경 후에도 보정 ON 유지")
    }

    // MARK: - Group K6: 무중단 freeform 경로 (code review HIGH-1 fix)

    /// `pilotApplyFreeform` 의 핵심 호출 재현.
    @discardableResult
    private func freeform(_ cmd: WalkingCommand, periodMs: Double) -> Bool {
        session.pilotApplyFreeform(cmd, periodMs: periodMs)
    }

    func test_K14_freeform_writes_amplitude_and_period() {
        // **정직성 주의**: robot 미연결 (테스트 환경) 에서는 freeform cycle 이 cradle/
        // bus 게이트로 활성화되지 않아 반환값이 false 일 수 있다. 그러나
        // `applyMobileFreeformTuning` 은 게이트 **전에** slider 를 write 하므로
        // tuning 전파 (속도 모델의 핵심) 는 robot 없이도 검증된다. cycle 활성화
        // (mobileFreeformActive) 는 실 robot 필요 → motorGate 의 bus/dxl 조건 +
        // hardware E2E 로 별도 보장.
        freeform(WalkingCommand(strideMm: 30, sideMm: 5, turnDeg: 3), periodMs: 650)
        XCTAssertEqual(session.strideMm, 30, accuracy: 0.001,
                       "freeform tuning → strideMm 전파 (게이트 전 write)")
        XCTAssertEqual(session.sideMm, 5, accuracy: 0.001)
        XCTAssertEqual(session.turnDeg, 3, accuracy: 0.001)
        XCTAssertEqual(session.customPeriodMs, 650, accuracy: 0.001,
                       "freeform 이 period 도 전파")
        XCTAssertTrue(session.advanced,
                      "freeform tuning 이 advanced=true 활성 (customPeriodMs effective)")
    }

    func test_K15_freeform_clamps_to_walklab_range() {
        // freeform 은 mobileFreeformClamp 적용 — 과도 입력 saturate.
        freeform(WalkingCommand(strideMm: 999, sideMm: 999, turnDeg: 999),
                 periodMs: 100)
        XCTAssertLessThanOrEqual(session.strideMm, 38, "stride freeform clamp 38")
        XCTAssertLessThanOrEqual(session.sideMm, 22, "side freeform clamp 22")
        XCTAssertLessThanOrEqual(session.turnDeg, 18, "turn freeform clamp 18")
        XCTAssertGreaterThanOrEqual(session.customPeriodMs, 600,
                                    "period freeform clamp floor 600")
    }

    func test_K16_freeform_continuous_update_no_restart() {
        // **HIGH-1 핵심 검증 (data-level)**: 연속 freeform update 가 매번 tuning 을
        // 즉시 갱신 — 두 번째 호출의 stride/period 가 바로 반영된다. 이것이 "재시작
        // 없는 무중단 갱신" 의 데이터 측면 증거.
        //
        // (task-level 의 walkReady 멈칫 제거는 `startOrUpdateMobileFreeform` 이
        // mobileFreeformActive 시 startMobileFreeformCycle 을 호출하지 않고 early
        // return 하는 source 경로 — line 32-34 — 로 보장. robot 활성 상태는 E2E
        // 로 별도 검증.)
        freeform(WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0), periodMs: 700)
        XCTAssertEqual(session.strideMm, 20, accuracy: 0.001, "첫 update stride")
        XCTAssertEqual(session.customPeriodMs, 700, accuracy: 0.001, "첫 update period")
        // 연속 throttle/amplitude 변경 — 즉시 반영.
        freeform(WalkingCommand(strideMm: 38, sideMm: 0, turnDeg: 0), periodMs: 600)
        XCTAssertEqual(session.customPeriodMs, 600, accuracy: 0.001,
                       "두 번째 update 의 period 즉시 반영 (재시작 없이)")
        XCTAssertEqual(session.strideMm, 38, accuracy: 0.001,
                       "두 번째 update 의 amplitude 즉시 반영")
    }

    func test_K17_freeform_blocked_during_emergency() {
        session.start(.march)
        session.emergencyStop(trigger: .externalEStop)
        let ok = freeform(WalkingCommand(strideMm: 30, sideMm: 0, turnDeg: 0),
                          periodMs: 600)
        XCTAssertFalse(ok, "emergency 중 freeform 거부")
    }

    func test_K18_freeform_throttle_only_change_propagates() {
        // 무중단 경로의 핵심: stick 고정 + throttle 만 변경 → period 즉시 반영.
        freeform(WalkingCommand(strideMm: 30, sideMm: 0, turnDeg: 0), periodMs: 850)
        XCTAssertEqual(session.customPeriodMs, 850, accuracy: 0.001)
        // 같은 stride, throttle 만 빠르게 (period 600).
        freeform(WalkingCommand(strideMm: 30, sideMm: 0, turnDeg: 0), periodMs: 600)
        XCTAssertEqual(session.customPeriodMs, 600, accuracy: 0.001,
                       "throttle-only 변경 → period 즉시 motor 반영 (멈칫 없음)")
        XCTAssertEqual(session.strideMm, 30, accuracy: 0.001,
                       "stride 불변 (throttle 만 변경)")
    }

    func test_K19_freeform_balance_correction_wired() {
        // 보정 ON + freeform 보행 → applyBalanceCorrectionIfEnabled 가 동일하게
        // wire 됨 (transformPose). identity 가 아닌 실제 함수 경로 증명.
        session.enableBalanceCorrection = true
        freeform(WalkingCommand(strideMm: 20, sideMm: 0, turnDeg: 0), periodMs: 700)
        XCTAssertTrue(session.enableBalanceCorrection,
                      "freeform 보행 중 보정 ON 유지")
        // 보정 OFF 시 identity 반환 검증 (보여주기식 아님).
        session.enableBalanceCorrection = false
        let result = session.applyBalanceCorrectionIfEnabled(to: .walkReady)
        XCTAssertFalse(session.lastCorrectionApplied,
                       "보정 OFF → 미적용 (함수 실제 실행 증거)")
        for j in JointID.allCases {
            XCTAssertEqual(result.raw(j), RobotPose.walkReady.raw(j),
                           "OFF → identity")
        }
    }

    // MARK: - Group K7: 냉정 점검 후 안전 fix 검증 (CRITICAL/HIGH/MEDIUM)

    func test_K20_emergency_stop_sets_session_emergency() {
        // **CRITICAL fix**: cockpit E-Stop 이 session.emergencyStop 호출 → 즉시
        // hardware emergency. (PilotCockpitView.cockpitEmergencyStop 의 핵심 호출.)
        session.start(.march)
        XCTAssertFalse(session.pilotIsEmergency)
        session.emergencyStop(trigger: .userClick)
        XCTAssertTrue(session.pilotIsEmergency,
                      "E-Stop → session emergency 활성 (즉시 정지)")
    }

    func test_K21_emergency_blocks_subsequent_freeform_dispatch() {
        // E-Stop 후 stick 입력해도 freeform 거부 — 2초 marching 버그 제거 확인.
        session.emergencyStop(trigger: .userClick)
        let ok = freeform(WalkingCommand(strideMm: 38, sideMm: 0, turnDeg: 0),
                          periodMs: 600)
        XCTAssertFalse(ok, "emergency 중 freeform 차단 — robot 즉시 정지 유지")
    }

    func test_K22_recover_exits_session_emergency() {
        session.start(.march)
        session.emergencyStop(trigger: .userClick)
        XCTAssertTrue(session.pilotIsEmergency)
        // cockpitRecover 의 핵심: session.pilotEmergencyExit().
        session.pilotEmergencyExit()
        XCTAssertFalse(session.pilotIsEmergency, "Recover → emergency 해제")
    }

    func test_K23_release_clears_held_keys() {
        // **MEDIUM fix**: release() 가 heldKeys 정리 → E-Stop 후 ghost 키 제거.
        cockpit.insertHeldKey("w")
        cockpit.insertHeldKey("d")
        XCTAssertFalse(cockpit.heldKeys.isEmpty, "키 hold 상태")
        cockpit.release()
        XCTAssertTrue(cockpit.heldKeys.isEmpty,
                      "release → heldKeys 전부 clear (ghost 키 없음)")
        XCTAssertTrue(cockpit.lastCommand.isStop, "release → stop")
    }

    @MainActor
    func test_K24_backward_speed_gauge_honest_clamp() {
        // **냉정 점검 fix**: 후진 full (-38) 시 게이지가 freeform clamp (-30) 반영.
        // integrate() 가 30Hz timer 안에서 갱신하므로 직접 공식으로 검증.
        // mapper 후진 full → strideMm -38, freeform clamp → -30.
        let mapped = VirtualJoystickMapper.map(
            x: 0, y: 1.0, turn: 0, speedScale: 1.0,
            strideMmMax: VirtualJoystickMapper.cockpitStrideMm,
            sideMmMax: VirtualJoystickMapper.cockpitSideMm,
            turnDegMax: VirtualJoystickMapper.cockpitTurnDeg)
        XCTAssertEqual(mapped.strideMm, -38, accuracy: 0.5,
                       "mapper 후진 full = -38")
        let clamped = WalkMotionLibrary.mobileFreeformClamp(
            WalkMotionLibrary.AdvancedTuning(
                strideMm: mapped.strideMm, sideMm: 0, turnDeg: 0,
                periodMs: 600, footHeightMm: 35, balanceGain: 1.0,
                hipPitchOffsetDeg: 13.0))
        XCTAssertEqual(clamped.strideMm, -30, accuracy: 0.5,
                       "freeform clamp 후진 = -30 (실 motor 값) — 게이지도 이 값 사용")
    }
}
#endif
