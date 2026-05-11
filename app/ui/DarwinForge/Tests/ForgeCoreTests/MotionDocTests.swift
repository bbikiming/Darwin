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

    func testStepSkipSlotsBecomeCenter() {
        // 32767은 사용 안 함 마커. toPose에서 2048이 되어야 한다.
        var positions = Array<UInt16>(repeating: 32767, count: 31)
        positions[0] = 2300   // R_SHOULDER_PITCH (id 1)
        let step = MotionStep(positions: positions)
        let pose = step.toPose()
        XCTAssertEqual(pose.raw(.rShoulderPitch), 2300)
        XCTAssertEqual(pose.raw(.rElbow), 2048)        // skip → center
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
}
