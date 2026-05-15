import XCTest
@testable import ForgeCore

final class MotionDocTests: XCTestCase {

    func testStepDefaultIsAllCenter() {
        let s = MotionStep()
        XCTAssertEqual(s.positions.count, 31)
        XCTAssertTrue(s.positions.allSatisfy { $0 == 2048 })
    }

    func testStepTimeConversion() {
        let s = MotionStep(positions: Array(repeating: 2048, count: 31),
                           pauseTime: 10,
                           playTime: 32)
        XCTAssertEqual(s.pauseMs, 80)
        XCTAssertEqual(s.playMs, 256)
    }

    func testStepPoseRoundTrip() {
        var p = RobotPose.walkReady
        p = p.with(.headPan, raw: 2300)
        p = p.with(.rElbow, raw: 2700)
        let step = MotionStep.from(pose: p, playMs: 250, pauseMs: 100)
        XCTAssertEqual(step.playMs, 248)   // 250/8 = 31, *8 = 248
        XCTAssertEqual(step.pauseMs, 96)
        let back = step.toPose()
        XCTAssertEqual(back.raw(.headPan), 2300)
        XCTAssertEqual(back.raw(.rElbow), 2700)
    }

    /// **Phase G2 (Codex audit P0-2)**: ROBOTIS 공식 인덱싱 `position[joint_id]`.
    /// slot 0 은 reserved. R_SHOULDER_PITCH (rawValue=1) 는 positions[1].
    /// invalid marker (0x4000) / legacy marker (32767) 모두 toPose 에서 center 처리.
    func testStepSkipSlotsBecomeCenter() {
        var positions = Array<UInt16>(repeating: 32767, count: 31)
        positions[1] = 2300   // R_SHOULDER_PITCH (id 1) — slot 1 (공식)
        let step = MotionStep(positions: positions)
        let pose = step.toPose()
        XCTAssertEqual(pose.raw(.rShoulderPitch), 2300)
        XCTAssertEqual(pose.raw(.rElbow), 2048)        // skip marker → center
    }

    /// **Phase G2 (P0-2)**: 공식 invalid bit (0x4000) 가 set 된 슬롯도 center 로.
    func testStepInvalidBitMaskBecomesCenter() {
        var positions = Array<UInt16>(repeating: 2048, count: 31)
        positions[1] = MotionStep.invalidBitMask | 1500  // invalid bit + 값 → invalid 로 인식
        positions[20] = MotionStep.invalidBitMask        // pure invalid marker
        let step = MotionStep(positions: positions)
        let pose = step.toPose()
        XCTAssertEqual(pose.raw(.rShoulderPitch), 2048, "invalid bit set → center fallback")
        XCTAssertEqual(pose.raw(.headTilt), 2048)
    }

    /// **Phase G2 (P0-2)**: from(pose:) 가 공식 인덱싱 사용. R_S_PITCH→[1], HEAD_TILT→[20].
    /// 값은 RobotPose joint limit 안에서 골라야 — clamping 우회 X.
    func testStepFromPoseUsesOfficialIndexing() {
        var pose = RobotPose.center
        pose = pose.with(.rShoulderPitch, raw: 1500)   // -48° (R_S_PITCH ±90° 범위 안)
        pose = pose.with(.headTilt, raw: 2200)         // +13° (HEAD_TILT ±45° 범위 안)
        let step = MotionStep.from(pose: pose, playMs: 256, pauseMs: 0)
        XCTAssertEqual(step.positions[1], 1500, "R_SHOULDER_PITCH must be at positions[1] (joint_id=1)")
        XCTAssertEqual(step.positions[20], 2200, "HEAD_TILT must be at positions[20] (joint_id=20)")
        XCTAssertEqual(step.positions[0], 0, "slot 0 is reserved")
    }

    /// **Phase G2 (P0-2)**: `toPose(previous:)` 는 invalid bit 면 previous 유지 — 공식 player 동작.
    func testStepToPosePreviousHoldsOnInvalid() {
        var positions = Array<UInt16>(repeating: MotionStep.invalidBitMask, count: 31)
        positions[0] = 0
        positions[1] = 1800   // R_S_PITCH 만 valid
        let step = MotionStep(positions: positions)
        var previous = RobotPose.center
        previous = previous.with(.lShoulderPitch, raw: 2500)  // L_S_PITCH = 2500
        let pose = step.toPose(previous: previous)
        XCTAssertEqual(pose.raw(.rShoulderPitch), 1800, "valid slot 그대로")
        XCTAssertEqual(pose.raw(.lShoulderPitch), 2500, "invalid → previous 유지 (공식 Action.cpp:555)")
    }

    func testPageTotalDuration() {
        let p = MotionPage(steps: [
            MotionStep(pauseTime: 0, playTime: 32),    // 256
            MotionStep(pauseTime: 4, playTime: 16)     // 128 + 32 = 160
        ])
        XCTAssertEqual(p.totalDurationMs, 256 + 160)
    }

    func testPageEndTimeMs() {
        let p = MotionPage(steps: [
            MotionStep(pauseTime: 0, playTime: 32),    // 256
            MotionStep(pauseTime: 4, playTime: 16)     // 128 + 32 = 160
        ])
        XCTAssertEqual(p.endTimeMs(stepIndex: 0), 256)
        XCTAssertEqual(p.endTimeMs(stepIndex: 1), 256 + 160)
    }

    func testJSONRoundTripWithRustSchema() throws {
        let doc = MotionDoc(
            version: 1,
            robotGeneration: "op2",
            pages: [
                MotionPage(id: 7, name: "Hello", steps: [
                    MotionStep(pauseTime: 5, playTime: 30)
                ])
            ]
        )
        let json = try doc.toJSON(prettyPrinted: true)
        XCTAssertTrue(json.contains("\"robot_generation\""), "snake_case key 누락")
        XCTAssertTrue(json.contains("\"play_time\""), "snake_case key 누락")

        let back = try MotionDoc.from(json: json)
        XCTAssertEqual(back.pages.count, 1)
        XCTAssertEqual(back.pages.first?.name, "Hello")
        XCTAssertEqual(back.pages.first?.steps.first?.playTime, 30)
    }

    func testPageLookupById() {
        let doc = MotionDoc(pages: [
            MotionPage(id: 1, name: "A"),
            MotionPage(id: 5, name: "B")
        ])
        XCTAssertEqual(doc.page(id: 5)?.name, "B")
        XCTAssertNil(doc.page(id: 99))
    }

    // MARK: - Phase G8 (Codex audit follow-up, 2026-05-15): MotionPage.chainedPoses

    /// **Phase G8 (P1/P2)**: `chainedPoses` 가 공식 Action.cpp:554-557 의 "invalid →
    /// previous hold" 동작을 따른다. step 별로 fold 해서 raw page 의 정확한 자세 시퀀스.
    func testChainedPosesFoldsInvalidBitFromPrevious() {
        // step 1: R_S_PITCH 만 1500 으로 set, 나머지 invalid.
        var step1Positions = Array<UInt16>(repeating: MotionStep.invalidBitMask, count: 31)
        step1Positions[0] = 0
        step1Positions[1] = 1500  // R_SHOULDER_PITCH
        // step 2: HEAD_TILT 만 2200, 나머지 invalid → R_S_PITCH 는 step1 의 1500 유지.
        var step2Positions = Array<UInt16>(repeating: MotionStep.invalidBitMask, count: 31)
        step2Positions[0] = 0
        step2Positions[20] = 2200  // HEAD_TILT

        let page = MotionPage(id: 1, name: "test",
            steps: [
                MotionStep(positions: step1Positions, pauseTime: 0, playTime: 16),
                MotionStep(positions: step2Positions, pauseTime: 0, playTime: 16)
            ])
        // anchor = center, 모든 관절 2048 부터 시작.
        let poses = page.chainedPoses(startingFrom: .center)
        XCTAssertEqual(poses.count, 2)
        // Step 1: R_S_PITCH=1500 (valid), 나머지 invalid → center (2048).
        XCTAssertEqual(poses[0].raw(.rShoulderPitch), 1500, "step 1 valid slot 반영")
        XCTAssertEqual(poses[0].raw(.headTilt), 2048, "step 1 invalid HEAD → center anchor")
        // Step 2: HEAD_TILT=2200 (valid), R_S_PITCH invalid → step 1 의 1500 유지 (공식 fold).
        XCTAssertEqual(poses[1].raw(.headTilt), 2200, "step 2 valid HEAD_TILT")
        XCTAssertEqual(poses[1].raw(.rShoulderPitch), 1500,
            "step 2 invalid R_S_PITCH → step 1 자세 hold (공식 Action.cpp:555)")
    }

    /// **Phase G8 (P1/P2)**: 옛 `poses` 는 fold 안 함 — step 별 독립 toPose. 공식 의미 X.
    /// 이 테스트가 fail 하면 의도치 않은 동작 변경.
    func testPosesIsSingleStepPreviewWithoutFold() {
        var positions = Array<UInt16>(repeating: MotionStep.invalidBitMask, count: 31)
        positions[0] = 0
        positions[1] = 1500
        let step = MotionStep(positions: positions, pauseTime: 0, playTime: 16)
        let page = MotionPage(id: 1, name: "t", steps: [step, step])
        let poses = page.poses
        // 각 step 의 invalid bit 가 center (2048) 로 변환됨 — fold X.
        XCTAssertEqual(poses[1].raw(.headTilt), 2048,
            ".poses 는 fold 없이 각 step 의 invalid → center 처리 (단발 미리보기 의도)")
    }

    /// **Phase G8 (P1/P2)**: chainedPoses 가 valid 만 있는 step 시퀀스에서 anchor 까지 정확.
    func testChainedPosesAllValidStepsPropagate() {
        var pose1 = RobotPose.center
        pose1 = pose1.with(.rShoulderPitch, raw: 1500)
        var pose2 = pose1
        pose2 = pose2.with(.headTilt, raw: 2200)

        let page = MotionPage(id: 1, name: "test",
            steps: [
                MotionStep.from(pose: pose1, playMs: 256, pauseMs: 0),
                MotionStep.from(pose: pose2, playMs: 256, pauseMs: 0)
            ])
        let chained = page.chainedPoses(startingFrom: .center)
        XCTAssertEqual(chained.count, 2)
        XCTAssertEqual(chained[0].raw(.rShoulderPitch), 1500)
        XCTAssertEqual(chained[1].raw(.rShoulderPitch), 1500, "step 2 도 유지")
        XCTAssertEqual(chained[1].raw(.headTilt), 2200)
    }
}
