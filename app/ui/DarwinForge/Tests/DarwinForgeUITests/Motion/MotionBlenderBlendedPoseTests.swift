import Foundation
import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// **사이클 58 — MotionBlender.blendedPose 실 구현 검증**.
@MainActor
final class MotionBlenderBlendedPoseTests: XCTestCase {

    func testBlendedPoseReturnsWalkingWhenIdle() {
        let blender = MotionBlender()
        let walking = RobotPose.center
        let blended = blender.blendedPose(walkingPose: walking)
        XCTAssertEqual(blended, walking, "idle → walking 그대로")
    }

    func testBlendedPoseLegacyAPIDelegates() {
        let blender = MotionBlender()
        let walking = RobotPose.center
        let blended = blender.blendedPose(walkBasePose: walking)
        XCTAssertEqual(blended, walking, "legacy API 동일")
    }

    func testBlendedPoseUpperNilReturnsWalking() {
        let blender = MotionBlender()
        blender.play(.walk(.march))
        let walking = RobotPose.center
        let blended = blender.blendedPose(walkingPose: walking)
        XCTAssertEqual(blended, walking, "lower=walk + upper=nil → walking")
    }

    func testBlendedPoseTeachReturnsSnapPose() {
        let blender = MotionBlender()
        let snap = TeachCapture.PoseSnapshot(
            name: "salute",
            pose: RobotPose.walkReady,
            capturedAt: Date()
        )
        blender.play(.teach(snap))
        let walking = RobotPose.center
        let blended = blender.blendedPose(walkingPose: walking)
        XCTAssertEqual(blended, snap.pose, "teach 자세 전신 반환")
    }
}
