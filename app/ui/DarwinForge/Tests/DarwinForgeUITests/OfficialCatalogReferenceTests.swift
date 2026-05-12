import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// `OfficialCatalogReference` — 16 페이지 합성에서 좌측 음수 관절값이 보존되는지 회귀.
///
/// CLAUDE_NEGATIVE_JOINT_FIX_DIRECTIVE: 종전 `Kinematics.degreeLimits` 의 단방향 `0...150`
/// 한계에서는 `lElbow / lKnee / lAnklePitch` 의 음수 값이 `RobotPose.with()` 의 자동 clamp
/// 로 0° 근처로 잘렸다. signed limits 적용 후엔 의도된 음수가 유지돼야 한다.
final class OfficialCatalogReferenceTests: XCTestCase {

    /// 페이지의 key step 자세를 반환. 한 step 페이지면 step 0, 여러 step 이면 가운데.
    private func keyPose(_ page: MotionPage) -> RobotPose {
        let idx = page.steps.count >= 3 ? page.steps.count / 2 : 0
        return page.steps[idx].toPose()
    }

    // MARK: - sitDown (Safe)

    func testSitDownKeepsLeftKneeNegative() {
        let page = OfficialCatalogReference.sitDown(id: 15)
        // key step (step 1) 의 lKnee 는 의도상 -105° 근처. clamp 되면 0° 쪽으로 점프.
        let pose = page.steps[1].toPose()
        let lKneeDeg = pose.degrees(.lKnee)
        XCTAssertLessThan(lKneeDeg, -90,
            "sitDown.lKnee=\(lKneeDeg)° 가 의도된 -105° 근처에 있어야 함 (clamp 안 됨)")
        let lAnkleDeg = pose.degrees(.lAnklePitch)
        XCTAssertLessThan(lAnkleDeg, -45,
            "sitDown.lAnklePitch=\(lAnkleDeg)° 가 의도된 -60° 근처에 있어야 함")
    }

    // MARK: - wow / oops / clapPlease (Safe — 팔 동작)

    func testWowKeepsLeftElbowNegative() {
        let page = OfficialCatalogReference.wow(id: 24)
        let pose = page.steps[1].toPose()  // cheer step.
        XCTAssertLessThan(pose.degrees(.lElbow), 0,
            "wow.lElbow 가 음수여야 함 (oneline -10° 의도)")
    }

    func testOopsKeepsLeftElbowDeepNegative() {
        let page = OfficialCatalogReference.oops(id: 27)
        let pose = page.steps[1].toPose()  // shrug.
        XCTAssertLessThan(pose.degrees(.lElbow), -50,
            "oops.lElbow 가 -70° 근처에 있어야 함")
    }

    func testClapPleaseKeepsLeftElbowNegative() {
        let page = OfficialCatalogReference.clapPlease(id: 54)
        // step 1 (apart) 와 step 2 (together) 모두 lElbow -40°.
        for step in page.steps[1...2] {
            let lElbow = step.toPose().degrees(.lElbow)
            XCTAssertLessThan(lElbow, -25,
                "clapPlease lElbow=\(lElbow)° 가 -40° 근처에 있어야 함")
        }
    }

    // MARK: - leftKick (HighRisk)

    func testLeftKickKeepsLiftKneeNegative() {
        let page = OfficialCatalogReference.leftKick(id: 13)
        // step 1 = lift (lKnee -80° 의도), step 2 = kick (lKnee -20° 의도).
        let liftPose = page.steps[1].toPose()
        XCTAssertLessThan(liftPose.degrees(.lKnee), -60,
            "leftKick lift.lKnee=\(liftPose.degrees(.lKnee))° 가 -80° 근처에 있어야 함")
        // hip pitch 도 양수 방향 (mirror — 좌발이 앞으로 swing).
        XCTAssertGreaterThan(liftPose.degrees(.lHipPitch), RobotPose.walkReady.degrees(.lHipPitch),
            "leftKick lift.lHipPitch 가 walkReady 보다 양수 방향 (mirror swing)")
    }

    // MARK: - 모든 페이지 software limits 회귀

    func testAllOfficialCatalogPosesWithinSoftwareLimits() {
        // 16 페이지 모든 step 의 모든 관절 raw 가 `JointID.rawLimits` 안에 있어야 함.
        // 종전 단방향 한계에서는 left mirror joint 가 clamp 됐다.
        let pages = OfficialCatalogReference.allPages(startId: 1)
        for page in pages {
            for (idx, step) in page.steps.enumerated() {
                let pose = step.toPose()
                for joint in JointID.allCases {
                    let raw = pose.raw(joint)
                    let limits = joint.rawLimits
                    XCTAssertTrue(limits.contains(raw),
                        "page=\(page.name) step \(idx) joint \(joint.name): raw=\(raw) outside \(limits)")
                }
            }
        }
    }
}
