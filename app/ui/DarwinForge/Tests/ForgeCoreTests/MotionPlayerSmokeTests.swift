import XCTest
@testable import ForgeCore

/// MotionPlayer는 DarwinForgeUI에 있어서 ForgeCoreTests에서는 직접 못 봄.
/// 대신 MotionDoc 모델의 보간이 정확히 동작하는지 검증.
final class MotionInterpolationTests: XCTestCase {

    func testTwoPosesLerpAt50Percent() {
        let a = RobotPose.center                                    // raw 2048
        let b = RobotPose.center.with([
            .headPan: 2400,
            .rElbow:  2200
        ])
        let mid = a.lerp(to: b, t: 0.5)
        XCTAssertEqual(mid.raw(.headPan), 2224)
        XCTAssertEqual(mid.raw(.rElbow),  2124)
    }

    func testStepEndPoseEqualsTargetPose() {
        let target = RobotPose.center.with(.rKnee, raw: 2400)
        let step = MotionStep.from(pose: target, playMs: 200, pauseMs: 0)
        let extracted = step.toPose()
        XCTAssertEqual(extracted.raw(.rKnee), 2400)
    }

    func testTimingFloorsToMultipleOf8() {
        let step = MotionStep.from(pose: .center, playMs: 257, pauseMs: 81)
        // 257/8 = 32 (floor), *8 = 256
        XCTAssertEqual(step.playMs, 256)
        // 81/8 = 10, *8 = 80
        XCTAssertEqual(step.pauseMs, 80)
    }

    func testThreePoseSequenceTotalDuration() {
        let page = MotionPage(steps: [
            MotionStep.from(pose: .walkReady, playMs: 200, pauseMs: 100),
            MotionStep.from(pose: .center,    playMs: 400, pauseMs: 0),
            MotionStep.from(pose: .walkReady, playMs: 200, pauseMs: 0)
        ])
        // 8단위 floor: 200→200, 100→96, 400→400, 200→200
        XCTAssertEqual(page.totalDurationMs, 200 + 96 + 400 + 200)
    }
}
