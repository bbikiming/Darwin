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
        // CLAUDE_NEGATIVE_JOINT_FIX_DIRECTIVE: mirrorSignFlip 이 모든 좌·우 pair (pitch 포함)
        // 에 적용된다. Rust 정합을 위해 12-bit MAX_POSITION reflect (4095 - raw) 사용.
        //   r 입장: src=lShoulderPitch=2500 → 4095-2500 = 1595.
        //   l 입장: src=rShoulderPitch=1500 → 4095-1500 = 2595.
        let p = RobotPose.center.with([
            .rShoulderPitch: 1500,
            .lShoulderPitch: 2500
        ])
        let m = p.mirrored()
        XCTAssertEqual(m.raw(.rShoulderPitch), 1595)
        XCTAssertEqual(m.raw(.lShoulderPitch), 2595)
    }

    func testMirrorYawFlipSign() {
        // headPan 2200 → mirror should reflect to 4095-2200 = 1895 (Rust reflect_12bit 와 동일).
        let p = RobotPose.center.with(.headPan, raw: 2200)
        let m = p.mirrored()
        XCTAssertEqual(m.raw(.headPan), 1895)
    }

    // MARK: - 음수 좌측 관절 / mirror 회귀 (CLAUDE_NEGATIVE_JOINT_FIX_DIRECTIVE)

    /// 종전 단방향 `0...150` 한계에서는 lElbow / lKnee / lAnklePitch 의 공식 음수 값이
    /// `RobotPose.with()` 의 clamp 로 0° 근처로 잘렸다. signed limits 적용 후엔 음수가
    /// 그대로 유지돼야 한다. 출처: `ini_pose.yaml` + motion_4096 GUI catalog 관측.
    func testWithPreservesOfficialNegativeMirrorJoints() {
        let p = RobotPose.walkReady.with([
            .lElbow:      Kinematics.raw(fromDegrees: -70),
            .lKnee:       Kinematics.raw(fromDegrees: -130),
            .lAnklePitch: Kinematics.raw(fromDegrees: -70),
            .rElbow:      Kinematics.raw(fromDegrees: -90)
        ])
        XCTAssertLessThan(p.degrees(.lElbow), -69,
            "lElbow 가 -70° 근처로 유지돼야 함 (clamp 되면 0° 쪽으로 점프)")
        XCTAssertLessThan(p.degrees(.lKnee), -129,
            "lKnee 가 -130° 근처로 유지돼야 함")
        XCTAssertLessThan(p.degrees(.lAnklePitch), -69,
            "lAnklePitch 가 -70° 근처로 유지돼야 함")
        XCTAssertLessThan(p.degrees(.rElbow), -89,
            "rElbow 도 음수가 유지돼야 함 (공식 catalog 관측 r_el min ≈ -94.7°)")
    }

    /// 공식 motion_4096 page 9 의 좌·우 mirror 관계가 `RobotPose.mirrored()` 에서
    /// 유지되는지. 종전엔 `mirrorSignFlip` 이 pitch 계열에 false 였어서 raw 가 그대로
    /// 복사됐다 — `PoseInspector` mirror mode 에서 우측 +50° 가 좌측 +50° 로 들어가는
    /// 부호 오류의 원인.
    func testMirrorWalkReadyKeepsOfficialSignedPairs() {
        let wr = RobotPose.walkReady
        let mirrored = wr.mirrored()
        // reflect 공식: raw' = 4095 - raw (Rust 정합). rawLimits clamp 으로 ±2 raw 오차 가능.
        func close(_ a: Int, _ b: Int, tol: Int = 2) -> Bool { abs(a - b) <= tol }

        XCTAssertTrue(close(mirrored.raw(.lKnee), 4095 - wr.raw(.rKnee)),
            "mirrored.lKnee=\(mirrored.raw(.lKnee)) ≈ 4095-wr.rKnee=\(4095 - wr.raw(.rKnee))")
        XCTAssertTrue(close(mirrored.raw(.rKnee), 4095 - wr.raw(.lKnee)))
        XCTAssertTrue(close(mirrored.raw(.lElbow), 4095 - wr.raw(.rElbow)))
        XCTAssertTrue(close(mirrored.raw(.rElbow), 4095 - wr.raw(.lElbow)))
        XCTAssertTrue(close(mirrored.raw(.lAnklePitch), 4095 - wr.raw(.rAnklePitch)))
        XCTAssertTrue(close(mirrored.raw(.rAnklePitch), 4095 - wr.raw(.lAnklePitch)))
        XCTAssertTrue(close(mirrored.raw(.lHipPitch), 4095 - wr.raw(.rHipPitch)))
        XCTAssertTrue(close(mirrored.raw(.rHipPitch), 4095 - wr.raw(.lHipPitch)))
        XCTAssertTrue(close(mirrored.raw(.lShoulderPitch), 4095 - wr.raw(.rShoulderPitch)))
        XCTAssertTrue(close(mirrored.raw(.rShoulderPitch), 4095 - wr.raw(.lShoulderPitch)))

        // headTilt 는 단축 (위/아래) 이라 반사하지 않음 — 부호 유지.
        XCTAssertEqual(mirrored.raw(.headTilt), wr.raw(.headTilt))
    }

    /// walkReady 는 ROBOTIS 공식 캘리브레이션 잔차 (특히 shoulder_pitch R+L=4016, ~7° 잔차)
    /// 때문에 mirror 가 identity 아님. 이것이 "의도된 비대칭" 임을 lock-in — 향후 누군가
    /// walkReady raw 를 좌·우 완벽 대칭으로 강제하면 ROBOTIS 공식과 어긋남.
    func testWalkReadyMirrorIsNotIdentity() {
        let wr = RobotPose.walkReady
        let mirrored = wr.mirrored()
        XCTAssertNotEqual(mirrored, wr,
            "walkReady 가 좌·우 완벽 대칭이면 ROBOTIS 공식 캘리브레이션 잔차가 손실됨")
        // 잔차의 주 원인 — shoulder_pitch.
        // wr.rShoulderPitch=1498 → mirror.lShoulderPitch=4095-1498=2597.
        // wr.lShoulderPitch=2518 (≠2597) → ~80 raw (7°) 잔차.
        XCTAssertNotEqual(mirrored.raw(.lShoulderPitch), wr.raw(.lShoulderPitch),
            "shoulder_pitch 잔차가 mirror 에서 노출되어야 함")
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
