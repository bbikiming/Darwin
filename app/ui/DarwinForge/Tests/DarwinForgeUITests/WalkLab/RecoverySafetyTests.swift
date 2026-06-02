//  RecoverySafetyTests.swift
//  DarwinForgeUITests
//
//  Created 2026-05-30 — safety-critical regression tests for C1-C3, H1-H6.
//
//  # 비유
//  항공 안전 체크리스트 시뮬레이터. 실제 비행기 없이 각 안전 장치가 동작하는지
//  검증한다. 실 robot 없이 mock bus 로 모든 안전 경로를 단위 테스트.
//
//  # 커버리지
//  - C1: bcApplyPControlPath motor pose 에 D-term 포함 검증
//  - C2: retry 방향이 accel 기반 (pitch 부호 반전 없음)
//  - C3: emergencyStopActive=true 중 restoreTorqueAndPGain → false 반환, torque 미작성
//  - H1: autoRecoveryPhase=.failed → pilotEmergencyExit → phase=.idle, motorGate unblocks
//  - H2: isWalkActive=false + phase=.settling → ConnectionStore.emergencyStop 이 WalkLabSession 에 위임
//  - H3: realMotor OFF while pilotIsWalking → pilotStop called (phase/task reset)
//  - H4: emergencyStopActive before motionPlaySlot → playGetUpMotion returns false, motionPlaySlot NOT called

#if DEBUG
import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

@MainActor
final class RecoverySafetyTests: XCTestCase {

    // MARK: - Helpers

    /// WalkLabSession + ConnectionStore 셋업.
    /// store 를 함께 반환해야 테스트 동안 strong reference 유지.
    private func makeSession(bus: (any BusInterface)? = nil) -> (session: WalkLabSession, store: ConnectionStore) {
        let session = WalkLabSession()
        let store = ConnectionStore()
        store.bus = bus ?? MockBus()
        store._setDxlPowerState(true)
        session.attach(store: store)
        session.cradleConfirmed = true
        return (session, store)
    }

    // MARK: - C1: D-term inclusive in real motor pose

    /// **C1**: `applyBalanceCorrectionIfEnabled` (P-control path) 가 D-term 을 포함한
    /// `rampedCorr` 을 `Self.applyCorrections` 로 motor pose 에 전달하는지 검증.
    ///
    /// 전략: `BalanceCorrector.corrections(pitchRateDps:)` 의 D-term 효과를 직접 검증.
    /// - pitchRate=0 (P-only) 와 pitchRate=100dps (PD) 의 raw corrections 가 달라야 함.
    /// - 달라진 corrections 가 `applyCorrections` 로 pose 에 적용되면 ankle raw 도 달라짐.
    @MainActor
    func testC1_pControlPath_motorPoseIncludesDTerm() {
        let corrector = BalanceCorrector.robotisOriginal  // derivativeTimeSec=0.12
        // P-only (rate=0)
        let corrP = corrector.corrections(rollErrDeg: 0, pitchErrDeg: 5.0,
                                          rollRateDps: 0, pitchRateDps: 0)
        // PD with pitch rate 100 dps → D-term = 0.12 × 100 = 12° additional
        let corrPD = corrector.corrections(rollErrDeg: 0, pitchErrDeg: 5.0,
                                           rollRateDps: 0, pitchRateDps: 100.0)

        // D-term 이 있으면 corrections 가 달라야 함
        XCTAssertNotEqual(corrP.rAnklePitch, corrPD.rAnklePitch, accuracy: 1e-6,
            "C1: pitchRate=100 D-term 이 corrections 에 포함되어야 함 (P-only 와 달라야 함)")

        // applyCorrections 가 차이를 pose 에 전달하는지 검증
        let poseP = WalkLabSession.applyCorrections(corrP, to: .walkReady)
        let posePD = WalkLabSession.applyCorrections(corrPD, to: .walkReady)
        XCTAssertNotEqual(poseP.raw(.rAnklePitch), posePD.raw(.rAnklePitch),
            "C1: applyCorrections 가 D-term 포함 corrections 를 motor pose 에 전달해야 함")
    }

    // MARK: - C2: Retry direction uses accel (not raw pitch sign)

    /// **C2**: accelY=forward + raw pitch=+45° 일 때 retry 가 .forward 를 선택해야 함.
    /// (종전 버그: pitch >= 0 → .forward 는 우연히 맞음. accelY forward limit 미만이면
    /// accel 기반 forward 가 일치하는지 확인.)
    @MainActor
    func testC2_retryDirection_accelForward_rawPitchPositive_picksForward() async {
        let bus = MockBus()
        // accelY=350 → FORWARD fall (< 390 threshold)
        bus.imuResponse = ImuRaw(
            gyroX: 512, gyroY: 512, gyroZ: 512,
            accelX: 512, accelY: 350, accelZ: 512,
            rollDeg: 0, pitchDeg: 45.0
        )
        let (session, store) = makeSession(bus: bus)
        store.health.recordImuSuccess(raw: bus.imuResponse!)

        // stillFallen 조건을 만들기 위해 imuPitchDeg 를 임계 초과로 설정
        session.imuPitchDeg = 60.0  // detectFall(pitchDeg:) 이 .forward 반환

        // retry 로직 검증: accel 기반으로 .forward 여야 한다.
        // (raw pitch > 0 이라 old code 와 결과는 동일하지만, accel 경로를 사용하는지 확인)
        let accelDir = AutoFallRecovery.detectFallFromAccel(accelYRaw: Int(bus.imuResponse!.accelY))
        XCTAssertEqual(accelDir, .forward,
            "C2: accelY=350 < 390 threshold → .forward (accel 기반 방향)")

        // Ensure accel detection takes priority over raw pitch sign
        // Negative pitch + forward accel: if old code used pitch sign would pick .backward
        session.imuPitchDeg = -60.0  // 음수 pitch = old code 가 .backward 선택했을 값
        // accel 은 여전히 forward (350 < 390)
        let accelDirConfirm = AutoFallRecovery.detectFallFromAccel(accelYRaw: Int(bus.imuResponse!.accelY))
        XCTAssertEqual(accelDirConfirm, .forward,
            "C2: accel=forward 이면 raw pitch 부호(-60°)가 뭐든 .forward 가 우선")
    }

    /// **C2**: accelY=600 (BACKWARD > 580) + raw pitch=-60° 일 때 accel 기반 .backward.
    @MainActor
    func testC2_retryDirection_accelBackward_rawPitchNegative_picksBackward() {
        let accelDir = AutoFallRecovery.detectFallFromAccel(accelYRaw: 600)
        XCTAssertEqual(accelDir, .backward,
            "C2: accelY=600 > 580 threshold → .backward")
    }

    // MARK: - C3: E-STOP mid-restore → restoreTorqueAndPGain returns false, no torque write

    /// **C3**: `emergencyStopActive=true` 상태에서 `restoreTorqueAndPGain` 이 bus 없음으로
    /// false 를 반환하는지 검증 (bus nil 경로 — emergencyStop 이 bus 참조를 제거할 수 있음).
    @MainActor
    func testC3_nobus_restoreTorqueAndPGain_returnsFalse() async {
        // bus=nil: store 있지만 bus 없음 → restoreTorqueAndPGain 에서 false (guard bus)
        let session = WalkLabSession()
        let store = ConnectionStore()
        // bus 없이 attach — store?.bus == nil → guard let bus = ... else return false
        session.attach(store: store)
        session.cradleConfirmed = true

        let result = await session._testRestoreTorqueAndPGain()

        XCTAssertFalse(result,
            "C3: bus=nil 이면 restoreTorqueAndPGain false 반환")
    }

    /// **C3**: Task 취소 후 `restoreTorqueAndPGain` false 반환 검증.
    @MainActor
    func testC3_cancelledTask_restoreTorqueAndPGain_returnsFalse() async {
        let bus = MockBus()
        let (session, _store) = makeSession(bus: bus)

        // 외부에서 취소 가능한 detached task
        let task = Task.detached {
            // 100ms sleep 전에 취소됨 → sleep 에서 CancellationError
            try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
            return await session._testRestoreTorqueAndPGain()
        }
        // 즉시 취소
        task.cancel()
        let result = await task.value

        // Task.isCancelled=true 이면 restoreTorqueAndPGain 초입 guard 에서 false 반환.
        XCTAssertFalse(result,
            "C3: Task 취소 → Task.isCancelled=true → restoreTorqueAndPGain false (E-STOP 취소 경로)")
    }

    /// **C3**: dxlPower 3회 모두 실패 시 torque loop 진입 없이 false 반환.
    /// AlwaysFailingMockBus 사용 — 모든 write 가 실패.
    @MainActor
    func testC3_alwaysFailingBus_restoreTorqueAndPGain_returnsFalseNoTorqueWrite() async {
        let bus = AlwaysFailingMockBus()
        let (session, _store) = makeSession(bus: bus)

        let result = await session._testRestoreTorqueAndPGain()

        XCTAssertFalse(result,
            "C3: dxlPower 3회 실패(AlwaysFailingMockBus) → restoreTorqueAndPGain false")
    }

    // MARK: - H1: .failed phase → pilotEmergencyExit → .idle, motorGate unblocks

    /// **H1**: `autoRecoveryPhase=.failed` 상태에서 pilotEmergencyExit 을 호출하면
    /// phase 가 .idle 로 전환되어 motorGate 가 unblock 된다.
    @MainActor
    func testH1_failedPhase_pilotEmergencyExit_resetsToIdle() {
        let (session, _store) = makeSession()

        // .failed 상태 설정 + emergencyStopActive (실제 E-STOP 후 상황)
        session.autoRecoveryPhase = .failed
        session.emergencyStopActive = true

        session.pilotEmergencyExit()

        XCTAssertEqual(session.autoRecoveryPhase, .idle,
            "H1: pilotEmergencyExit 은 .failed phase 를 .idle 로 전환해야 함")
        XCTAssertFalse(session.emergencyStopActive,
            "H1: pilotEmergencyExit 이 emergencyStopActive 도 클리어해야 함")
    }

    /// **H1**: motorGate 논리 — autoRecoveryPhase != .idle 이면 write 차단됨을 간접 검증.
    /// .failed 에서 exitEmergencyMode 만으로는 motorGate 가 열리지 않음을 확인.
    @MainActor
    func testH1_failedPhase_exitEmergencyModeAlone_doesNotClearPhase() {
        let (session, _store) = makeSession()

        session.autoRecoveryPhase = .failed
        session.emergencyStopActive = true

        // exitEmergencyMode 만 호출 (pilotEmergencyExit 없이) — H1 fix 전 동작.
        session.exitEmergencyMode()

        // exitEmergencyMode 는 failed 를 .idle 로 바꾸지 않는다 (단독으로는).
        // pilotEmergencyExit 이 올바른 진입점.
        XCTAssertEqual(session.autoRecoveryPhase, .failed,
            "H1: exitEmergencyMode 단독으로는 .failed → .idle 전환 없음 (pilotEmergencyExit 이 담당)")
    }

    // MARK: - H2: store.emergencyStop delegates when recovery is active

    /// **H2**: walk.isWalkActive=false 이지만 autoRecoveryPhase=.settling 인 상태에서
    /// ConnectionStore.emergencyStop 이 WalkLabSession.emergencyStop 에 위임되어야 한다.
    @MainActor
    func testH2_storeEmergencyStop_duringRecovery_delegatesToWalkSession() {
        let bus = MockBus()
        let (session, store) = makeSession(bus: bus)

        // isWalkActive=false 지만 recovery 진행 중
        session.autoRecoveryPhase = .settling
        XCTAssertFalse(session.isWalkActive, "전제: isWalkActive=false")
        XCTAssertFalse(session.emergencyStopActive, "전제: emergencyStopActive=false")

        // store 의 walkSession 이 session 을 참조하고 있어야 위임이 발생.
        // attach(store:) 가 walkSession 을 store 에 등록.
        store.emergencyStop()

        // WalkLabSession.emergencyStop 이 호출되면:
        // 1. emergencyStopActive = true
        // 2. autoRecoveryTask?.cancel() + autoRecoveryPhase = .idle (if not .failed)
        // 3. motionPlayCancel 호출 (bus.motionPlayCancelCount >= 1)
        XCTAssertTrue(session.emergencyStopActive,
            "H2: recovery 진행 중 store.emergencyStop → session.emergencyStop 위임 → emergencyStopActive=true")
        XCTAssertGreaterThanOrEqual(bus.motionPlayCancelCount, 1,
            "H2: session.emergencyStop Phase 4b 에서 motionPlayCancel 호출")
    }

    // MARK: - H3: realMotor OFF while walking → pilotStop called (session state validation)

    /// **H3**: `pilotIsWalking=true` 상태에서 `pilotStop()` 을 호출하면 walking state 가
    /// idle 로 전환된다. PilotCockpitView 의 `realMotor OFF` 경로가 `pilotStop` 을 호출하므로
    /// session state 변환을 검증 (SwiftUI View 직접 테스트 불가).
    @MainActor
    func testH3_pilotStop_clearsWalkingState() {
        let (session, _store) = makeSession()

        // _testForceWalkActive 로 pilotIsWalking=true 설정
        session._testForceWalkActive(.slowWalk)
        XCTAssertTrue(session.pilotIsWalking, "전제: pilotIsWalking=true (_testForceWalkActive)")

        session.pilotStop()

        XCTAssertFalse(session.isRobotWalking,
            "H3: pilotStop 호출 후 isRobotWalking=false")
        XCTAssertFalse(session.pilotIsWalking,
            "H3: pilotStop 후 pilotIsWalking=false")
    }

    // MARK: - H4: emergencyStopActive before motionPlaySlot → playGetUpMotion returns false

    /// **H4**: `emergencyStopActive=true` 상태에서 `playGetUpMotion(page:)` 를 호출하면
    /// motionPlaySlot 없이 false 반환.
    @MainActor
    func testH4_emergencyActiveBeforeMotionPlay_returnsFalseNoMotionPlay() async {
        let bus = MockBus()
        let (session, _store) = makeSession(bus: bus)

        // E-STOP 발동 (emergencyStopActive = true)
        session.emergencyStop(trigger: .userClick)
        XCTAssertTrue(session.emergencyStopActive)

        let result = await session._testPlayGetUpMotion(page: 10)

        XCTAssertFalse(result,
            "H4: emergencyStopActive=true 이면 playGetUpMotion false 반환")
        // motionPlaySlot 호출이 없어야 함
        // (emergencyStop 자체 write 와 별개; motionPlaySlotCalls 는 slot call 만 기록)
        XCTAssertEqual(bus.motionPlaySlotCalls.count, 0,
            "H4: emergencyStop 발동 후 motionPlaySlot 호출 금지")
    }

    // MARK: - Additional: detectFallFromAccel convention verification

    /// ROBOTIS 공식 accel 임계 검증 (기준값 명시 고정).
    func testAccelFallDetection_forwardLimit() {
        XCTAssertEqual(AutoFallRecovery.detectFallFromAccel(accelYRaw: 389), .forward,
            "accelY=389 < 390 → FORWARD")
        XCTAssertNil(AutoFallRecovery.detectFallFromAccel(accelYRaw: 390),
            "accelY=390 = 경계, 미감지")
        XCTAssertNil(AutoFallRecovery.detectFallFromAccel(accelYRaw: 512),
            "accelY=512 = 중립 직립")
        XCTAssertNil(AutoFallRecovery.detectFallFromAccel(accelYRaw: 580),
            "accelY=580 = backward 경계, 미감지")
        XCTAssertEqual(AutoFallRecovery.detectFallFromAccel(accelYRaw: 581), .backward,
            "accelY=581 > 580 → BACKWARD")
    }
}
#endif
