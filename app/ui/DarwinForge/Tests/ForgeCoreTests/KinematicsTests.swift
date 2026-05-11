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
        XCTAssertEqual(JointID.rElbow.degreeLimits.lowerBound, 0)
        XCTAssertEqual(JointID.rElbow.degreeLimits.upperBound, 150)
        XCTAssertEqual(JointID.headTilt.degreeLimits.upperBound, 45)
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
        XCTAssertTrue(JointID.rHipYaw.mirrorSignFlip)
        XCTAssertTrue(JointID.headPan.mirrorSignFlip)
        XCTAssertFalse(JointID.rElbow.mirrorSignFlip)
        XCTAssertFalse(JointID.headTilt.mirrorSignFlip)
    }
}
