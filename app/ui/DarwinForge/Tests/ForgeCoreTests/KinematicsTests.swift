import XCTest
@testable import ForgeCore

final class KinematicsTests: XCTestCase {
    func testRawToDegreesCenter() {
        XCTAssertEqual(Kinematics.degrees(fromRaw: 2048), 0.0, accuracy: 1e-6)
    }

    func testRawToDegreesEnd() {
        XCTAssertEqual(Kinematics.degrees(fromRaw: 4095), 179.913, accuracy: 0.01)
        XCTAssertEqual(Kinematics.degrees(fromRaw: 0), -180.0, accuracy: 0.01)
    }

    func testDegreesRoundTrip() {
        for deg: Double in stride(from: -90, through: 90, by: 15) {
            let raw = Kinematics.raw(fromDegrees: deg)
            let back = Kinematics.degrees(fromRaw: raw)
            XCTAssertEqual(back, deg, accuracy: 0.1, "round-trip failed at \(deg)°")
        }
    }

    func testRadiansAndDegreesAgree() {
        let raw = 2560  // about +45°
        let degrees = Kinematics.degrees(fromRaw: raw)
        let radians = Kinematics.radians(fromRaw: raw)
        XCTAssertEqual(degrees, radians * 180.0 / .pi, accuracy: 1e-6)
    }

    func testRawClampedAtExtremes() {
        XCTAssertEqual(Kinematics.raw(fromDegrees: 1000), 4095)
        XCTAssertEqual(Kinematics.raw(fromDegrees: -1000), 0)
    }

    func testDegreeLimits() {
        // 좌·우 대칭 signed range — 공식 motion_4096 / ini_pose 의 좌측 음수 값 통과 보장.
        // 출처: docs/architecture/joint-conventions.md + forge-core::joint::state::JointLimits.
        XCTAssertEqual(JointID.rElbow.degreeLimits.lowerBound, -150)
        XCTAssertEqual(JointID.rElbow.degreeLimits.upperBound, 150)
        XCTAssertEqual(JointID.lElbow.degreeLimits.lowerBound, -150)
        XCTAssertEqual(JointID.lElbow.degreeLimits.upperBound, 150)
        XCTAssertEqual(JointID.rKnee.degreeLimits.lowerBound, -150)
        XCTAssertEqual(JointID.rKnee.degreeLimits.upperBound, 150)
        XCTAssertEqual(JointID.lKnee.degreeLimits.lowerBound, -150)
        XCTAssertEqual(JointID.lKnee.degreeLimits.upperBound, 150)
        XCTAssertEqual(JointID.rHipPitch.degreeLimits.lowerBound, -90)
        XCTAssertEqual(JointID.rHipPitch.degreeLimits.upperBound, 90)
        XCTAssertEqual(JointID.lHipPitch.degreeLimits.lowerBound, -90)
        XCTAssertEqual(JointID.lHipPitch.degreeLimits.upperBound, 90)
        XCTAssertEqual(JointID.rAnklePitch.degreeLimits.lowerBound, -90)
        XCTAssertEqual(JointID.rAnklePitch.degreeLimits.upperBound, 90)
        XCTAssertEqual(JointID.lAnklePitch.degreeLimits.lowerBound, -90)
        XCTAssertEqual(JointID.lAnklePitch.degreeLimits.upperBound, 90)
        XCTAssertEqual(JointID.headTilt.degreeLimits.upperBound, 45)
    }

    /// 공식 ini_pose 와 motion_4096 page 9 의 음수 좌측 관절값이 한계 안에 들어가는지.
    /// 종전 단방향 0...150 한계에서는 이 값들이 클램프 됐다.
    func testOfficialNegativeJointsAreWithinLimits() {
        // ini_pose.yaml: l_el = -30, l_knee = -130, l_ank_pitch = -70.
        XCTAssertTrue(JointID.lElbow.degreeLimits.contains(-30),
            "lElbow degreeLimits 가 공식 ini_pose l_el=-30 을 포함해야 함")
        XCTAssertTrue(JointID.lKnee.degreeLimits.contains(-130),
            "lKnee degreeLimits 가 공식 ini_pose l_knee=-130 을 포함해야 함")
        XCTAssertTrue(JointID.lAnklePitch.degreeLimits.contains(-70),
            "lAnklePitch degreeLimits 가 공식 ini_pose l_ank_pitch=-70 을 포함해야 함")
        // motion_4096 catalog 관측: r_el min ≈ -94.7°.
        XCTAssertTrue(JointID.rElbow.degreeLimits.contains(-90),
            "rElbow degreeLimits 가 공식 catalog 관측 r_el=-90 을 포함해야 함")
    }

    func testRawLimitsContainsCenter() {
        for j in JointID.allCases {
            let limits = j.rawLimits
            XCTAssertLessThanOrEqual(limits.lowerBound, 2048,
                                     "lower limit must include center for \(j)")
            XCTAssertGreaterThanOrEqual(limits.upperBound, 2048,
                                        "upper limit must include center for \(j)")
        }
    }

    func testRotationAxesGroupedByConvention() {
        XCTAssertEqual(JointID.rShoulderPitch.rotationAxis, SIMD3(0, 1, 0))
        XCTAssertEqual(JointID.rShoulderRoll.rotationAxis,  SIMD3(1, 0, 0))
        XCTAssertEqual(JointID.rHipYaw.rotationAxis,        SIMD3(0, 0, 1))
        XCTAssertEqual(JointID.headPan.rotationAxis,        SIMD3(0, 0, 1))
    }

    func testMirroredJointPairs() {
        XCTAssertEqual(JointID.rElbow.mirrored, .lElbow)
        XCTAssertEqual(JointID.lKnee.mirrored,  .rKnee)
        XCTAssertEqual(JointID.headPan.mirrored, .headPan)
    }

    func testMirrorSignFlip() {
        // 공식 motion_4096 page 9: 모든 좌·우 pair 가 중심 반사 관계.
        // headPan 도 좌우 방향이라 반사. headTilt 만 단축이라 부호 유지.
        XCTAssertTrue(JointID.rHipYaw.mirrorSignFlip)
        XCTAssertTrue(JointID.lHipYaw.mirrorSignFlip)
        XCTAssertTrue(JointID.headPan.mirrorSignFlip)

        // pitch 계열도 반사해야 한다 (이전엔 false 였던 회귀 보호).
        XCTAssertTrue(JointID.rShoulderPitch.mirrorSignFlip)
        XCTAssertTrue(JointID.lShoulderPitch.mirrorSignFlip)
        XCTAssertTrue(JointID.rElbow.mirrorSignFlip)
        XCTAssertTrue(JointID.lElbow.mirrorSignFlip)
        XCTAssertTrue(JointID.rHipPitch.mirrorSignFlip)
        XCTAssertTrue(JointID.lHipPitch.mirrorSignFlip)
        XCTAssertTrue(JointID.rKnee.mirrorSignFlip)
        XCTAssertTrue(JointID.lKnee.mirrorSignFlip)
        XCTAssertTrue(JointID.rAnklePitch.mirrorSignFlip)
        XCTAssertTrue(JointID.lAnklePitch.mirrorSignFlip)

        // 유일한 예외 — 위/아래 단축은 좌우 미러로 부호가 바뀌지 않는다.
        XCTAssertFalse(JointID.headTilt.mirrorSignFlip)
    }
}
