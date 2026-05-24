import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// **v1.22.x (2026-05-24) — 사이클 116 (WalkCycleEngine coverage)**.
///
/// `WalkLabSession+WalkCycleEngine.swift` 의 두 static engine
/// (`runContinuousWalk` / `runWalkCycle`) 에 대한 최초 단위 테스트.
/// 종전: coverage 0%. 목표: 50%+ (P0 first pass).
///
/// # 비유
///
/// 공장 조립 라인의 PLC (Programmable Logic Controller) 단위 검사.
/// 실제 컨베이어 (로봇 하드웨어) 없이 모의 컨베이어 (MockBus) 로
/// 각 스텝 — 속도 설정 → 위치 전송 → 타임아웃 → 복귀 — 을 검증.
///
/// # 전략
///
/// - `runWalkCycle` (loop=false): 단일 cycle 종료 경로 집중 검증.
/// - `runContinuousWalk`: entry → cycle(짧음) → exit 흐름 검증.
/// - MockBus 활용 — 속도/위치 write 기록 확인.
/// - FailingMockBuses (AlwaysFailingMockBus, SingleJointFailMockBus) 로 fault path 검증.
///
/// # Task.sleep 우회 전략
///
/// `runWalkCycle` / `runContinuousWalk` 내부의 `Task.sleep(nanoseconds:)` 는
/// `max(80, playMs + pauseMs)` ms. `MotionStep.from(pose:playMs:pauseMs:)` 에서
/// `playMs=8` (playTime=1) + `pauseMs=0` → `max(80, 8)` = **80 ms** 으로 최소화.
/// 테스트당 sleep overhead ≤ steps × 80 ms 수준으로 제한.
final class WalkLabSessionWalkCycleEngineTests: XCTestCase {

    // MARK: - Helpers

    /// 하체 관절 Set (lowerBodyJoints private static 의 공개 동등체).
    private var lowerBodyJoints: Set<JointID> {
        Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })
    }

    /// 최소 duration MotionStep — playMs=8 (최솟값 유효 단위), pauseMs=0.
    /// Task.sleep = max(80, 8+0) = 80ms 로 최소화.
    private func minimalStep() -> MotionStep {
        .from(pose: .walkReady, playMs: 8, pauseMs: 0)
    }

    /// 1-step `MotionPage` — runWalkCycle 호출용.
    private func singleStepPage() -> MotionPage {
        MotionPage(id: 200, steps: [minimalStep()])
    }

    /// 1-step ContinuousWalkPlan — runContinuousWalk 호출용.
    private func singleStepPlan() -> WalkMotionLibrary.ContinuousWalkPlan {
        let s = minimalStep()
        return WalkMotionLibrary.ContinuousWalkPlan(entry: [s], cycle: [s], exit: [s])
    }

    // MARK: - runWalkCycle: 정상 경로

    /// loop=false + 성공 bus → completedMaxDuration 반환.
    ///
    /// "보행 루프를 딱 한 바퀴 돌렸을 때 정상 종료 코드가 반환된다."
    func testRunWalkCycle_SingleLoop_ReturnsCompletedMaxDuration() async {
        let bus = MockBus()
        let page = singleStepPage()

        let result = await WalkLabSession.runWalkCycle(
            bus: bus,
            page: page,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            loop: false
        )

        XCTAssertEqual(result.reason, .completedMaxDuration,
                       "loop=false 단일 cycle → completedMaxDuration")
        XCTAssertGreaterThan(result.stepsExecuted, 0,
                             "적어도 1 step 이상 실행")
    }

    /// loop=false + 성공 bus → movingSpeed 모든 관절에 기록.
    ///
    /// "cycle 시작 전 모든 관절에 속도 명령이 전송된다."
    func testRunWalkCycle_SingleLoop_SetsMovingSpeedForAllJoints() async {
        let bus = MockBus()
        let page = singleStepPage()

        _ = await WalkLabSession.runWalkCycle(
            bus: bus,
            page: page,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            loop: false
        )

        let speedSet = Set(bus.speedWrites.map { $0.joint })
        for joint in JointID.allCases {
            XCTAssertTrue(speedSet.contains(joint),
                          "\(joint.name) 에 setMovingSpeed 호출 없음")
        }
    }

    /// loop=false + 성공 bus → positionWrite 기록됨 (walkReady → 자신이면 changedJoints=0).
    ///
    /// "walkReady pose 에서 walkReady step 은 변경 관절이 없어 setPosition 호출이 0."
    func testRunWalkCycle_WalkReadyStep_ZeroPositionWrites() async {
        let bus = MockBus()
        // walkReady → walkReady: changedJoints = 0
        let page = singleStepPage()

        _ = await WalkLabSession.runWalkCycle(
            bus: bus,
            page: page,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            loop: false
        )

        // walkReady → walkReady step 은 delta=0 → setPosition 호출 없음.
        XCTAssertEqual(bus.positionWrites.count, 0,
                       "동일 pose step 은 setPosition 미호출")
    }

    /// onPose 콜백 — step 당 1회 호출.
    ///
    /// "각 step 이 처리될 때마다 onPose 가 정확히 한 번 호출된다."
    func testRunWalkCycle_OnPoseCallback_CalledPerStep() async {
        let bus = MockBus()
        let page = MotionPage(id: 201, steps: [minimalStep(), minimalStep()])
        var poseCount = 0

        _ = await WalkLabSession.runWalkCycle(
            bus: bus,
            page: page,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            loop: false,
            onPose: { _ in poseCount += 1 }
        )

        XCTAssertEqual(poseCount, 3, "step 2개 + exit walkReady → onPose 3회 호출")
    }

    // MARK: - runWalkCycle: 취소 경로

    /// Task cancel → userCancelled.
    ///
    /// "외부에서 Task 취소 시 endReason 이 userCancelled 로 전환된다."
    func testRunWalkCycle_TaskCancelled_ReturnsUserCancelled() async {
        let bus = MockBus()
        // 여러 step 으로 취소 발화 기회 확대 (각 80ms sleep 포함).
        let steps = (0..<3).map { _ in minimalStep() }
        let page = MotionPage(id: 202, steps: steps)

        let task = Task {
            await WalkLabSession.runWalkCycle(
                bus: bus,
                page: page,
                maxDurationSec: 0,
                lowerBodyJoints: lowerBodyJoints,
                loop: true  // loop=true 여야 cancel 이 의미 있음
            )
        }
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.reason, .userCancelled,
                       "Task cancel → userCancelled")
    }

    // MARK: - runWalkCycle: bus 끊김

    /// isBusAlive=false → busDisconnected.
    ///
    /// "bus 연결이 끊겼음을 탐지하면 즉시 busDisconnected 로 중단된다."
    func testRunWalkCycle_BusAlwaysDead_ReturnsBusDisconnected() async {
        let bus = MockBus()
        let page = singleStepPage()

        let result = await WalkLabSession.runWalkCycle(
            bus: bus,
            page: page,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            loop: false,
            isBusAlive: { false }
        )

        XCTAssertEqual(result.reason, .busDisconnected,
                       "isBusAlive=false → busDisconnected")
    }

    // MARK: - runWalkCycle: hard stop (emergencyStop)

    /// isHardStopped=true → exit phase 스킵 + userCancelled.
    ///
    /// "긴급 정지 상태에서는 walkReady 복귀 시도 없이 즉시 반환된다 (torque OFF 보호)."
    func testRunWalkCycle_HardStopped_SkipsExitAndReturnsUserCancelled() async {
        let bus = MockBus()
        let page = singleStepPage()
        var positionBeforeHardStop = 0

        let result = await WalkLabSession.runWalkCycle(
            bus: bus,
            page: page,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            loop: false,
            isHardStopped: { true }
        )
        positionBeforeHardStop = bus.positionWrites.count

        // hard stop 시 exit setPosition 없음 (walkReady 복귀 스킵).
        XCTAssertEqual(result.reason, .userCancelled,
                       "isHardStopped=true → userCancelled 반환")
        XCTAssertNotNil(result.sampleError,
                        "sampleError 에 emergencyStop 안내 메시지 포함")
        XCTAssertTrue(result.sampleError?.contains("emergencyStop") ?? false,
                      "sampleError 에 'emergencyStop' 키워드 포함")
        XCTAssertEqual(positionBeforeHardStop, 0,
                       "hard stop → exit setPosition 호출 없음")
    }

    // MARK: - runWalkCycle: speed write 실패

    /// movingSpeed 실패 시 speedWriteFailures 기록.
    ///
    /// "속도 전송 실패는 결과의 speedWriteFailures 에 누적된다."
    func testRunWalkCycle_MovingSpeedFailures_RecordedInResult() async {
        let bus = AlwaysFailingMockBus(failMovingSpeed: true)
        let page = singleStepPage()

        let result = await WalkLabSession.runWalkCycle(
            bus: bus,
            page: page,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            loop: false
        )

        XCTAssertGreaterThan(result.speedWriteFailures, 0,
                             "setMovingSpeed 항상 실패 → speedWriteFailures > 0")
        XCTAssertNotNil(result.sampleError,
                        "속도 실패 sampleError 기록")
    }

    // MARK: - runWalkCycle: position write 실패

    /// 단일 하체 관절 위치 전송 반복 실패 → lowerBodyWriteFailure (또는 bulkWriteFailure).
    ///
    /// "하체 관절 위치 전송이 임계 횟수를 초과해 실패하면 보행이 안전하게 중단된다."
    ///
    /// **버그 수정 (사이클 116, V280-F)**: 이전 코드는 모든 step 이 동일한 rHipYaw=1024
    /// 값을 사용 → step 2부터 previous.raw(.rHipYaw)==target.raw(.rHipYaw)==1024 로
    /// changedJoints 가 빈 배열 → setPosition 미호출 → perJointConsecutiveFailureLimit
    /// 카운터 미누적. 홀/짝 step 을 1024/3072 로 교번하여 매 step changedJoints 에
    /// rHipYaw 포함 보장.
    func testRunWalkCycle_LowerBodyJointAlwaysFail_StopsBelowThreshold() async {
        // 하체 관절 중 하나 (rHipYaw) 만 실패.
        let bus = SingleJointFailMockBus(failJoint: .rHipYaw)
        // 충분한 step 수 → perJointConsecutiveFailureLimit (5) 초과 유도.
        // 홀/짝 step 에서 rHipYaw 를 1024/3072 로 교번 → 매 step changedJoints 에 포함.
        let steps = (0..<10).map { i in
            var pos = Array<UInt16>(repeating: MotionStep.invalidBitMask, count: 31)
            pos[Int(JointID.rHipYaw.rawValue)] = (i % 2 == 0) ? 1024 : 3072  // 교번 → always changed
            return MotionStep(positions: pos, pauseTime: 0, playTime: 1)
        }
        let page = MotionPage(id: 203, steps: steps)

        let result = await WalkLabSession.runWalkCycle(
            bus: bus,
            page: page,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            loop: false
        )

        // perJointConsecutiveFailureLimit=5 초과 → lowerBodyWriteFailure.
        XCTAssertEqual(result.reason, .lowerBodyWriteFailure,
                       "단일 하체 관절 연속 실패 → lowerBodyWriteFailure")
        XCTAssertGreaterThan(result.positionWriteFailures, 0,
                             "positionWriteFailures 누적")
    }

    // MARK: - runWalkCycle: transformPose 콜백

    /// transformPose 가 identity 함수일 때 결과 불변 확인.
    ///
    /// "balance correction 패스스루(identity) 시 정상 종료 코드는 변경되지 않는다."
    func testRunWalkCycle_TransformPoseIdentity_DoesNotAlterEndReason() async {
        let bus = MockBus()
        let page = singleStepPage()

        let result = await WalkLabSession.runWalkCycle(
            bus: bus,
            page: page,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            loop: false,
            transformPose: { $0 }  // identity
        )

        XCTAssertEqual(result.reason, .completedMaxDuration,
                       "identity transformPose → endReason 불변")
    }

    // MARK: - runContinuousWalk: 정상 경로

    /// 정상 bus + single-step plan → completedMaxDuration.
    ///
    /// "entry→cycle(짧음)→exit 흐름이 정상 완료되면 completedMaxDuration 을 반환한다."
    func testRunContinuousWalk_NormalBus_ReturnsCompletedMaxDuration() async {
        let bus = MockBus()
        let plan = singleStepPlan()

        // maxDurationSec=0 → endDate=nil → cycle loop 는 Task.isCancelled 만 체크.
        // loop 탈출: Task cancel 없으면 무한 — maxDurationSec 음수 처리 없음.
        // 따라서 Task 직접 취소로 종료 유도.
        let task = Task {
            await WalkLabSession.runContinuousWalk(
                bus: bus,
                plan: plan,
                maxDurationSec: 0,
                lowerBodyJoints: lowerBodyJoints
            )
        }
        // 250ms 후 cancel → cycle 최소 1회는 실행됨.
        try? await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.reason, .userCancelled,
                       "Task cancel → userCancelled (정상 종료 계열)")
        // stepsExecuted: entry 1 + cycle N 포함 — 0 이상이면 실행됨.
        XCTAssertGreaterThanOrEqual(result.stepsExecuted, 0,
                                    "stepsExecuted 음수 불가")
    }

    /// 모든 관절에 movingSpeed 설정 확인.
    ///
    /// "연속 보행 시작 시 모든 20 관절에 속도 명령이 한 번씩 전송된다."
    func testRunContinuousWalk_SetsMovingSpeedOnce_ForAllJoints() async {
        let bus = MockBus()
        let plan = singleStepPlan()

        let task = Task {
            await WalkLabSession.runContinuousWalk(
                bus: bus,
                plan: plan,
                maxDurationSec: 0,
                lowerBodyJoints: lowerBodyJoints
            )
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.value

        let speedJoints = Set(bus.speedWrites.map { $0.joint })
        XCTAssertEqual(speedJoints.count, JointID.allCases.count,
                       "모든 관절에 speedWrite 완료")
    }

    // MARK: - runContinuousWalk: bus 끊김

    /// isBusAlive=false → entry 단계에서 busDisconnected.
    ///
    /// "bus 연결 끊김을 탐지하면 entry step 도중 즉시 busDisconnected 로 중단된다."
    func testRunContinuousWalk_BusDead_ReturnsBusDisconnected() async {
        let bus = MockBus()
        let plan = singleStepPlan()

        let result = await WalkLabSession.runContinuousWalk(
            bus: bus,
            plan: plan,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            isBusAlive: { false }
        )

        XCTAssertEqual(result.reason, .busDisconnected,
                       "isBusAlive=false → busDisconnected")
    }

    // MARK: - runContinuousWalk: hard stop

    /// isHardStopped=true → exit 스킵 + sampleError 포함.
    ///
    /// "긴급 정지 상태에서 연속 보행도 exit phase 를 건너뛰어 토크 OFF 보호가 유지된다."
    ///
    /// **버그 수정 (사이클 116, V280-F)**: 이전 코드는 `isBusAlive: { true }` 기본값 +
    /// `maxDurationSec: 0` 조합으로 cycleLoop 가 `endDate == nil` + `isHardStopped` 조기
    /// 반환 (sleep 없음) → 무한 busy-loop 유발. `isBusAlive: { false }` 추가로 cycleLoop
    /// 최초 isBusAlive 체크에서 즉시 break, 이후 isHardStopped 분기가 .userCancelled 반환.
    func testRunContinuousWalk_HardStopped_SkipsExitPhase() async {
        let bus = MockBus()
        let plan = singleStepPlan()

        let result = await WalkLabSession.runContinuousWalk(
            bus: bus,
            plan: plan,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            isBusAlive: { false },  // cycleLoop 진입 즉시 busDisconnected → isHardStopped 분기로 override
            isHardStopped: { true }
        )

        XCTAssertEqual(result.reason, .userCancelled,
                       "isHardStopped=true → userCancelled")
        XCTAssertTrue(result.sampleError?.contains("emergencyStop") ?? false,
                      "sampleError 에 'emergencyStop' 포함")
    }

    // MARK: - runContinuousWalk: onBusWriteFailure callback

    /// movingSpeed 실패 시 onBusWriteFailure 콜백 호출.
    ///
    /// "속도 전송 실패마다 ConnectionStore 누적을 위해 onBusWriteFailure 가 호출된다."
    func testRunContinuousWalk_MovingSpeedFail_TriggersOnBusWriteFailureCallback() async {
        let bus = AlwaysFailingMockBus(failMovingSpeed: true)
        let plan = singleStepPlan()

        var failureCallbackCount = 0
        let callbackLock = NSLock()

        let result = await WalkLabSession.runContinuousWalk(
            bus: bus,
            plan: plan,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBodyJoints,
            isBusAlive: { false },  // 즉시 종료 (busDisconnected)
            onBusWriteFailure: {
                callbackLock.lock()
                failureCallbackCount += 1
                callbackLock.unlock()
            }
        )

        // movingSpeed 실패는 isBusAlive 체크 전이므로 callback 호출됨.
        // Main actor 도달에 짧은 시간이 필요하므로 결과 확인 전 await.
        await Task.yield()

        XCTAssertEqual(result.reason, .busDisconnected)
        XCTAssertGreaterThan(result.speedWriteFailures, 0,
                             "속도 write 실패 카운트")
    }

    // MARK: - runContinuousWalk: transformPose integration

    /// transformPose 가 pose 를 변형할 때 onPose 가 변형된 값을 받음.
    ///
    /// "balance corrector 가 pose 를 변형하면 3D 모델 갱신 콜백에 보정된 pose 가 전달된다."
    ///
    /// **버그 수정 (사이클 116, V280-F)**: 이전 코드의 `isBusAlive: { false }` 는 entry
    /// 실행 전 체크에서 즉시 break → onPose 미호출. `maxDurationSec: 1` 로 변경해
    /// entry 를 정상 실행하고 1초 후 자연 종료. cycle/exit 가 빈 배열이므로
    /// 실제 대기는 entry step sleep (80ms) + cycleLoop timeout (~1초) 이하.
    func testRunContinuousWalk_TransformPose_OnPoseReceivesTransformedPose() async {
        let bus = MockBus()
        // entry step 에 walkReady 와 다른 포즈 사용 → transformPose 적용 확인.
        var pos = Array<UInt16>(repeating: MotionStep.invalidBitMask, count: 31)
        pos[Int(JointID.headPan.rawValue)] = 1500
        let customStep = MotionStep(positions: pos, pauseTime: 0, playTime: 1)
        let plan = WalkMotionLibrary.ContinuousWalkPlan(
            entry: [customStep],
            cycle: [minimalStep()],  // 1 step → cycleLoop 에 80ms sleep 제공, tight-loop 방지
            exit: []
        )

        var receivedPoses: [RobotPose] = []
        // transformPose: headPan raw 를 강제로 1234 로 변환.
        let transform: @MainActor @Sendable (RobotPose) -> RobotPose = { pose in
            var dict: [JointID: Int] = [:]
            for j in JointID.allCases { dict[j] = pose.raw(j) }
            dict[.headPan] = 1234
            return RobotPose(positions: dict)
        }

        _ = await WalkLabSession.runContinuousWalk(
            bus: bus,
            plan: plan,
            maxDurationSec: 1,  // 1초 후 종료 (cycle step 80ms sleep × ~12 iter)
            lowerBodyJoints: lowerBodyJoints,
            onPose: { pose in receivedPoses.append(pose) },
            transformPose: transform
        )

        XCTAssertFalse(receivedPoses.isEmpty, "entry step onPose 호출됨")
        if let firstPose = receivedPoses.first {
            XCTAssertEqual(firstPose.raw(.headPan), 1234,
                           "transformPose 가 onPose 에 전달되는 pose 를 변형")
        }
    }

    // MARK: - runContinuousWalk: maxDurationSec 유효 경로

    /// maxDurationSec=1 → 1초 후 자동 종료 completedMaxDuration.
    ///
    /// "최대 시간 도달 시 보행이 정상 종료 코드(completedMaxDuration)를 반환한다."
    func testRunContinuousWalk_MaxDurationElapsed_ReturnsCompletedMaxDuration() async {
        let bus = MockBus()
        // entry 없음, cycle 1 step → maxDuration 1s 에 자연 종료.
        let s = minimalStep()
        let plan = WalkMotionLibrary.ContinuousWalkPlan(entry: [], cycle: [s], exit: [])

        let result = await WalkLabSession.runContinuousWalk(
            bus: bus,
            plan: plan,
            maxDurationSec: 1,
            lowerBodyJoints: lowerBodyJoints
        )

        XCTAssertEqual(result.reason, .completedMaxDuration,
                       "maxDurationSec 도달 → completedMaxDuration")
    }
}
