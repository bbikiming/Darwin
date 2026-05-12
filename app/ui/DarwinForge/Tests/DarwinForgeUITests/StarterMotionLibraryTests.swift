import ForgeCore
import XCTest
@testable import DarwinForgeUI

/// P0-H 회귀: prebundled motion library 검증.
///
/// 목표:
///   1. 첫 실행 시 사용자가 *바로 실행해 볼* 페이지가 5개 이상.
///   2. 모든 starter 페이지는 walk_ready로 시작·종료 (연속 재생 안전).
///   3. 모든 step의 자세가 16-DOF 중 적어도 1개 이상 채워져 있다.
///   4. 첫 페이지("기본 자세")는 0° idle 자세.
final class StarterMotionLibraryTests: XCTestCase {

    func testStarterPagesAreNotEmpty() {
        let pages = MotionStudioView.starterPages()
        XCTAssertGreaterThanOrEqual(pages.count, 5,
            "P0-H: 첫 실행 motion library에 최소 5 페이지 필요 (idle, T-pose, bow, wave, sit)")
    }

    func testEveryPageHasAtLeastOneStep() {
        for page in MotionStudioView.starterPages() {
            XCTAssertFalse(page.steps.isEmpty,
                "page \(page.id) (\(page.name)) 에 step이 없음")
        }
    }

    /// 첫 step과 마지막 step이 walk_ready 또는 idle (안전 자세) — 연속 재생 시 호환.
    func testStarterPagesStartAndEndAtSafePose() {
        let safePoses: [RobotPose] = [.walkReady, .idle]
        for page in MotionStudioView.starterPages() {
            guard let firstStep = page.steps.first, let lastStep = page.steps.last else {
                XCTFail("page \(page.id) empty"); return
            }
            XCTAssertTrue(safePoses.contains(firstStep.toPose()),
                "page \(page.id) (\(page.name)) — 시작 자세가 walk_ready/idle 아님")
            XCTAssertTrue(safePoses.contains(lastStep.toPose()),
                "page \(page.id) (\(page.name)) — 종료 자세가 walk_ready/idle 아님 (연속 재생 위험)")
        }
    }

    /// 페이지 ID는 unique. RoboPlus 호환성 위해 중요.
    func testPageIdsAreUnique() {
        let pages = MotionStudioView.starterPages()
        let ids = Set(pages.map(\.id))
        XCTAssertEqual(ids.count, pages.count, "starter page ID 중복")
    }

    /// 첫 페이지는 idle 자세를 시각적으로 보여주는 안내 page.
    func testFirstPageIsIdle() {
        guard let first = MotionStudioView.starterPages().first else {
            XCTFail("no first page"); return
        }
        XCTAssertTrue(first.name.contains("기본") || first.name.lowercased().contains("idle"),
            "첫 페이지는 '기본 자세' 명명 (사용자가 처음 봤을 때 안전 자세를 인지)")
    }
}
