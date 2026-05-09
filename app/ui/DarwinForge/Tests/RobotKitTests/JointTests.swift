import XCTest
@testable import RobotKit

final class JointTests: XCTestCase {
    func testAllSixteenCanonicalJointsExposed() {
        // 16 distinct IDs from JointData.h: 1..6, 11..18, 19, 20.
        XCTAssertEqual(JointID.allCases.count, 16)
    }

    func testBodyPartGroupingMatchesAnatomy() {
        XCTAssertEqual(JointID.rShoulderPitch.bodyPart, .rightArm)
        XCTAssertEqual(JointID.lKnee.bodyPart, .leftLeg)
        XCTAssertEqual(JointID.headTilt.bodyPart, .head)
    }

    func testFixturesCoverBothGenerations() {
        XCTAssertEqual(Robot.darwinOne.generation, .op)
        XCTAssertEqual(Robot.darwinOne.controller, .cm730)
        XCTAssertEqual(Robot.darwinTwo.generation, .op2)
        XCTAssertEqual(Robot.darwinTwo.controller, .cm740)
    }
}
