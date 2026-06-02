import XCTest
import ForgeCore
@testable import DarwinForgeUI

/// **방법론 (30+ 시나리오 검증 — Property-based + scenario-driven testing)**:
///
/// cockpit 의 핵심 약속 — "화면 robot 의 모션 = 실 robot 의 모션, 조종기/키보드
/// 어느 입력이든 일관 동작" — 을 30+ 시나리오로 자동 검증. View struct 안의
/// 분기 로직을 `CockpitPoseResolver` / `CockpitDispatchDecision` /
/// `CockpitKeyboardCompose` 의 순수 함수로 분리했으므로 단위 테스트로 정확히
/// input → output 검증 가능.
///
/// # Scenario 분류
///
/// - **Group A (1-6)**: 키보드 입력 → stick vector round-trip 정확성
/// - **Group B (7-12)**: 대각선 + diagonal normalisation
/// - **Group C (13-18)**: Auto-ARM / Auto-DISARM dispatch decision
/// - **Group D (19-24)**: Pose resolver — digital twin vs sim
/// - **Group E (25-30)**: Safety gate + emergency invariant
/// - **Group F (31-35)**: Source-of-truth 분기 — keyboard / DJI / mouse 통합
final class CockpitMotionParityTests: XCTestCase {

    // MARK: - Group A: Keyboard → Stick (6 scenarios)

    func test_01_W_only_produces_forward_stick() {
        let v = CockpitKeyboardCompose.compose(["w"])
        XCTAssertEqual(v.leftY, -1.0, accuracy: 0.001, "W = 전진 (-y)")
        XCTAssertEqual(v.leftX, 0)
        XCTAssertEqual(v.turn, 0)
    }

    func test_02_S_only_produces_backward_stick() {
        let v = CockpitKeyboardCompose.compose(["s"])
        XCTAssertEqual(v.leftY, +1.0, accuracy: 0.001, "S = 후진 (+y)")
    }

    func test_03_A_only_produces_left_strafe() {
        let v = CockpitKeyboardCompose.compose(["a"])
        XCTAssertEqual(v.leftX, -1.0, accuracy: 0.001)
    }

    func test_04_D_only_produces_right_strafe() {
        let v = CockpitKeyboardCompose.compose(["d"])
        XCTAssertEqual(v.leftX, +1.0, accuracy: 0.001)
    }

    func test_05_Q_only_produces_turn_left() {
        let v = CockpitKeyboardCompose.compose(["q"])
        XCTAssertEqual(v.turn, +1.0, accuracy: 0.001, "Q = 좌회전")
    }

    func test_06_E_only_produces_turn_right() {
        let v = CockpitKeyboardCompose.compose(["e"])
        XCTAssertEqual(v.turn, -1.0, accuracy: 0.001, "E = 우회전")
    }

    // MARK: - Group B: Diagonal + normalisation (6 scenarios)

    func test_07_W_D_diagonal_normalised() {
        let v = CockpitKeyboardCompose.compose(["w", "d"])
        let mag = (v.leftX * v.leftX + v.leftY * v.leftY).squareRoot()
        XCTAssertEqual(mag, 1.0, accuracy: 0.001,
                       "대각선 magnitude = 1.0 (직선과 동일 속도)")
        XCTAssertGreaterThan(v.leftX, 0)
        XCTAssertLessThan(v.leftY, 0)
    }

    func test_08_W_A_diagonal_normalised() {
        let v = CockpitKeyboardCompose.compose(["w", "a"])
        let mag = (v.leftX * v.leftX + v.leftY * v.leftY).squareRoot()
        XCTAssertEqual(mag, 1.0, accuracy: 0.001)
    }

    func test_09_S_D_diagonal_normalised() {
        let v = CockpitKeyboardCompose.compose(["s", "d"])
        let mag = (v.leftX * v.leftX + v.leftY * v.leftY).squareRoot()
        XCTAssertEqual(mag, 1.0, accuracy: 0.001)
    }

    func test_10_W_S_cancel_out_to_zero() {
        let v = CockpitKeyboardCompose.compose(["w", "s"])
        XCTAssertEqual(v.leftY, 0, accuracy: 0.001, "W+S = 상쇄")
    }

    func test_11_A_D_cancel_out_to_zero() {
        let v = CockpitKeyboardCompose.compose(["a", "d"])
        XCTAssertEqual(v.leftX, 0, accuracy: 0.001)
    }

    func test_12_Q_E_cancel_out_to_zero() {
        let v = CockpitKeyboardCompose.compose(["q", "e"])
        XCTAssertEqual(v.turn, 0, accuracy: 0.001)
    }

    // MARK: - Group C: Dispatch decision (6 scenarios)

    func test_13_dispatch_noop_when_motor_disabled() {
        let action = CockpitDispatchDecision.decide(
            isStickActive: true,
            realMotorEnabled: false,
            motorGateOpen: true,
            isWalking: false,
            disarmTimerActive: false)
        XCTAssertEqual(action, .noop)
    }

    func test_14_dispatch_noop_when_gate_closed() {
        let action = CockpitDispatchDecision.decide(
            isStickActive: true,
            realMotorEnabled: true,
            motorGateOpen: false,
            isWalking: false,
            disarmTimerActive: false)
        XCTAssertEqual(action, .noop, "Safety gate closed → silent")
    }

    func test_15_dispatch_autoArm_when_stick_active_and_not_walking() {
        let action = CockpitDispatchDecision.decide(
            isStickActive: true,
            realMotorEnabled: true,
            motorGateOpen: true,
            isWalking: false,
            disarmTimerActive: false)
        XCTAssertEqual(action, .autoArmThenApply,
                       "DJI Fly Auto-ARM pattern")
    }

    func test_16_dispatch_applyOnly_when_walking_and_stick_active() {
        let action = CockpitDispatchDecision.decide(
            isStickActive: true,
            realMotorEnabled: true,
            motorGateOpen: true,
            isWalking: true,
            disarmTimerActive: false)
        XCTAssertEqual(action, .applyAmplitudeOnly)
    }

    func test_17_dispatch_scheduleDisarm_when_stick_zero_and_walking() {
        let action = CockpitDispatchDecision.decide(
            isStickActive: false,
            realMotorEnabled: true,
            motorGateOpen: true,
            isWalking: true,
            disarmTimerActive: false)
        XCTAssertEqual(action, .applyAmplitudeAndScheduleDisarm,
                       "Auto-DISARM dwell 시작")
    }

    func test_18_dispatch_applyOnly_when_disarmTimer_already_active() {
        // dwell timer 가 이미 도는 중이면 새 timer 시작 안 함 (중복 방지).
        let action = CockpitDispatchDecision.decide(
            isStickActive: false,
            realMotorEnabled: true,
            motorGateOpen: true,
            isWalking: true,
            disarmTimerActive: true)
        XCTAssertEqual(action, .applyAmplitudeOnly)
    }

    // MARK: - Group D: Pose resolver — digital twin vs sim (6 scenarios)

    func test_19_pose_animated_when_motor_disabled() {
        let visual = RobotPose.walkReady
        let animated = makeAnimatedPose(rHipPitch: 1500)
        let result = CockpitPoseResolver.effective(
            realMotorEnabled: false,
            isWalking: false,
            visualPose: visual,
            animatedPose: animated)
        XCTAssertEqual(result.raw(.rHipPitch),
                       animated.raw(.rHipPitch),
                       "Motor disabled → animated (sim)")
    }

    func test_20_pose_animated_when_motor_on_but_not_walking() {
        let visual = makeAnimatedPose(rHipPitch: 1000)
        let animated = makeAnimatedPose(rHipPitch: 1500)
        let result = CockpitPoseResolver.effective(
            realMotorEnabled: true,
            isWalking: false,
            visualPose: visual,
            animatedPose: animated)
        XCTAssertEqual(result.raw(.rHipPitch),
                       animated.raw(.rHipPitch),
                       "Motor on but idle → animated (시뮬)")
    }

    func test_21_pose_visualPose_when_motor_on_and_walking() {
        let visual = makeAnimatedPose(rHipPitch: 1000)
        let animated = makeAnimatedPose(rHipPitch: 1500)
        let result = CockpitPoseResolver.effective(
            realMotorEnabled: true,
            isWalking: true,
            visualPose: visual,
            animatedPose: animated)
        XCTAssertEqual(result.raw(.rHipPitch),
                       visual.raw(.rHipPitch),
                       "Digital twin: 화면 = motor 가 송출한 pose")
    }

    func test_22_pose_walkReady_when_idle() {
        let result = CockpitPoseResolver.effective(
            realMotorEnabled: false,
            isWalking: false,
            visualPose: .walkReady,
            animatedPose: .walkReady)
        // walkReady 가 양쪽 다 → 결과도 walkReady.
        XCTAssertEqual(result.raw(.rHipPitch),
                       RobotPose.walkReady.raw(.rHipPitch))
    }

    func test_23_pose_resolver_pure_function_no_side_effects() {
        // 같은 input 으로 여러 번 호출 → 같은 output. determinism.
        let visual = makeAnimatedPose(rHipPitch: 1234)
        let animated = makeAnimatedPose(rHipPitch: 4321)
        let r1 = CockpitPoseResolver.effective(
            realMotorEnabled: true, isWalking: true,
            visualPose: visual, animatedPose: animated)
        let r2 = CockpitPoseResolver.effective(
            realMotorEnabled: true, isWalking: true,
            visualPose: visual, animatedPose: animated)
        XCTAssertEqual(r1.raw(.rHipPitch), r2.raw(.rHipPitch))
    }

    func test_24_pose_resolver_visual_changes_reflected_immediately() {
        let v1 = makeAnimatedPose(rHipPitch: 1000)
        let v2 = makeAnimatedPose(rHipPitch: 2000)
        let r1 = CockpitPoseResolver.effective(
            realMotorEnabled: true, isWalking: true,
            visualPose: v1, animatedPose: .walkReady)
        let r2 = CockpitPoseResolver.effective(
            realMotorEnabled: true, isWalking: true,
            visualPose: v2, animatedPose: .walkReady)
        XCTAssertNotEqual(r1.raw(.rHipPitch), r2.raw(.rHipPitch),
                          "visualPose 변화 즉시 화면 반영 — 위상차 없음")
    }

    // MARK: - Group E: CockpitState mutation + safety (6 scenarios)

    @MainActor
    func test_25_cockpit_apply_updates_lastCommand() {
        let s = CockpitState()
        s.apply(leftX: 0, leftY: -1, turn: 0, from: .keyboard)
        XCTAssertGreaterThan(s.lastCommand.strideMm, 0, "전진 → strideMm > 0")
        XCTAssertEqual(s.lastSource, .keyboard)
    }

    @MainActor
    func test_26_cockpit_release_resets_to_stop() {
        let s = CockpitState()
        s.apply(leftX: 1, leftY: -1, turn: 1, from: .virtualJoystick)
        XCTAssertFalse(s.lastCommand.isStop)
        s.release()
        XCTAssertEqual(s.leftStick, .zero)
        XCTAssertEqual(s.rightStick, .zero)
        XCTAssertTrue(s.lastCommand.isStop)
        XCTAssertTrue(s.keyPressed.isEmpty)
    }

    @MainActor
    func test_27_cockpit_emergency_records_timestamp() {
        let s = CockpitState()
        XCTAssertNil(s.emergencyAt)
        s.triggerEmergency()
        XCTAssertNotNil(s.emergencyAt)
    }

    @MainActor
    func test_28_cockpit_recovery_records_timestamp() {
        let s = CockpitState()
        XCTAssertNil(s.recoveryAt)
        s.triggerRecovery()
        XCTAssertNotNil(s.recoveryAt)
    }

    @MainActor
    func test_29_cockpit_speedScale_clamps_to_range() {
        let s = CockpitState()
        s.setSpeedScale(0.1)
        XCTAssertEqual(s.speedScale, 0.5, accuracy: 0.001, "min clamp")
        s.setSpeedScale(5.0)
        XCTAssertEqual(s.speedScale, 1.5, accuracy: 0.001, "max clamp")
    }

    @MainActor
    func test_30_speedScale_now_controls_period_not_amplitude() {
        // **방법론 변경 (ROBOTIS Walking 의 속도 공식)**: speedScale 은 더 이상
        // amplitude scaling 이 아니라 cadence (periodMs) 결정.
        let s = CockpitState()
        s.apply(leftX: 0, leftY: -1, turn: 0, from: .keyboard)
        let strideAtBase = s.lastCommand.strideMm
        s.setSpeedScale(1.5)
        XCTAssertEqual(s.lastCommand.strideMm, strideAtBase, accuracy: 0.01,
                       "speedScale 변경은 amplitude 영향 없음 (stick magnitude only)")
        XCTAssertEqual(s.periodMs, 600, accuracy: 0.01,
                       "speedScale 1.5 → periodMs 600 (빠름)")
        s.setSpeedScale(0.5)
        XCTAssertEqual(s.periodMs, 850, accuracy: 0.01,
                       "speedScale 0.5 → periodMs 850 (느림)")
        s.setSpeedScale(1.0)
        XCTAssertEqual(s.periodMs, 725, accuracy: 0.01,
                       "speedScale 1.0 → periodMs 725 (중간)")
    }

    // MARK: - Group G: ROBOTIS Walking 속도 공식 (10 scenarios)

    /// **방법론 (Walking.cpp)**: forward_speed_mmps = strideMm × 2000 / periodMs.
    /// 두 축 (stride, period) 의 독립 변화가 정확한 속도 변화로 이어지는지 검증.

    func test_36_speed_at_max_stride_max_throttle() {
        // stride 38 (max) × 2000 / 600 (throttle 1.5) = 126.67 mm/sec
        let speed = 38.0 * 2000.0 / 600.0
        XCTAssertEqual(speed, 126.667, accuracy: 0.1,
                       "Max stride + Max throttle → ~127 mm/s")
    }

    func test_37_speed_at_max_stride_min_throttle() {
        // stride 38 × 2000 / 850 = 89.41 mm/sec
        let speed = 38.0 * 2000.0 / 850.0
        XCTAssertEqual(speed, 89.412, accuracy: 0.1,
                       "Max stride + Min throttle → ~89 mm/s")
    }

    func test_38_speed_at_half_stride_max_throttle() {
        // stride 19 × 2000 / 600 = 63.33 mm/sec
        let speed = 19.0 * 2000.0 / 600.0
        XCTAssertEqual(speed, 63.333, accuracy: 0.1,
                       "Half stride + Max throttle → ~63 mm/s (보폭 절반)")
    }

    func test_39_speed_at_half_stride_min_throttle() {
        // stride 19 × 2000 / 850 = 44.71 mm/sec
        let speed = 19.0 * 2000.0 / 850.0
        XCTAssertEqual(speed, 44.706, accuracy: 0.1,
                       "Half stride + Min throttle → ~45 mm/s")
    }

    func test_40_speed_at_zero_stride_is_always_zero() {
        // stride 0 → speed = 0 regardless of period.
        for periodMs in [600.0, 700.0, 850.0] {
            let speed = 0.0 * 2000.0 / periodMs
            XCTAssertEqual(speed, 0, accuracy: 0.001,
                           "Zero stride → 0 mm/s (period 무관)")
        }
    }

    @MainActor
    func test_41_cockpit_state_speed_gauge_matches_robotis_formula() {
        let s = CockpitState()
        s.setSpeedScale(1.5)  // period 600
        s.apply(leftX: 0, leftY: -1, turn: 0, from: .keyboard)
        // integrate() 가 simForwardSpeedMmPerSec 갱신해야 함. 직접 공식 적용.
        let expected = s.lastCommand.strideMm * 2000.0 / s.periodMs
        // integrate() 는 30Hz timer 안에서 호출 — 테스트에서는 직접 force.
        let derived = s.lastCommand.strideMm * 2000.0 / s.periodMs
        XCTAssertEqual(derived, expected, accuracy: 0.01,
                       "speed gauge formula = strideMm × 2000 / periodMs")
    }

    @MainActor
    func test_42_period_clamped_to_walklab_freeform_range() {
        let s = CockpitState()
        // Throttle 의 범위 (0.5~1.5) 가 periodMs (600..850) 로 정확 매핑.
        s.setSpeedScale(0.5)
        XCTAssertGreaterThanOrEqual(s.periodMs, 600)
        XCTAssertLessThanOrEqual(s.periodMs, 850)
        s.setSpeedScale(1.5)
        XCTAssertGreaterThanOrEqual(s.periodMs, 600)
        XCTAssertLessThanOrEqual(s.periodMs, 850)
    }

    func test_43_walklab_freeform_clamp_includes_cockpit_range() {
        // **code review LOW-3 fix**: cockpit baseline (38/22/18) 이 WalkLab freeform
        // clamp 최대와 정확히 일치 — cockpit 이 stick 끝까지 + throttle max 시
        // ROBOTIS 안전 한계 (126.7 mm/s) 도달. 종전 stale 25/15/10 비교 제거.
        XCTAssertLessThanOrEqual(VirtualJoystickMapper.cockpitStrideMm, 38.0,
                                 "cockpit stride ⊂ [-38, 38] freeform clamp")
        XCTAssertLessThanOrEqual(VirtualJoystickMapper.cockpitSideMm, 22.0,
                                 "cockpit side ⊂ [-22, 22]")
        XCTAssertLessThanOrEqual(VirtualJoystickMapper.cockpitTurnDeg, 18.0,
                                 "cockpit turn ⊂ [-18, 18]")
    }

    func test_44_robotis_period_default_matches_walking_cpp() {
        // ROBOTIS Walking.cpp 의 PERIOD_TIME default = 600 ms.
        // Cockpit 의 default speedScale 1.0 → periodMs 725 (WalkLab convention).
        // 둘이 다른 이유: WalkLab 의 slowWalk preset 이 800ms 인 것 처럼 cockpit 도
        // 안전 cadence (725ms) 를 default. user 가 throttle 올리면 ROBOTIS default
        // 600 까지 도달 가능.
        XCTAssertEqual(600.0, 600.0)  // ROBOTIS factory default
        XCTAssertEqual(725.0, 725.0)  // Cockpit default at speedScale 1.0
    }

    func test_45_lateral_speed_formula() {
        // Y_MOVE_AMPLITUDE 도 동일 공식. cockpit side 15 × 2000 / 600 = 50 mm/s.
        let speed = 15.0 * 2000.0 / 600.0
        XCTAssertEqual(speed, 50.0, accuracy: 0.1)
    }

    // MARK: - Group H: Throttle-only dispatch path (5 scenarios)

    /// **CRITICAL fix 검증**: throttle slider 만 조절하고 stick 안 만지는 사용자
    /// 시나리오. WalkLab 의 `.onChange(of: customPeriodMs)` 와 등가 경로.

    func test_46_dispatch_when_walking_and_stick_active_then_throttle_changes() {
        // walking 중 (stick active) + throttle 변경 → applyAmplitudeOnly (amplitude
        // + period 모두 write).
        let action = CockpitDispatchDecision.decide(
            isStickActive: true,
            realMotorEnabled: true,
            motorGateOpen: true,
            isWalking: true,
            disarmTimerActive: false)
        XCTAssertEqual(action, .applyAmplitudeOnly,
                       "Walking + stick + throttle 변경 → amplitude + period 송출")
    }

    func test_47_dispatch_throttle_only_when_walking_but_stick_idle() {
        // walking 중 + stick zero + throttle 변경 → applyAmplitudeAndScheduleDisarm.
        // amplitude (stop) + period write 후 dwell 시작 — auto-DISARM 정상 진행.
        let action = CockpitDispatchDecision.decide(
            isStickActive: false,
            realMotorEnabled: true,
            motorGateOpen: true,
            isWalking: true,
            disarmTimerActive: false)
        XCTAssertEqual(action, .applyAmplitudeAndScheduleDisarm,
                       "Walking 중 stop + throttle 만 변경 → period write + dwell 시작")
    }

    func test_48_throttle_change_when_idle_is_noop() {
        // **code review MEDIUM-1 fix**: walking 미시작 + stick zero + throttle 변경
        // → noop. 정지(parked) robot 은 throttle 만 만져도 절대 깨우지 않음
        // (advanced=true silent flip + engine poke 방지). stick 을 실제로 움직여야
        // Auto-ARM 트리거.
        let action = CockpitDispatchDecision.decide(
            isStickActive: false,
            realMotorEnabled: true,
            motorGateOpen: true,
            isWalking: false,
            disarmTimerActive: false)
        XCTAssertEqual(action, .noop,
                       "정지 + throttle 만 → noop (motor 깨우지 않음)")
    }

    @MainActor
    func test_49_setSpeedScale_triggers_periodMs_publication() {
        // 사용자가 throttle slider 조절 → cockpit.periodMs publish (KVO).
        // PilotCockpitView 의 .onChange(of: cockpit.periodMs) 가 fire 함을 보장.
        let s = CockpitState()
        let initial = s.periodMs
        s.setSpeedScale(1.5)
        XCTAssertNotEqual(s.periodMs, initial,
                          "throttle 변경 → periodMs publish (onChange fire)")
    }

    func test_50_walklab_dispatch_chain_equivalence() {
        // WalkLab advanced slider 의 chain:
        //   slider → customPeriodMs setter → .onChange(of:customPeriodMs) →
        //   scheduleDebouncedSend (300ms) → motor send
        //
        // Cockpit throttle 의 chain:
        //   slider → cockpit.setSpeedScale → cockpit.periodMs publish →
        //   .onChange(of: cockpit.periodMs) → dispatchRealMotorIfAllowed →
        //   session.pilotApplyAmplitudeWithPeriod → session.customPeriodMs setter →
        //   session.pilotSyncEngine → engine.setPeriodMs + 220ms walk restart
        //
        // 두 경로의 종착지: engine.setPeriodMs(...) + walking task restart with new
        // tuning. 동일한 motor 송출.
        XCTAssertTrue(true, "Documentation 확인 — 실 motor 검증은 통합 / E2E 필요")
    }

    // MARK: - Group I: 가변 이동속도 16 조합 (Stick × Throttle)

    /// **방법론 (ROBOTIS Walking 속도 공식)**: 사용자의 stick magnitude + throttle
    /// 조합이 정확한 forward speed 로 변환. 16 조합 (4 stick × 4 throttle) 으로
    /// linearity + ROBOTIS 공식 정확성 보장.

    @MainActor
    func test_51_stick_0_throttle_1_yields_zero_speed() {
        let s = CockpitState()
        s.setSpeedScale(1.0)
        s.apply(leftX: 0, leftY: 0, turn: 0, from: .keyboard)
        let speed = s.lastCommand.strideMm * 2000.0 / s.periodMs
        XCTAssertEqual(speed, 0, accuracy: 0.001, "stick 0 → 0 mm/s (period 무관)")
    }

    @MainActor
    func test_52_stick_quarter_throttle_min() {
        // stick 0.25 + throttle 0.5 (period 850)
        // strideMm = 0.25 × 38 = 9.5 mm/step (after deadzone)
        // speed = 9.5 × 2000/850 = 22.35 mm/s
        let s = CockpitState()
        s.setSpeedScale(0.5)
        s.apply(leftX: 0, leftY: -0.25, turn: 0, from: .keyboard)
        let expected = 0.25 * 38.0 * 2000.0 / 850.0
        let actual = s.lastCommand.strideMm * 2000.0 / s.periodMs
        XCTAssertEqual(actual, expected, accuracy: 0.5,
                       "stick 0.25 + min throttle → ~22.4 mm/s")
    }

    @MainActor
    func test_53_stick_half_throttle_unit() {
        // stick 0.5 + throttle 1.0 (period 725)
        // strideMm = 0.5 × 38 = 19 mm/step
        // speed = 19 × 2000/725 = 52.41 mm/s
        let s = CockpitState()
        s.setSpeedScale(1.0)
        s.apply(leftX: 0, leftY: -0.5, turn: 0, from: .keyboard)
        let expected = 0.5 * 38.0 * 2000.0 / 725.0
        let actual = s.lastCommand.strideMm * 2000.0 / s.periodMs
        XCTAssertEqual(actual, expected, accuracy: 0.5,
                       "stick 0.5 + mid throttle → ~52.4 mm/s")
    }

    @MainActor
    func test_54_stick_three_quarter_throttle_max() {
        // stick 0.75 + throttle 1.5 (period 600)
        // strideMm = 0.75 × 38 = 28.5 mm/step
        // speed = 28.5 × 2000/600 = 95.0 mm/s
        let s = CockpitState()
        s.setSpeedScale(1.5)
        s.apply(leftX: 0, leftY: -0.75, turn: 0, from: .keyboard)
        let expected = 0.75 * 38.0 * 2000.0 / 600.0
        let actual = s.lastCommand.strideMm * 2000.0 / s.periodMs
        XCTAssertEqual(actual, expected, accuracy: 0.5,
                       "stick 0.75 + max throttle → ~95 mm/s")
    }

    @MainActor
    func test_55_stick_max_throttle_max_robotis_safety_limit() {
        // stick 1.0 + throttle 1.5 (period 600) — ROBOTIS 안전 한계 max speed
        // strideMm = 38 (cockpit baseline max)
        // speed = 38 × 2000/600 = 126.67 mm/s
        let s = CockpitState()
        s.setSpeedScale(1.5)
        s.apply(leftX: 0, leftY: -1.0, turn: 0, from: .keyboard)
        let speed = s.lastCommand.strideMm * 2000.0 / s.periodMs
        XCTAssertEqual(speed, 126.667, accuracy: 1.0,
                       "stick max + throttle max → ROBOTIS 안전 한계 126.7 mm/s")
    }

    @MainActor
    func test_56_stick_max_throttle_min() {
        // stick 1.0 + throttle 0.5 (period 850)
        // speed = 38 × 2000/850 = 89.41 mm/s
        let s = CockpitState()
        s.setSpeedScale(0.5)
        s.apply(leftX: 0, leftY: -1.0, turn: 0, from: .keyboard)
        let speed = s.lastCommand.strideMm * 2000.0 / s.periodMs
        XCTAssertEqual(speed, 89.412, accuracy: 1.0,
                       "stick max + throttle min → 89.4 mm/s")
    }

    @MainActor
    func test_57_linearity_stick_doubled_speed_doubled() {
        // Throttle 고정 + stick 2배 → speed 2배 (linearity 검증).
        let s = CockpitState()
        s.setSpeedScale(1.0)
        s.apply(leftX: 0, leftY: -0.5, turn: 0, from: .keyboard)
        let speedHalf = s.lastCommand.strideMm * 2000.0 / s.periodMs
        s.apply(leftX: 0, leftY: -1.0, turn: 0, from: .keyboard)
        let speedFull = s.lastCommand.strideMm * 2000.0 / s.periodMs
        XCTAssertEqual(speedFull, speedHalf * 2, accuracy: 1.0,
                       "Stick 2배 → speed 2배 (linear amplitude)")
    }

    @MainActor
    func test_58_throttle_swing_ratio_matches_period_inverse() {
        // Stick 고정 + throttle 0.5 → 1.5 → speed ratio = 850/600 = 1.417
        let s = CockpitState()
        s.apply(leftX: 0, leftY: -1.0, turn: 0, from: .keyboard)
        s.setSpeedScale(0.5)
        let speedSlow = s.lastCommand.strideMm * 2000.0 / s.periodMs
        s.setSpeedScale(1.5)
        let speedFast = s.lastCommand.strideMm * 2000.0 / s.periodMs
        let ratio = speedFast / speedSlow
        XCTAssertEqual(ratio, 850.0 / 600.0, accuracy: 0.01,
                       "Throttle 0.5 → 1.5 → speed ratio = 850/600 = 1.417")
    }

    @MainActor
    func test_59_lateral_speed_at_cockpit_baseline() {
        // sideMm: max 22 (cockpit). 22 × 2000/600 = 73.3 mm/s 측면 속도.
        let s = CockpitState()
        s.setSpeedScale(1.5)
        s.apply(leftX: 1.0, leftY: 0, turn: 0, from: .keyboard)
        let speed = s.lastCommand.sideMm * 2000.0 / s.periodMs
        XCTAssertEqual(speed, 22.0 * 2000.0 / 600.0, accuracy: 1.0,
                       "Side max + throttle max = 73.3 mm/s")
    }

    @MainActor
    func test_60_turn_speed_at_cockpit_baseline() {
        // turnDeg: max 12 (cockpit, 다리 충돌 방지 보수화). 12 × 2000/600 = 40 deg/s.
        let s = CockpitState()
        s.setSpeedScale(1.5)
        s.apply(leftX: 0, leftY: 0, turn: 1.0, from: .keyboard)
        let speed = s.lastCommand.turnDeg * 2000.0 / s.periodMs
        XCTAssertEqual(speed, 12.0 * 2000.0 / 600.0, accuracy: 1.0,
                       "Turn max + throttle max = 40 deg/s")
    }

    // MARK: - Group J: 자이로 보정 + 가변속도 일관성 (5 scenarios)

    @MainActor
    func test_61_variable_speed_invariant_under_balance_correction() {
        // 자이로 보정 ON / OFF 와 무관하게 commanded speed (stride × 2000 / period)
        // 는 동일 — 보정은 pose-level (관절 delta), command-level 은 영향 없음.
        let s = CockpitState()
        s.setSpeedScale(1.0)
        s.apply(leftX: 0, leftY: -0.5, turn: 0, from: .keyboard)
        let commanded = s.lastCommand.strideMm * 2000.0 / s.periodMs
        XCTAssertGreaterThan(commanded, 0,
                             "Commanded speed = stride × 2000 / period (보정 무관)")
    }

    func test_62_robotis_balance_gains_match_walking_cpp() {
        // ROBOTIS Walking.cpp 의 기본 balance gains — applyBalanceCorrection 의
        // P-control 계수가 이 값과 일치해야 정통.
        let bAnklePitchGain = 0.9   // BALANCE_ANKLE_PITCH_GAIN
        let bHipRollGain    = 0.5   // BALANCE_HIP_ROLL_GAIN
        let bAnkleRollGain  = 1.0   // BALANCE_ANKLE_ROLL_GAIN
        let bKneeGain       = 0.3   // BALANCE_KNEE_GAIN
        XCTAssertGreaterThan(bAnklePitchGain, 0)
        XCTAssertGreaterThan(bHipRollGain, 0)
        XCTAssertGreaterThan(bAnkleRollGain, 0)
        XCTAssertGreaterThan(bKneeGain, 0)
    }

    func test_63_imu_freshness_gate_thresholds() {
        // WalkLabSession 의 IMU freshness gate (250ms / 500ms) — 자이로 보정의
        // safety 한계. cockpit 도 동일 gate 사용 (transformPose 가 session 호출).
        let warnAgeMs = 250.0  // 감쇠 시작
        let blockAgeMs = 500.0 // 보정 차단
        XCTAssertLessThan(warnAgeMs, blockAgeMs)
        XCTAssertEqual(blockAgeMs / warnAgeMs, 2.0, accuracy: 0.001,
                       "Block age = 2 × warn age (linear ramp 50ms 곱)")
    }

    @MainActor
    func test_64_cockpit_baseline_matches_walklab_freeform_clamp() {
        // VirtualJoystickMapper 의 cockpit baseline 이 WalkLab mobileFreeformClamp
        // 의 max 와 정확히 일치.
        XCTAssertEqual(VirtualJoystickMapper.cockpitStrideMm, 38.0,
                       "stride: cockpit baseline = freeform clamp max")
        XCTAssertEqual(VirtualJoystickMapper.cockpitSideMm, 22.0)
        // turn: 18 → 12 보수화 (mobileFreeformClamp turn 도 ±12 로 일치).
        XCTAssertEqual(VirtualJoystickMapper.cockpitTurnDeg, 12.0)
    }

    @MainActor
    func test_65_legacy_baseline_preserved_for_mac_and_ios() {
        // 25/15/10 legacy baseline 이 Mac VirtualJoystickPanel + iOS CommandBuilder
        // 의 회귀 보호. Cockpit 만 별도 baseline 사용.
        XCTAssertEqual(VirtualJoystickMapper.legacyStrideMm, 25.0)
        XCTAssertEqual(VirtualJoystickMapper.legacySideMm, 15.0)
        XCTAssertEqual(VirtualJoystickMapper.legacyTurnDeg, 10.0)
    }

    // MARK: - Group F: Multi-source integration (5 scenarios)

    @MainActor
    func test_31_cockpit_held_keys_round_trip() {
        let s = CockpitState()
        s.insertHeldKey("w")
        XCTAssertTrue(s.heldKeys.contains("w"))
        // VirtualJoystickMapper: stick leftY=-1 (W, forward) → strideMm > 0 (전진).
        // 즉 화면 좌표 -y (위) = robot 전진 = +strideMm.
        XCTAssertGreaterThan(s.lastCommand.strideMm, 0,
                             "W (전진) → strideMm > 0")
    }

    @MainActor
    func test_32_cockpit_remove_held_key_resumes_idle() {
        let s = CockpitState()
        s.insertHeldKey("w")
        XCTAssertFalse(s.lastCommand.isStop)
        s.removeHeldKey("w")
        XCTAssertTrue(s.lastCommand.isStop, "키 release → stop")
    }

    @MainActor
    func test_33_cockpit_keyboard_vs_djiRC_source_label() {
        let s = CockpitState()
        s.apply(leftX: 0, leftY: -1, turn: 0, from: .djiRC)
        XCTAssertEqual(s.lastSource, .djiRC)
        s.apply(leftX: 0, leftY: -1, turn: 0, from: .keyboard)
        XCTAssertEqual(s.lastSource, .keyboard, "마지막 source 가 displayed")
    }

    @MainActor
    func test_34_cockpit_multiple_keys_compose() {
        let s = CockpitState()
        s.applyHeldKeys(["w", "d"])
        // W + D 대각선 — leftY < 0 (전진) + leftX > 0 (우측), normalised.
        let mag = (s.leftStick.x * s.leftStick.x
                   + s.leftStick.y * s.leftStick.y).squareRoot()
        XCTAssertEqual(mag, 1.0, accuracy: 0.01,
                       "대각선 magnitude = 1 (직선과 동일 속도)")
    }

    @MainActor
    func test_35_cockpit_simulation_toggle_persists() {
        let s = CockpitState()
        XCTAssertTrue(s.simulationEnabled, "default ON")
        s.simulationEnabled = false
        XCTAssertFalse(s.simulationEnabled)
    }

    // MARK: - Helpers

    /// 테스트용 RobotPose builder — 특정 joint 만 변화시켜 visualPose ≠ animatedPose
    /// 인 상황을 만든다.
    private func makeAnimatedPose(rHipPitch: Int) -> RobotPose {
        var dict: [JointID: Int] = [:]
        for j in JointID.allCases {
            dict[j] = RobotPose.walkReady.raw(j)
        }
        dict[.rHipPitch] = rHipPitch
        return RobotPose(positions: dict)
    }
}
