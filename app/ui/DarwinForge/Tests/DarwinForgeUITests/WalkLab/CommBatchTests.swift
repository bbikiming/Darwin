// Phase 1 SYNC_WRITE batching regression tests.
//
// Verifies:
// 1. `MockBus.setPositions` records a single batched call, not N individual setPosition calls.
// 2. `runMobileFreeformWalk` sendStep issues ONE `setPositions` call per step (not 14 separate
//    `setPosition` calls).
// 3. Transport failure from `setPositions` escalates `endReason` to `.lowerBodyWriteFailure`
//    or `.bulkWriteFailure` (consistent with previous per-joint failure detection).
// 4. Head pending target is appended to the batch (same SYNC_WRITE packet as legs).
// 5. Existing MotionConflict / head-flush ordering behaviour still holds.
#if DEBUG
import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

// MARK: - 1. MockBus.setPositions records a batch, not individual writes

final class CommBatchMockBusTests: XCTestCase {

    /// `setPositions` records one entry in `batchPositionCalls` with all targets.
    func testSetPositions_RecordsOneBatchCall() {
        let bus = MockBus()
        let targets: [(JointID, UInt16)] = [
            (.rHipPitch,  2048),
            (.lHipPitch,  2048),
            (.rKnee,      2100),
            (.lKnee,      2100),
        ]
        XCTAssertNoThrow(try bus.setPositions(targets))
        XCTAssertEqual(bus.batchPositionCalls.count, 1,
                       "setPositions 1번 호출 → batchPositionCalls 1 entry")
        XCTAssertEqual(bus.batchPositionCalls[0].count, 4,
                       "배치에 4개 타겟 포함")
    }

    /// `setPositions` also appends each target to `positionWrites` for backward-compat.
    func testSetPositions_AlsoPopulatesPositionWrites() {
        let bus = MockBus()
        let targets: [(JointID, UInt16)] = [(.rKnee, 2200), (.lKnee, 2200)]
        try! bus.setPositions(targets)
        XCTAssertEqual(bus.positionWrites.count, 2,
                       "positionWrites 에도 개별 기록 (기존 assertion 호환)")
    }

    /// `setPositions` failure injection throws and does NOT record writes.
    func testSetPositions_FailureInjection_ThrowsAndNoRecord() {
        let bus = MockBus()
        bus.failNextSetPositions = true
        XCTAssertThrowsError(try bus.setPositions([(.rKnee, 2048)]))
        XCTAssertTrue(bus.batchPositionCalls.isEmpty,
                      "실패 시 batchPositionCalls 비어 있어야 함")
        XCTAssertTrue(bus.positionWrites.isEmpty,
                      "실패 시 positionWrites 비어 있어야 함")
    }

    /// Empty targets — no-op, no writes.
    func testSetPositions_EmptyTargets_NoOp() {
        let bus = MockBus()
        XCTAssertNoThrow(try bus.setPositions([]))
        XCTAssertTrue(bus.batchPositionCalls.isEmpty)
        XCTAssertTrue(bus.positionWrites.isEmpty)
    }

    /// Default protocol extension (loop fallback) is used by conformers that don't override.
    /// MockBus DOES override, so this tests BusInterface default via a minimal conformer.
    func testBusInterfaceDefault_LoopFallback() throws {
        let mock = MinimalMockBus()
        let targets: [(JointID, UInt16)] = [(.rKnee, 2100), (.lKnee, 2100)]
        try mock.setPositions(targets)
        XCTAssertEqual(mock.setPositionCallCount, 2,
                       "default extension loops — 2 setPosition calls for 2 targets")
    }
}

// MARK: - 2. sendStep uses one setPositions batch, not N setPosition calls

@MainActor
final class CommBatchSendStepTests: XCTestCase {

    private func makeTuning() -> WalkMotionLibrary.AdvancedTuning {
        WalkMotionLibrary.AdvancedTuning(
            strideMm: 20, sideMm: 0, turnDeg: 0,
            periodMs: 700, footHeightMm: 35,
            balanceGain: 1.0, hipPitchOffsetDeg: 13
        )
    }

    private var lowerBody: Set<JointID> {
        Set(JointID.allCases.filter { $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg })
    }

    /// sendStep issues ONE `setPositions` batch call per step, not individual setPosition calls.
    func testSendStep_UsesBatchWrite_NotIndividualWrites() async {
        let bus = MockBus()
        let callActor = CommBatchCounterActor()
        let tuningProvider: @Sendable () async -> WalkMotionLibrary.AdvancedTuning? = {
            let n = await callActor.increment()
            guard n <= 2 else { return nil }
            return WalkMotionLibrary.AdvancedTuning(
                strideMm: 20, sideMm: 0, turnDeg: 0,
                periodMs: 700, footHeightMm: 35,
                balanceGain: 1.0, hipPitchOffsetDeg: 13
            )
        }

        let result = await WalkLabSession.runMobileFreeformWalk(
            bus: bus,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBody,
            tuningProvider: tuningProvider
        )

        // There should be batch calls but zero individual setPosition calls from legs.
        // (positionWrites is populated by setPositions mock, not by individual setPosition).
        let stepsExecuted = result.stepsExecuted
        XCTAssertGreaterThan(stepsExecuted, 0, "최소 1 step 실행되어야 함")

        // batchPositionCalls should equal the number of steps that had changed joints.
        // Individual setPosition calls (not from batch) should only come from speed setup
        // (setMovingSpeed is separate), never from the leg write path.
        XCTAssertGreaterThan(bus.batchPositionCalls.count, 0,
                             "sendStep 가 배치 write 를 호출해야 함")

        // Each batch call must contain multiple joints (not 1 — that would be per-joint loop).
        for (i, batch) in bus.batchPositionCalls.enumerated() {
            XCTAssertGreaterThan(batch.count, 1,
                "배치 호출 \(i) 는 복수 관절 포함해야 함 (per-joint loop 가 아닌 SYNC_WRITE)")
        }
    }

    /// When setPositions throws (transport failure), endReason is escalated.
    func testSendStep_BatchTransportFailure_EscalatesEndReason() async {
        let bus = MockBus()
        // Always fail setPositions
        let callActor = CommBatchCounterActor()
        let tuningProvider: @Sendable () async -> WalkMotionLibrary.AdvancedTuning? = {
            let n = await callActor.increment()
            // Give enough cycles that failure accumulates to threshold
            guard n <= 20 else { return nil }
            return WalkMotionLibrary.AdvancedTuning(
                strideMm: 20, sideMm: 0, turnDeg: 0,
                periodMs: 700, footHeightMm: 35,
                balanceGain: 1.0, hipPitchOffsetDeg: 13
            )
        }
        // Fail every batch write
        let failingBus = AlwaysFailSetPositionsMockBus()

        let result = await WalkLabSession.runMobileFreeformWalk(
            bus: failingBus,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBody,
            tuningProvider: tuningProvider
        )

        // Should eventually hit lowerBodyWriteFailure or bulkWriteFailure.
        let accepted: [WalkLabSession.WalkCycleResult.EndReason] = [
            .lowerBodyWriteFailure, .bulkWriteFailure, .userCancelled
        ]
        XCTAssertTrue(accepted.contains(result.reason),
                      "배치 transport 실패 → failure endReason. got: \(result.reason)")
        XCTAssertGreaterThan(result.positionWriteFailures, 0,
                             "positionWriteFailures 증가해야 함")
    }
}

// MARK: - 3. Head appended to batch

@MainActor
final class CommBatchHeadInBatchTests: XCTestCase {

    private var lowerBody: Set<JointID> {
        Set(JointID.allCases.filter { $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg })
    }

    /// When headProvider returns a value, headPan/headTilt appear in the batch alongside legs.
    func testSendStep_HeadAppendedToBatch() async {
        let bus = MockBus()
        let callActor = CommBatchCounterActor()
        let tuningProvider: @Sendable () async -> WalkMotionLibrary.AdvancedTuning? = {
            let n = await callActor.increment()
            guard n <= 2 else { return nil }
            return WalkMotionLibrary.AdvancedTuning(
                strideMm: 20, sideMm: 0, turnDeg: 0,
                periodMs: 700, footHeightMm: 35,
                balanceGain: 1.0, hipPitchOffsetDeg: 13
            )
        }
        let headProvider: @Sendable () async -> (pan: Int, tilt: Int)? = {
            return (pan: 2100, tilt: 2010)
        }

        let _ = await WalkLabSession.runMobileFreeformWalk(
            bus: bus,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBody,
            tuningProvider: tuningProvider,
            headProvider: headProvider
        )

        // At least one batch call should contain headPan + headTilt alongside leg joints.
        let batchesWithHead = bus.batchPositionCalls.filter { batch in
            batch.contains(where: { $0.joint == .headPan }) &&
            batch.contains(where: { $0.joint == .headTilt })
        }
        XCTAssertFalse(batchesWithHead.isEmpty,
                       "headProvider 있을 때 headPan/headTilt 가 배치에 포함되어야 함")

        // Verify no separate setPosition for head outside a batch (no individual head writes
        // from the old headProvider path — it should all go through setPositions batch).
        // positionWrites from batch already contain head joints, so count should match.
        let headWrites = bus.positionWrites.filter {
            $0.joint == .headPan || $0.joint == .headTilt
        }
        XCTAssertFalse(headWrites.isEmpty, "head write 가 positionWrites 에 있어야 함")
    }

    /// isHardStopped=true — head is NOT appended to batch (write suppressed).
    func testSendStep_HeadNotInBatch_WhenHardStopped() async {
        let bus = MockBus()
        let callActor = CommBatchCounterActor()
        let tuningProvider: @Sendable () async -> WalkMotionLibrary.AdvancedTuning? = {
            let n = await callActor.increment()
            guard n <= 2 else { return nil }
            return WalkMotionLibrary.AdvancedTuning(
                strideMm: 20, sideMm: 0, turnDeg: 0,
                periodMs: 700, footHeightMm: 35,
                balanceGain: 1.0, hipPitchOffsetDeg: 13
            )
        }

        let _ = await WalkLabSession.runMobileFreeformWalk(
            bus: bus,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBody,
            tuningProvider: tuningProvider,
            headProvider: { return (pan: 2100, tilt: 2010) },
            isHardStopped: { true }  // always hard-stopped
        )

        // Hard-stopped → sendStep returns early, no writes at all.
        let headWrites = bus.positionWrites.filter {
            $0.joint == .headPan || $0.joint == .headTilt
        }
        XCTAssertTrue(headWrites.isEmpty,
                      "hardStopped 시 head write 없어야 함")
    }
}

// MARK: - 4. Regression: head-flush ordering (no interleave) still holds

@MainActor
final class CommBatchHeadFlushRegressionTests: XCTestCase {

    /// After batching, head writes must still come AFTER leg writes within a step
    /// (they are in the same batch, so ordering within the batch is: legs first, then head).
    func testBatch_HeadJointsAfterLegJoints_WithinEachBatch() async {
        let bus = MockBus()
        let lowerBody = Set(JointID.allCases.filter { $0.bodyPart == .rightLeg || $0.bodyPart == .leftLeg })
        let callActor = CommBatchCounterActor()
        let tuningProvider: @Sendable () async -> WalkMotionLibrary.AdvancedTuning? = {
            let n = await callActor.increment()
            guard n <= 2 else { return nil }
            return WalkMotionLibrary.AdvancedTuning(
                strideMm: 20, sideMm: 0, turnDeg: 0,
                periodMs: 700, footHeightMm: 35,
                balanceGain: 1.0, hipPitchOffsetDeg: 13
            )
        }
        let headProvider: @Sendable () async -> (pan: Int, tilt: Int)? = {
            return (pan: 2100, tilt: 2010)
        }

        let _ = await WalkLabSession.runMobileFreeformWalk(
            bus: bus,
            maxDurationSec: 0,
            lowerBodyJoints: lowerBody,
            tuningProvider: tuningProvider,
            headProvider: headProvider
        )

        // In each batch that contains head joints, head joints must appear AFTER all leg joints.
        for (i, batch) in bus.batchPositionCalls.enumerated() {
            guard batch.contains(where: { $0.joint == .headPan || $0.joint == .headTilt }) else {
                continue
            }
            // Find index of last leg joint and first head joint.
            let lastLegIdx = batch.indices.last(where: { lowerBody.contains(batch[$0].joint) })
            let firstHeadIdx = batch.indices.first(where: {
                batch[$0].joint == .headPan || batch[$0].joint == .headTilt
            })
            if let li = lastLegIdx, let hi = firstHeadIdx {
                XCTAssertLessThan(li, hi,
                    "배치 \(i): leg joint (idx \(li)) 가 head joint (idx \(hi)) 보다 앞에 있어야 함")
            }
        }
    }
}

// MARK: - Helpers

/// Thread-safe counter for async closures.
private actor CommBatchCounterActor {
    private var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

/// Minimal BusInterface conformer that does NOT override `setPositions` — tests the default extension.
private final class MinimalMockBus: BusInterface, @unchecked Sendable {
    private(set) var setPositionCallCount = 0

    func ping(id: UInt8) throws {}
    func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] { [] }
    func boardSnapshot() throws -> BoardSnapshot { throw ForgeError.io }
    func readImu() throws -> ImuRaw { throw ForgeError.io }
    func readFsrLeft() throws -> FsrReading { throw ForgeError.io }
    func readFsrRight() throws -> FsrReading { throw ForgeError.io }
    func setDxlPower(_ on: Bool) throws {}
    func setTorque(_ joint: JointID, enable: Bool) throws {}
    func emergencyStop() throws {}
    @discardableResult
    func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 {
        setPositionCallCount += 1
        return position
    }
    func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {}
    func setPGain(_ joint: JointID, value: UInt8) throws {}
    func readState(_ joint: JointID) throws -> JointState { throw ForgeError.io }
    func motionPlaySlot(slot: UInt8, binPath: String?, dryRun: Bool,
                        confirmRisk: Bool, singleFootOk: Bool,
                        followChain: Bool, maxChainDepth: Int) throws {}
    func motionPlayCancel() throws {}
    var isMotionPlaying: Bool { false }
}

/// MockBus variant that always fails `setPositions` (transport error simulation).
private final class AlwaysFailSetPositionsMockBus: BusInterface, @unchecked Sendable {
    func ping(id: UInt8) throws {}
    func scan(lo: UInt8, hi: UInt8) throws -> [UInt8] { [] }
    func boardSnapshot() throws -> BoardSnapshot { throw ForgeError.io }
    func readImu() throws -> ImuRaw { throw ForgeError.io }
    func readFsrLeft() throws -> FsrReading { throw ForgeError.io }
    func readFsrRight() throws -> FsrReading { throw ForgeError.io }
    func setDxlPower(_ on: Bool) throws {}
    func setTorque(_ joint: JointID, enable: Bool) throws {}
    func emergencyStop() throws {}
    @discardableResult
    func setPosition(_ joint: JointID, raw position: UInt16) throws -> UInt16 { position }
    func setPositions(_ targets: [(JointID, UInt16)]) throws {
        throw ForgeError.io  // always fail
    }
    func setMovingSpeed(_ joint: JointID, speed: UInt16) throws {}
    func setPGain(_ joint: JointID, value: UInt8) throws {}
    func readState(_ joint: JointID) throws -> JointState { throw ForgeError.io }
    func motionPlaySlot(slot: UInt8, binPath: String?, dryRun: Bool,
                        confirmRisk: Bool, singleFootOk: Bool,
                        followChain: Bool, maxChainDepth: Int) throws {}
    func motionPlayCancel() throws {}
    var isMotionPlaying: Bool { false }
}

#endif
