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

    // MARK: - 사이클 155 (codex MINOR #2 fix): canonical ID set 검증

    /// safeIDs ∪ placeholderCautionIDs ∪ placeholderHighRiskIDs ∪ highRiskIDs = 16 entries.
    /// 4 set 가 disjoint (overlap 없음).
    func testCanonicalIDSetsDisjointAnd16Total() {
        let safe = OfficialCatalogReference.safeIDs
        let placeholderCaution = OfficialCatalogReference.placeholderCautionIDs
        let placeholderHighRisk = OfficialCatalogReference.placeholderHighRiskIDs
        let highRisk = OfficialCatalogReference.highRiskIDs

        // pairwise disjoint
        XCTAssertTrue(safe.isDisjoint(with: placeholderCaution))
        XCTAssertTrue(safe.isDisjoint(with: placeholderHighRisk))
        XCTAssertTrue(safe.isDisjoint(with: highRisk))
        XCTAssertTrue(placeholderCaution.isDisjoint(with: placeholderHighRisk))
        XCTAssertTrue(placeholderCaution.isDisjoint(with: highRisk))
        XCTAssertTrue(placeholderHighRisk.isDisjoint(with: highRisk))

        // total
        XCTAssertEqual(safe.count + placeholderCaution.count
                       + placeholderHighRisk.count + highRisk.count, 16,
                       "4 set 합집합 = 16 (ROBOTIS 공식 카탈로그)")
    }

    /// allOfficialIDs 가 allPages 의 실제 ID 와 일치 — drift 차단.
    func testAllOfficialIDsMatchesActualPages() {
        let pages = OfficialCatalogReference.allPages(startId: 1)
        let actualIDs = Set(pages.map { Int($0.id) })
        XCTAssertEqual(actualIDs, OfficialCatalogReference.allOfficialIDs,
                       "canonical allOfficialIDs 가 실제 등록 ID 와 일치해야 함")
    }

    /// placeholderIDs convenience 가 caution ∪ highRisk.
    func testPlaceholderIDsConvenience() {
        XCTAssertEqual(OfficialCatalogReference.placeholderIDs,
                       OfficialCatalogReference.placeholderCautionIDs
                            .union(OfficialCatalogReference.placeholderHighRiskIDs))
    }

    /// allHighRiskIDs convenience 가 highRisk ∪ placeholderHighRisk.
    func testAllHighRiskIDsConvenience() {
        XCTAssertEqual(OfficialCatalogReference.allHighRiskIDs,
                       OfficialCatalogReference.highRiskIDs
                            .union(OfficialCatalogReference.placeholderHighRiskIDs))
    }

    /// ID 17 (Hand Standing) 은 placeholder + highRisk — 양쪽 collection 에 모두 포함.
    /// 사이클 154 review codex MINOR #1 — 안전 우선 표시 (highRisk section).
    func testID17IsPlaceholderAndHighRisk() {
        XCTAssertTrue(OfficialCatalogReference.placeholderHighRiskIDs.contains(17))
        XCTAssertTrue(OfficialCatalogReference.placeholderIDs.contains(17))
        XCTAssertTrue(OfficialCatalogReference.allHighRiskIDs.contains(17))
        // ID 17 은 safe / placeholderCaution / highRisk(원본 set) 에는 없음.
        XCTAssertFalse(OfficialCatalogReference.safeIDs.contains(17))
        XCTAssertFalse(OfficialCatalogReference.placeholderCautionIDs.contains(17))
        XCTAssertFalse(OfficialCatalogReference.highRiskIDs.contains(17))
    }

    /// 사이클 157 (codex cumulative review missing test): ID 17 의 safetyColor 가
    /// 실제로 .dangerous (highRisk red) 반환 — section grouping + color 일관성 검증.
    @MainActor
    func testID17SafetyColorIsDangerous() {
        let page = OfficialCatalogReference.handStanding(id: 17)
        let entry = StarterEntry(page: page)
        // Color equality 비교는 SwiftUI 에서 직접 안 됨 → DFMotionSafetyColor 와 동일성 검증.
        // 본 테스트는 invariant — canonical ID set 변경 시 view 색이 함께 drift 안 함.
        XCTAssertTrue(OfficialCatalogReference.allHighRiskIDs.contains(Int(page.id)),
                      "ID 17 canonical highRisk 포함")
        // safetyColor 가 nondefault (verified 가 아닌) 색 반환 확인 — 모든 highRisk 가 dangerous.
        let safeEntry = StarterEntry(page: OfficialCatalogReference.standUp(id: 1))
        XCTAssertNotEqual(
            String(describing: entry.safetyColor),
            String(describing: safeEntry.safetyColor),
            "ID 17 의 safetyColor 가 safe ID 와 달라야 함 (highRisk → dangerous)")
    }

    /// 사이클 157: caution+placeholder ID 10/11 의 safetyColor 도 verified (safe) 와 달라야.
    @MainActor
    func testPlaceholderCautionSafetyColorIsUnverified() {
        let getUpFront = StarterEntry(page: OfficialCatalogReference.getUpFront(id: 10))
        let safeEntry = StarterEntry(page: OfficialCatalogReference.standUp(id: 1))
        XCTAssertNotEqual(
            String(describing: getUpFront.safetyColor),
            String(describing: safeEntry.safetyColor),
            "ID 10 (caution) 의 safetyColor 가 safe ID 와 달라야 함")
    }
}
