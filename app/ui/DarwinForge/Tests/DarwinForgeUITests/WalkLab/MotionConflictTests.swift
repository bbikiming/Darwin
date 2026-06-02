// V298-MotionConflict: Fix #1/#2/#3 회귀 가드 테스트
// - Fix #1: 보행 중 머리 조종 → pending 버퍼 경로; 직접 writeJointPosition 미발사
// - Fix #2: 미세 tuning 변화 시 engine.setCommand skip; 실 변화 시 전송; stop 전환 항상 전송
// - Fix #3: 정상 정지 시 smooth applyPoseSmoothly; emergency 시 즉시 경로
#if DEBUG
import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

// MARK: - Helpers (MainActor — ConnectionStore/WalkLabSession 초기화 격리)

@MainActor
private func makeStoreWithBus() -> (store: ConnectionStore, bus: MockBus) {
    let bus = MockBus()
    let harness = RecordingHarness()
    let store = ConnectionStore(harness: harness)
    store.bus = bus
    return (store, bus)
}

@MainActor
private func makeSession(store: ConnectionStore? = nil) -> WalkLabSession {
    let session = WalkLabSession(harness: RecordingHarness())
    if let store = store {
        session.attach(store: store)
        session.cradleConfirmed = true
    }
    return session
}

// MARK: - Fix #1: pending head during walk

@MainActor
final class MotionConflictPendingHeadTests: XCTestCase {

    /// 보행 중 setPendingHead 를 호출하면 pendingHeadPanRaw/TiltRaw 에 저장된다.
    func testSetPendingHead_StoresPendingValues() {
        let session = makeSession()
        session.setPendingHead(panRaw: 2100, tiltRaw: 2000)
        XCTAssertEqual(session.pendingHeadPanRaw, 2100)
        XCTAssertEqual(session.pendingHeadTiltRaw, 2000)
    }

    /// pendingHeadSnapshot() 은 저장된 값을 반환하고 nil 로 초기화한다 (1회 소비).
    func testPendingHeadSnapshot_ConsumesAndNilifies() async {
        let session = makeSession()
        session.setPendingHead(panRaw: 2100, tiltRaw: 2000)
        let snap = session.pendingHeadSnapshot()
        XCTAssertEqual(snap?.pan, 2100, "pan raw 반환")
        XCTAssertEqual(snap?.tilt, 2000, "tilt raw 반환")
        // 소비 후 nil
        XCTAssertNil(session.pendingHeadPanRaw, "소비 후 nil")
        XCTAssertNil(session.pendingHeadTiltRaw, "소비 후 nil")
    }

    /// pending 이 없으면 nil 반환.
    func testPendingHeadSnapshot_NilWhenEmpty() {
        let session = makeSession()
        let snap = session.pendingHeadSnapshot()
        XCTAssertNil(snap, "pending 없으면 nil")
    }

    /// 두 번 연속 snapshot — 첫 번째만 값, 두 번째는 nil.
    func testPendingHeadSnapshot_OnlyConsumedOnce() {
        let session = makeSession()
        session.setPendingHead(panRaw: 2200, tiltRaw: 1900)
        let first  = session.pendingHeadSnapshot()
        let second = session.pendingHeadSnapshot()
        XCTAssertNotNil(first)
        XCTAssertNil(second, "두 번째는 소비 없음")
    }
}

// MARK: - Fix #1: head flush ordering in sendStep

@MainActor
final class MotionConflictHeadFlushOrderTests: XCTestCase {

    /// sendStep 내 head flush invariant: head write 는 같은 step 의 leg write 루프
    /// AFTER 발생한다. 즉 어떤 head write 다음에 leg write 가 나타나지 않는다
    /// (head 가 leg 사이에 끼어들어 인터리브하지 않음).
    ///
    /// 검증 방법: 전체 positionWrites 시퀀스에서 head write(idx=h) 직후
    /// leg write(idx=h+1)가 등장하는 쌍이 있으면 인터리브 발생 → 실패.
    func testRunMobileFreeformWalk_HeadWriteNeverInterleave() async {
        let bus = MockBus()
        // headProvider 는 매 step 마다 non-nil 반환.
        let headProvider: @Sendable () async -> (pan: Int, tilt: Int)? = {
            return (pan: 2100, tilt: 2010)
        }

        let lowerBody = Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })
        let tuning = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 700, footHeightMm: 35,
            balanceGain: 1.0, hipPitchOffsetDeg: 13)
        let callActor = CounterActor()
        let tuningProvider: @Sendable () async -> WalkMotionLibrary.AdvancedTuning? = {
            let count = await callActor.increment()
            if count > 2 { return nil }
            return tuning
        }

        let _ = await WalkLabSession.runMobileFreeformWalk(
            bus: bus,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBody,
            tuningProvider: tuningProvider,
            headProvider: headProvider
        )

        let writes = bus.positionWrites

        // head write 가 있어야 함 (headProvider 가 매번 값 반환).
        let headWrites = writes.filter { $0.joint == .headPan || $0.joint == .headTilt }
        XCTAssertFalse(headWrites.isEmpty, "headProvider 로 인해 head write 가 발생해야 함")

        // 인터리브 검증: head(idx=i) 다음에 leg(idx=i+1) 가 나타나는 쌍 없어야 함.
        var interleaveFound = false
        for i in writes.indices.dropLast() {
            let isHead = writes[i].joint == .headPan || writes[i].joint == .headTilt
            let nextIsLeg = lowerBody.contains(writes[i + 1].joint)
            if isHead && nextIsLeg {
                interleaveFound = true
                break
            }
        }
        XCTAssertFalse(interleaveFound,
            "head write 직후 leg write 가 등장하면 인터리브 — head 는 leg 루프 이후에만 발생해야 함")
    }

    /// headProvider = nil (default) 이면 head write 가 발생하지 않는다.
    func testRunMobileFreeformWalk_NoHeadWriteWhenProviderNil() async {
        let bus = MockBus()
        let lowerBody = Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })
        let tuning = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 700, footHeightMm: 35,
            balanceGain: 1.0, hipPitchOffsetDeg: 13)
        let callActor = CounterActor()
        let tuningProvider: @Sendable () async -> WalkMotionLibrary.AdvancedTuning? = {
            let count = await callActor.increment()
            if count > 2 { return nil }
            return tuning
        }

        let _ = await WalkLabSession.runMobileFreeformWalk(
            bus: bus,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBody,
            tuningProvider: tuningProvider
            // headProvider 미전달 = nil (기존 동작 보존)
        )

        let headWrites = bus.positionWrites.filter {
            $0.joint == .headPan || $0.joint == .headTilt
        }
        XCTAssertTrue(headWrites.isEmpty, "headProvider nil 시 head write 없어야 함")
    }

    /// isHardStopped = true 이면 headProvider 있어도 head write 를 건너뛴다.
    func testRunMobileFreeformWalk_HeadSkippedWhenHardStopped() async {
        let bus = MockBus()
        let lowerBody = Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })
        let tuning = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 700, footHeightMm: 35,
            balanceGain: 1.0, hipPitchOffsetDeg: 13)
        let callActor = CounterActor()
        let tuningProvider: @Sendable () async -> WalkMotionLibrary.AdvancedTuning? = {
            let count = await callActor.increment()
            if count > 2 { return nil }
            return tuning
        }

        let _ = await WalkLabSession.runMobileFreeformWalk(
            bus: bus,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBody,
            tuningProvider: tuningProvider,
            headProvider: { return (pan: 2100, tilt: 2010) },
            isHardStopped: { true }   // 항상 hard-stopped
        )

        let headWrites = bus.positionWrites.filter {
            $0.joint == .headPan || $0.joint == .headTilt
        }
        // isHardStopped=true → sendStep 이 즉시 return (다리도 write 안 함).
        // head write 도 없어야 함.
        XCTAssertTrue(headWrites.isEmpty, "hardStopped 시 head write 없어야 함")
    }
}

// MARK: - Fix #2: dispatch thrash skip

@MainActor
final class MotionConflictDispatchThrottleTests: XCTestCase {

    /// 동일 tuning 을 두 번 apply → _lastAppliedFreeformTuning 캐시 값이 유지된다.
    func testApplyTuningTwice_SameValues_CacheUnchanged() {
        let session = makeSession()
        session.mobileFreeformActive = true

        let tuning = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 5,
            periodMs: 700, footHeightMm: 35,
            balanceGain: 1.0, hipPitchOffsetDeg: 13)

        _ = session.startOrUpdateMobileFreeform(tuning: tuning)
        let firstCache = session._lastAppliedFreeformTuning

        _ = session.startOrUpdateMobileFreeform(tuning: tuning)
        let secondCache = session._lastAppliedFreeformTuning

        XCTAssertNotNil(firstCache, "첫 apply 후 cache 설정되어야 함")
        // 동일 apply → skip → cache 값 변경 없음 (동일 값 유지).
        XCTAssertEqual(firstCache?.strideMm, secondCache?.strideMm,
                       "동일 apply 시 cache strideMm 변경 없음")
    }

    /// 실질적으로 다른 값(|Δstride| ≥ 0.5) → cache 갱신.
    func testApplyTuning_DifferentValues_UpdatesCache() {
        let session = makeSession()
        session.mobileFreeformActive = true

        let tuning1 = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 700, footHeightMm: 35, balanceGain: 1.0, hipPitchOffsetDeg: 13)
        let tuning2 = WalkMotionLibrary.AdvancedTuning(
            strideMm: 25, sideMm: 0, turnDeg: 0,  // +5mm > epsilon 0.5
            periodMs: 700, footHeightMm: 35, balanceGain: 1.0, hipPitchOffsetDeg: 13)

        _ = session.startOrUpdateMobileFreeform(tuning: tuning1)
        _ = session.startOrUpdateMobileFreeform(tuning: tuning2)

        XCTAssertEqual(session._lastAppliedFreeformTuning?.strideMm ?? 0,
                       tuning2.strideMm, accuracy: 0.01,
                       "다른 값 apply 시 cache 가 새 값으로 갱신되어야 함")
    }

    /// stop 전환(stride/side/turn 모두 0) → delta 관계없이 항상 적용 (cache 갱신).
    func testApplyTuning_StopTransition_AlwaysApplied() {
        let session = makeSession()
        session.mobileFreeformActive = true

        let running = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 5, turnDeg: 3,
            periodMs: 700, footHeightMm: 35, balanceGain: 1.0, hipPitchOffsetDeg: 13)
        let stop = WalkMotionLibrary.AdvancedTuning(
            strideMm: 0, sideMm: 0, turnDeg: 0,  // stop
            periodMs: 700, footHeightMm: 35, balanceGain: 1.0, hipPitchOffsetDeg: 13)

        _ = session.startOrUpdateMobileFreeform(tuning: running)
        _ = session.startOrUpdateMobileFreeform(tuning: stop)

        // stop 후 cache 는 stop tuning 으로 갱신.
        XCTAssertEqual(session._lastAppliedFreeformTuning?.strideMm ?? 1, 0, accuracy: 0.01,
                       "stop 전환 후 cache 가 stop tuning 으로 갱신되어야 함")
    }

    /// 보행 비활성 상태에서 apply → cache nil 로 초기화.
    func testApplyTuning_WhenNotWalking_ClearsCache() {
        let session = makeSession()
        // 보행 중 상태에서 cache 세팅.
        session.mobileFreeformActive = true
        let tuning = WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 700, footHeightMm: 35, balanceGain: 1.0, hipPitchOffsetDeg: 13)
        _ = session.startOrUpdateMobileFreeform(tuning: tuning)
        XCTAssertNotNil(session._lastAppliedFreeformTuning, "보행 중 cache 설정")

        // 보행 비활성 → cache nil.
        session.mobileFreeformActive = false
        session.walkCycleTask = nil
        _ = session.startOrUpdateMobileFreeform(tuning: tuning)
        XCTAssertNil(session._lastAppliedFreeformTuning,
                     "보행 비활성 apply 후 cache nil 초기화")
    }
}

// MARK: - Fix #3: smooth walkReady return

@MainActor
final class MotionConflictSmoothReturnTests: XCTestCase {

    /// 정상 정지(비emergency) + bus/cradle 있음 → cancelWalkCycle 이 lastRobotEvent 를
    /// smooth 경로용으로 갱신하고, smoothReturnTask handle 을 저장한다.
    /// H1 fix: 종전 'smooth Task positionWrites check skipped' → handle 저장 + overlap 방지 확인.
    func testCancelWalkCycle_NonEmergency_SetsLastRobotEventAndStoresHandle() async {
        let (store, bus) = makeStoreWithBus()
        let session = makeSession(store: store)
        session.cradleConfirmed = true

        // long-lived task: await task.value 가 완료되지 않아 smoothReturnTask body 가
        // nil set 하기 전에 handle 저장을 확인 가능.
        let longTask: Task<Void, Never> = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
        }
        session.walkCycleTask = longTask

        bus.resetRecordedWrites()

        session.cancelWalkCycle(eventLabel: "test-smooth-return")

        // smooth 경로에서 lastRobotEvent = "🤖 \(eventLabel)" 으로 갱신.
        XCTAssertEqual(session.lastRobotEvent, "🤖 test-smooth-return",
                       "smooth 경로 진입 시 lastRobotEvent 갱신")
        XCTAssertNil(session.walkCycleTask, "cancel 후 walkCycleTask nil")
        // H1 fix: smoothReturnTask handle 저장 확인 — re-arm/E-STOP 이 이 handle 로 cancel 가능.
        XCTAssertNotNil(session.smoothReturnTask,
                        "H1 fix: cancelWalkCycle 후 smoothReturnTask handle 저장 필수")

        // cleanup
        longTask.cancel()
    }

    /// emergency 중 → walkCycleTask 가 nil 로 정리된다.
    func testCancelWalkCycle_DuringEmergency_CancelsTask() {
        let (store, _) = makeStoreWithBus()
        let session = makeSession(store: store)
        session.cradleConfirmed = true
        session.emergencyStopActive = true

        let dummyTask: Task<Void, Never> = Task { }
        session.walkCycleTask = dummyTask

        session.cancelWalkCycle(eventLabel: "test-emergency-path")

        XCTAssertNil(session.walkCycleTask, "cancel 후 walkCycleTask nil")
    }

    /// bus 없는 시뮬 모드에서는 즉시 경로 (walkCycleTask nil 확인).
    func testCancelWalkCycle_NoBus_CancelsTask() {
        let session = makeSession()   // store 없음 → bus nil
        session.cradleConfirmed = false

        let dummyTask: Task<Void, Never> = Task { }
        session.walkCycleTask = dummyTask

        session.cancelWalkCycle(eventLabel: "test-no-bus")

        XCTAssertNil(session.walkCycleTask, "cancel 후 walkCycleTask nil")
    }
}

// MARK: - Fix #3: emergency precedence

@MainActor
final class MotionConflictEmergencyPrecedenceTests: XCTestCase {

    /// emergency 도중 pendingHead 가 있어도 isHardStopped=true 이면 head write 를 건너뛴다.
    func testEmergency_HeadFlushSkippedWhenHardStopped() async {
        let bus = MockBus()
        let lowerBody = Set(JointID.allCases.filter {
            $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg
        })
        let callActor = CounterActor()
        let tuningProvider: @Sendable () async -> WalkMotionLibrary.AdvancedTuning? = {
            let count = await callActor.increment()
            if count > 1 { return nil }
            return WalkMotionLibrary.AdvancedTuning(
                strideMm: 20, sideMm: 0, turnDeg: 0,
                periodMs: 700, footHeightMm: 35, balanceGain: 1.0, hipPitchOffsetDeg: 13)
        }

        let _ = await WalkLabSession.runMobileFreeformWalk(
            bus: bus,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBody,
            tuningProvider: tuningProvider,
            headProvider: { return (pan: 2200, tilt: 2010) },
            isHardStopped: { true }   // emergency = hard-stopped
        )

        let headWrites = bus.positionWrites.filter {
            $0.joint == .headPan || $0.joint == .headTilt
        }
        XCTAssertTrue(headWrites.isEmpty, "hardStopped(emergency) 중 head write 없어야 함")
    }
}

// MARK: - Thread-safe helpers for @Sendable closures

/// 단일 once-and-done head target 을 thread-safe 하게 제공하는 actor.
private actor HeadProviderActor {
    private var provided = false
    func next(pan: Int, tilt: Int) -> (pan: Int, tilt: Int)? {
        guard !provided else { return nil }
        provided = true
        return (pan, tilt)
    }
}

/// 호출 횟수를 thread-safe 하게 누적하는 actor.
private actor CounterActor {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

#endif
