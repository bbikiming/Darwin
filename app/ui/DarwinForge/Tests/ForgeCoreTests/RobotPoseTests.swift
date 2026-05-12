import XCTest
@testable import ForgeCore

final class RobotPoseTests: XCTestCase {

    func testCenterAllAt2048() {
        let p = RobotPose.center
        for j in JointID.allCases {
            XCTAssertEqual(p.raw(j), 2048)
        }
    }

    func testWalkReadyDifferentFromCenter() {
        XCTAssertNotEqual(RobotPose.walkReady, .center)
    }

    func testWithSingleJointClamps() {
        let p = RobotPose.center.with(.rElbow, raw: 5000)  // 한계 밖
        XCTAssertLessThanOrEqual(p.raw(.rElbow), JointID.rElbow.rawLimits.upperBound)
    }

    func testWithMultipleJoints() {
        let p = RobotPose.center.with([
            .headPan: 2200,
            .headTilt: 1900
        ])
        XCTAssertEqual(p.raw(.headPan), 2200)
        XCTAssertEqual(p.raw(.headTilt), 1900)
        XCTAssertEqual(p.raw(.rElbow), 2048) // 다른 관절은 변경 없음
    }

    func testLerpEndpoints() {
        let a = RobotPose.center
        let b = RobotPose.walkReady
        XCTAssertEqual(a.lerp(to: b, t: 0), a)
        XCTAssertEqual(a.lerp(to: b, t: 1), b)
    }

    func testLerpMidpoint() {
        let a = RobotPose.center                                              // 모두 2048
        let b = RobotPose.center.with(.rElbow, raw: 2400)
        let mid = a.lerp(to: b, t: 0.5)
        XCTAssertEqual(mid.raw(.rElbow), 2224)  // (2048 + 2400) / 2
    }

    func testLerpClampsT() {
        let a = RobotPose.center
        let b = RobotPose.center.with(.headPan, raw: 2400)
        XCTAssertEqual(a.lerp(to: b, t: -1), a)
        XCTAssertEqual(a.lerp(to: b, t: 99), b)
    }

    func testMirrorSwapsSides() {
        let p = RobotPose.center.with([
            .rShoulderPitch: 1500,
            .lShoulderPitch: 2500
        ])
        let m = p.mirrored()
        XCTAssertEqual(m.raw(.rShoulderPitch), 2500)
        XCTAssertEqual(m.raw(.lShoulderPitch), 1500)
    }

    func testMirrorYawFlipSign() {
        // headPan 2200 → mirror should flip to 4096-2200 = 1896.
        let p = RobotPose.center.with(.headPan, raw: 2200)
        let m = p.mirrored()
        XCTAssertEqual(m.raw(.headPan), 1896)
    }

    func testCodableRoundTrip() throws {
        let p = RobotPose.walkReady
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(RobotPose.self, from: data)
        XCTAssertEqual(p, back)
    }

    // MARK: - changedJoints (P0-B regression)

    func testChangedJointsFromNilReturnsAll() {
        // 첫 동기화 (cache 없음) → 16관절 모두.
        let p = RobotPose.walkReady
        XCTAssertEqual(p.changedJoints(from: nil).count, JointID.allCases.count)
    }

    func testChangedJointsSamePoseReturnsEmpty() {
        let p = RobotPose.walkReady
        XCTAssertTrue(p.changedJoints(from: p).isEmpty)
    }

    func testChangedJointsSingleJointDifference() {
        // 슬라이더 1개만 움직인 시나리오 — 패킷 1개만 발행되어야 함.
        let prior = RobotPose.center
        let next = prior.with(.headPan, raw: 2200)
        let changed = next.changedJoints(from: prior)
        XCTAssertEqual(changed.count, 1, "P0-B: 1관절 변경 시 diff 결과는 1개만")
        XCTAssertEqual(changed.first, .headPan)
    }

    func testChangedJointsMultipleJointDifference() {
        let prior = RobotPose.center
        let next = prior.with([
            .rElbow:        2300,
            .lShoulderRoll: 1900,
            .headTilt:      2100
        ])
        let changed = Set(next.changedJoints(from: prior))
        XCTAssertEqual(changed, Set([.rElbow, .lShoulderRoll, .headTilt]))
    }

    func testChangedJointsOrderIsStable() {
        // 안정 순서 (JointID.allCases 순서) — UI에서 표시 순서 일관성.
        let prior = RobotPose.center
        let next = prior.with([.headPan: 2100, .rElbow: 2300])
        let changed = next.changedJoints(from: prior)
        // headPan은 ID 19, rElbow는 ID 5 → allCases 정의 순서 검증.
        let positions = changed.map { $0.rawValue }
        XCTAssertEqual(positions, positions.sorted { lhs, rhs in
            JointID.allCases.firstIndex { $0.rawValue == lhs }!
                < JointID.allCases.firstIndex { $0.rawValue == rhs }!
        })
    }
}
