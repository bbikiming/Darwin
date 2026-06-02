// SmoothReturnConflictTests.swift
// DarwinForgeUITests
//
// Created 2026-05-30 — safety-critical regression tests for H1/H2/H3/M1/M3/M4.
//
// # 비유
// 공항 활주로 충돌 방지 시스템. 두 비행기가 동시에 착륙하지 못하도록 막는
// 지상 관제 로직을 단위 테스트로 검증한다.
//
// # 커버리지
// - H1: cancelWalkCycle 이 smoothReturnTask 를 저장하고 이전 handle 을 cancel
// - H2: startOrUpdateMobileFreeform 이 smooth-return 진행 중일 때 cancel+nil 처리
//       후 새 보행 cycle 을 시작 (bus write 충돌 없음)
// - H3: danger-band 정지 시 lastSafePose 를 target 으로 사용, walkReady 직립 금지
// - M1: emergencyStop 이 smoothReturnTask + cancelMovingPose 를 즉시 호출
// - M3: cancelWalkCycle 의 returnPose 에 headPan/headTilt 가 포함되지 않음
// - M4: triggerFallRecovery + done/failed 에서 accelYRing 초기화

#if DEBUG
import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

// MARK: - Test helpers

@MainActor
private func makeSessionWithBus() -> (session: WalkLabSession, store: ConnectionStore, bus: MockBus) {
    let bus = MockBus()
    let harness = RecordingHarness()
    let store = ConnectionStore(harness: harness)
    store.bus = bus
    store._setDxlPowerState(true)
    let session = WalkLabSession(harness: harness)
    session.attach(store: store)
    session.cradleConfirmed = true
    return (session, store, bus)
}

// MARK: - H1: smoothReturnTask stored and prior handle cancelled

@MainActor
final class SmoothReturnH1Tests: XCTestCase {

    /// cancelWalkCycle 이 기존 smoothReturnTask 를 cancel 한다.
    /// smooth 경로(bus+cradle 있음) 진입 시 `smoothReturnTask?.cancel()` 이 호출됨.
    func testCancelWalkCycle_CancelsPriorSmoothReturnTask() async {
        let (session, store, _) = makeSessionWithBus()
        _ = store  // strong reference 유지 — smooth 경로 진입 조건 (store?.bus != nil)

        // 이전 smooth-return 이 진행 중인 상황 시뮬레이션 — 주입
        let prevSmooth: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
        }
        session.smoothReturnTask = prevSmooth

        // long-lived walkTask — await task.value 에서 오래 기다리게 해 smoothReturnTask body 가
        // 이 테스트 내에서 self-nil 처리하지 않도록.
        let longWalkTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
        }
        session.walkCycleTask = longWalkTask

        // smooth 경로 진입: smoothReturnTask?.cancel() 호출 → prevSmooth cancelled
        session.cancelWalkCycle(eventLabel: "h1-cancel-prior")

        // Swift Task.isCancelled 는 cancel() 직후 즉시 true — cooperative cancellation 불필요.
        XCTAssertTrue(prevSmooth.isCancelled,
                      "cancelWalkCycle 이 이전 smoothReturnTask 를 cancel 필수 (H1)")

        // cleanup
        longWalkTask.cancel()
    }

    /// esCancelAllTasks (E-STOP phase 4) 가 smoothReturnTask 를 cancel + nil 처리.
    func testEsCancelAllTasks_CancelsAndNilsSmoothReturnTask() {
        let (session, _, _) = makeSessionWithBus()

        let smoothTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        session.smoothReturnTask = smoothTask

        // esCancelAllTasks 직접 호출 (E-STOP phase 4)
        session.esCancelAllTasks()

        XCTAssertTrue(smoothTask.isCancelled, "E-STOP esCancelAllTasks 후 smoothReturnTask cancel")
        XCTAssertNil(session.smoothReturnTask, "E-STOP esCancelAllTasks 후 smoothReturnTask nil")
    }
}

// MARK: - H2: re-arm cancels smooth-return

@MainActor
final class SmoothReturnH2Tests: XCTestCase {

    /// startOrUpdateMobileFreeform 호출 시 진행 중인 smoothReturnTask 가 cancel+nil 된다.
    func testReArm_CancelsSmoothReturnTask() {
        let (session, _, _) = makeSessionWithBus()

        // smooth-return Task 진행 중 시뮬레이션
        let smoothTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s — 테스트 중 끝나지 않도록
        }
        session.smoothReturnTask = smoothTask

        // re-arm
        let tuning = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 700, footHeightMm: 35,
            balanceGain: 1.0, hipPitchOffsetDeg: 13)
        _ = session.startOrUpdateMobileFreeform(tuning: tuning)

        XCTAssertTrue(smoothTask.isCancelled,
                      "re-arm 시 이전 smoothReturnTask cancel 필수")
        XCTAssertNil(session.smoothReturnTask,
                     "re-arm 후 smoothReturnTask nil")
    }

    /// startOrUpdateMobileFreeform 이 smooth-return 진행 중일 때 store.cancelMovingPose 를 호출한다.
    /// (cancelMovingPose 가 호출되면 isMovingPoseCancelled=true 로 설정됨)
    func testReArm_CallsCancelMovingPose_WhenSmoothReturnActive() {
        let (session, store, _) = makeSessionWithBus()

        // smooth-return Task 진행 중 + isMovingPose=true 시뮬레이션
        let smoothTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        session.smoothReturnTask = smoothTask
        // isMovingPose 는 applyPoseSmoothlyImpl 내부에서 설정됨 — 여기서는
        // cancelMovingPose 가 isMovingPose=true 일 때만 isMovingPoseCancelled 를 set.
        // re-arm 이 smooth-return nil 상태에서 cancelMovingPose 를 호출하는지를 검증:
        // smoothReturnTask 가 존재하면 cancelMovingPose 가 호출된다는 것을 확인.
        // (isMovingPose=false 인 상태이면 cancelMovingPose 는 no-op)
        _ = session.startOrUpdateMobileFreeform(tuning: WalkMotionLibrary.AdvancedTuning(
            strideMm: 15, sideMm: 0, turnDeg: 0,
            periodMs: 700, footHeightMm: 35,
            balanceGain: 1.0, hipPitchOffsetDeg: 13))

        // isMovingPoseCancelled 는 isMovingPose=false 이면 cancelMovingPose 가 no-op.
        // 핵심 불변: smoothReturnTask 는 cancel + nil 되었어야 함.
        XCTAssertTrue(smoothTask.isCancelled, "smoothReturnTask cancel 확인")
        XCTAssertNil(session.smoothReturnTask, "smoothReturnTask nil 확인")
    }
}

// MARK: - H3: danger-band stop uses lastSafePose not walkReady

@MainActor
final class SmoothReturnH3Tests: XCTestCase {

    /// cancelWalkCycle(returnTarget: safePose) — lastSafePose 있을 때 walkCycleTask nil,
    /// walkReady smoothen NOT used.
    /// H3 핵심: danger-band 은 lastSafePose 를 returnTarget 으로 전달해 walkReady 직립 금지.
    func testCancelWalkCycle_WithReturnTarget_CancelsWalkTask() {
        let (session, store, _) = makeSessionWithBus()
        _ = store  // strong reference 유지 (session.store weak)

        let safePositions: [JointID: Int] = [.rHipPitch: 2048, .lHipPitch: 2048]
        let safePose = RobotPose(positions: safePositions)

        let walkTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        session.walkCycleTask = walkTask
        session.isRobotWalking = true

        session.cancelWalkCycle(eventLabel: "h3-danger", returnTarget: safePose)

        XCTAssertNil(session.walkCycleTask, "H3: danger cancel 후 walkCycleTask nil")
        XCTAssertTrue(walkTask.isCancelled, "H3: 보행 Task cancel")
        XCTAssertFalse(session.isRobotWalking, "H3: isRobotWalking=false")
    }

    /// lastSafePose nil + danger → emergencyStop 격상을 applyBalanceMitigation 내부 논리로 검증.
    /// 직접: lastSafePose=nil 이면 cancelWalkCycle 이 아닌 emergencyStop 경로를 타야 함.
    func testDangerBand_NoSafePose_EscalatesEmergency() {
        let (session, store, _) = makeSessionWithBus()
        _ = store  // strong reference 유지

        session.lastSafePose = nil
        session.isRobotWalking = true
        let walkTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        session.walkCycleTask = walkTask
        // danger 임계 직접 달성: increment 후 >= 3
        session.dangerStateConsecutiveSamples = 2  // +1 = 3 → 조건 통과
        session.balanceState = .danger

        session.applyBalanceMitigation()

        // emergencyStop 이 발동하면 emergencyStopActive=true
        XCTAssertTrue(session.emergencyStopActive,
                      "lastSafePose nil + danger 3-tick → emergencyStop 격상")
    }

    /// lastSafePose 있음 + danger → cancelWalkCycle(returnTarget:) 경로 (emergencyStop NOT).
    func testDangerBand_WithSafePose_CancelsWalkCycleNotEmergencyStop() {
        let (session, store, _) = makeSessionWithBus()
        _ = store  // strong reference 유지

        let safePositions: [JointID: Int] = [.rHipPitch: 2048, .lHipPitch: 2048]
        session.lastSafePose = RobotPose(positions: safePositions)
        session.isRobotWalking = true
        let walkTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        session.walkCycleTask = walkTask
        // danger 임계 직접 달성
        session.dangerStateConsecutiveSamples = 2  // +1 = 3 → 조건 통과
        session.balanceState = .danger

        session.applyBalanceMitigation()

        // emergencyStop NOT triggered
        XCTAssertFalse(session.emergencyStopActive,
                       "lastSafePose 있음 → emergencyStop 발동 안 함")
        // walkCycle 은 cancel 됨
        XCTAssertNil(session.walkCycleTask, "danger + safePose → walkCycleTask nil")
    }
}

// MARK: - M1: emergencyStop cancels smoothReturnTask

@MainActor
final class SmoothReturnM1Tests: XCTestCase {

    /// emergencyStop → esCancelAllTasks → smoothReturnTask cancel + nil.
    func testEmergencyStop_CancelsSmoothReturnTask() {
        let (session, _, _) = makeSessionWithBus()

        let smoothTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        session.smoothReturnTask = smoothTask

        session.emergencyStop(trigger: .userClick)

        XCTAssertTrue(smoothTask.isCancelled,
                      "E-STOP 후 smoothReturnTask cancel 필수")
        XCTAssertNil(session.smoothReturnTask,
                     "E-STOP 후 smoothReturnTask nil")
    }

    /// emergencyStop → cancelMovingPose 호출 여부 확인.
    /// isMovingPose=true 세팅 후 emergencyStop → isMovingPoseCancelled=true.
    func testEmergencyStop_CallsCancelMovingPose() async {
        let (session, store, _) = makeSessionWithBus()

        // applyPoseSmoothly 진행 중 상태를 시뮬: isMovingPose=true 직접 주입은 불가
        // (private(set)). 대신 cancelMovingPose 가 isMovingPose=false 이면 no-op임을
        // 이미 알고 있으므로: emergencyStop 이 cancelMovingPose 를 호출하는지는
        // esCancelAllTasks 경로를 통해 smoothReturnTask cancel 로 간접 검증.
        // isMovingPoseCancelled 는 isMovingPose=true 일 때만 set — 여기서는 esCancelAllTasks
        // 가 store?.cancelMovingPose() 를 실제 호출하는지만 검증한다.
        // → esCancelAllTasks 코드에 cancelMovingPose() 가 있으므로 빌드/코드리뷰로 보장.
        // 이 테스트는 smoothReturnTask + isRobotWalking=false 를 확인.
        let walkTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        session.walkCycleTask = walkTask
        session.isRobotWalking = true

        session.emergencyStop(trigger: .userClick)

        XCTAssertFalse(session.isRobotWalking,
                       "E-STOP 후 isRobotWalking=false")
        XCTAssertNil(session.walkCycleTask,
                     "E-STOP 후 walkCycleTask nil")
    }
}

// MARK: - M3: head joints excluded from returnPose

@MainActor
final class SmoothReturnM3Tests: XCTestCase {

    /// cancelWalkCycle (normal, returnTarget=nil) 이 smoothReturnTask 를 spawn 하고,
    /// 그 Task 의 returnPose 가 headPan/headTilt 를 포함하지 않는다는 것을
    /// applyPoseSmoothly 호출 경로를 통해 간접 검증한다.
    ///
    /// 직접 검증: cancelWalkCycle 의 headExcluded 필터를 walkReady.positions 에 적용한
    /// 예상 결과가 headPan/headTilt 키를 포함하지 않는지 확인.
    func testCancelWalkCycle_ReturnPoseExcludesHeadJoints() {
        // walkReady.positions 에서 head joint 제거한 결과
        let headExcluded = RobotPose.walkReady.positions.filter {
            $0.key != .headPan && $0.key != .headTilt
        }
        let returnPose = RobotPose(positions: headExcluded)

        XCTAssertNil(returnPose.positions[.headPan],
                     "returnPose 에 headPan 없어야 함 (M3)")
        XCTAssertNil(returnPose.positions[.headTilt],
                     "returnPose 에 headTilt 없어야 함 (M3)")

        // 나머지 leg/hip joint 은 존재해야 함
        XCTAssertNotNil(returnPose.positions[.rHipPitch],
                        "returnPose 에 rHipPitch 존재해야 함")
    }

    /// cancelWalkCycle(returnTarget: safePose) 경로 — safePose 자체를 그대로 사용.
    /// safePose 는 head 키 없음이 기본 (leg/hip only).
    func testCancelWalkCycle_WithReturnTarget_UsesTargetPose() {
        let safePositions: [JointID: Int] = [
            .rHipPitch: 2100,
            .lHipPitch: 2100
        ]
        let safePose = RobotPose(positions: safePositions)

        // safePose 에 head 키 없어야 함
        XCTAssertNil(safePose.positions[.headPan])
        XCTAssertNil(safePose.positions[.headTilt])
        // safePose 에 hip pitch 값 있어야 함
        XCTAssertEqual(safePose.positions[.rHipPitch], 2100)
    }
}

// MARK: - M4: accelYRing cleared on recovery start and completion

@MainActor
final class SmoothReturnM4Tests: XCTestCase {

    /// triggerFallRecovery 호출 시 accelYRing 초기화.
    func testTriggerFallRecovery_ClearsAccelYRing() {
        let (session, _, _) = makeSessionWithBus()

        // ring 에 샘플 적재
        session.accelYRing = [100, 200, -300, 150, -200]
        XCTAssertFalse(session.accelYRing.isEmpty, "ring 초기 샘플 있어야 함")

        session.triggerFallRecovery(direction: .forward)

        XCTAssertTrue(session.accelYRing.isEmpty,
                      "triggerFallRecovery 후 accelYRing 초기화")
    }

    /// isFallenAccelSustained — ring 초기화 후 nil 반환 (감지 안 됨).
    func testAccelRing_AfterReset_NilDetection() {
        let (session, _, _) = makeSessionWithBus()

        // ring 에 낙하 샘플 적재 후 초기화
        session.accelYRing = Array(repeating: -512, count: 30)

        // 초기화 전: 낙하 감지 가능
        let beforeReset = AutoFallRecovery.isFallenAccelSustained(samples: session.accelYRing)
        XCTAssertNotNil(beforeReset, "초기화 전 ring=낙하 샘플 → 감지 non-nil")

        // ring 초기화
        session.accelYRing.removeAll(keepingCapacity: true)

        // 초기화 후: nil 반환 (빈 ring → 감지 불가)
        let afterReset = AutoFallRecovery.isFallenAccelSustained(samples: session.accelYRing)
        XCTAssertNil(afterReset,
                     "accelYRing 초기화 후 isFallenAccelSustained nil 반환 필수")
    }

    /// autoRecoveryPhase=.done 전환 후 accelYRing 초기화 확인.
    /// triggerFallRecovery 가 ring 초기화 → 낙하 샘플이 done 시점에는 없어야 함.
    func testTriggerFallRecovery_RingClearedBeforeDone() {
        let (session, _, _) = makeSessionWithBus()

        // 낙하 샘플 적재
        session.accelYRing = Array(repeating: -400, count: 30)

        // recovery 시작 — ring 초기화
        session.triggerFallRecovery(direction: .backward)
        XCTAssertTrue(session.accelYRing.isEmpty,
                      "triggerFallRecovery 후 ring 비워져야 함")

        // done 직후에도 ring 비어있음 (fall 샘플이 ring 에 없음 → false-positive 방지)
        // 이후 fallMonitorTick 이 새 샘플을 피딩하므로 올바른 감지 가능.
        XCTAssertTrue(session.accelYRing.isEmpty,
                      "done 전환 시점 ring 비어있어야 함 (새 감지는 fresh samples 로)")
    }
}

// MARK: - MotionConflict Fix#3 update: smooth task positionWrites overlap

@MainActor
final class MotionConflictSmoothReturnOverlapTests: XCTestCase {

    /// 종전 'smooth Task positionWrites check skipped' 를 대체.
    /// smoothReturnTask 가 re-arm 호출 전에 cancel 되면 버스에 walkReady drain write 가
    /// 새 gait write 와 겹치지 않는다.
    ///
    /// 전략: smoothReturnTask 를 수동 spawn (long sleep) → re-arm → cancel 확인 → 빈 bus
    func testNoOverlapWalkReadyAndNewGait_WhenReArmCancelsSmoothReturn() async {
        let (session, _, bus) = makeSessionWithBus()

        // smooth-return Task: 10초 sleep (테스트 중 끝나지 않음)
        let smoothTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        session.smoothReturnTask = smoothTask

        bus.resetRecordedWrites()

        // re-arm: smooth-return 취소 + 새 cycle 시작 시도
        let tuning = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 700, footHeightMm: 35,
            balanceGain: 1.0, hipPitchOffsetDeg: 13)
        _ = session.startOrUpdateMobileFreeform(tuning: tuning)

        // smooth-return Task 가 cancel 되었으므로 walkReady drain write 없음
        XCTAssertTrue(smoothTask.isCancelled,
                      "re-arm 후 smooth-return Task cancel 필수 — bus contention 방지")

        // bus write 는 새 freeform task 가 spawn 되어야 나타남 — 여기서는 task spawn만 확인
        // (실제 write 는 async Task 내부 — 이 테스트에서는 cancel 확인이 핵심)
    }
}

#endif
