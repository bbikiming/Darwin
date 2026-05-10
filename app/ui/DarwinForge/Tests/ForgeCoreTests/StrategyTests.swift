import XCTest
@testable import ForgeCore

final class StrategyTests: XCTestCase {
    func testIdleToLookingWhenActive() {
        let next = Strategy.step(from: .idle, ballPixelCount: 0, sinceKickMs: 0, abort: false)
        XCTAssertEqual(next, .lookingForBall)
    }

    func testApproachingToKickingWhenBallBig() {
        let next = Strategy.step(from: .approachingBall, ballPixelCount: 2000, sinceKickMs: 0, abort: false)
        XCTAssertEqual(next, .kicking)
    }

    func testAbortForcesIdle() {
        let next = Strategy.step(from: .approachingBall, ballPixelCount: 2000, sinceKickMs: 0, abort: true)
        XCTAssertEqual(next, .idle)
    }
}

final class WalkEngineTests: XCTestCase {
    func testTickAdvancesElapsed() {
        let e = WalkEngine()
        e.setCommand(x: 0.04, y: 0, a: 0, enabled: true)
        let f = e.tick(dtMs: 100)
        XCTAssertGreaterThan(f.elapsedMs, 99.0)
    }
}

final class JointIDTests: XCTestCase {
    func testCanonicalSixteenJoints() {
        XCTAssertEqual(JointID.allCases.count, 16)
    }

    func testHeadGrouping() {
        XCTAssertEqual(JointID.headPan.bodyPart, .head)
        XCTAssertEqual(JointID.lKnee.bodyPart, .leftLeg)
    }
}
