import XCTest
@testable import DarwinForgeUI
import ForgeCore

/// 사이클 207 (Teach P2): PoseDeltaCalculator pure logic 검증.
///
/// # 비유
///
/// 두 사진의 픽셀 색상 차이 계산기 — 픽셀(관절)별 delta 와 전체 RMS 를 검증.
final class PoseDeltaCalculatorTests: XCTestCase {

    // MARK: - testIdenticalPosesZeroRMS

    /// 동일한 자세 두 개를 비교하면 모든 delta = 0, RMS = 0.
    func testIdenticalPosesZeroRMS() {
        let pose = RobotPose.walkReady
        let result = PoseDeltaCalculator.compare(
            baseline: pose,
            candidate: pose,
            baselineLabel: "A",
            candidateLabel: "B"
        )

        XCTAssertEqual(result.rmsDeg, 0.0, accuracy: 1e-9,
                       "동일 자세: RMS = 0")
        for delta in result.perJointDeltas {
            XCTAssertEqual(delta.deltaDeg, 0.0, accuracy: 1e-9,
                           "\(delta.jointName): delta = 0")
        }
    }

    // MARK: - testSingleJointDelta

    /// 관절 1개(rShoulderPitch)만 10° 다를 때 RMS = 10 / sqrt(N).
    func testSingleJointDelta() {
        // baseline: center pose (모든 관절 0°).
        let baseline = RobotPose.center

        // candidate: rShoulderPitch 만 raw 기반으로 10° 이동.
        // Kinematics.raw(fromDegrees: 10) 를 쓰면 정확하지만
        // 테스트는 degrees(rShoulderPitch) 를 직접 측정해 delta 검증.
        let targetRaw = Kinematics.raw(fromDegrees: 10.0)
        let candidate = baseline.with(.rShoulderPitch, raw: targetRaw)

        let result = PoseDeltaCalculator.compare(
            baseline: baseline,
            candidate: candidate,
            baselineLabel: "center",
            candidateLabel: "shifted"
        )

        // 변경된 관절의 baselineDeg ≈ 0, candidateDeg ≈ 10.
        let changed = result.perJointDeltas.first {
            $0.jointName == JointID.rShoulderPitch.name
        }
        XCTAssertNotNil(changed)
        if let changed {
            XCTAssertEqual(changed.baselineDeg, 0.0, accuracy: 0.5,
                           "baseline rShoulderPitch ≈ 0°")
            XCTAssertEqual(changed.candidateDeg, 10.0, accuracy: 0.5,
                           "candidate rShoulderPitch ≈ 10°")
            XCTAssertEqual(changed.deltaDeg, changed.candidateDeg - changed.baselineDeg,
                           accuracy: 1e-9,
                           "delta = candidate - baseline")
        }

        // RMS = sqrt(delta^2 / N) where N = JointID.allCases.count.
        let n = Double(JointID.allCases.count)
        let expectedDelta = candidate.degrees(.rShoulderPitch) - baseline.degrees(.rShoulderPitch)
        let expectedRMS = (expectedDelta * expectedDelta / n).squareRoot()
        XCTAssertEqual(result.rmsDeg, expectedRMS, accuracy: 1e-9,
                       "단일 관절 delta=\(expectedDelta)° → RMS=\(expectedRMS)°")
    }

    // MARK: - testPeakJointDetection

    /// peakJoint 는 |delta| 가 가장 큰 관절을 가리킨다.
    func testPeakJointDetection() {
        let baseline = RobotPose.center

        // rKnee: 30°, lHipPitch: 5° — peak 는 rKnee 여야 한다.
        let candidate = baseline
            .with(.rKnee, raw: Kinematics.raw(fromDegrees: 30.0))
            .with(.lHipPitch, raw: Kinematics.raw(fromDegrees: 5.0))

        let result = PoseDeltaCalculator.compare(
            baseline: baseline,
            candidate: candidate,
            baselineLabel: "center",
            candidateLabel: "multi-joint"
        )

        XCTAssertNotNil(result.peakJoint, "peak 관절이 존재해야 함")
        XCTAssertEqual(result.peakJoint?.jointName, JointID.rKnee.name,
                       "rKnee(30°)가 lHipPitch(5°)보다 큰 delta → peak")
    }

    // MARK: - testLabelsPreserved

    /// baselineLabel / candidateLabel 이 Comparison 에 그대로 보존된다.
    func testLabelsPreserved() {
        let result = PoseDeltaCalculator.compare(
            baseline: RobotPose.idle,
            candidate: RobotPose.walkReady,
            baselineLabel: "idle-label",
            candidateLabel: "walkReady-label"
        )

        XCTAssertEqual(result.baselineLabel, "idle-label",
                       "baselineLabel 보존")
        XCTAssertEqual(result.candidateLabel, "walkReady-label",
                       "candidateLabel 보존")
    }

    // MARK: - testPerJointDeltasCount

    /// perJointDeltas 개수 = JointID.allCases.count (20).
    func testPerJointDeltasCount() {
        let result = PoseDeltaCalculator.compare(
            baseline: RobotPose.center,
            candidate: RobotPose.idle,
            baselineLabel: "a",
            candidateLabel: "b"
        )
        XCTAssertEqual(result.perJointDeltas.count, JointID.allCases.count,
                       "20 관절 모두 delta 포함")
    }

    // MARK: - testJointIdAndNameConsistency

    /// jointId == JointID.rawValue, jointName == JointID.name 로 일치.
    func testJointIdAndNameConsistency() {
        let result = PoseDeltaCalculator.compare(
            baseline: RobotPose.center,
            candidate: RobotPose.center,
            baselineLabel: "x",
            candidateLabel: "y"
        )
        for (delta, joint) in zip(result.perJointDeltas, JointID.allCases) {
            XCTAssertEqual(delta.jointId, Int(joint.rawValue),
                           "\(joint.name) jointId 불일치")
            XCTAssertEqual(delta.jointName, joint.name,
                           "\(joint) jointName 불일치")
        }
    }
}
