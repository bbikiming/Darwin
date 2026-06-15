import XCTest
@testable import DarwinForgeUI
@testable import ForgeCore

/// 사이클 193 P0 #2 — Teach → Motion 전달 bridge regression guard.
final class TeachToMotionTransferTests: XCTestCase {

    // MARK: - Notification name

    /// dfTransferPoseToMotion notification name 이 존재하는지 확인.
    func testTransferPoseToMotionNotificationNameExists() {
        let name = Notification.Name.dfTransferPoseToMotion
        XCTAssertEqual(name.rawValue, "DarwinForge.TransferPoseToMotion",
                       "dfTransferPoseToMotion rawValue 가 'DarwinForge.TransferPoseToMotion' 이어야 함")
    }

    // MARK: - SynthMotionExporter.reassignPageIds bridge

    /// existingMaxId=0 일 때 reassignPageIds 가 id=1 인 단일 페이지를 반환하는지 확인.
    func testReassignPageIdsFromZeroProducesIdOne() {
        let step = MotionStep.from(pose: .center, playMs: 256, pauseMs: 0)
        let draft = MotionPage(id: 1, name: "티칭 자세 1", steps: [step])

        let result = SynthMotionExporter.reassignPageIds(
            existingMaxId: 0,
            importPages: [draft]
        )

        guard case .success(let pages) = result else {
            XCTFail("reassignPageIds 는 성공을 반환해야 함")
            return
        }
        XCTAssertEqual(pages.count, 1, "단일 페이지가 반환되어야 함")
        XCTAssertEqual(pages[0].id, 1, "existingMaxId=0 이면 첫 페이지 id=1 이어야 함")
        XCTAssertEqual(pages[0].steps.count, 1, "단일 step 이 유지되어야 함")
    }

    /// 단일 step 에 담긴 pose 가 변경 없이 전달되는지 확인.
    func testReassignPreservesSingleStep() {
        let pose = RobotPose.center
        let step = MotionStep.from(pose: pose, playMs: 256, pauseMs: 0)
        let draft = MotionPage(id: 99, name: "test", steps: [step])

        let result = SynthMotionExporter.reassignPageIds(
            existingMaxId: 0,
            importPages: [draft]
        )

        guard case .success(let pages) = result else {
            XCTFail("reassignPageIds 는 성공을 반환해야 함")
            return
        }
        XCTAssertEqual(pages[0].steps.count, 1)
        // step 이 동일한 playMs / pauseMs 유지.
        XCTAssertEqual(pages[0].steps[0].playMs, 256)
        XCTAssertEqual(pages[0].steps[0].pauseMs, 0)
    }
}
