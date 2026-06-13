import XCTest
@testable import DarwinForgeUI

/// B2 — `WalkConflationSlot` **value-type unit** tests (cockpit-latency-hardening).
///
/// SCOPE (SDD bounce HIGH): these exercise the slot data structure in isolation —
/// multiple offers then one drain. That offer-pile-up sequence is what proves the
/// slot's *own* latest-wins + ordered-safety-lane logic. It does NOT prove the
/// production relay routing: under the actor + transport serialization,
/// `handleWalk` offers exactly one frame then drains, so the slot never holds >1
/// frame between drains. The STOP-ordered-ahead / never-dropped property *through
/// the real path* is proven separately by
/// `WalkConflationRoutingIntegrationTests.test_stopInterleavedBetweenWalkFrames_reachesSendWalkOrderedAhead`.
///
/// Invariant under test (slot unit only): latest-wins for MOVING walk velocity;
/// stop / enabled=false frames in a SEPARATE never-dropped, ORDERED lane.
/// No ms value is asserted.
final class WalkConflationSlotTests: XCTestCase {

    // MARK: - Helpers

    private func movingWalk(xMm: Double, aDeg: Double = 0) -> WalkPayload {
        WalkPayload(preset: .freeform, enabled: true,
                    xMm: xMm, yMm: 0, aDeg: aDeg, periodMs: 600,
                    footMm: 40, hipPitchDeg: 0, speedScale: 1.0)
    }

    private func stopWalk() -> WalkPayload {
        WalkPayload(preset: .stop, enabled: false,
                    xMm: 0, yMm: 0, aDeg: 0, periodMs: 600,
                    footMm: 40, hipPitchDeg: 0, speedScale: 1.0)
    }

    /// enabled=false but preset still .freeform — classifier must treat as safety.
    private func disabledWalk() -> WalkPayload {
        WalkPayload(preset: .freeform, enabled: false,
                    xMm: 0, yMm: 0, aDeg: 0, periodMs: 600,
                    footMm: 40, hipPitchDeg: 0, speedScale: 1.0)
    }

    // MARK: - test_rapidWalkFrames_onlyLatestApplied

    func test_rapidWalkFrames_onlyLatestApplied() {
        var slot = WalkConflationSlot()
        slot = slot.offering(.walk(movingWalk(xMm: 10)))
        slot = slot.offering(.walk(movingWalk(xMm: 20)))
        slot = slot.offering(.walk(movingWalk(xMm: 30)))

        let (drained, _) = slot.draining()
        XCTAssertEqual(drained.count, 1, "rapid moving frames coalesce to one")
        guard case let .walk(payload) = drained[0] else {
            return XCTFail("surviving frame must be a walk frame")
        }
        XCTAssertEqual(payload.xMm, 30, "latest moving velocity wins")
    }

    // MARK: - slot-unit ordering (NOT the production-path proof — see class doc)

    /// SLOT UNIT ONLY: a [walk,walk,STOP,walk] offer sequence into the value type
    /// keeps STOP ordered ahead of the later walk on drain. This is the data
    /// structure's contract — the real relay path is proven in
    /// WalkConflationRoutingIntegrationTests (the production routing never produces
    /// this 4-offers-1-drain sequence).
    func test_slotUnit_stopInterleavedBetweenWalkFrames_orderedAhead() {
        // [walk, walk, STOP, walk]
        var slot = WalkConflationSlot()
        slot = slot.offering(.walk(movingWalk(xMm: 10)))
        slot = slot.offering(.walk(movingWalk(xMm: 20)))
        slot = slot.offering(.safety(stopWalk()))
        slot = slot.offering(.walk(movingWalk(xMm: 30)))

        let (drained, _) = slot.draining()

        // STOP must be present.
        let stopIndex = drained.firstIndex { frame in
            if case let .safety(p) = frame { return p.preset == .stop }
            return false
        }
        XCTAssertNotNil(stopIndex, "interleaved STOP must be delivered, never dropped")

        // The surviving walk (xMm:30) must be present...
        let walkIndex = drained.firstIndex { frame in
            if case let .walk(p) = frame { return p.xMm == 30 }
            return false
        }
        XCTAssertNotNil(walkIndex, "latest walk must survive conflation")

        // ...and STOP must be ordered AHEAD of the later walk — never behind it.
        XCTAssertLessThan(stopIndex!, walkIndex!,
                          "safety STOP must be ordered before the later walk")
    }

    // MARK: - test_estopIsNeverConflated

    func test_estopIsNeverConflated() {
        // Two safety stops + walks interleaved — BOTH safety frames survive ordered.
        var slot = WalkConflationSlot()
        slot = slot.offering(.walk(movingWalk(xMm: 10)))
        slot = slot.offering(.safety(stopWalk()))
        slot = slot.offering(.walk(movingWalk(xMm: 20)))
        slot = slot.offering(.safety(stopWalk()))

        let (drained, _) = slot.draining()
        let safetyCount = drained.filter { if case .safety = $0 { return true }; return false }.count
        XCTAssertEqual(safetyCount, 2,
                       "every safety frame survives — safety lane is never coalesced")
        // The walk lane still conflates to exactly one.
        let walkCount = drained.filter { if case .walk = $0 { return true }; return false }.count
        XCTAssertEqual(walkCount, 1, "moving lane still conflates to one")
    }

    // MARK: - test_enabledFalseTreatedAsStop_notConflated

    func test_enabledFalseTreatedAsStop_notConflated() {
        // enabled=false frames are SAFETY (classified by the server), so when
        // offered as .safety they must never be conflated away.
        var slot = WalkConflationSlot()
        slot = slot.offering(.walk(movingWalk(xMm: 10)))
        slot = slot.offering(.safety(disabledWalk()))
        slot = slot.offering(.safety(disabledWalk()))

        let (drained, _) = slot.draining()
        let safetyFrames = drained.compactMap { frame -> WalkPayload? in
            if case let .safety(p) = frame { return p }
            return nil
        }
        XCTAssertEqual(safetyFrames.count, 2,
                       "enabled=false frames are safety — never coalesced")
        for p in safetyFrames {
            XCTAssertFalse(p.enabled, "disabled frame routed through safety lane")
        }
    }

    // MARK: - test_droppedWalkFrameAckBehaviorIsIntentional

    func test_droppedWalkFrameAckBehaviorIsIntentional() {
        // DECISION: conflated-away walk frames are intentionally NOT individually
        // delivered/ACKed — only the surviving latest walk reaches the robot, and
        // the slot reports how many moving frames were superseded. This makes the
        // ACK contract explicit: callers ACK the survivors drain() returns, and the
        // dropped count is the audit trail for the rest. Safety frames are never
        // counted as dropped.
        var slot = WalkConflationSlot()
        slot = slot.offering(.walk(movingWalk(xMm: 10)))   // superseded
        slot = slot.offering(.walk(movingWalk(xMm: 20)))   // superseded
        slot = slot.offering(.safety(stopWalk()))          // never dropped
        slot = slot.offering(.walk(movingWalk(xMm: 30)))   // survives

        let (drained, droppedWalkFrames) = slot.draining()

        // Two moving frames were superseded by the surviving latest walk.
        XCTAssertEqual(droppedWalkFrames, 2,
                       "superseded moving frames are counted, not silently lost")
        // Survivors = 1 safety + 1 walk.
        XCTAssertEqual(drained.count, 2)

        // After draining the slot is empty and reports zero dropped.
        let (empty, droppedAfter) = slot.draining()
        XCTAssertTrue(empty.isEmpty, "drain consumes the slot")
        XCTAssertEqual(droppedAfter, 0)
    }
}
