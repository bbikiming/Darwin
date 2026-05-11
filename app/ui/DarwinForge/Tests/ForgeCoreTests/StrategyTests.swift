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
    /// ROBOTIS-OP2 e-Manual: 팔 6 + 다리 12 + 머리 2 = 20 DOF.
    func testCanonicalTwentyJoints() {
        XCTAssertEqual(JointID.allCases.count, 20)
    }

    func testHeadGrouping() {
        XCTAssertEqual(JointID.headPan.bodyPart, .head)
        XCTAssertEqual(JointID.lKnee.bodyPart, .leftLeg)
        XCTAssertEqual(JointID.rAnklePitch.bodyPart, .rightLeg)
        XCTAssertEqual(JointID.lAnkleRoll.bodyPart, .leftLeg)
    }

    /// 한 다리는 6 DOF — yaw/roll/pitch/knee/ankle pitch/ankle roll.
    func testEachLegHasSixJoints() {
        let r = JointID.allCases.filter { $0.bodyPart == .rightLeg }
        let l = JointID.allCases.filter { $0.bodyPart == .leftLeg }
        XCTAssertEqual(r.count, 6)
        XCTAssertEqual(l.count, 6)
    }

    /// e-Manual ID 값과 매핑이 정확히 일치하는지 회귀 잠금.
    func testEManualIdMapping() {
        XCTAssertEqual(JointID.rShoulderPitch.rawValue, 1)
        XCTAssertEqual(JointID.lShoulderPitch.rawValue, 2)
        XCTAssertEqual(JointID.rHipYaw.rawValue,        7)
        XCTAssertEqual(JointID.lHipYaw.rawValue,        8)
        XCTAssertEqual(JointID.rHipRoll.rawValue,       9)
        XCTAssertEqual(JointID.lHipRoll.rawValue,       10)
        XCTAssertEqual(JointID.rHipPitch.rawValue,      11)
        XCTAssertEqual(JointID.lHipPitch.rawValue,      12)
        XCTAssertEqual(JointID.rKnee.rawValue,          13)
        XCTAssertEqual(JointID.lKnee.rawValue,          14)
        XCTAssertEqual(JointID.rAnklePitch.rawValue,    15)
        XCTAssertEqual(JointID.lAnklePitch.rawValue,    16)
        XCTAssertEqual(JointID.rAnkleRoll.rawValue,     17)
        XCTAssertEqual(JointID.lAnkleRoll.rawValue,     18)
        XCTAssertEqual(JointID.headPan.rawValue,        19)
        XCTAssertEqual(JointID.headTilt.rawValue,       20)
    }
}
